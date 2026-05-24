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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "SECRET LINKS")
                content
            }
            .background(Theme.inverseInk)
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
            VStack(spacing: 16) {
                ProgressView()
                Text("loading…")
                    .font(.mono(.footnote))
                    .foregroundStyle(Theme.mute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(err)
                    .font(.mono(.footnote))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                Button("RETRY") { Task { await load() } }
                    .monoButton()
                    .padding(.horizontal, 16)
                Spacer()
            }
        } else if rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("no secret links yet.")
                    .font(.mono(.subheadline))
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                Text("enable the lock icon in compose to send one.")
                    .font(.mono(.footnote))
                    .foregroundStyle(Theme.mute)
                    .padding(.horizontal, 16)
                Spacer()
            }
        } else {
            if let err = revokeError {
                Text(err)
                    .font(.mono(11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Hairline()
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.token) { row in
                        rowView(row)
                        Hairline()
                    }
                }
            }
        }
    }

    // MARK: - Row

    private func rowView(_ row: SecretSenderRow) -> some View {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let expired = row.expires_at < now
        let dim = row.revoked || expired || row.self_destructed
        let status = statusLabel(row: row, expired: expired)

        return VStack(alignment: .leading, spacing: 0) {
            // Recipient + status badge
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let recipient = row.recipient_addr, !recipient.isEmpty {
                        Text(recipient)
                            .font(.mono(.subheadline))
                            .foregroundStyle(dim ? Theme.mute : Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("share link")
                            .font(.mono(.subheadline))
                            .italic()
                            .foregroundStyle(Theme.mute)
                    }
                    if let hint = row.hint, !hint.isEmpty {
                        Text("hint: \(hint)")
                            .font(.mono(11))
                            .foregroundStyle(Theme.mute)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                statusBadge(status, selfDestructed: row.self_destructed)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Stats + policy
            let created = Date(timeIntervalSince1970: Double(row.created_at) / 1000)
            let expires = Date(timeIntervalSince1970: Double(row.expires_at) / 1000)
            HStack(spacing: 12) {
                Text(policyLabel(row.policy))
                    .font(.mono(10))
                    .foregroundStyle(Theme.mute)
                Text("\(row.opens_count) open\(row.opens_count == 1 ? "" : "s")")
                    .font(.mono(10))
                    .foregroundStyle(Theme.mute)
                if row.fail_count > 0 {
                    Text("\(row.fail_count) failed")
                        .font(.mono(10))
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            Text("\(created.formatted(date: .abbreviated, time: .shortened)) · expires \(expires.formatted(date: .abbreviated, time: .omitted))")
                .font(.mono(10))
                .foregroundStyle(Theme.mute)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Actions
            if !dim {
                HStack(spacing: 8) {
                    let wasCopied = copiedToken == row.token
                    Button(wasCopied ? "COPIED ✓" : "COPY LINK") {
                        copyLink(row)
                    }
                    .monoButton()

                    let isRevoking = revoking.contains(row.token)
                    Button(isRevoking ? "REVOKING…" : "REVOKE") {
                        pendingRevoke = row
                    }
                    .monoButton(disabled: isRevoking)
                    .disabled(isRevoking)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func statusBadge(_ label: String, selfDestructed: Bool) -> some View {
        let color: Color = selfDestructed ? .red : Theme.mute
        return Text(label.uppercased())
            .font(.mono(9, .medium))
            .tracking(1.0)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private func statusLabel(row: SecretSenderRow, expired: Bool) -> String {
        if row.self_destructed { return "self-destructed" }
        if row.revoked          { return "revoked" }
        if expired              { return "expired" }
        if row.first_opened_at != nil { return "opened" }
        return "active"
    }

    private func policyLabel(_ policy: String) -> String {
        switch policy {
        case "one_time": return "one-time"
        case "1h":       return "1h after open"
        case "24h":      return "24h after open"
        case "14d":      return "14d after open"
        case "never":    return "never (1y max)"
        default:         return policy
        }
    }

    // MARK: - Actions

    private func copyLink(_ row: SecretSenderRow) {
        // The server stores the full URL in `url` on create, but SecretSenderRow
        // only has the token. Reconstruct the URL from the known base.
        let url = "https://mail.middleseat.vc/s/\(row.token)"
        UIPasteboard.general.string = url
        withAnimation {
            copiedToken = row.token
        }
        // Clear the "COPIED ✓" state after 2 seconds.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedToken == row.token {
                copiedToken = nil
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
            revokeError = (error as? LocalizedError)?.errorDescription ?? "revoke failed"
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
}
