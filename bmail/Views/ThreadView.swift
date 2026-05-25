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

    // MARK: - Navigation title

    private var navigationTitle: String {
        // Use the subject of the first message if available, else fallback.
        if let first = messages.first,
           let d = decrypted[first.id],
           let subj = d.subject, !subj.isEmpty {
            return subj
        }
        return "Thread"
    }

    var body: some View {
        ZStack {
            Wallpaper()

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = loadError {
                DSEmptyState(
                    systemName: "exclamationmark.triangle",
                    title: "Something went wrong",
                    hint: errorMessage
                )
            } else {
                messageScrollView
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar { trailingMenu; bottomBar }
        .toolbarBackground(.thinMaterial, for: .bottomBar)
        .task { await load() }
        .sheet(item: $replyState) { rs in
            ComposeView(reply: rs)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.thickMaterial)
                .presentationCornerRadius(DS.Radius.sheet)
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .onAppear { subscribeIfNeeded() }
        .onDisappear { unsubscribe?(); unsubscribe = nil }
    }

    // MARK: - Message scroll view

    private var messageScrollView: some View {
        ScrollView {
            LazyVStack(spacing: DS.Space.m) {
                ForEach(messages) { m in
                    MessageCard(
                        message: m,
                        decrypted: decrypted[m.id],
                        attachments: attachmentsByMessage[m.id] ?? [],
                        onReply: { startReply(to: m) },
                        onDownload: { att in await downloadAndShare(att, on: m) }
                    )
                    .contextMenu {
                        Button {
                            Task { await toggleStarred(m) }
                        } label: {
                            Label(
                                m.starred ? "Unstar" : "Star",
                                systemImage: m.starred ? "star.slash" : "star"
                            )
                        }

                        Button {
                            Task { await toggleRead(m) }
                        } label: {
                            Label(
                                m.read ? "Mark as unread" : "Mark as read",
                                systemImage: m.read ? "envelope.badge" : "envelope.open"
                            )
                        }

                        Divider()

                        Button(role: .destructive) {
                            Task { await deleteMessage(m) }
                        } label: {
                            Label("Delete message", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            // Extra bottom padding so last card clears the bottom toolbar.
            .padding(.bottom, 60)
        }
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var trailingMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    // Star all (placeholder — no bulk-star API today)
                } label: {
                    Label("Star", systemImage: "star")
                }

                Button {
                    Task {
                        if let last = messages.last { await toggleRead(last) }
                    }
                } label: {
                    Label("Mark as unread", systemImage: "envelope.badge")
                }

                Divider()

                Button(role: .destructive) {
                    Task { await deleteThread() }
                } label: {
                    Label("Delete thread", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button("Archive", systemImage: "archivebox") {
                // Archive action — wired to API when endpoint lands.
            }

            Spacer()

            Button("Move", systemImage: "folder") {
                // Move action placeholder.
            }

            Spacer()

            Button("Trash", systemImage: "trash") {
                Task { await deleteThread() }
            }
            .tint(.red)

            Spacer()

            Button("Reply", systemImage: "arrowshape.turn.up.left.fill") {
                if let last = messages.last { startReply(to: last) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func startReply(to m: MessageRow) {
        let subj = decrypted[m.id]?.subject ?? ""
        let prefix = subj.lowercased().hasPrefix("re:") ? "" : "Re: "
        replyState = ReplyState(
            messageId: m.message_id ?? m.id,
            toAddrs: [m.from_addr],
            subject: prefix + subj
        )
    }

    // MARK: - Data

    private func load() async {
        loading = true
        loadError = nil
        do {
            let ms: [MessageRow] = try await APIClient.shared.get("/api/threads/\(threadID)")
            messages = ms
            loading = false
            await decrypt(ms)
            await loadAttachments(ms)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Load failed"
            loading = false
        }
    }

    private func decrypt(_ ms: [MessageRow]) async {
        guard let priv = app.priv else { return }
        var out: [String: DecryptedMessage] = [:]
        for m in ms {
            var d = DecryptedMessage()
            if let blob = Data(b64u: m.subject_ct_b64) {
                d.subject = try? Crypto.openSealedString(blob, priv: priv)
            }
            if let blob = Data(b64u: m.body_ct_b64) {
                d.body = try? Crypto.openSealedString(blob, priv: priv)
            }
            out[m.id] = d
        }
        decrypted = out
    }

    private func loadAttachments(_ ms: [MessageRow]) async {
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
                return DecodedAttachment(id: row.id, mime: row.mime, sizeBytes: row.size_bytes, filename: name)
            }
        }
        attachmentsByMessage = out
    }

    private func deleteThread() async {
        do {
            _ = try await APIClient.shared.deleteThread(id: threadID)
            DSHaptics.impactMedium()
            dismiss()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Delete failed"
        }
    }

    private func deleteMessage(_ m: MessageRow) async {
        let prev = messages
        messages.removeAll { $0.id == m.id }
        if messages.isEmpty {
            do {
                try await APIClient.shared.deleteMessage(id: m.id)
                DSHaptics.impactMedium()
                dismiss()
            } catch {
                messages = prev
                loadError = (error as? LocalizedError)?.errorDescription ?? "Delete failed"
            }
            return
        }
        do {
            try await APIClient.shared.deleteMessage(id: m.id)
        } catch {
            messages = prev
            loadError = (error as? LocalizedError)?.errorDescription ?? "Delete failed"
        }
    }

    private func toggleStarred(_ m: MessageRow) async {
        do { try await APIClient.shared.patchMessage(id: m.id, starred: !m.starred) }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? "Update failed" }
    }

    private func toggleRead(_ m: MessageRow) async {
        do { try await APIClient.shared.patchMessage(id: m.id, read: !m.read) }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? "Update failed" }
    }

    private func downloadAndShare(_ att: DecodedAttachment, on _: MessageRow) async {
        do {
            let raw = try await AttachmentService.shared.download(id: att.id)
            let bytes: Data = {
                guard let priv = app.priv, raw.count >= 32 + 24 + 16 else { return raw }
                return (try? Crypto.openSealedBox(raw, priv: priv)) ?? raw
            }()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bmail-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = att.filename.replacingOccurrences(of: "/", with: "_")
            let dest = dir.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
            try bytes.write(to: dest, options: .atomic)
            shareURL = dest
        } catch {
            loadError = "Download failed: \(error.localizedDescription)"
        }
    }

    private func subscribeIfNeeded() {
        guard unsubscribe == nil else { return }
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

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - MessageCard

private struct MessageCard: View {
    let message: MessageRow
    let decrypted: ThreadView.DecryptedMessage?
    let attachments: [ThreadView.DecodedAttachment]
    let onReply: () -> Void
    let onDownload: (ThreadView.DecodedAttachment) async -> Void

    @State private var downloading: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {

            // MARK: Encryption indicator
            DSEncryptionPill()

            // MARK: Sender header
            HStack(alignment: .top, spacing: DS.Space.m) {
                DSAvatar(initials: initials(from: message.from_addr), size: .row)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.from_addr)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !message.to_addrs.isEmpty {
                        Text("To \(message.to_addrs.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                Text(RelativeDate.format(
                    message.received_at == 0 ? message.sent_at : message.received_at
                ))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DS.Color.inkFaint)
            }

            Divider()

            // MARK: Subject
            if let subj = decrypted?.subject, !subj.isEmpty {
                Text(subj)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            // MARK: Body
            if let body = decrypted?.body, !body.isEmpty {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            // MARK: Attachments
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Attachments")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.Color.inkFaint)
                        .textCase(nil)

                    ForEach(attachments) { att in
                        attachmentChip(att)
                    }
                }
                .padding(.top, DS.Space.xs)
            }

            // MARK: Reply button
            HStack {
                Spacer()
                Button("Reply", systemImage: "arrowshape.turn.up.left.fill", action: onReply)
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
            }
            .padding(.top, DS.Space.xs)
        }
        .padding(DS.Space.l)
        .glassCard(radius: DS.Radius.card)
    }

    private func attachmentChip(_ att: ThreadView.DecodedAttachment) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "doc.fill")
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(att.filename)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(byteCount(att.sizeBytes))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if downloading.contains(att.id) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Open") {
                    Task {
                        downloading.insert(att.id)
                        await onDownload(att)
                        downloading.remove(att.id)
                    }
                }
                .font(.callout)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }

    private func byteCount(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    private func initials(from raw: String) -> String {
        let name: String
        if let lt = raw.firstIndex(of: "<") {
            name = String(raw[raw.startIndex..<lt]).trimmingCharacters(in: .whitespaces)
        } else {
            name = raw
        }
        let parts = name.split(separator: " ").map(String.init)
        if parts.count >= 2, let f = parts[0].first, let s = parts[1].first {
            return "\(f)\(s)".uppercased()
        }
        let localPart = name.split(separator: "@").first.map(String.init) ?? name
        return String(localPart.prefix(2)).uppercased()
    }
}
