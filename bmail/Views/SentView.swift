import SwiftUI

struct SentView: View {
    @Environment(AppModel.self) private var app
    @State private var threads: [ThreadRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var loading = true
    @State private var openThread: ThreadRow?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "SENT")

                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if threads.isEmpty {
                    EmptyStateView(title: "no sent messages")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(threads) { t in
                                ThreadRowView(
                                    thread: t,
                                    subject: subjects[t.id],
                                    ownAddresses: Set((app.me?.addresses ?? []).map { $0.lowercased() })
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { openThread = t }
                                Hairline()
                            }
                        }
                    }
                }
            }
            .background(Theme.inverseInk)
            .task { await load() }
            .refreshable { await load() }
            .navigationDestination(item: $openThread) { t in
                ThreadView(threadID: t.id)
            }
        }
    }

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
