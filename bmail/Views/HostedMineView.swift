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
            ZStack {
                Wallpaper()
                content
            }
            .navigationTitle("Hosted links")
            .navigationBarTitleDisplayMode(.large)
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
                Text("Recipients with the URL will see \"Files no longer available\".")
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
                systemName: "link.icloud",
                title: "No hosted links yet",
                hint: "Hosted files appear here after you send an email with an attachment over 10 MB."
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
                        if !row.revoked && !isExpired(row) {
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

    private func rowView(_ row: HostedSenderRow) -> some View {
        let expired = isExpired(row)
        let dim = row.revoked || expired

        return Button {
            if !dim, row.sender_cek_wrap_b64 != nil {
                DSHaptics.selection()
                openAsSender(row)
            }
        } label: {
            HStack(spacing: DS.Space.m) {
                // File icon (first file's MIME, or generic)
                Image(systemName: row.files.first.map { mimeIcon($0.mime) } ?? "doc.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    // Filename(s)
                    Text(rowTitle(row))
                        .font(.callout)
                        .foregroundStyle(dim ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Recipients
                    Text(recipientSummary(row))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: DS.Space.xs) {
                    Text(relativeDate(row.created_at))
                        .font(.dsMono(.footnote))
                        .foregroundStyle(.secondary)

                    if row.revoked {
                        statusPill("Revoked", color: .red)
                    } else if expired {
                        statusPill("Expired", color: .secondary)
                    } else if row.download_count > 0 {
                        statusPill("\(row.download_count) dl", color: Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
        }
        .buttonStyle(.plain)
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Actions

    private func openAsSender(_ row: HostedSenderRow) {
        guard let priv = app.priv else {
            revokeError = "Your session is locked — unlock with your passkey to re-view sent files."
            return
        }
        guard let wrapB64 = row.sender_cek_wrap_b64,
              let sealedBlob = Data(b64u: wrapB64) else {
            revokeError = "This link was created before sender re-view shipped. Use the original URL from your sent message."
            return
        }
        do {
            let cek = try Crypto.openSealedBox(sealedBlob, priv: priv)
            openDestination = HostedDestination(id: row.token, token: row.token, cek: cek)
        } catch {
            revokeError = "Could not unwrap CEK: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    private func revoke(_ row: HostedSenderRow) async {
        revokeError = nil
        revoking.insert(row.token)
        defer { revoking.remove(row.token) }
        do {
            _ = try await APIClient.shared.hostedRevoke(token: row.token)
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
            rows = try await APIClient.shared.hostedMine()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Helpers

    private func isExpired(_ row: HostedSenderRow) -> Bool {
        row.expires_at < Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func rowTitle(_ row: HostedSenderRow) -> String {
        guard !row.files.isEmpty else { return "Files" }
        if row.files.count == 1 { return row.files[0].filename }
        return "\(row.files[0].filename) +\(row.files.count - 1) more"
    }

    private func recipientSummary(_ row: HostedSenderRow) -> String {
        if row.recipient_addrs.isEmpty { return "—" }
        if row.recipient_addrs.count == 1 { return row.recipient_addrs[0] }
        return "\(row.recipient_addrs[0]) +\(row.recipient_addrs.count - 1) more"
    }

    private func relativeDate(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
