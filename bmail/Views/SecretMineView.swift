// SecretMineView.swift
// Sender dashboard for password-protected secret links.
//
// Lists all secret links the signed-in user has created. The sender cannot
// decrypt content (they don't store the password), so this view is purely
// lifecycle management: copy the share URL, revoke, and see open/fail stats.
//
// Mirrored from web/src/pages/Secrets.tsx.

import SwiftUI

struct SecretMineView: View {
    @State private var rows: [SecretSenderRow] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var revoking: Set<String> = []
    @State private var revokeError: String?
    @State private var pendingRevoke: SecretSenderRow?
    @State private var copiedToken: String?
    @State private var showCopiedHUD = false

    var body: some View {
        NavigationStack {
            ZStack {
                Wallpaper()
                content

                // "Link copied" HUD toast
                if showCopiedHUD {
                    VStack {
                        Spacer()
                        Text("Link copied")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, DS.Space.l)
                            .padding(.vertical, DS.Space.m)
                            .background(.regularMaterial, in: Capsule())
                            .glassEdge(radius: 99)
                            .padding(.bottom, DS.Space.xxl)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle("Secret links")
            .navigationBarTitleDisplayMode(.large)
            .task { await load() }
            .refreshable { await load() }
            .confirmationDialog(
                "Revoke this link?",
                isPresented: Binding(
                    get: { pendingRevoke != nil },
                    set: { if !$0 { pendingRevoke = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Revoke", role: .destructive) {
                    if let row = pendingRevoke {
                        Task { await revoke(row) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingRevoke = nil }
            } message: {
                Text("The recipient will no longer be able to open this link.")
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading && rows.isEmpty {
            VStack(spacing: DS.Space.m) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.accentColor)
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(spacing: DS.Space.m) {
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.xl)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            DSEmptyState(
                systemName: "lock.shield",
                title: "No secret links yet",
                hint: "Enable the lock icon in compose to send a password-protected message."
            )
        } else {
            listContent
        }
    }

    // MARK: - List

    private var listContent: some View {
        List {
            if let err = revokeError {
                Section {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            ForEach(rows, id: \.token) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !row.revoked && !row.self_destructed && !isExpired(row) {
                            Button(role: .destructive) {
                                DSHaptics.notifyWarning()
                                pendingRevoke = row
                            } label: {
                                Label("Revoke", systemImage: "xmark.circle")
                            }
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Row

    private func rowView(_ row: SecretSenderRow) -> some View {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let expired = row.expires_at < now
        let dim = row.revoked || expired || row.self_destructed

        return Button {
            guard !dim else { return }
            copyLink(row)
        } label: {
            HStack(spacing: DS.Space.m) {
                // Lock icon as leading indicator
                Image(systemName: row.self_destructed ? "flame" : "lock.fill")
                    .font(.title3)
                    .foregroundStyle(row.self_destructed ? .red : .accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    // Recipient or share-link label
                    if let recipient = row.recipient_addr, !recipient.isEmpty {
                        Text(recipient)
                            .font(.callout)
                            .foregroundStyle(dim ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Share link")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .italic()
                    }

                    // Meta: policy + stats
                    HStack(spacing: DS.Space.s) {
                        Text(policyLabel(row.policy))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if row.opens_count > 0 {
                            Text("·")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("\(row.opens_count) open\(row.opens_count == 1 ? "" : "s")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if row.fail_count > 0 {
                            Text("·")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("\(row.fail_count) failed unlock\(row.fail_count == 1 ? "" : "s")")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    // Self-destructed badge
                    if row.self_destructed {
                        Label("Self-destructed", systemImage: "flame")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    Text(relativeDate(row.created_at))
                        .font(.dsMono(.footnote))
                        .foregroundStyle(.secondary)

                    if !dim {
                        if copiedToken == row.token {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Image(systemName: "doc.on.clipboard")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        statusPill(statusLabel(row: row, expired: expired))
                    }
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
        }
        .buttonStyle(.plain)
    }

    private func statusPill(_ text: String) -> some View {
        let isDestructive = text == "Self-destructed" || text == "Revoked"
        let color: Color = isDestructive ? .red : .secondary
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func statusLabel(row: SecretSenderRow, expired: Bool) -> String {
        if row.self_destructed { return "Self-destructed" }
        if row.revoked          { return "Revoked" }
        if expired              { return "Expired" }
        if row.first_opened_at != nil { return "Opened" }
        return "Active"
    }

    private func policyLabel(_ policy: String) -> String {
        switch policy {
        case "one_time": return "One-time"
        case "1h":       return "1h after open"
        case "24h":      return "24h after open"
        case "14d":      return "14d after open"
        case "never":    return "Never (1y max)"
        default:         return policy
        }
    }

    // MARK: - Actions

    private func copyLink(_ row: SecretSenderRow) {
        let url = "https://mail.middleseat.vc/s/\(row.token)"
        UIPasteboard.general.string = url
        DSHaptics.impactLight()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            copiedToken = row.token
            showCopiedHUD = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.25)) {
                showCopiedHUD = false
                if copiedToken == row.token { copiedToken = nil }
            }
        }
    }

    private func revoke(_ row: SecretSenderRow) async {
        revokeError = nil
        revoking.insert(row.token)
        defer { revoking.remove(row.token) }
        do {
            _ = try await APIClient.shared.secretRevoke(token: row.token)
            rows.removeAll { $0.token == row.token }
        } catch {
            revokeError = (error as? LocalizedError)?.errorDescription ?? "Revoke failed."
            await load()
        }
    }

    // MARK: - Load

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            rows = try await APIClient.shared.secretMine()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Helpers

    private func isExpired(_ row: SecretSenderRow) -> Bool {
        row.expires_at < Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func relativeDate(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
