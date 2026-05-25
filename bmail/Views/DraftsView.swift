import SwiftUI

struct DraftsView: View {
    @Environment(AppModel.self) private var app
    @State private var drafts: [DraftRow] = []
    @State private var subjects: [String: String] = [:]
    @State private var loading = true
    @State private var resumingDraft: DraftRow?
    @State private var unsubscribe: (() -> Void)?

    private let net = NetworkMonitor.shared
    private let cache = MailCache.default

    var body: some View {
        NavigationStack {
            ZStack {
                Wallpaper()

                Group {
                    if loading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if drafts.isEmpty {
                        DSEmptyState(
                            systemName: "doc.text",
                            title: "No drafts"
                        )
                    } else {
                        draftList
                    }
                }
            }
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.large)
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $resumingDraft) { d in
                ComposeView(resumeDraft: d)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.thickMaterial)
                    .presentationCornerRadius(DS.Radius.sheet)
            }
            .onAppear { subscribeIfNeeded() }
            .onDisappear { unsubscribe?(); unsubscribe = nil }
        }
    }

    // MARK: - Draft list

    private var draftList: some View {
        List {
            ForEach(drafts) { d in
                Button {
                    resumingDraft = d
                } label: {
                    DraftMailRow(
                        draft: d,
                        subject: subjects[d.id]
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        discard(d.id)
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

    /// A draft is "empty" if it has no recipient, no subject, and no body.
    /// We don't list those — they're usually compose-and-abandon residue —
    /// and we silently delete them server-side so they don't reappear.
    private static func isEmpty(_ d: DraftRow) -> Bool {
        let noRecipient = d.to_addrs.isEmpty && d.cc_addrs.isEmpty && d.bcc_addrs.isEmpty
        let noSubject = (d.subject_ct_b64?.isEmpty ?? true)
        let noBody = (d.body_ct_b64?.isEmpty ?? true)
        return noRecipient && noSubject && noBody
    }

    private func load() async {
        // Seed from cache so users see something instantly, and offline still
        // renders a list.
        let cached = cache.loadDrafts()
        if !cached.isEmpty {
            drafts = cached.filter { !Self.isEmpty($0) }
            loading = false
            await decryptSubjects(drafts)
        }

        guard net.isOnline else {
            loading = false
            return
        }

        loading = drafts.isEmpty
        do {
            let rows: [DraftRow] = try await APIClient.shared.get("/api/drafts")
            let kept = rows.filter { !Self.isEmpty($0) }
            drafts = kept
            cache.saveDrafts(kept)
            loading = false
            await decryptSubjects(kept)
            // Best-effort cleanup of empty server-side drafts.
            let empties = rows.filter(Self.isEmpty)
            for d in empties {
                _ = try? await APIClient.shared.delete("/api/drafts/\(d.id)")
            }
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
        cache.saveDrafts(drafts)
        Task {
            _ = try? await APIClient.shared.delete("/api/drafts/\(id)")
        }
    }

    private func subscribeIfNeeded() {
        guard unsubscribe == nil else { return }
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

// MARK: - Draft mail row

/// Variant of `MailRow` sized for drafts: recipient · subject · relative date.
/// Extracted here to keep `MailRow` generic (it takes a `primary` string, not a `DraftRow`).
private struct DraftMailRow: View {
    let draft: DraftRow
    let subject: String?

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            // Avatar from first recipient initial
            DSAvatar(initials: initials(from: draft.to_addrs.first ?? ""), size: .row)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recipientLabel)
                        .font(.callout.weight(.regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: DS.Space.xs)

                    Text(RelativeDate.format(draft.updated_at))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(DS.Color.inkFaint)
                }

                if let subj = subject, !subj.isEmpty {
                    Text(subj)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
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
