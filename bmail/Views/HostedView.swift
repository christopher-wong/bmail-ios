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

struct HostedView: View {
    let token: String
    let cek: Data

    @Environment(AppModel.self) private var app
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
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "ENCRYPTED DOWNLOAD")
                content
            }
            .background(Theme.inverseInk)
        }
        .task { await loadMeta() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorView(err)
        } else if let meta {
            if meta.revoked {
                statusView(
                    headline: "files no longer available",
                    body: "The sender revoked this download link. Ask them to share again if you still need the files."
                )
            } else if meta.expired {
                statusView(
                    headline: "link expired",
                    body: "Hosted download links expire 14 days after they're sent. Ask the sender to share again."
                )
            } else {
                fileListView(meta)
            }
        } else {
            loadingView
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("loading…")
                .font(.mono(.footnote))
                .foregroundStyle(Theme.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message.contains("404") ? "this link does not exist" : message)
                .font(.mono(.footnote))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                .padding(16)
            Spacer()
        }
    }

    private func statusView(headline: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.mono(.title3, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.top, 20)
            Text(body)
                .font(.mono(.footnote))
                .foregroundStyle(Theme.mute)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileListView(_ meta: HostedPublicView) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Sender identity block — above the fold, anti-phishing posture.
                senderBlock(meta)

                // E2E callout
                e2eCallout(meta)

                // File list
                VStack(spacing: 0) {
                    let label = "FILES (\(meta.files.count), \(formatBytes(meta.total_bytes)) encrypted)"
                    Text(label)
                        .font(.mono(11, .medium))
                        .tracking(1.5)
                        .foregroundStyle(Theme.mute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                    Hairline()
                    ForEach(meta.files, id: \.r2_key) { file in
                        fileRow(file)
                        Hairline()
                    }
                }

                if meta.download_count > 0 {
                    Text("downloaded \(meta.download_count) time\(meta.download_count == 1 ? "" : "s") so far.")
                        .font(.mono(10))
                        .foregroundStyle(Theme.mute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Subviews

    private func senderBlock(_ meta: HostedPublicView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("sent by")
                .font(.mono(10))
                .tracking(1.0)
                .foregroundStyle(Theme.mute)

            if let name = meta.sender_name, !name.isEmpty {
                Text(name)
                    .font(.mono(.title3, weight: .medium))
                Text(meta.sender_addr)
                    .font(.mono(12))
                    .foregroundStyle(Theme.mute)
            } else {
                Text(meta.sender_addr)
                    .font(.mono(.title3, weight: .medium))
            }

            if !meta.recipient_addrs.isEmpty {
                let recipLine: String = {
                    if meta.recipient_addrs.count == 1 { return meta.recipient_addrs[0] }
                    return "\(meta.recipient_addrs[0]) +\(meta.recipient_addrs.count - 1) more"
                }()
                Group {
                    Text("to")
                        .font(.mono(10))
                        .tracking(1.0)
                        .foregroundStyle(Theme.mute)
                        .padding(.top, 6)
                    Text(recipLine)
                        .font(.mono(12))
                }
            }

            if let subject = meta.subject, !subject.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("subject")
                        .font(.mono(10))
                        .tracking(1.0)
                        .foregroundStyle(Theme.mute)
                    Text(subject)
                        .font(.mono(12))
                }
                .padding(.top, 4)
            }

            Text(metaTimestampLine(meta))
                .font(.mono(10))
                .foregroundStyle(Theme.mute)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func e2eCallout(_ meta: HostedPublicView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You're on bmail's encrypted-download page.")
                .font(.mono(11, .medium))
            Text("These files are end-to-end encrypted — the decryption key lives only in your URL (after the #), so our servers can't read your files. Anyone with the full URL can decrypt them, so treat it like a password. If you weren't expecting this from \(meta.sender_name ?? meta.sender_addr), don't download anything.")
                .font(.mono(10))
                .foregroundStyle(Theme.mute)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func fileRow(_ file: HostedFile) -> some View {
        let state = fileStates[file.r2_key] ?? .idle
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename)
                    .font(.mono(.subheadline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(formatBytes(file.plaintext_size)) · \(file.mime)")
                    .font(.mono(10))
                    .foregroundStyle(Theme.mute)
                switch state {
                case .downloading(let p):
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(Theme.ink)
                        .padding(.top, 2)
                    Text("decrypting… \(Int(p * 100))%")
                        .font(.mono(10))
                        .foregroundStyle(Theme.mute)
                case .failed(let msg):
                    Text(msg)
                        .font(.mono(10))
                        .foregroundStyle(.red)
                case .idle, .done:
                    EmptyView()
                }
            }
            Spacer()
            downloadButton(file: file, state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func downloadButton(file: HostedFile, state: FileDownloadState) -> some View {
        let label: String = {
            switch state {
            case .idle:              return "DOWNLOAD"
            case .downloading:       return "…"
            case .done:              return "AGAIN ▸"
            case .failed:            return "RETRY"
            }
        }()
        let isIdle: Bool = {
            if case .idle = state { return true } else { return false }
        }()
        let busy: Bool = {
            if case .downloading = state { return true } else { return false }
        }()

        return Button(label) {
            Task { await downloadFile(file) }
        }
        .monoButton(prominent: isIdle, disabled: busy)
        .disabled(busy)
    }

    // MARK: - Download logic

    private func downloadFile(_ file: HostedFile) async {
        fileStates[file.r2_key] = .downloading(progress: 0)

        // Create a temp file for the plaintext output.
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

            // Present system share sheet so the user can save to Files or open in another app.
            shareFile(at: tmp, filename: file.filename)

        } catch {
            try? FileManager.default.removeItem(at: tmp)
            fileStates[file.r2_key] = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "download failed: \(error)"
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

    private func metaTimestampLine(_ meta: HostedPublicView) -> String {
        let created = Date(timeIntervalSince1970: Double(meta.created_at) / 1000)
        let expires = Date(timeIntervalSince1970: Double(meta.expires_at) / 1000)
        let createdStr = created.formatted(date: .abbreviated, time: .shortened)
        let expiresStr = expires.formatted(date: .abbreviated, time: .omitted)
        return "\(createdStr) · expires \(expiresStr)"
    }
}

// MARK: - Helpers

private func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: n)
}
