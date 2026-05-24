// HostedMineView.swift
// Sender dashboard — lists the current user's hosted-attachment links, lets
// them preview with decrypted CEK, or revoke any active row.

import SwiftUI

struct HostedMineView: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [HostedSenderRow] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var revoking: Set<String> = []
    @State private var revokeError: String?
    @State private var openDestination: HostedDestination?
    @State private var pendingRevoke: HostedSenderRow?

    struct HostedDestination: Identifiable, Hashable {
        let id: String   // token
        let token: String
        let cek: Data
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "HOSTED FILES")
                content
            }
            .background(Theme.inverseInk)
            .task { await load() }
            .refreshable { await load() }
            .navigationDestination(item: $openDestination) { dest in
                HostedView(token: dest.token, cek: dest.cek)
            }
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
                Text("Recipients with the URL will see \"files no longer available\".")
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
                Text("no hosted attachments yet.")
                    .font(.mono(.subheadline))
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                Text("they're created automatically when you send a file ≥ 10 MiB.")
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

    private func rowView(_ row: HostedSenderRow) -> some View {
        let expired = row.expires_at < Int64(Date().timeIntervalSince1970 * 1000)
        let dim = row.revoked || expired

        return VStack(alignment: .leading, spacing: 0) {
            // Recipients + subject
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    let recipText: String = {
                        if row.recipient_addrs.isEmpty { return "—" }
                        if row.recipient_addrs.count == 1 { return row.recipient_addrs[0] }
                        return "\(row.recipient_addrs[0]) +\(row.recipient_addrs.count - 1) more"
                    }()
                    Text(recipText)
                        .font(.mono(.subheadline))
                        .foregroundStyle(dim ? Theme.mute : Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let subject = row.subject, !subject.isEmpty {
                        Text(subject)
                            .font(.mono(11))
                            .foregroundStyle(Theme.mute)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                // Status badge
                if row.revoked {
                    badge("revoked", color: .red)
                } else if expired {
                    badge("expired", color: Theme.mute)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Files + metadata
            VStack(alignment: .leading, spacing: 2) {
                ForEach(row.files, id: \.r2_key) { f in
                    Text("  \(f.filename)  \(formatBytes(f.plaintext_size))")
                        .font(.mono(11))
                        .foregroundStyle(Theme.mute)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            // Meta row: created, expires, downloads
            let created = Date(timeIntervalSince1970: Double(row.created_at) / 1000)
            let expires = Date(timeIntervalSince1970: Double(row.expires_at) / 1000)
            Text("\(created.formatted(date: .abbreviated, time: .shortened)) · expires \(expires.formatted(date: .abbreviated, time: .omitted)) · \(row.download_count) dl")
                .font(.mono(10))
                .foregroundStyle(Theme.mute)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Actions
            if !dim {
                HStack(spacing: 8) {
                    if row.sender_cek_wrap_b64 != nil {
                        Button("VIEW") { openAsSender(row) }
                            .monoButton()
                    }
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

    private func badge(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.mono(9, .medium))
            .tracking(1.0)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Actions

    private func openAsSender(_ row: HostedSenderRow) {
        guard let priv = app.priv else {
            revokeError = "your session is locked — unlock with your passkey to re-view sent files"
            return
        }
        guard let wrapB64 = row.sender_cek_wrap_b64,
              let sealedBlob = Data(b64u: wrapB64) else {
            revokeError = "this link was created before sender re-view shipped; use the original URL from your sent message."
            return
        }
        do {
            let cek = try Crypto.openSealedBox(sealedBlob, priv: priv)
            openDestination = HostedDestination(id: row.token, token: row.token, cek: cek)
        } catch {
            revokeError = "could not unwrap CEK: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    private func revoke(_ row: HostedSenderRow) async {
        revokeError = nil
        revoking.insert(row.token)
        defer { revoking.remove(row.token) }
        do {
            _ = try await APIClient.shared.hostedRevoke(token: row.token)
            // Optimistic remove
            rows.removeAll { $0.token == row.token }
        } catch {
            revokeError = (error as? LocalizedError)?.errorDescription ?? "revoke failed"
            // Refresh on error so the list is consistent with server state.
            await load()
        }
    }

    // MARK: - Load

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            rows = try await APIClient.shared.hostedMine()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

// MARK: - Helpers

private func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: n)
}
