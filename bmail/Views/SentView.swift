import SwiftUI

struct SentView: View {
    @Environment(AppModel.self) private var app
    @State private var threads: [ThreadRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var snippets: [String: String] = [:]
    @State private var loading = true
    @State private var openThread: ThreadRow?

    var body: some View {
        NavigationStack {
            ZStack {
                Wallpaper()

                Group {
                    if loading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if threads.isEmpty {
                        DSEmptyState(
                            systemName: "paperplane",
                            title: "No sent messages"
                        )
                    } else {
                        threadList
                    }
                }
            }
            .navigationTitle("Sent")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(item: $openThread) { t in
                ThreadView(threadID: t.id)
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: - Thread list

    private var threadList: some View {
        List {
            ForEach(threads) { t in
                Button {
                    openThread = t
                } label: {
                    MailRow(
                        primary: recipientLabel(for: t),
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

    // MARK: - Recipient label

    private func recipientLabel(for t: ThreadRow) -> String {
        let ownAddresses = Set((app.me?.addresses ?? []).map { $0.lowercased() })
        let others = t.participants.filter { !ownAddresses.contains($0.lowercased()) }
        let list = others.isEmpty ? t.participants : others
        if list.isEmpty { return "(no recipients)" }
        let head = list.prefix(3).joined(separator: ", ")
        return head + (list.count > 3 ? " +\(list.count - 3)" : "")
    }

    // MARK: - Data

    private func load() async {
        let cached = MailCache.default.loadThreads(.sentThreads)
        if !cached.isEmpty {
            threads = cached
            loading = false
            await decryptSubjects(cached)
        } else {
            loading = true
        }

        guard NetworkMonitor.shared.isOnline else {
            loading = false
            return
        }

        do {
            let rows: [ThreadRow] = try await APIClient.shared.get("/api/threads?limit=100&outbound_only=1")
            threads = rows
            MailCache.default.saveThreads(rows, scope: .sentThreads)
            loading = false
            await decryptSubjects(rows)
        } catch {
            loading = false
        }
    }

    private func decryptSubjects(_ rows: [ThreadRow]) async {
        guard let priv = app.priv else { return }
        var subjectOut: [String: String] = [:]
        var snippetOut: [String: String] = [:]
        for t in rows {
            if let subj = t.decryptedSubject(priv: priv) { subjectOut[t.id] = subj }
            if let prev = t.decryptedPreview(priv: priv) { snippetOut[t.id] = prev }
        }
        subjects = subjectOut
        snippets = snippetOut
    }
}
