import Foundation
import os.log

/// Disk-backed cache of the encrypted list payloads we already fetched.
///
/// The decrypted plaintext never touches disk — only the ciphertext rows the
/// server returned. On launch, views can render from the cache immediately
/// (no spinner), and when the network is down `SearchView` and the list
/// screens can still show last-known content.
///
/// One JSON file per scope in `<Caches>/mail-cache/`.
struct MailCache: Sendable {

    enum Scope: String {
        case inboxThreads = "inbox-threads"
        case sentThreads  = "sent-threads"
        case drafts       = "drafts"
        case allThreads   = "all-threads"
    }

    static let `default`: MailCache = {
        let root = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mail-cache", isDirectory: true)
        return MailCache(rootURL: root)
    }()

    let rootURL: URL

    private static let log = Logger(subsystem: "com.bmail", category: "MailCache")

    // MARK: - Threads

    func loadThreads(_ scope: Scope) -> [ThreadRow] {
        load(scope, as: [ThreadRow].self) ?? []
    }

    func saveThreads(_ rows: [ThreadRow], scope: Scope) {
        save(rows, scope: scope)
    }

    // MARK: - Drafts

    func loadDrafts() -> [DraftRow] {
        load(.drafts, as: [DraftRow].self) ?? []
    }

    func saveDrafts(_ rows: [DraftRow]) {
        save(rows, scope: .drafts)
    }

    // MARK: - Generic

    private func load<T: Decodable>(_ scope: Scope, as _: T.Type) -> T? {
        let url = fileURL(for: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.log.warning("MailCache: corrupt \(scope.rawValue, privacy: .public): \(error, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, scope: Scope) {
        do {
            try ensureRoot()
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL(for: scope), options: [.atomic])
        } catch {
            Self.log.error("MailCache: save \(scope.rawValue, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func fileURL(for scope: Scope) -> URL {
        rootURL.appendingPathComponent("\(scope.rawValue).json")
    }

    private func ensureRoot() throws {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }
}
