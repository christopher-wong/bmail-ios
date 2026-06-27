import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var app
    @State private var threads: [ThreadRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var snippets: [String: String] = [:]
    @State private var loading = true
    @State private var loadError: String?
    @State private var openThread: ThreadRow?
    @State private var showCompose = false
    @State private var unsubscribe: (() -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                Wallpaper()

                Group {
                    if loading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage = loadError {
                        DSEmptyState(
                            systemName: "exclamationmark.triangle",
                            title: "Something went wrong",
                            hint: errorMessage
                        )
                    } else if threads.isEmpty {
                        DSEmptyState(
                            systemName: "tray",
                            title: "Inbox empty",
                            hint: "Emails routed to your address(es) will appear here."
                        )
                    } else {
                        threadList
                    }
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Compose", systemImage: "square.and.pencil") {
                        showCompose = true
                    }
                }
            }
            .navigationDestination(item: $openThread) { t in
                ThreadView(threadID: t.id)
            }
            .sheet(isPresented: $showCompose) {
                ComposeView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thickMaterial)
                    .presentationCornerRadius(DS.Radius.sheet)
            }
            .task { await load() }
            .refreshable { await load() }
            .onAppear { subscribeIfNeeded() }
            .onDisappear { unsubscribe?(); unsubscribe = nil }
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
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        DSHaptics.notifyWarning()
                        Task { await delete(t) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sender label

    private func senderLabel(for t: ThreadRow) -> String {
        let ownAddresses = Set((app.me?.addresses ?? []).map { $0.lowercased() })
        if t.first_direction == .in, let from = t.first_from_addr { return from }
        let others = t.participants.filter { !ownAddresses.contains($0.lowercased()) }
        let list = others.isEmpty ? t.participants : others
        if list.isEmpty { return "(no participants)" }
        let head = list.prefix(3).joined(separator: ", ")
        return head + (list.count > 3 ? " +\(list.count - 3)" : "")
    }

    // MARK: - Data

    private func load() async {
        loadError = nil

        // Seed from cache so offline still has a list to show.
        let cached = MailCache.default.loadThreads(.inboxThreads)
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
            let rows: [ThreadRow] = try await APIClient.shared.get("/api/threads?limit=100&inbound_only=1")
            threads = rows
            MailCache.default.saveThreads(rows, scope: .inboxThreads)
            loading = false
            await decryptSubjects(rows)
        } catch {
            if threads.isEmpty {
                loadError = (error as? LocalizedError)?.errorDescription ?? "Load failed"
            }
            loading = false
        }
    }

    private func delete(_ t: ThreadRow) async {
        let prev = threads
        threads.removeAll { $0.id == t.id }
        do {
            _ = try await APIClient.shared.deleteThread(id: t.id)
            DSHaptics.impactMedium()
        } catch {
            threads = prev
            loadError = (error as? LocalizedError)?.errorDescription ?? "Delete failed"
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

    private func subscribeIfNeeded() {
        guard unsubscribe == nil else { return }
        unsubscribe = RealtimeClient.shared.subscribe { ev in
            let shouldReload: Bool
            switch ev {
            case .messageNew(let dir, _, _): shouldReload = (dir == .in)
            case .messageDelete, .threadDelete: shouldReload = true
            default: shouldReload = false
            }
            if shouldReload { Task { await load() } }
        }
    }
}
