import SwiftUI

/// Entirely client-side search.
///
/// Loads the full thread set once (cached + a single optional refresh from
/// the server), decrypts subjects in memory, and filters locally on every
/// keystroke. Nothing is ever sent to the server — the query, including any
/// PII the user types, stays on the device.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var threads: [ThreadRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var snippets: [String: String] = [:]
    @State private var loading = true
    @State private var openThread: ThreadRow?

    private let cache = MailCache.default
    private let net = NetworkMonitor.shared

    var body: some View {
        ZStack {
            Wallpaper()

            Group {
                if loading && threads.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    DSEmptyState(
                        systemName: "magnifyingglass",
                        title: query.isEmpty ? "Search mail" : "No matches",
                        hint: query.isEmpty
                            ? "Type a subject, sender, or recipient. Search runs entirely on this device."
                            : "Nothing in your mail matches that query."
                    )
                } else {
                    resultList
                }
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search messages")
        .navigationDestination(item: $openThread) { t in
            ThreadView(threadID: t.id)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Results

    private var filtered: [ThreadRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return threads.filter { t in
            if let subj = subjects[t.id], subj.lowercased().contains(q) { return true }
            if let snip = snippets[t.id], snip.lowercased().contains(q) { return true }
            if t.participants.contains(where: { $0.lowercased().contains(q) }) { return true }
            if let from = t.first_from_addr, from.lowercased().contains(q) { return true }
            if let hint = t.subject_hint, hint.lowercased().contains(q) { return true }
            return false
        }
    }

    private var resultList: some View {
        List {
            ForEach(filtered) { t in
                Button {
                    openThread = t
                } label: {
                    MailRow(
                        primary: senderLabel(for: t),
                        subject: subjects[t.id],
                        snippet: snippets[t.id],
                        timestamp: t.last_message_at,
                        unread: t.unread_count > 0,
                        attachments: false,
                        starred: t.has_starred
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Data

    private func load() async {
        // Combine whatever inbox / sent / all caches we have, deduplicated.
        var seed: [String: ThreadRow] = [:]
        for scope: MailCache.Scope in [.allThreads, .inboxThreads, .sentThreads] {
            for row in cache.loadThreads(scope) {
                seed[row.id] = row
            }
        }
        if !seed.isEmpty {
            threads = Array(seed.values).sorted { $0.last_message_at > $1.last_message_at }
            loading = false
            await decryptSubjects(threads)
        }

        guard net.isOnline else {
            loading = false
            return
        }

        do {
            let rows: [ThreadRow] = try await APIClient.shared.get("/api/threads?limit=200")
            threads = rows
            cache.saveThreads(rows, scope: .allThreads)
            loading = false
            await decryptSubjects(rows)
        } catch {
            loading = false
        }
    }

    private func decryptSubjects(_ rows: [ThreadRow]) async {
        guard let priv = app.priv else { return }
        var subjectOut = subjects
        var snippetOut = snippets
        for t in rows {
            if subjectOut[t.id] == nil, let subj = t.decryptedSubject(priv: priv) {
                subjectOut[t.id] = subj
            }
            if snippetOut[t.id] == nil, let prev = t.decryptedPreview(priv: priv) {
                snippetOut[t.id] = prev
            }
        }
        subjects = subjectOut
        snippets = snippetOut
    }

    private func senderLabel(for t: ThreadRow) -> String {
        let ownAddresses = Set((app.me?.addresses ?? []).map { $0.lowercased() })
        if t.first_direction == .in, let from = t.first_from_addr { return from }
        let others = t.participants.filter { !ownAddresses.contains($0.lowercased()) }
        let list = others.isEmpty ? t.participants : others
        if list.isEmpty { return "(no participants)" }
        let head = list.prefix(3).joined(separator: ", ")
        return head + (list.count > 3 ? " +\(list.count - 3)" : "")
    }
}
