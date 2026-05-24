import SwiftUI
import UIKit

struct ThreadView: View {
    let threadID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [MessageRow] = []
    @State private var decrypted: [String: DecryptedMessage] = [:]
    @State private var attachmentsByMessage: [String: [DecodedAttachment]] = [:]
    @State private var loading = true
    @State private var loadError: String?
    @State private var replyState: ReplyState?
    @State private var shareURL: URL?
    @State private var unsubscribe: (() -> Void)?

    struct DecryptedMessage {
        var subject: String?
        var body: String?
    }

    struct DecodedAttachment: Identifiable, Hashable {
        let id: String
        let mime: String
        let sizeBytes: Int64
        var filename: String
    }

    struct ReplyState: Identifiable {
        let id = UUID()
        let messageId: String
        let toAddrs: [String]
        let subject: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text("‹ BACK")
                        .font(.mono(.caption, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(Theme.ink)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to thread list")
                Text("THREAD")
                    .font(.mono(12, .medium))
                    .tracking(1.5)
                Text(threadID)
                    .font(.mono(11))
                    .foregroundStyle(Theme.mute)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    Task { await deleteThread() }
                } label: {
                    Text("DELETE")
                        .font(.mono(.caption, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(Theme.ink)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete thread")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = loadError {
                EmptyStateView(title: e)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { m in
                            MessageCard(
                                message: m,
                                decrypted: decrypted[m.id],
                                attachments: attachmentsByMessage[m.id] ?? [],
                                onReply: { startReply(to: m) },
                                onDownload: { att in await downloadAndShare(att, on: m) }
                            )
                            .contextMenu {
                                Button(m.starred ? "Unstar" : "Star") {
                                    Task { await toggleStarred(m) }
                                }
                                Button(m.read ? "Mark as unread" : "Mark as read") {
                                    Task { await toggleRead(m) }
                                }
                                Button("Delete message", role: .destructive) {
                                    Task { await deleteMessage(m) }
                                }
                            }
                            Hairline()
                        }
                    }
                }
            }
        }
        .background(Theme.inverseInk)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(item: $replyState) { rs in
            ComposeView(reply: rs)
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .onAppear {
            if unsubscribe == nil {
                unsubscribe = RealtimeClient.shared.subscribe { ev in
                    let shouldReload: Bool
                    switch ev {
                    case .messageNew(_, _, let tid): shouldReload = (tid == nil || tid == threadID)
                    case .messageDelete(_, let tid): shouldReload = (tid == nil || tid == threadID)
                    case .messageRead, .messageStar: shouldReload = true
                    case .threadDelete(let tid): shouldReload = (tid == threadID)
                    default: shouldReload = false
                    }
                    if shouldReload { Task { await load() } }
                }
            }
        }
        .onDisappear {
            unsubscribe?(); unsubscribe = nil
        }
    }

    private func startReply(to m: MessageRow) {
        let subj = decrypted[m.id]?.subject ?? ""
        let prefix = subj.lowercased().hasPrefix("re:") ? "" : "re: "
        replyState = ReplyState(
            messageId: m.message_id ?? m.id,
            toAddrs: [m.from_addr],
            subject: prefix + subj
        )
    }

    private func load() async {
        loading = true
        do {
            let ms: [MessageRow] = try await APIClient.shared.get("/api/threads/\(threadID)")
            self.messages = ms
            self.loading = false
            await decrypt(ms)
            await loadAttachments(ms)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "load failed"
            loading = false
        }
    }

    private func decrypt(_ ms: [MessageRow]) async {
        guard let priv = app.priv else { return }
        var out: [String: DecryptedMessage] = [:]
        for m in ms {
            var d = DecryptedMessage()
            if let blob = Data(b64u: m.subject_ct_b64) {
                d.subject = (try? Crypto.openSealedString(blob, priv: priv)) ?? nil
            }
            if let blob = Data(b64u: m.body_ct_b64) {
                d.body = (try? Crypto.openSealedString(blob, priv: priv)) ?? nil
            }
            out[m.id] = d
        }
        self.decrypted = out
    }

    private func loadAttachments(_ ms: [MessageRow]) async {
        // Fan out fetches concurrently, then decrypt filenames on main.
        var rowsByMessage: [String: [AttachmentRow]] = [:]
        await withTaskGroup(of: (String, [AttachmentRow]).self) { group in
            for m in ms {
                group.addTask {
                    let rows = (try? await AttachmentService.shared.list(forMessageID: m.id)) ?? []
                    return (m.id, rows)
                }
            }
            for await (mid, rows) in group { rowsByMessage[mid] = rows }
        }

        let priv = app.priv
        var out: [String: [DecodedAttachment]] = [:]
        for (mid, rows) in rowsByMessage {
            out[mid] = rows.map { row in
                var name = row.r2_key.split(separator: "/").last.map(String.init) ?? "attachment"
                if let priv, let ct = row.filename_ct_b64, let blob = Data(b64u: ct),
                   let n = try? Crypto.openSealedString(blob, priv: priv) {
                    name = n
                }
                return DecodedAttachment(
                    id: row.id,
                    mime: row.mime,
                    sizeBytes: row.size_bytes,
                    filename: name
                )
            }
        }
        self.attachmentsByMessage = out
    }

