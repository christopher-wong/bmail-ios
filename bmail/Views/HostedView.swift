// HostedView.swift
// Recipient (and sender-preview) screen for E2E-encrypted hosted downloads.
//
// Anti-phishing design rationale: sender identity is rendered above the fold
// in large text before any file list or download controls appear. The screen
// also surfaces an explicit callout that decryption happens locally and that
// the key never reaches the server. This mirrors the web's HostedView.tsx
// posture and makes it hard for a malicious actor to pass off a spoofed page
// as a bmail download — the user sees the sender's verified handle/address
// before interacting with any download affordance.
//
// Reached via:
//   - Universal Link:  https://mail.middleseat.vc/d/<token>#k=<cek_b64u>
//   - Dev deep link:   bmail://hosted?token=<token>&k=<cek_b64u>
//   - HostedMineView:  sender pushes here with unwrapped CEK directly

import SwiftUI

// MARK: - Shared sender identity card

/// Reusable sender identity card used by HostedView and SecretLinkView gate.
/// Prominent above-the-fold anti-phishing surface: avatar + display name +
/// monospaced email (spoofing-obvious) + encryption pill + trust copy.
struct SenderIdentityCard: View {
    let displayName: String?
    let email: String
    let pillLabel: String
    var trustCopy: String? = nil

    private var initials: String {
        if let name = displayName, !name.isEmpty {
            let parts = name.split(separator: " ")
            if parts.count >= 2 {
                return String(parts[0].prefix(1) + parts[1].prefix(1))
            }
            return String(name.prefix(2))
        }
        return String(email.prefix(2))
    }

