import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var app
    @State private var threads: [ThreadRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var loading = true
    @State private var loadError: String?
    @State private var openThread: ThreadRow?
    @State private var unsubscribe: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(
                    title: "INBOX",
                    subtitle: app.me?.addresses.joined(separator: ", ")
                )

                content
            }
            .background(Theme.inverseInk)
            .task { await load() }
            .refreshable { await load() }
            .navigationDestination(item: $openThread) { t in
                ThreadView(threadID: t.id)
            }
            .onAppear {
                if unsubscribe == nil {
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
            .onDisappear {
                unsubscribe?(); unsubscribe = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = loadError {
            EmptyStateView(title: e)
        } else if threads.isEmpty {
            EmptyStateView(title: "inbox is empty", hint: "emails routed to your address(es) will appear here.")
        } else {
            List {
                ForEach(threads) { t in
                    ThreadRowView(
                        thread: t,
                        subject: subjects[t.id],
                        ownAddresses: Set((app.me?.addresses ?? []).map { $0.lowercased() })
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { openThread = t }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.inverseInk)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await delete(t) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .overlay(alignment: .bottom) { Hairline() }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.inverseInk)
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            let rows: [ThreadRow] = try await APIClient.shared.get("/api/threads?limit=100&inbound_only=1")
            self.threads = rows
            self.loading = false
            await decryptSubjects(rows)
        } catch {
            self.loadError = (error as? LocalizedError)?.errorDescription ?? "load failed"
            self.loading = false
        }
    }

    private func delete(_ t: ThreadRow) async {
        // Optimistic remove; realtime push will reconcile on other clients.
        let prev = threads
        threads.removeAll { $0.id == t.id }
        do {
            _ = try await APIClient.shared.deleteThread(id: t.id)
        } catch {
            threads = prev
            loadError = (error as? LocalizedError)?.errorDescription ?? "delete failed"
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
        self.subjects = out
    }
}

struct ThreadRowView: View {
    let thread: ThreadRow
    let subject: String?
    let ownAddresses: Set<String>
    @ScaledMetric(relativeTo: .body) private var senderColumn: CGFloat = 200

    var label: String {
        if thread.first_direction == .in, let from = thread.first_from_addr { return from }
        let others = thread.participants.filter { !ownAddresses.contains($0.lowercased()) }
        let list = others.isEmpty ? thread.participants : others
        if list.isEmpty { return "(no participants)" }
        let head = list.prefix(3).joined(separator: ", ")
        let extra = list.count > 3 ? " +\(list.count - 3)" : ""
        return head + extra
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.mono(14, thread.unread_count > 0 ? .bold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: senderColumn, alignment: .leading)

            HStack(spacing: 6) {
                if let s = subject, !s.isEmpty {
                    Text(s)
                        .font(.mono(14))
                        .lineLimit(1)
                } else {
                    Text("[encrypted]")
                        .font(.mono(12))
                        .foregroundStyle(Theme.mute)
                }
                if thread.has_starred {
                    Chip("★")
                }
                if thread.message_count > 1 {
                    Chip("\(thread.message_count)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(RelativeDate.format(thread.last_message_at))
                .font(.mono(11))
                .foregroundStyle(Theme.mute)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [label]
        if let s = subject, !s.isEmpty { parts.append(s) }
        else { parts.append("encrypted") }
        if thread.unread_count > 0 { parts.append("unread") }
        if thread.message_count > 1 { parts.append("\(thread.message_count) messages") }
        parts.append(RelativeDate.format(thread.last_message_at))
        return parts.joined(separator: ", ")
    }
}

struct Chip: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.mono(10))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: () -> Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.mono(12, .medium))
                    .tracking(1.5)
                if let s = subtitle, !s.isEmpty {
                    Text(s)
                        .font(.mono(11))
                        .foregroundStyle(Theme.mute)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline()
        }
    }
}

struct EmptyStateView: View {
    let title: String
    var hint: String? = nil
    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.mono(14))
                .foregroundStyle(Theme.ink)
            if let h = hint {
                Text(h)
                    .font(.mono(11))
                    .foregroundStyle(Theme.mute)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