    private func deleteThread() async {
        do {
            _ = try await APIClient.shared.deleteThread(id: threadID)
            dismiss()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "delete failed"
        }
    }

    private func deleteMessage(_ m: MessageRow) async {
        let prev = messages
        messages.removeAll { $0.id == m.id }
        if messages.isEmpty {
            // Last message in the thread — dismiss and let realtime clear the row.
            do {
                try await APIClient.shared.deleteMessage(id: m.id)
                dismiss()
            } catch {
                messages = prev
                loadError = (error as? LocalizedError)?.errorDescription ?? "delete failed"
            }
            return
        }
        do {
            try await APIClient.shared.deleteMessage(id: m.id)
        } catch {
            messages = prev
            loadError = (error as? LocalizedError)?.errorDescription ?? "delete failed"
        }
    }

    private func toggleStarred(_ m: MessageRow) async {
        let next = !m.starred
        do { try await APIClient.shared.patchMessage(id: m.id, starred: next) }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? "patch failed" }
    }

    private func toggleRead(_ m: MessageRow) async {
        let next = !m.read
        do { try await APIClient.shared.patchMessage(id: m.id, read: next) }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? "patch failed" }
    }

    private func downloadAndShare(_ att: DecodedAttachment, on _: MessageRow) async {
        do {
            let raw = try await AttachmentService.shared.download(id: att.id)
            // Inbound attachments arrive sealed; outbound (sender's at-rest copy) is plaintext.
            // Try seal-open first, fall back to raw if it doesn't look like a sealed envelope.
            let bytes: Data = {
                guard let priv = app.priv, raw.count >= 32 + 24 + 16 else { return raw }
                return (try? Crypto.openSealedBox(raw, priv: priv)) ?? raw
            }()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bmail-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = att.filename.replacingOccurrences(of: "/", with: "_")
            let dest = dir.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
            try bytes.write(to: dest, options: .atomic)
            self.shareURL = dest
        } catch {
            self.loadError = "download failed: \(error.localizedDescription)"
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct MessageCard: View {
    let message: MessageRow
    let decrypted: ThreadView.DecryptedMessage?
    let attachments: [ThreadView.DecodedAttachment]
    let onReply: () -> Void
    let onDownload: (ThreadView.DecodedAttachment) async -> Void
    @State private var downloading: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                directionTag
                Text(message.from_addr)
                    .font(.mono(13, .medium))
                Spacer()
                Text(RelativeDate.format(message.received_at == 0 ? message.sent_at : message.received_at))
                    .font(.mono(11))
                    .foregroundStyle(Theme.mute)
            }

            if !message.to_addrs.isEmpty {
                HStack(spacing: 6) {
                    Text("to")
                        .font(.mono(10))
                        .foregroundStyle(Theme.mute)
                    Text(message.to_addrs.joined(separator: ", "))
                        .font(.mono(11))
                        .foregroundStyle(Theme.mute)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let subj = decrypted?.subject, !subj.isEmpty {
                Text(subj)
                    .font(.mono(15, .medium))
            } else {
                Text("[encrypted subject]")
                    .font(.mono(12))
                    .foregroundStyle(Theme.mute)
            }

            if let body = decrypted?.body {
                Text(body)
                    .font(.mono(13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text("[encrypted body]")
                    .font(.mono(12))
                    .foregroundStyle(Theme.mute)
            }

            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("attachments")
                        .monoLabel()
                    ForEach(attachments) { att in
                        attachmentRow(att)
                    }
                }
                .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("REPLY ▸", action: onReply)
                    .monoButton()
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func attachmentRow(_ att: ThreadView.DecodedAttachment) -> some View {
        HStack(spacing: 8) {
            Text(att.filename)
                .font(.mono(12))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(byteCount(att.sizeBytes))
                .font(.mono(10))
                .foregroundStyle(Theme.mute)
            Spacer()
            if downloading.contains(att.id) {
                ProgressView()
            } else {
                Button("OPEN ▸") {
                    Task {
                        downloading.insert(att.id)
                        await onDownload(att)
                        downloading.remove(att.id)
                    }
                }
                .monoButton()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private func byteCount(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    private var directionTag: some View {
        Text(label)
            .font(.mono(9, .medium))
            .tracking(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private var label: String {
        switch message.direction {
        case .in: return "IN"
        case .out: return "OUT"
        case .draft: return "DRAFT"
        }
    }
}
