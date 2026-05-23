import SwiftUI

struct DraftsView: View {
    @Environment(AppModel.self) private var app
    @State private var drafts: [DraftRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var loading = true
    @State private var resumingDraft: DraftRow?
    @State private var unsubscribe: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "DRAFTS")

                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if drafts.isEmpty {
                    EmptyStateView(title: "no drafts")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(drafts) { d in
                                DraftRowView(draft: d, subject: subjects[d.id], onDiscard: { discard(d.id) })
                                    .contentShape(Rectangle())
                                    .onTapGesture { resumingDraft = d }
                                Hairline()
                            }
                        }
                    }
                }
            }
            .background(Theme.inverseInk)
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $resumingDraft) { d in ComposeView(resumeDraft: d) }
            .onAppear {
                if unsubscribe == nil {
                    unsubscribe = RealtimeClient.shared.subscribe { ev in
                        switch ev {
                        case .draftUpsert, .draftDelete:
                            Task { await load() }
                        default:
                            break
                        }
                    }
                }
            }
            .onDisappear { unsubscribe?(); unsubscribe = nil }
        }
    }

    private func load() async {
        loading = true
        do {
            let rows: [DraftRow] = try await APIClient.shared.get("/api/drafts")
            drafts = rows
            loading = false
            await decryptSubjects(rows)
        } catch {
            loading = false
        }
    }

    private func decryptSubjects(_ rows: [DraftRow]) async {
        guard let priv = app.priv else { return }
        var out: [String: String] = [:]
        for d in rows {
            guard let ct = d.subject_ct_b64, let blob = Data(b64u: ct) else { continue }
            if let s = try? Crypto.openSealedString(blob, priv: priv) { out[d.id] = s }
        }
        subjects = out
    }

    private func discard(_ id: String) {
        drafts.removeAll { $0.id == id }
        Task {
            _ = try? await APIClient.shared.delete("/api/drafts/\(id)")
        }
    }
}

private struct DraftRowView: View {
    let draft: DraftRow
    let subject: String?
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.to_addrs.first ?? "(no recipient)")
                .font(.mono(14, .medium))
            Text(subject ?? "(no subject)")
                .font(.mono(13))
                .foregroundStyle(subject == nil ? Theme.mute : Theme.ink)
                .lineLimit(1)
            HStack {
                Text(RelativeDate.format(draft.updated_at))
                    .font(.mono(11))
                    .foregroundStyle(Theme.mute)
                Spacer()
                Button("DISCARD", action: onDiscard).monoButton()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
