import Foundation
import Observation

/// Mirrors web/src/lib/realtime.ts. One WebSocket to `/api/realtime`,
/// auto-reconnect with exponential backoff, ping/pong heartbeat.
///
/// Auth piggy-backs on the same cookie that APIClient already holds — we
/// open the socket through APIClient.shared.session so the cookie is sent
/// on the upgrade request.
@Observable
@MainActor
final class RealtimeClient {
    static let shared = RealtimeClient()

    // Public state for views that want to surface connection status.
    private(set) var isConnected: Bool = false

    private var task: URLSessionWebSocketTask?
    private var receiveLoopID: UUID?
    private var stopped: Bool = true
    private var reconnectAttempt: Int = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var lastPongAt: Date = .distantPast

    private var handlers: [UUID: (RealtimeEvent) -> Void] = [:]

    private let pingInterval: Duration = .seconds(25)
    private let pongTimeout: Duration = .seconds(75)

    private init() {}

    private var url: URL {
        // APIClient.baseURL is https://mail.middleseat.vc → wss:// + /api/realtime.
        var comps = URLComponents(url: APIClient.shared.baseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = "/api/realtime"
        return comps.url!
    }

    // MARK: - Public

    func start() {
        stopped = false
        if task != nil || reconnectTask != nil { return }
        connect()
    }

    func stop() {
        stopped = true
        reconnectAttempt = 0
        reconnectTask?.cancel(); reconnectTask = nil
        pingTask?.cancel(); pingTask = nil
        task?.cancel(with: .normalClosure, reason: "client-stop".data(using: .utf8))
        task = nil
        isConnected = false
        receiveLoopID = nil
    }

    @discardableResult
    func subscribe(_ handler: @escaping (RealtimeEvent) -> Void) -> () -> Void {
        let id = UUID()
        handlers[id] = handler
        return { [weak self] in
            Task { @MainActor [weak self] in self?.handlers.removeValue(forKey: id) }
        }
    }

    // MARK: - Internals

    private func connect() {
        guard !stopped else { return }
        let t = APIClient.shared.session.webSocketTask(with: url)
        self.task = t
        let loopID = UUID()
        self.receiveLoopID = loopID
        t.resume()
        lastPongAt = .now
        // Don't flip isConnected / reset backoff yet: the upgrade hasn't been
        // proven; an immediate close would otherwise both lie about
        // connectivity and erase the backoff counter, producing a hot
        // reconnect loop on a server that always rejects.
        startHeartbeat()
        Task { await self.receiveLoop(loopID: loopID, task: t) }
    }

    private func receiveLoop(loopID: UUID, task: URLSessionWebSocketTask) async {
        var sawFirstFrame = false
        while !stopped, self.receiveLoopID == loopID {
            do {
                let msg = try await task.receive()
                if !sawFirstFrame {
                    // First successful receive = upgrade really worked. Now
                    // it's safe to mark connected and clear the backoff.
                    sawFirstFrame = true
                    self.isConnected = true
                    self.reconnectAttempt = 0
                }
                switch msg {
                case .string(let s):
                    self.lastPongAt = .now
                    if s == "pong" { continue }
                    if let data = s.data(using: .utf8),
                       let ev = try? JSONDecoder().decode(RealtimeEvent.self, from: data) {
                        for h in handlers.values { h(ev) }
                    }
                case .data(let d):
                    self.lastPongAt = .now
                    if let ev = try? JSONDecoder().decode(RealtimeEvent.self, from: d) {
                        for h in handlers.values { h(ev) }
                    }
                @unknown default:
                    continue
                }
            } catch {
                // Socket failed/closed — schedule a reconnect.
                self.scheduleReconnect()
                return
            }
        }
    }

    private func startHeartbeat() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pingInterval)
                if Task.isCancelled { return }
                if let t = self.task, t.state == .running {
                    try? await t.send(.string("ping"))
                }
                // Watchdog: if we've gone too long without a pong, force-reconnect.
                if Date.now.timeIntervalSince(self.lastPongAt) > Double(self.pongTimeout.components.seconds) {
                    self.task?.cancel(with: .goingAway, reason: "heartbeat-timeout".data(using: .utf8))
                    return
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        isConnected = false
        pingTask?.cancel(); pingTask = nil
        task = nil
        receiveLoopID = nil
        if reconnectTask != nil { return }

        // 1s, 2s, 4s, 8s, 16s, 30s thereafter, plus up to 1s jitter.
        let base = min(30.0, pow(2.0, Double(reconnectAttempt)))
        let jitter = Double.random(in: 0..<1.0)
        let delay = base + jitter
        reconnectAttempt = min(reconnectAttempt + 1, 5)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                self.connect()
            }
        }
    }
}

// MARK: - Event model

/// Matches the web client's RealtimeEvent union. Decoded permissively —
/// unrecognized event types decode as `.unknown` so a new server-side event
/// doesn't crash old clients.
enum RealtimeEvent: Decodable, Sendable {
    case messageNew(direction: Direction, msgID: String, threadID: String?)
    case messageRead(msgID: String, read: Bool)
    case messageStar(msgID: String, starred: Bool)
    case messageDelete(msgID: String, threadID: String?)
    case threadDelete(threadID: String)
    case draftUpsert(draftID: String, updatedAt: Int64)
    case draftDelete(draftID: String)
    case unknown(String)

    private enum CodingKeys: String, CodingKey {
        case type, direction, msg_id, thread_id, read, starred, draft_id, updated_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "message.new":
            let dirRaw = (try? c.decode(String.self, forKey: .direction)) ?? "in"
            let dir = Direction(rawValue: dirRaw) ?? .in
            self = .messageNew(
                direction: dir,
                msgID: (try? c.decode(String.self, forKey: .msg_id)) ?? "",
                threadID: try? c.decode(String.self, forKey: .thread_id)
            )
        case "message.read":
            self = .messageRead(
                msgID: (try? c.decode(String.self, forKey: .msg_id)) ?? "",
                read: (try? c.decode(Bool.self, forKey: .read)) ?? true
            )
        case "message.star":
            self = .messageStar(
                msgID: (try? c.decode(String.self, forKey: .msg_id)) ?? "",
                starred: (try? c.decode(Bool.self, forKey: .starred)) ?? false
            )
        case "message.delete":
            self = .messageDelete(
                msgID: (try? c.decode(String.self, forKey: .msg_id)) ?? "",
                threadID: try? c.decode(String.self, forKey: .thread_id)
            )
        case "thread.delete":
            self = .threadDelete(threadID: (try? c.decode(String.self, forKey: .thread_id)) ?? "")
        case "draft.upsert":
            self = .draftUpsert(
                draftID: (try? c.decode(String.self, forKey: .draft_id)) ?? "",
                updatedAt: (try? c.decode(Int64.self, forKey: .updated_at)) ?? 0
            )
        case "draft.delete":
            self = .draftDelete(draftID: (try? c.decode(String.self, forKey: .draft_id)) ?? "")
        default:
            self = .unknown(type)
        }
    }
}
