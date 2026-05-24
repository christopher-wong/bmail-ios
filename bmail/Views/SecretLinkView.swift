// SecretLinkView.swift
// Recipient screen for password-protected secret links.
//
// Reached via:
//   Universal Link:  https://mail.middleseat.vc/s/<token>
//   Dev deep link:   bmail://secret?token=<token>
//
// Phases:
//   A. Loading  — GET /api/s/:token → SecretLinkPublicView
//   B. Gate     — full-screen password prompt (with hint if present)
//   C. Unlock   — derive KDF → POST /api/s/:token/open → decrypt inline fields
//   D. Decrypted — show subject + body + attachment download buttons

import OpenAPIRuntime
import SwiftUI

struct SecretLinkView: View {
    let token: String

    @State private var meta: SecretLinkPublicView?
    @State private var loadError: String?
    @State private var phase: ViewPhase = .loading
    @State private var password: String = ""
    @State private var unlocking = false
    @State private var unlockError: UnlockError?
    @State private var decoded: DecodedSecret?
    @State private var attStates: [String: AttDownloadState] = [:]  // r2_key → state

    // MARK: - Enums

    enum ViewPhase { case loading, gate, decrypted, dead(DeadReason) }
    enum DeadReason { case selfDestructed, revoked, expired, notFound }

    enum UnlockError {
        case wrongPassword(attemptsRemaining: Int?)
        case other(String)
    }

    struct DecodedSecret {
        let cek: Data
        let check: Data
        let subject: String
        let body: String
        let attachments: [AttachmentMeta]
        let senderAddr: String
        let senderName: String?
        let policy: String?
        let expiresAt: Int64?
    }

    struct AttachmentMeta: Identifiable {
        let id: String  // r2_key
        let r2Key: String
        let mime: String
        let filename: String
        let plaintextSize: Int64
        let ciphertextSize: Int64
        let chunkSize: Int64
        let chunkCount: Int64
    }

