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
        ZStack {
            Wallpaper()
            mainContent
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
        VStack(spacing: DS.Space.m) {
            ProgressView()
                .controlSize(.large)
                .tint(.accentColor)
            Text("Decrypting…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Password gate

    private func passwordGateView(_ meta: SecretLinkPublicView) -> some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                // Anti-phishing: sender identity above the fold before any input.
                SenderIdentityCard(
                    displayName: meta.sender_name,
                    email: meta.sender_addr,
                    pillLabel: "Password protected"
                )
                .padding(.top, DS.Space.l)

                // Load error banner (if initial fetch had a recoverable error)
                if let err = loadError {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.l)
                }

                // Password card
                GlassCard(radius: DS.Radius.card) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        // Optional hint
                        if let hint = meta.hint, !hint.isEmpty {
                            Text(hint)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        // Password field
                        SecureField("Password", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(DS.Space.m)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                            .onSubmit { Task { await tryUnlock(meta: meta) } }

                        // Attempts warning
                        if let err = unlockError, case .wrongPassword(let n) = err, let n, n <= 3 {
                            Text("\(n) attempt\(n == 1 ? "" : "s") left before this link self-destructs.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else if let err = unlockError {
                            Text(unlockErrorText(err))
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        // Unlock button
                        Button {
                            Task { await tryUnlock(meta: meta) }
                        } label: {
                            Group {
                                if unlocking {
                                    HStack(spacing: DS.Space.s) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(.white)
                                        Text("Decrypting…")
                                    }
                                } else {
                                    Text("Unlock")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .disabled(unlocking || password.isEmpty)
                    }
                    .padding(DS.Space.l)
                }
                .padding(.horizontal, DS.Space.l)

                // Privacy microcopy
                Text("Your password never leaves this device. It's processed locally through Argon2id; only a derived check value is sent to verify.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
            }
        }
    }

    private func unlockErrorText(_ err: UnlockError) -> String {
        switch err {
        case .wrongPassword(let n):
            if let n, n <= 3 {
                return "Wrong password — \(n) attempt\(n == 1 ? "" : "s") left before this link self-destructs."
            } else if let n {
                return "Wrong password (\(n) attempts left)."
            } else {
                return "Wrong password."
            }
        case .other(let msg):
            return msg
        }
    }

    // MARK: - Decrypted view

    private func decryptedView(_ s: DecodedSecret) -> some View {
        ScrollView {
            VStack(spacing: DS.Space.l) {
                // Compact sender card — user already proved the password, full card not needed.
                compactSenderCard(addr: s.senderAddr, name: s.senderName)
                    .padding(.top, DS.Space.l)

                // Subject + body card
                GlassCard(radius: DS.Radius.card) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        if !s.subject.isEmpty {
                            Text(s.subject)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.primary)
                        }

                        if let policy = s.policy, let expiresAt = s.expiresAt {
                            let expiryDate = Date(timeIntervalSince1970: Double(expiresAt) / 1000)
                            let note: String = policy == "one_time"
                                ? "One-time view — download all attachments now."
                                : "Expires \(expiryDate.formatted(date: .abbreviated, time: .omitted))."
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if !s.body.isEmpty {
                            Divider()
                            Text(s.body)
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, DS.Space.l)

                // Attachments
                if !s.attachments.isEmpty {
                    GlassCard(radius: DS.Radius.card) {
                        VStack(spacing: 0) {
                            ForEach(Array(s.attachments.enumerated()), id: \.element.id) { index, att in
                                attachmentRow(att, decoded: s)
                                if index < s.attachments.count - 1 {
                                    Divider()
                                        .padding(.leading, DS.Space.l)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.l)
                }
            }
            .padding(.bottom, DS.Space.xxl)
        }
    }

    private func compactSenderCard(addr: String, name: String?) -> some View {
        GlassCard(radius: DS.Radius.card) {
            HStack(spacing: DS.Space.m) {
                let initials: String = {
                    if let n = name, !n.isEmpty {
                        let parts = n.split(separator: " ")
                        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)) }
                        return String(n.prefix(2))
                    }
                    return String(addr.prefix(2))
                }()

                DSAvatar(initials: initials, size: .row)

                VStack(alignment: .leading, spacing: 2) {
                    if let n = name, !n.isEmpty {
                        Text(n)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(addr)
                        .font(.dsMono(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                DSEncryptionPill(label: "Decrypted")
            }
            .padding(DS.Space.m)
        }
        .padding(.horizontal, DS.Space.l)
    }

    private func attachmentRow(_ att: AttachmentMeta, decoded: DecodedSecret) -> some View {
        let state = attStates[att.r2Key] ?? .idle
        let isBusy: Bool = { if case .downloading = state { return true } else { return false } }()

        return VStack(spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: mimeIcon(att.mime))
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 2) {
                    Text(att.filename)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(formatBytes(att.plaintextSize))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                attDownloadButton(att: att, state: state, decoded: decoded)
            }

            if case .downloading(let p) = state {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.leading, 48)
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
        .disabled(isBusy)
    }

    @ViewBuilder
    private func attDownloadButton(att: AttachmentMeta, state: AttDownloadState, decoded: DecodedSecret) -> some View {
        switch state {
        case .idle:
            Button("Download", systemImage: "arrow.down.circle") {
                Task { await downloadAttachment(att, decoded: decoded) }
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
                Task { await downloadAttachment(att, decoded: decoded) }
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        case .failed:
            Button("Retry", systemImage: "arrow.down.circle") {
                Task { await downloadAttachment(att, decoded: decoded) }
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Dead screens

    private func deadView(_ reason: DeadReason) -> some View {
        Group {
            switch reason {
            case .selfDestructed:
                DSEmptyState(
                    systemName: "flame",
                    title: "This link has self-destructed",
                    hint: "Too many failed attempts. The content has been deleted."
                )
                // Tint the glyph red via overlay — DSEmptyState uses inkFaint which we override.
                .overlay(alignment: .top) {
                    Image(systemName: "flame")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(.red)
                        .symbolRenderingMode(.hierarchical)
                        .padding(.top, DS.Space.xxl)
                }

            case .revoked:
                DSEmptyState(
                    systemName: "xmark.shield",
                    title: "This link was revoked",
                    hint: "The sender revoked this link. Ask them to share a new one if you still need the content."
                )

            case .expired:
                DSEmptyState(
                    systemName: "clock.badge.xmark",
                    title: "This link has expired",
                    hint: "The link passed its expiry time. Ask the sender to share a new one."
                )

            case .notFound:
                DSEmptyState(
                    systemName: "questionmark.folder",
                    title: "Link not found",
                    hint: "Double-check the URL and try again."
                )
            }
        }
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
        } catch let secretErr as SecretLinkError {
            // 410 from GET signals a dead link. Use the structured state so
            // we render the distinct anti-phishing screen rather than a
            // generic "couldn't load" message.
            switch secretErr {
            case .selfDestructed: phase = .dead(.selfDestructed)
            case .revoked:        phase = .dead(.revoked)
            case .expired:        phase = .dead(.expired)
            default:
                loadError = secretErr.errorDescription ?? "\(secretErr)"
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
                unlockError = .other("Invalid KDF params from server.")
                return
            }

            guard let saltData = Data(b64u: meta.argon_salt_b64) else {
                unlockError = .other("Invalid salt encoding.")
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
                unlockError = .other("Invalid wrapped CEK encoding.")
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
                unlockError = .other("Failed to decrypt message body.")
                return
            }

            // Decrypt attachment filenames. The web encrypts filenames in the
            // single-chunk framed format (ChunkedAEAD) since uploadAttachmentChunked.
            // Try framed first, fall back to single-blob for legacy attachments.
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
                    if let (pt, _) = try? ChunkedAEAD.decryptChunk(cek: cekData, framedChunk: fctData, chunkIndex: 0),
                       let s = String(data: pt, encoding: .utf8) { return s }
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
            DSHaptics.notifySuccess()
            shareFile(at: tmp, filename: att.filename)

        } catch let secretErr as SecretLinkError {
            try? FileManager.default.removeItem(at: tmp)
            switch secretErr {
            case .selfDestructed:
                attStates[att.r2Key] = .failed(message: "Link self-destructed.")
            case .revoked:
                attStates[att.r2Key] = .failed(message: "Link revoked or expired.")
            default:
                attStates[att.r2Key] = .failed(
                    message: secretErr.errorDescription ?? "Download failed."
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            attStates[att.r2Key] = .failed(
                message: (error as? LocalizedError)?.errorDescription ?? "Download failed."
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
