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
    @State private var expandedIDs: Set<String> = []
    /// Last message id we auto-expanded, so realtime reloads only auto-expand a
    /// genuinely new latest message rather than fighting the user's toggles.
    @State private var lastExpandedAnchor: String?
    @State private var shareURL: URL?
    @State private var unsubscribe: (() -> Void)?
    /// Guards the one-time scroll-to-latest when a thread first opens.
    @State private var didInitialScroll = false

    struct DecryptedMessage {
        var subject: String?
        var body: String?
        var bodyHTML: String?
        var snippet: String?
    }

    struct DecodedAttachment: Identifiable, Hashable {
        let id: String
        let mime: String
        let sizeBytes: Int64
        var filename: String
    }

    struct ReplyState: Identifiable {
        let id = UUID()
        /// In-reply-to message id. Nil for a forward (a fresh message).
        let messageId: String?
        let toAddrs: [String]
        let ccAddrs: [String]
        let subject: String
        var bodyPrefill: String = ""
        var isForward: Bool = false
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
        .toolbar { trailingMenu }
        // Hide the parent TabView's tab bar while reading a thread so our
        // bottom control bar isn't drawn under it.
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if !loading && loadError == nil {
                bottomControlBar
            }
        }
        .task {
            await app.loadImageSettingsIfNeeded()
            await load()
        }
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DS.Space.m) {
                    ForEach(messages) { m in
                        MessageCard(
                            message: m,
                            decrypted: decrypted[m.id],
                            attachments: attachmentsByMessage[m.id] ?? [],
                            isExpanded: expandedIDs.contains(m.id),
                            canReplyAll: canReplyAll(m),
                            onToggleExpand: { toggleExpand(m) },
                            onReply: { startReply(to: m, all: false) },
                            onReplyAll: { startReply(to: m, all: true) },
                            onDownload: { att in await downloadAndShare(att, on: m) }
                        )
                        .contextMenu {
                            Button {
                                startReply(to: m, all: false)
                            } label: {
                                Label("Reply", systemImage: "arrowshape.turn.up.left")
                            }

                            if canReplyAll(m) {
                                Button {
                                    startReply(to: m, all: true)
                                } label: {
                                    Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                                }
                            }

                            Button {
                                startForward(m)
                            } label: {
                                Label("Forward", systemImage: "arrowshape.turn.up.right")
                            }

                            Divider()

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
            }
            // Open on the latest message so it fills the screen rather than the
            // re-quoted history above it.
            .onAppear { scrollToLatest(proxy) }
        }
    }

    /// Scroll so the newest message sits at the top of the viewport. Runs once
    /// per thread open; the collapsed history above keeps a stable height, so a
    /// single deferred scroll lands correctly.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll, let last = messages.last else { return }
        didInitialScroll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(last.id, anchor: .top)
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

    /// A single unified control bar pinned to the bottom, instead of four
    /// separate floating glass circles drawn over the message content.
    private var bottomControlBar: some View {
        HStack(spacing: DS.Space.m) {
            controlButton("Archive", systemImage: "archivebox") {
                // Archive action — wired to API when endpoint lands.
            }

            Spacer(minLength: 0)

            controlButton("Move", systemImage: "folder") {
                // Move action placeholder.
            }

            Spacer(minLength: 0)

            controlButton("Trash", systemImage: "trash", tint: .red) {
                Task { await deleteThread() }
            }

            Spacer(minLength: 0)

            if let last = messages.last {
                Menu {
                    Button {
                        startReply(to: last, all: false)
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    if canReplyAll(last) {
                        Button {
                            startReply(to: last, all: true)
                        } label: {
                            Label("Reply all", systemImage: "arrowshape.turn.up.left.2")
                        }
                    }
                    Button {
                        startForward(last)
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                } label: {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: Circle())
                } primaryAction: {
                    startReply(to: last, all: false)
                }
                .accessibilityLabel("Reply")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.xs)
    }

    private func controlButton(
        _ title: String,
        systemImage: String,
        tint: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Actions

    private func toggleExpand(_ m: MessageRow) {
        withAnimation(.snappy(duration: 0.22)) {
            if expandedIDs.contains(m.id) {
                expandedIDs.remove(m.id)
            } else {
                expandedIDs.insert(m.id)
            }
        }
    }

    private var myAddresses: Set<String> {
        Set((app.me?.addresses ?? []).map { canonicalAddr($0) })
    }

    /// Reply-all is only meaningful when there's more than one other party
    /// besides me across From / To / Cc.
    private func canReplyAll(_ m: MessageRow) -> Bool {
        var others = Set<String>()
        others.insert(canonicalAddr(m.from_addr))
        for a in m.to_addrs + m.cc_addrs { others.insert(canonicalAddr(a)) }
        others.subtract(myAddresses)
        others.remove("")
        return others.count > 1
    }

    private func startReply(to m: MessageRow, all: Bool) {
        let subj = decrypted[m.id]?.subject ?? ""
        let prefix = subj.lowercased().hasPrefix("re:") ? "" : "Re: "
        let mine = myAddresses
        let iSentThis = mine.contains(canonicalAddr(m.from_addr))

        var to: [String]
        var cc: [String] = []
        if iSentThis {
            // Replying to my own message keeps the original audience.
            to = m.to_addrs
            if all { cc = m.cc_addrs }
        } else {
            to = [m.from_addr]
            if all {
                to += m.to_addrs
                cc = m.cc_addrs
            }
        }

        // Drop my own addresses, de-duplicate case-insensitively, and never
        // repeat a To recipient in Cc.
        to = dedupeAddrs(to, excluding: mine)
        cc = dedupeAddrs(cc, excluding: mine.union(to.map { canonicalAddr($0) }))

        replyState = ReplyState(
            messageId: m.message_id ?? m.id,
            toAddrs: to,
            ccAddrs: all ? cc : [],
            subject: prefix + subj
        )
    }

    private func startForward(_ m: MessageRow) {
        let d = decrypted[m.id]
        let subj = d?.subject ?? ""
        let prefix = subj.lowercased().hasPrefix("fwd:") ? "" : "Fwd: "
        let bodyText: String = {
            if let b = d?.body, !b.isEmpty { return b.looksLikeHTML ? b.strippingHTML : b }
            if let h = d?.bodyHTML, !h.isEmpty { return h.strippingHTML }
            return ""
        }()
        var quoted = "\n\n---------- Forwarded message ----------\n"
        quoted += "From: \(m.from_addr)\n"
        if !m.to_addrs.isEmpty { quoted += "To: \(m.to_addrs.joined(separator: ", "))\n" }
        if !subj.isEmpty { quoted += "Subject: \(subj)\n" }
        quoted += "\n" + bodyText
        replyState = ReplyState(
            messageId: nil,
            toAddrs: [],
            ccAddrs: [],
            subject: prefix + subj,
            bodyPrefill: quoted,
            isForward: true
        )
    }

    /// Lowercased bare email, unwrapping a `Name <email>` form for comparison.
    private func canonicalAddr(_ raw: String) -> String {
        var s = raw
        if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt {
            s = String(s[s.index(after: lt)..<gt])
        }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func dedupeAddrs(_ xs: [String], excluding: Set<String>) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs {
            let trimmed = x.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let c = canonicalAddr(trimmed)
            if excluding.contains(c) { continue }
            if seen.insert(c).inserted { out.append(trimmed) }
        }
        return out
    }

    // MARK: - Data

    private func load() async {
        loading = true
        loadError = nil
        do {
            let ms: [MessageRow] = try await APIClient.shared.get("/api/threads/\(threadID)")
            messages = ms
            // Expand the latest message; older ones stay collapsed. Re-runs on
            // realtime reloads expand a newly-arrived latest message too, while
            // preserving the user's manual toggles on existing messages.
            if let last = ms.last, last.id != lastExpandedAnchor {
                expandedIDs.insert(last.id)
                lastExpandedAnchor = last.id
            }
            loading = false
            await decrypt(ms)
            await loadAttachments(ms)
            await markUnreadAsRead()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Load failed"
            loading = false
        }
    }

    /// Mark every inbound, unread message in this thread as read.
    ///
    /// Standard email-app behaviour: opening a thread implies you've read it.
    /// Updates the local state first so the bold "unread" sender styling
    /// disappears instantly, then fires the PATCH calls in parallel. Errors
    /// are best-effort silenced — a transient network blip shouldn't make the
    /// thread regress to "unread" in the UI, and the next inbox refresh from
    /// the server will reconcile any divergence.
    private func markUnreadAsRead() async {
        let targets = messages.enumerated().compactMap { idx, m -> (Int, String)? in
            (m.direction == .in && !m.read) ? (idx, m.id) : nil
        }
        guard !targets.isEmpty else { return }

        for (idx, _) in targets { messages[idx].read = true }

        await withTaskGroup(of: Void.self) { group in
            for (_, msgID) in targets {
                group.addTask {
                    _ = try? await APIClient.shared.patchMessage(id: msgID, read: true)
                }
            }
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
            if let ct = m.body_html_ct_b64, let blob = Data(b64u: ct) {
                d.bodyHTML = try? Crypto.openSealedString(blob, priv: priv)
            }
            if let ct = m.snippet_ct_b64, let blob = Data(b64u: ct) {
                d.snippet = (try? Crypto.openSealedString(blob, priv: priv))?.strippingHTML
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
    let isExpanded: Bool
    let canReplyAll: Bool
    let onToggleExpand: () -> Void
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onDownload: (ThreadView.DecodedAttachment) async -> Void

    @State private var downloading: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if isExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .padding(DS.Space.l)
        .glassCard(radius: DS.Radius.card)
        .contentShape(Rectangle())
    }

    // MARK: - Collapsed

    private var collapsedContent: some View {
        Button(action: onToggleExpand) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                DSAvatar(initials: initials(from: message.from_addr), size: .row)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.from_addr)
                        .font(.callout.weight(message.read ? .regular : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: DS.Space.s)

                trailingMeta
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expandedContent: some View {
        DSEncryptionPill()

        // Sender header — tap to collapse.
        Button(action: onToggleExpand) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                DSAvatar(initials: initials(from: message.from_addr), size: .row)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.from_addr)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !message.to_addrs.isEmpty {
                        Text(recipientLine("To", message.to_addrs))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if !message.cc_addrs.isEmpty {
                        Text(recipientLine("Cc", message.cc_addrs))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: DS.Space.s)

                trailingMeta
            }
        }
        .buttonStyle(.plain)

        Divider()

        // MARK: Subject
        if let subj = decrypted?.subject, !subj.isEmpty {
            Text(subj)
                .font(.headline)
                .foregroundStyle(.primary)
        }

        // MARK: Body
        bodyView

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

        // MARK: Reply actions
        HStack(spacing: DS.Space.s) {
            Spacer()
            if canReplyAll {
                Button("Reply all", systemImage: "arrowshape.turn.up.left.2", action: onReplyAll)
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
            }
            Button("Reply", systemImage: "arrowshape.turn.up.left.fill", action: onReply)
                .buttonStyle(.bordered)
                .tint(.accentColor)
        }
        .padding(.top, DS.Space.xs)
    }

    // MARK: - Body (renders HTML even when it lands in the plain-text field)

    @ViewBuilder
    private var bodyView: some View {
        if let html = decrypted?.bodyHTML, !html.isEmpty {
            MessageBodyView(html: html, senderDomain: message.from_addr.emailHostDomain)
        } else if let body = decrypted?.body, !body.isEmpty {
            if body.looksLikeHTML {
                MessageBodyView(html: body, senderDomain: message.from_addr.emailHostDomain)
            } else {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Shared bits

    private var trailingMeta: some View {
        HStack(spacing: DS.Space.xs) {
            if message.starred {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            if !attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkFaint)
            }
            Text(RelativeDate.format(
                message.received_at == 0 ? message.sent_at : message.received_at
            ))
            .font(.footnote.monospacedDigit())
            .foregroundStyle(DS.Color.inkFaint)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DS.Color.inkFaint)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
    }

    /// One-line preview for the collapsed state: server snippet first, then a
    /// stripped-down version of whatever body we have.
    private var previewText: String {
        if let s = decrypted?.snippet, !s.isEmpty { return s }
        if let b = decrypted?.body, !b.isEmpty { return b.strippingHTML }
        if let h = decrypted?.bodyHTML, !h.isEmpty { return h.strippingHTML }
        return "(no preview)"
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

    /// A short one-line summary of recipients: up to two names, then "+N",
    /// so multiple addresses don't get truncated mid-string.
    private func recipientLine(_ prefix: String, _ addrs: [String]) -> String {
        let names = addrs.map(displayName)
        switch names.count {
        case 0: return prefix
        case 1: return "\(prefix) \(names[0])"
        case 2: return "\(prefix) \(names[0]), \(names[1])"
        default: return "\(prefix) \(names[0]), \(names[1]) +\(names.count - 2)"
        }
    }

    /// A display label for a recipient: the name from a `Name <email>` form,
    /// otherwise the bare email address.
    private func displayName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if let lt = t.firstIndex(of: "<") {
            let name = t[t.startIndex..<lt]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
            if let gt = t.firstIndex(of: ">"), t.index(after: lt) < gt {
                return String(t[t.index(after: lt)..<gt])
            }
        }
        return t
    }
}