    enum AttDownloadState {
        case idle
        case downloading(progress: Double)
        case done(url: URL)
        case failed(message: String)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "SECRET MESSAGE")
                mainContent
            }
            .background(Theme.inverseInk)
        }
        .task { await loadMeta() }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        switch phase {
        case .loading:
            loadingView
        case .gate:
            if let meta {
                passwordGateView(meta)
            } else {
                loadingView
            }
        case .decrypted:
            if let decoded {
                decryptedView(decoded)
            }
        case .dead(let reason):
            deadView(reason)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("loading…")
                .font(.mono(.footnote))
                .foregroundStyle(Theme.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Password gate

    private func passwordGateView(_ meta: SecretLinkPublicView) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Sender identity block — anti-phishing: show sender before any interaction.
                senderBlock(meta)

                // Hint block
                if let hint = meta.hint, !hint.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HINT")
                            .font(.mono(10, .medium))
                            .tracking(1.5)
                            .foregroundStyle(Theme.mute)
                        Text(hint)
                            .font(.mono(.subheadline))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                // Password entry
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("password", text: $password)
                        .font(.mono(.subheadline))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                        .onSubmit { Task { await tryUnlock(meta: meta) } }

                    Button(unlocking ? "checking…" : "UNLOCK ▸") {
                        Task { await tryUnlock(meta: meta) }
                    }
                    .monoButton(prominent: true, disabled: unlocking || password.isEmpty)
                    .disabled(unlocking || password.isEmpty)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                // Error / attempts remaining
                if let err = unlockError {
                    unlockErrorView(err)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }

                // Privacy note
                Text("Your password never leaves this device. It runs through Argon2id locally; only a derived check value is sent to verify.")
                    .font(.mono(10))
                    .foregroundStyle(Theme.mute)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
    }

    private func unlockErrorView(_ err: UnlockError) -> some View {
        let text: String
        switch err {
        case .wrongPassword(let n):
            if let n, n <= 3 {
                text = "wrong password — \(n) attempt\(n == 1 ? "" : "s") left before this link self-destructs"
            } else if let n {
                text = "wrong password (\(n) attempts left)"
            } else {
                text = "wrong password"
            }
        case .other(let msg):
            text = msg
        }
        return Text(text)
            .font(.mono(12))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    // MARK: - Decrypted view

    private func decryptedView(_ s: DecodedSecret) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header: from, to, subject
                VStack(alignment: .leading, spacing: 4) {
                    Text("from")
                        .font(.mono(10)).tracking(1).foregroundStyle(Theme.mute)
                    if let name = s.senderName, !name.isEmpty {
                        Text(name).font(.mono(.title3, weight: .medium))
                        Text(s.senderAddr).font(.mono(12)).foregroundStyle(Theme.mute)
                    } else {
                        Text(s.senderAddr).font(.mono(.title3, weight: .medium))
                    }

                    if !s.subject.isEmpty {
                        Text("subject").font(.mono(10)).tracking(1).foregroundStyle(Theme.mute)
                            .padding(.top, 6)
                        Text(s.subject).font(.mono(.subheadline))
                    }

                    if let policy = s.policy, let expiresAt = s.expiresAt {
                        let expiryDate = Date(timeIntervalSince1970: Double(expiresAt) / 1000)
                        let note: String = {
                            if policy == "one_time" { return "one-time view — download all attachments now" }
                            return "expires \(expiryDate.formatted(date: .abbreviated, time: .omitted))"
                        }()
                        Text(note)
                            .font(.mono(10))
                            .foregroundStyle(Theme.mute)
                            .padding(.top, 6)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // Body
                if !s.body.isEmpty {
                    Text(s.body)
                        .font(.mono(.subheadline))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

                // Attachments
                if !s.attachments.isEmpty {
                    Hairline().padding(.horizontal, 16)
                    Text("ATTACHMENTS (\(s.attachments.count))")
                        .font(.mono(11, .medium))
                        .tracking(1.5)
                        .foregroundStyle(Theme.mute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        ForEach(s.attachments) { att in
                            attachmentRow(att, decoded: s)
                            Hairline()
                        }
                    }
                }
            }
        }
    }

    private func attachmentRow(_ att: AttachmentMeta, decoded: DecodedSecret) -> some View {
        let state = attStates[att.r2Key] ?? .idle
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(att.filename)
                    .font(.mono(.subheadline))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(formatBytes(att.plaintextSize)) · \(att.mime)")
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
                    Text(msg).font(.mono(10)).foregroundStyle(.red)
                case .idle, .done:
                    EmptyView()
                }
            }
            Spacer()
            let isBusy: Bool = { if case .downloading = state { return true } else { return false } }()
            let label: String = {
                switch state {
                case .idle:        return "DOWNLOAD"
                case .downloading: return "…"
                case .done:        return "AGAIN ▸"
                case .failed:      return "RETRY"
                }
            }()
            let isIdle: Bool = { if case .idle = state { return true } else { return false } }()
            Button(label) { Task { await downloadAttachment(att, decoded: decoded) } }
                .monoButton(prominent: isIdle, disabled: isBusy)
                .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Dead screens

    private func deadView(_ reason: DeadReason) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("secret message")
                .font(.mono(.title3, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.top, 20)

            switch reason {
            case .selfDestructed:
                Text("This link self-destructed after too many failed unlock attempts. The content has been permanently deleted from the server.")
                    .font(.mono(.footnote))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(.horizontal, 16)
                Text("Ask the sender to share a new link if you still need this content.")
                    .font(.mono(10))
                    .foregroundStyle(Theme.mute)
                    .padding(.horizontal, 16)

            case .revoked:
                Text("This link was revoked by the sender or already used (one-time view).")
                    .font(.mono(.footnote))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(.horizontal, 16)

            case .expired:
                Text("This link has expired.")
                    .font(.mono(.footnote))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(.horizontal, 16)

            case .notFound:
                Text("This link does not exist.")
                    .font(.mono(.footnote))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                    .padding(.horizontal, 16)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sender block

    private func senderBlock(_ meta: SecretLinkPublicView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("secret message from")
                .font(.mono(10)).tracking(1).foregroundStyle(Theme.mute)
            if let name = meta.sender_name, !name.isEmpty {
                Text(name).font(.mono(.title3, weight: .medium))
                Text(meta.sender_addr).font(.mono(12)).foregroundStyle(Theme.mute)
            } else {
                Text(meta.sender_addr).font(.mono(.title3, weight: .medium))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Load

    private func loadMeta() async {
        do {
            let view = try await APIClient.shared.secretView(token: token)
            meta = view
            if view.self_destructed {
                phase = .dead(.selfDestructed)
            } else if view.revoked {
                phase = .dead(.revoked)
            } else if view.expired {
                phase = .dead(.expired)
            } else {
                phase = .gate
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if msg.contains("404") {
                phase = .dead(.notFound)
            } else {
                loadError = msg
                phase = .gate  // show gate anyway so user sees something
            }
        }
    }

    // MARK: - Unlock

    private func tryUnlock(meta: SecretLinkPublicView) async {
        guard !unlocking, !password.isEmpty else { return }
        unlocking = true
        unlockError = nil

        defer { unlocking = false }

        do {
            // Parse KDF params from the server-supplied JSON string.
            guard let paramsData = meta.kdf_params.data(using: .utf8),
                  let params = try? JSONDecoder().decode(ArgonParams.self, from: paramsData)
            else {
                unlockError = .other("invalid KDF params from server")
                return
            }

            guard let saltData = Data(b64u: meta.argon_salt_b64) else {
                unlockError = .other("invalid salt encoding")
                return
            }

            // Run Argon2 + HKDF on a background thread — intentionally slow.
            let pw = password
            let kdf = try await Task.detached(priority: .userInitiated) {
                try SecretLinkCrypto.derive(password: pw, salt: saltData, kdfParams: params)
            }.value

            let openReq = SecretLinkOpenReq(password_check_b64: kdf.check.b64u)
            let resp = try await APIClient.shared.secretOpen(token: token, req: openReq)

            // Unwrap CEK.
            guard let wrappedCEKData = Data(b64u: resp.password_wrap_b64) else {
                unlockError = .other("invalid wrapped CEK encoding")
                return
            }
            let cekData = try SecretLinkCrypto.unwrapCEK(wrappedCEKData, wrapKey: kdf.wrapKey)

            // Decrypt subject and body (single-blob format, not chunked).
            let subject: String = {
                guard let ctData = Data(b64u: resp.subject_ct_b64),
                      let pt = try? SecretLinkCrypto.decryptWithCEK(ctData, cek: cekData),
                      let s = String(data: pt, encoding: .utf8)
                else { return "" }
                return s
            }()

            guard let bodyCTData = Data(b64u: resp.body_ct_b64),
                  let bodyData = try? SecretLinkCrypto.decryptWithCEK(bodyCTData, cek: cekData),
                  let bodyText = String(data: bodyData, encoding: .utf8)
            else {
                unlockError = .other("failed to decrypt message body")
                return
            }

            // Decrypt attachment filenames. The web encrypts filenames in the
            // single-chunk framed format (ChunkedAEAD) since uploadAttachmentChunked.
            // Try framed first, fall back to single-blob for legacy attachments.
            // resp.attachments is [OpenAPIObjectContainer] — each .value is [String: (any Sendable)?].
            let attachments: [AttachmentMeta] = resp.attachments.compactMap { raw in
                let dict = raw.value
                guard let r2Key = dict["r2_key"] as? String, !r2Key.isEmpty else { return nil }
                let mime    = (dict["mime"]    as? String) ?? "application/octet-stream"
                let fctB64  = (dict["filename_ct_b64"] as? String) ?? ""
                let size    = int64From(dict["size"])
                let ptSize  = int64From(dict["plaintext_size"])
                let chunkSz = int64From(dict["chunk_size"])
                let chunkCt = int64From(dict["chunk_count"])

                guard let fctData = Data(b64u: fctB64) else { return nil }

                let filename: String = {
                    // Try framed format first (new uploads use ChunkedAEAD for filenames).
                    if let (pt, _) = try? ChunkedAEAD.decryptChunk(cek: cekData, framedChunk: fctData, chunkIndex: 0),
                       let s = String(data: pt, encoding: .utf8) { return s }
                    // Legacy single-blob fallback.
                    if let pt = try? SecretLinkCrypto.decryptWithCEK(fctData, cek: cekData),
                       let s = String(data: pt, encoding: .utf8) { return s }
                    return "attachment"
                }()

                return AttachmentMeta(
                    id: r2Key, r2Key: r2Key, mime: mime,
                    filename: filename,
                    plaintextSize: ptSize > 0 ? ptSize : size,
                    ciphertextSize: size,
                    chunkSize: chunkSz,
                    chunkCount: chunkCt > 0 ? chunkCt : 1
                )
            }

            decoded = DecodedSecret(
                cek: cekData,
                check: kdf.check,
                subject: subject,
                body: bodyText,
                attachments: attachments,
                senderAddr: resp.sender_addr,
                senderName: resp.sender_name,
                policy: resp.policy,
                expiresAt: resp.expires_at
            )
            phase = .decrypted

        } catch let secretErr as SecretLinkError {
            switch secretErr {
            case .wrongPassword(let n):
                unlockError = .wrongPassword(attemptsRemaining: n)
            case .selfDestructed:
                phase = .dead(.selfDestructed)
            case .revoked:
                phase = .dead(.revoked)
            case .expired:
                phase = .dead(.expired)
            case .http(let s, let m):
                unlockError = .other("\(s): \(m)")
            }
        } catch {
            unlockError = .other((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: - Attachment download

    private func downloadAttachment(_ att: AttachmentMeta, decoded: DecodedSecret) async {
        attStates[att.r2Key] = .downloading(progress: 0)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: att.filename).pathExtension)

        do {
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let fh = try FileHandle(forWritingTo: tmp)
            defer { try? fh.close() }

            let chunkCount = att.chunkCount > 0 ? att.chunkCount : 1
            let chunkSize  = att.chunkSize
            let overhead: Int64 = 4 + 24 + 16  // ChunkedAEAD header + nonce + tag

            if chunkSize == 0 {
                // Legacy non-chunked single-blob format.
                let req = SecretAttachmentReq(
                    password_check_b64: decoded.check.b64u,
                    r2_key: att.r2Key,
                    offset: nil, length: nil
                )
                let ct = try await APIClient.shared.secretAttachment(token: token, req: req)
                let pt = try SecretLinkCrypto.decryptWithCEK(ct, cek: decoded.cek)
                try fh.write(contentsOf: pt)
            } else {
                // Chunked path: ranged reads, one chunk at a time.
                for i in Int64(0)..<chunkCount {
                    let isFinalChunk = (i == chunkCount - 1)
                    let thisChunkPt = isFinalChunk
                        ? att.plaintextSize - i * chunkSize
                        : chunkSize
                    let encOffset = i * (chunkSize + overhead)
                    let encLen    = thisChunkPt + overhead

                    let req = SecretAttachmentReq(
                        password_check_b64: decoded.check.b64u,
                        r2_key: att.r2Key,
                        offset: encOffset,
                        length: encLen
                    )
                    let ct = try await APIClient.shared.secretAttachment(token: token, req: req)
                    let (pt, _) = try ChunkedAEAD.decryptChunk(
                        cek: decoded.cek,
                        framedChunk: ct,
                        chunkIndex: UInt32(i)
                    )
                    try fh.write(contentsOf: pt)

                    let progress = Double(i + 1) / Double(chunkCount)
                    attStates[att.r2Key] = .downloading(progress: min(progress, 0.99))
                }
            }

            attStates[att.r2Key] = .done(url: tmp)
            shareFile(at: tmp, filename: att.filename)

        } catch let secretErr as SecretLinkError {
            try? FileManager.default.removeItem(at: tmp)
            switch secretErr {
            case .selfDestructed:
                attStates[att.r2Key] = .failed(message: "link self-destructed")
            case .revoked:
                attStates[att.r2Key] = .failed(message: "link revoked or expired")
            default:
                attStates[att.r2Key] = .failed(
                    message: secretErr.errorDescription ?? "download failed"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            attStates[att.r2Key] = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "download failed"
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
}

// MARK: - Helpers

/// Safely coerce an `(any Sendable)?` from an `OpenAPIObjectContainer` dict into `Int64`.
private func int64From(_ v: (any Sendable)?) -> Int64 {
    switch v {
    case let n as Int64:  return n
    case let n as Int:    return Int64(n)
    case let n as Double: return Int64(n)
    default:              return 0
    }
}

private func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: n)
}
