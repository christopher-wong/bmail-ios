import SwiftUI

struct SentView: View {
    @Environment(AppModel.self) private var app
    @State private var threads: [ThreadRow] = []
    @State private var subjects: [String: String] = [:]
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
                        snippet: nil,
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
        loading = true
        do {
            let rows: [ThreadRow] = try await APIClient.shared.get("/api/threads?limit=100&outbound_only=1")
            threads = rows
            loading = false
            await decryptSubjects(rows)
        } catch {
            loading = false
        }
    }

    private func decryptSubjects(_ rows: [ThreadRow]) async {
        guard let priv = app.priv else { return }
        var out: [String: String] = [:]
        for t in rows {
            guard let s = t.first_subject_ct_b64, let blob = Data(b64u: s) else { continue }
            if let plaintext = try? Crypto.openSealedString(blob, priv: priv) {
                out[t.id] = plaintext
            }
        }
        subjects = out
    }
}
