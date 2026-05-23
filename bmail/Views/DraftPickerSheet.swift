import SwiftUI

/// Drafts list, presented from the compose sheet. Tapping a row loads that
/// draft into the open compose form (replacing whatever is currently being
/// composed). Swiping discards the row.
struct DraftPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let currentDraftID: String?
    let onPick: (DraftRow) -> Void

    @State private var drafts: [DraftRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "DRAFTS", trailing: {
                    AnyView(
                        Button("DONE") { dismiss() }.monoButton()
                    )
                })

                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if drafts.isEmpty {
                    EmptyStateView(
                        title: "no drafts",
                        hint: "your autosaved drafts will show up here"
                    )
                } else {
                    List {
                        ForEach(drafts) { d in
                            DraftPickerRow(
                                draft: d,
                                subject: subjects[d.id],
                                isCurrent: d.id == currentDraftID
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(d) }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                        .onDelete(perform: discard)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.inverseInk)
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func load() async {
        loading = true
        do {
            let rows: [DraftRow] = try await APIClient.shared.get("/api/drafts")
            drafts = rows.sorted { $0.updated_at > $1.updated_at }
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

    private func discard(at offsets: IndexSet) {
        let ids = offsets.map { drafts[$0].id }
        drafts.remove(atOffsets: offsets)
        Task {
            for id in ids {
                _ = try? await APIClient.shared.delete("/api/drafts/\(id)")
            }
        }
    }
}

private struct DraftPickerRow: View {
    let draft: DraftRow
    let subject: String?
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(draft.to_addrs.first ?? "(no recipient)")
                    .font(.mono(.subheadline, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isCurrent {
                    Text("CURRENT")
                        .font(.mono(.caption2, weight: .medium))
                        .tracking(0.8)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: 1)
                        )
                        .foregroundStyle(Theme.mute)
                }
                Spacer()
                Text(RelativeDate.format(draft.updated_at))
                    .font(.mono(.caption))
                    .foregroundStyle(Theme.mute)
            }
            Text(subject ?? "(no subject)")
                .font(.mono(.footnote))
                .foregroundStyle(subject == nil ? Theme.mute : Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) { Hairline() }
    }
}