    var body: some View {
        GlassCard(radius: DS.Radius.sheet) {
            VStack(spacing: DS.Space.m) {
                DSAvatar(initials: initials, size: .header)

                VStack(spacing: DS.Space.xs) {
                    if let name = displayName, !name.isEmpty {
                        Text(name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                    }

                    Text(email)
                        .font(.dsMono(.body))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                DSEncryptionPill(label: pillLabel)

                if let copy = trustCopy {
                    Text(copy)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.s)
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DS.Space.l)
    }
}

// MARK: - HostedView

struct HostedView: View {
    let token: String
    let cek: Data

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var meta: HostedPublicView?
    @State private var loadError: String?
    @State private var fileStates: [String: FileDownloadState] = [:]    // r2Key → state

    enum FileDownloadState {
        case idle
        case downloading(progress: Double)  // 0…1
        case done(url: URL)
        case failed(message: String)
    }

    var body: some View {
        ZStack {
            Wallpaper()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
        .task { await loadMeta() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorStateView(err)
        } else if let meta {
            if meta.revoked {
                deadStateView(
                    systemName: "xmark.shield",
                    title: "Files no longer available",
                    hint: "The sender revoked this download link. Ask them to share again if you still need the files."
                )
            } else if meta.expired {
                deadStateView(
                    systemName: "clock.badge.xmark",
                    title: "Link expired",
                    hint: "Hosted download links expire 14 days after they're sent. Ask the sender to share again."
                )
            } else {
                fileListView(meta)
            }
        } else {
            loadingStateView
        }
    }

    // MARK: - Loading

    private var loadingStateView: some View {
        VStack(spacing: DS.Space.m) {
            ProgressView()
                .controlSize(.large)
                .tint(.accentColor)
            Text("Loading…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorStateView(_ message: String) -> some View {
        DSEmptyState(
            systemName: "exclamationmark.triangle",
            title: message.contains("404") ? "Link not found" : "Something went wrong",
            hint: message.contains("404") ? nil : message
        )
    }

    // MARK: - Dead (revoked / expired)

    private func deadStateView(systemName: String, title: String, hint: String) -> some View {
        DSEmptyState(systemName: systemName, title: title, hint: hint)
    }

    // MARK: - File list

    private func fileListView(_ meta: HostedPublicView) -> some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                // 1. Sender identity card — above the fold, anti-phishing posture.
                SenderIdentityCard(
                    displayName: meta.sender_name,
                    email: meta.sender_addr,
                    pillLabel: "End-to-end encrypted",
                    trustCopy: "These files were encrypted in their browser. Only you can decrypt them on this device."
                )
                .padding(.top, DS.Space.l)

                // 2. File list card
                GlassCard(radius: DS.Radius.card) {
                    VStack(spacing: 0) {
                        ForEach(Array(meta.files.enumerated()), id: \.element.r2_key) { index, file in
                            fileRow(file, expiresAt: meta.expires_at)
                            if index < meta.files.count - 1 {
                                Divider()
                                    .padding(.leading, DS.Space.l)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.l)

                // Download count footnote
                if meta.download_count > 0 {
                    Text("Downloaded \(meta.download_count) time\(meta.download_count == 1 ? "" : "s") so far.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.xl)
                }
            }
            .padding(.bottom, DS.Space.xxl)
        }
    }

    // MARK: - File row

    private func fileRow(_ file: HostedFile, expiresAt: Int64) -> some View {
        let state = fileStates[file.r2_key] ?? .idle
        return VStack(spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: mimeIcon(file.mime))
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(fileMeta(file, expiresAt: expiresAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                downloadButton(file: file, state: state)
            }

            // Progress bar — only shown while downloading
            if case .downloading(let p) = state {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.leading, 48)  // align under filename
            }

            if case .failed(let msg) = state {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 48)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private func downloadButton(file: HostedFile, state: FileDownloadState) -> some View {
        let isBusy: Bool = { if case .downloading = state { return true } else { return false } }()

        return Group {
            switch state {
            case .idle:
                Button("Download", systemImage: "arrow.down.circle") {
                    Task { await downloadFile(file) }
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)

            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
                    .frame(width: 44, height: 32)

            case .done:
                Button("Again", systemImage: "arrow.counterclockwise.circle") {
                    Task { await downloadFile(file) }
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)

            case .failed:
                Button("Retry", systemImage: "arrow.down.circle") {
                    Task { await downloadFile(file) }
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .disabled(isBusy)
    }

    // MARK: - Download logic

    private func downloadFile(_ file: HostedFile) async {
        fileStates[file.r2_key] = .downloading(progress: 0)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: file.filename).pathExtension)

        do {
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let fh = try FileHandle(forWritingTo: tmp)
            defer { try? fh.close() }

            let chunkSize = Int(file.chunk_size > 0 ? file.chunk_size : Int64(Uploader.chunkSize))
            let overhead = 4 + 24 + 16  // header + nonce + tag
            let wireChunkSize = Int64(chunkSize + overhead)
            var chunkIndex: UInt32 = 0
            var offset: Int64 = 0
            let totalCiphertext = file.size

            while true {
                let end = min(offset + wireChunkSize - 1, totalCiphertext - 1)
                let chunkData = try await APIClient.shared.hostedDownload(
                    token: token,
                    r2Key: file.r2_key,
                    rangeStart: offset,
                    rangeEnd: end
                )

                let (plaintext, isFinal) = try ChunkedAEAD.decryptChunk(
                    cek: cek,
                    framedChunk: chunkData,
                    chunkIndex: chunkIndex
                )

                // Write directly to disk — never accumulate plaintext in memory.
                try fh.write(contentsOf: plaintext)

                offset += Int64(chunkData.count)
                chunkIndex += 1

                let progress = totalCiphertext > 0 ? Double(offset) / Double(totalCiphertext) : 1.0
                fileStates[file.r2_key] = .downloading(progress: min(progress, 0.99))

                if isFinal { break }
            }

            fileStates[file.r2_key] = .done(url: tmp)
            DSHaptics.notifySuccess()
            shareFile(at: tmp, filename: file.filename)

        } catch {
            try? FileManager.default.removeItem(at: tmp)
            fileStates[file.r2_key] = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "Download failed: \(error)"
            )
        }
    }

    @MainActor
    private func shareFile(at url: URL, filename: String) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        root.present(vc, animated: true)
    }

    // MARK: - Fetch

    private func loadMeta() async {
        loadError = nil
        do {
            meta = try await APIClient.shared.hostedView(token: token)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Helpers

    /// File size + optional expiry date sourced from the enclosing HostedPublicView.
    private func fileMeta(_ file: HostedFile, expiresAt: Int64) -> String {
        let sizeStr = formatBytes(file.plaintext_size)
        guard expiresAt > 0 else { return sizeStr }
        let expires = Date(timeIntervalSince1970: Double(expiresAt) / 1000)
        return "\(sizeStr) · expires \(expires.formatted(date: .abbreviated, time: .omitted))"
    }
}

// MARK: - Helpers

/// Map a MIME type to the most representative SF Symbol.
func mimeIcon(_ mime: String) -> String {
    let m = mime.lowercased()
    if m.hasPrefix("image/")       { return "photo.fill" }
    if m.hasPrefix("video/")       { return "video.fill" }
    if m.hasPrefix("audio/")       { return "waveform" }
    if m == "application/pdf"      { return "doc.richtext.fill" }
    if m.contains("zip") || m.contains("tar") || m.contains("gzip") { return "doc.zipper" }
    if m.hasPrefix("text/")        { return "doc.text.fill" }
    if m.contains("spreadsheet") || m.contains("excel") { return "tablecells.fill" }
    if m.contains("presentation") || m.contains("powerpoint") { return "rectangle.on.rectangle.fill" }
    return "doc.fill"
}

private func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: n)
}
