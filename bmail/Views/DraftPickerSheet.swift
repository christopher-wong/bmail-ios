import SwiftUI

/// Drafts list presented from the compose sheet. Tapping a row loads that
/// draft into the open compose form. Swiping discards the draft.
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
            ZStack {
                // Wallpaper visible through the thick-material sheet background.
                Wallpaper()

                Group {
                    if loading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if drafts.isEmpty {
                        DSEmptyState(
                            systemName: "doc.text",
                            title: "No drafts",
                            hint: "Your autosaved drafts will show up here."
                        )
                    } else {
                        draftList
                    }
                }
            }
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thickMaterial)
        .presentationCornerRadius(DS.Radius.sheet)
    }

    // MARK: - Draft list

    private var draftList: some View {
        List {
            ForEach(drafts) { d in
                Button {
                    onPick(d)
                } label: {
                    PickerDraftRow(
                        draft: d,
                        subject: subjects[d.id],
                        isCurrent: d.id == currentDraftID
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        discardOne(d)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Data

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

    private func discardOne(_ d: DraftRow) {
        let id = d.id
        drafts.removeAll { $0.id == id }
        Task {
            _ = try? await APIClient.shared.delete("/api/drafts/\(id)")
        }
    }
}

// MARK: - Picker row

private struct PickerDraftRow: View {
    let draft: DraftRow
    let subject: String?
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            DSAvatar(initials: initials(from: draft.to_addrs.first ?? ""), size: .row)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(recipientLabel)
                        .font(.callout.weight(.regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }

                    Spacer(minLength: 0)

                    Text(RelativeDate.format(draft.updated_at))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(DS.Color.inkFaint)
                }

                if let subj = subject, !subj.isEmpty {
                    Text(subj)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("(no subject)")
                        .font(.subheadline)
                        .foregroundStyle(DS.Color.inkFaint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
    }

    private var recipientLabel: String {
        if draft.to_addrs.isEmpty { return "(no recipient)" }
        let head = draft.to_addrs.prefix(2).joined(separator: ", ")
        return head + (draft.to_addrs.count > 2 ? " +\(draft.to_addrs.count - 2)" : "")
    }

    private func initials(from raw: String) -> String {
        let localPart = raw.split(separator: "@").first.map(String.init) ?? raw
        return String(localPart.prefix(2)).uppercased()
    }
}
