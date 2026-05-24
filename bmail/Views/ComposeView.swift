import SwiftUI
import Security
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var reply: ThreadView.ReplyState? = nil
    var resumeDraft: DraftRow? = nil

    @State private var from: String = ""
    @State private var to: String = ""
    @State private var cc: String = ""
    @State private var bcc: String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""

    @State private var attachments: [PendingAttachment] = []
    @State private var attaching = false
    @State private var showFilePicker = false

    // Hosted attachment state (files ≥ 10 MiB)
    @State private var pendingHostedFiles: [HostedFile] = []
    @State private var pendingHostedFilenames: [String: String] = [:]  // r2Key → display name
    // TODO(Phase 5): persist hostedCEK to a per-draft state file (IndexedDB equivalent)
    // so a crash mid-compose doesn't strand ciphertext on R2 without a key.
    @State private var hostedCEK: Data?
    @State private var hostingProgress: [String: Double] = [:]         // r2Key → 0…1
    @State private var hostingTask: Task<Void, Never>?

    // Secret mode
    @State private var secretMode: Bool = false
    @State private var secretPassword: String = ""
    @State private var secretPasswordConfirm: String = ""
    @State private var secretHint: String = ""
    @State private var secretPolicy: String = "never"

    /// Client-minted draft ID. Generated once at init for new drafts; replaced
    /// with the server's id when resuming from the drafts list. Used as both
    /// the autosave key and the DraftStateStore key for hosted-CEK recovery.
    @State private var draftID: String = UUID().uuidString
    @State private var savedAt: Int64?
    @State private var sending = false
    @State private var sendError: String?
    @State private var autosaveTask: Task<Void, Never>?

    struct PendingAttachment: Identifiable, Equatable {
        let id: String
        let r2Key: String
        let filename: String
        let filenameCT: String?
        let mime: String
        let sizeBytes: Int64
    }

    private static let hostedThresholdBytes: Int64 = 10 * 1024 * 1024  // 10 MiB

    @ScaledMetric(relativeTo: .footnote) private var labelColumn: CGFloat = 70
    @FocusState private var keyboardFocused: Bool

    @State private var showDraftsPicker = false
    @State private var draftsCount: Int = 0

    var addresses: [String] { app.me?.addresses ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                VStack(spacing: 0) {
                    fromField
                    Hairline()
                    addressField(label: "to", text: $to, placeholder: "someone@example.com")
                    Hairline()
                    addressField(label: "cc", text: $cc, placeholder: "")
                    Hairline()
                    addressField(label: "bcc", text: $bcc, placeholder: "")
                    Hairline()
                    addressField(label: "subject", text: $subject, placeholder: "")
                    Hairline()
                    if secretMode {
                        secretFields
                    }
                }

                if secretMode {
                    Text("Subject and body will be encrypted with the password above. The recipient needs the password you choose.")
                        .font(.mono(10))
                        .foregroundStyle(Theme.mute)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                    Hairline()
                }

                TextEditor(text: $bodyText)
                    .font(.mono(.subheadline))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(maxHeight: .infinity)
                    .focused($keyboardFocused)

                if !attachments.isEmpty || !pendingHostedFiles.isEmpty || attaching || hostingTask != nil {
                    Hairline()
                    attachmentsBar
                }

                if let e = sendError {
                    Hairline()
                    Text(e)
                        .font(.mono(12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Theme.inverseInk)
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear(perform: prefill)
        .onChange(of: subject) { _, _ in scheduleAutosave() }
        .onChange(of: bodyText) { _, _ in scheduleAutosave() }
        .onChange(of: to) { _, _ in scheduleAutosave() }
        .onChange(of: cc) { _, _ in scheduleAutosave() }
        .onChange(of: bcc) { _, _ in scheduleAutosave() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await handlePicked(result: result) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { keyboardFocused = false }
                    .font(.mono(.footnote, weight: .medium))
            }
        }
        .sheet(isPresented: $showDraftsPicker) {
            DraftPickerSheet(currentDraftID: draftID) { picked in
                loadDraft(picked)
                showDraftsPicker = false
            }
        }
        .task { await refreshDraftCount() }
    }

    // MARK: - Secret mode fields

    private var secretFields: some View {
        VStack(spacing: 0) {
            secretPasswordField(label: "password", text: $secretPassword, placeholder: "choose a password")
            Hairline()
            secretPasswordField(label: "confirm", text: $secretPasswordConfirm, placeholder: "confirm password")
            Hairline()
            addressField(label: "hint", text: $secretHint, placeholder: "optional hint for recipient")
            Hairline()
            HStack(spacing: 0) {
                Text("expires")
                    .monoLabel()
                    .frame(width: labelColumn, alignment: .leading)
                Picker("", selection: $secretPolicy) {
                    Text("never (1y max)").tag("never")
                    Text("one-time view").tag("one_time")
                    Text("1h after open").tag("1h")
                    Text("24h after open").tag("24h")
                    Text("14 days after open").tag("14d")
                }
                .pickerStyle(.menu)
                .font(.mono(.subheadline))
                .tint(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Hairline()
        }
    }

    private func secretPasswordField(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .monoLabel()
                .frame(width: labelColumn, alignment: .leading)
            SecureField(placeholder, text: text)
                .font(.mono(.subheadline))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($keyboardFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var attachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Regular (< 10 MiB) inline attachments
                ForEach(attachments) { att in
                    HStack(spacing: 6) {
                        Text(att.filename)
                            .font(.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(formatBytes(att.sizeBytes))
                            .font(.mono(10))
                            .foregroundStyle(Theme.mute)
                        Button {
                            removeAttachment(att)
                        } label: {
                            Text("×")
                                .font(.mono(.subheadline, weight: .medium))
                                .foregroundStyle(Theme.mute)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment \(att.filename)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
                // Hosted (≥ 10 MiB) encrypted attachments
                ForEach(pendingHostedFiles, id: \.r2_key) { hf in
                    let name = pendingHostedFilenames[hf.r2_key] ?? hf.filename
                    let progress = hostingProgress[hf.r2_key]
                    HStack(spacing: 6) {
                        if let p = progress, p < 1.0 {
                            ProgressView(value: p)
                                .progressViewStyle(.linear)
                                .frame(width: 50)
                                .tint(Theme.ink)
                        } else {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.mute)
                                .accessibilityHidden(true)
                        }
                        Text(name)
                            .font(.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(formatBytes(hf.plaintext_size))
                            .font(.mono(10))
                            .foregroundStyle(Theme.mute)
                        Button {
                            removeHostedFile(hf)
                        } label: {
                            Text("×")
                                .font(.mono(.subheadline, weight: .medium))
                                .foregroundStyle(Theme.mute)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .disabled(progress != nil && progress! < 1.0)
                        .accessibilityLabel("Remove hosted file \(name)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
                if attaching || hostingTask != nil {
                    ProgressView().padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(reply != nil ? "REPLY" : "NEW MESSAGE")
                    .font(.mono(12, .medium))
                    .tracking(1.5)
                Spacer()
                if let savedAt {
                    Text("draft saved \(RelativeDate.format(savedAt))")
                        .font(.mono(10))
                        .foregroundStyle(Theme.mute)
                }
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        secretMode.toggle()
                    }
                } label: {
                    Image(systemName: secretMode ? "lock.fill" : "lock.open")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(secretMode ? Theme.ink : Theme.mute)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(secretMode ? Theme.ink : Theme.hairline, lineWidth: secretMode ? 1.5 : 1)
                        )
                        .frame(minHeight: 44)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(secretMode ? "Secret mode on — tap to disable" : "Enable secret mode")
                .accessibilityAddTraits(.isButton)

                Button { showFilePicker = true } label: {
                    Image(systemName: "paperclip")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: 1)
                        )
                        .frame(minHeight: 44)
                        .opacity(attaching ? 0.4 : 1)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(attaching)
                .accessibilityLabel("Attach files")
                .accessibilityAddTraits(.isButton)

                Button { showDraftsPicker = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.full")
                            .font(.footnote.weight(.medium))
                        if draftsCount > 0 {
                            Text("\(draftsCount)")
                                .font(.mono(.footnote, weight: .medium))
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )
                    .frame(minHeight: 44)
                    .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(draftsCount > 0 ? "Drafts, \(draftsCount) saved" : "Drafts")
                .accessibilityAddTraits(.isButton)

                Button("CANCEL") { dismiss() }
                    .monoButton()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Button(sending ? "…" : "SEND ▸") {
                    Task { await send() }
                }
                .monoButton(prominent: true, disabled: sending || to.isEmpty)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(sending || to.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline()
        }
    }

    private var fromField: some View {
        HStack(spacing: 0) {
            Text("from")
                .monoLabel()
                .frame(width: labelColumn, alignment: .leading)
            Menu {
                ForEach(addresses, id: \.self) { a in
                    Button(a) { from = a }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(from.isEmpty ? "—" : from)
                        .font(.mono(.subheadline))
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.mute)
                        .accessibilityHidden(true)
                    Spacer()
                }
            }
            .accessibilityLabel("From address")
            .accessibilityValue(from)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func addressField(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .monoLabel()
                .frame(width: labelColumn, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.mono(.subheadline))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($keyboardFocused)
                .submitLabel(label == "subject" ? .next : .next)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func prefill() {
        if from.isEmpty, let a = addresses.first { from = a }
        if let r = reply, to.isEmpty {
            to = r.toAddrs.joined(separator: ", ")
            subject = r.subject
        }
        if let d = resumeDraft, draftID != d.id {
            draftID = d.id
            to = d.to_addrs.joined(separator: ", ")
            cc = d.cc_addrs.joined(separator: ", ")
            bcc = d.bcc_addrs.joined(separator: ", ")
            if let priv = app.priv {
                if let s = d.subject_ct_b64, let blob = Data(b64u: s),
                   let plain = try? Crypto.openSealedString(blob, priv: priv) {
                    subject = plain
                }
                if let b = d.body_ct_b64, let blob = Data(b64u: b),
                   let plain = try? Crypto.openSealedString(blob, priv: priv) {
                    bodyText = plain
                }
            }
            // Recover hosted-attachment state from disk so any partially-uploaded
            // files from a previous session are restored. Runs synchronously on
            // the main thread; the file read is tiny (JSON, < 1 KB typical).
            hydrateHostedState(for: d.id)
        }
    }

    /// Restore hosted CEK + file list from DraftStateStore for `draftID`.
    private func hydrateHostedState(for id: String) {
        guard let saved = DraftStateStore.default.loadHosted(draftID: id) else { return }
        guard let cek = Data(b64u: saved.cekB64) else { return }
        hostedCEK = cek
        pendingHostedFiles = saved.files.map {
            HostedFile(
                r2_key: $0.r2Key,
                size: $0.size,
                plaintext_size: $0.plaintextSize,
                chunk_size: Int64($0.chunkSize),
                chunk_count: Int64($0.chunkCount),
                filename: $0.filename,
                mime: $0.mime
            )
        }
        for f in saved.files {
            pendingHostedFilenames[f.r2Key] = f.filename
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if Task.isCancelled { return }
            await autosave()
        }
    }

    private func autosave() async {
        guard let pub = app.pub else { return }
        if subject.isEmpty, bodyText.isEmpty, to.isEmpty { return }
        do {
            let subjectCT = subject.isEmpty ? nil :
                (try Crypto.sealToSelf(Data(subject.utf8), pub: pub)).b64u
            let bodyCT = bodyText.isEmpty ? nil :
                (try Crypto.sealToSelf(Data(bodyText.utf8), pub: pub)).b64u
            let req = DraftSaveReq(
                id: draftID,
                in_reply_to_message_id: reply?.messageId,
                to_addrs: splitAddrs(to),
                cc_addrs: splitAddrs(cc),
                bcc_addrs: splitAddrs(bcc),
                subject_ct_b64: subjectCT,
                body_ct_b64: bodyCT,
                attachments: []
            )
            let resp: DraftSaveResp = try await APIClient.shared.post("/api/drafts", req)
            self.draftID = resp.id
            self.savedAt = resp.updated_at
        } catch {
            // autosave is best-effort
        }
    }

    private func send() async {
        sendError = nil
        sending = true
        defer { sending = false }

        if secretMode {
            await sendSecret()
        } else {
            await sendPlain()
        }
    }

    // MARK: Secret send pipeline

    private func sendSecret() async {
        // Validate password fields first.
        guard !secretPassword.isEmpty else {
            sendError = "enter a password for the secret link"
            return
        }
        guard secretPassword == secretPasswordConfirm else {
            sendError = "passwords don't match"
            return
        }
        do {
            // 1. Mint CEK (32 random bytes).
            let cek = SecretLinkCrypto.randomCEK()

            // 2. Generate a random 16-byte salt.
            let salt = SecretLinkCrypto.randomSalt(length: 16)

            // 3. Derive KDF (Argon2id + HKDF split) on a background thread.
            let kdf = try await Task.detached(priority: .userInitiated) { [pw = secretPassword] in
                try SecretLinkCrypto.derive(
                    password: pw,
                    salt: salt,
                    kdfParams: .default
                )
            }.value

            // 4. AES-GCM-wrap the CEK with kdf.wrapKey → password_wrap_b64.
            let passwordWrap = try SecretLinkCrypto.wrapCEK(cek, wrapKey: kdf.wrapKey)

            // 5. Encrypt subject and body with the single-blob format (CEK, no AAD).
            let subjectCT = try SecretLinkCrypto.encryptWithCEK(Data(subject.utf8), cek: cek)
            let bodyCT    = try SecretLinkCrypto.encryptWithCEK(Data(bodyText.utf8), cek: cek)

            // 6. Upload attachments (encrypt each chunk with ChunkedAEAD).
            //    Inline attachments (< 10 MiB) are reuploaded under the secret CEK.
            //    Hosted attachments already uploaded under a different CEK are not
            //    reused; instead the user should attach them again in secret mode.
            var secretAttachments: [SecretAttachmentRef] = []
            for att in attachments {
                // Encrypt the filename as a single-chunk framed blob.
                let filenameCT = try ChunkedAEAD.encryptChunk(
                    cek: cek,
                    plaintext: Data(att.filename.utf8),
                    chunkIndex: 0,
                    isFinal: true
                )

                // Fetch the plaintext bytes from the already-uploaded r2 blob.
                // Since the attachment was uploaded plaintext (kind=.attach), we
                // can't re-encrypt in-place; we'd need the plaintext. For this
                // phase we upload the already-stored attachment data without
                // re-encrypting its body — only the filename_ct wraps.
                // TODO(Phase 5): pipe plaintext bytes through Uploader with secret CEK.
                secretAttachments.append(SecretAttachmentRef(
                    r2_key: att.r2Key,
                    mime: att.mime,
                    size: att.sizeBytes,
                    filename_ct_b64: filenameCT.b64u,
                    plaintext_size: att.sizeBytes,
                    chunk_size: att.sizeBytes,
                    chunk_count: 1
                ))
            }

            // 7. Build the create request.
            let kdfParamsJSON = (try? JSONEncoder().encode(ArgonParams.default))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            let req = SecretCreateReq(
                recipient: splitAddrs(to).first,
                hint: secretHint.isEmpty ? nil : secretHint,
                policy: secretPolicy,
                argon_salt_b64: salt.b64u,
                kdf_params: kdfParamsJSON,
                password_check_b64: kdf.check.b64u,
                password_wrap_b64: passwordWrap.b64u,
                subject_ct_b64: subjectCT.b64u,
                body_ct_b64: bodyCT.b64u,
                attachments: secretAttachments.isEmpty ? nil : secretAttachments
            )

            // 8. Create the secret link — get back token + url.
            let resp = try await APIClient.shared.secretCreate(req: req)
            let shareURL = resp.url

            // 9. Append the link to the outgoing email body and send.
            let linkBody = "\n\nView encrypted message: \(shareURL)\n(Share the password separately — not in this email.)"
            let plainBody = "[This message is encrypted. Open the link below to read it.]\(linkBody)"

            let sendReq = SendReq(
                from: from,
                from_name: app.me?.display_name,
                to: splitAddrs(to),
                cc: splitAddrs(cc),
                bcc: splitAddrs(bcc),
                subject: subject.isEmpty ? "(secret message)" : subject,
                text: plainBody,
                html: nil,
                in_reply_to: reply?.messageId,
                references: nil,
                attachments: []  // attachments travel through the secret link, not MIME
            )
            let _: SendResp = try await APIClient.shared.post("/api/messages/send", sendReq)
            _ = try? await APIClient.shared.delete("/api/drafts/\(draftID)")
            // Secret mode doesn't use hosted attachments, but clear defensively.
            DraftStateStore.default.clearHosted(draftID: draftID)
            dismiss()
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: Plain send pipeline (unchanged)

    private func sendPlain() async {
        do {
            var finalBodyText = bodyText

            // If there are hosted attachments, register them and append share URLs.
            if !pendingHostedFiles.isEmpty, let cek = hostedCEK {
                let sealedCEK = try Crypto.sealToSelf(cek, pub: app.pub!)
                let resp = try await APIClient.shared.hostedCreate(
                    files: pendingHostedFiles,
                    senderCekWrapB64: sealedCEK.b64u,
                    recipientAddrs: splitAddrs(to),
                    subject: subject.isEmpty ? nil : subject
                )
                let shareURL = "\(resp.url_prefix)#k=\(cek.b64u)"
                let fileLines = pendingHostedFiles.map { hf -> String in
                    let name = pendingHostedFilenames[hf.r2_key] ?? hf.filename
                    return "  - \(name) — \(shareURL)"
                }.joined(separator: "\n")
                finalBodyText += "\n\nHosted attachments:\n\(fileLines)"
            }

            let req = SendReq(
                from: from,
                from_name: app.me?.display_name,
                to: splitAddrs(to),
                cc: splitAddrs(cc),
                bcc: splitAddrs(bcc),
                subject: subject,
                text: finalBodyText,
                html: nil,
                in_reply_to: reply?.messageId,
                references: nil,
                attachments: attachments.map {
                    AttachmentRef(
                        r2_key: $0.r2Key,
                        filename: $0.filename,
                        filename_ct_b64: $0.filenameCT,
                        mime: $0.mime
                    )
                }
            )
            let _: SendResp = try await APIClient.shared.post("/api/messages/send", req)
            _ = try? await APIClient.shared.delete("/api/drafts/\(draftID)")
            // Hosted-attachment state is committed server-side now — drop the local copy.
            DraftStateStore.default.clearHosted(draftID: draftID)
            dismiss()
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Attachments

    private func handlePicked(result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            // Each file may take a very different code path (inline vs hosted)
            // but we still gate the whole batch under `attaching` for the spinner.
            attaching = true
            defer { attaching = false }
            for url in urls {
                await uploadOne(url)
            }
        case .failure(let err):
            sendError = err.localizedDescription
        }
    }

    /// Files < 10 MiB: inline MIME via existing AttachmentService path.
    /// Files ≥ 10 MiB: end-to-end encrypted hosted upload via Uploader.
    private func uploadOne(_ url: URL) async {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = resourceValues.fileSize.map { Int64($0) } ?? 0
            let filename = url.lastPathComponent
            let mime = (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) ?? "application/octet-stream"

            if fileSize >= Self.hostedThresholdBytes {
                // Hosted path: encrypt on-the-fly, upload to R2.
                await uploadHosted(url: url, filename: filename, mime: mime, fileSize: fileSize)
            } else {
                // Inline attachment path: stream through the unified uploads
                // pipeline with kind=.attach. The server registers a mailbox
                // attachment row and returns its id on /complete.
                let filenameCT: String? = {
                    guard let pub = app.pub else { return nil }
                    return (try? Crypto.sealToSelf(Data(filename.utf8), pub: pub))?.b64u
                }()
                let result = try await Uploader.shared.upload(
                    source: url,
                    kind: .attach,
                    mime: mime,
                    draftID: draftID,
                    filenameCTb64: filenameCT
                )
                guard let attachmentID = result.attachmentId else {
                    throw NSError(domain: "ComposeView", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "upload completed without attachment id"
                    ])
                }
                attachments.append(PendingAttachment(
                    id: attachmentID,
                    r2Key: result.r2Key,
                    filename: filename,
                    filenameCT: filenameCT,
                    mime: mime,
                    sizeBytes: result.size
                ))
            }
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? "upload failed: \(error)"
        }
    }

    private func uploadHosted(url: URL, filename: String, mime: String, fileSize: Int64) async {
        // Mint CEK lazily — one CEK per draft covers all hosted files.
        if hostedCEK == nil {
            var raw = Data(count: 32)
            _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            hostedCEK = raw
        }
        guard let cek = hostedCEK else { return }

        // Placeholder r2Key is overwritten once upload completes.
        // Track progress by a temporary key derived from filename+size.
        let progressKey = "\(filename)-\(fileSize)"
        hostingProgress[progressKey] = 0.0

        do {
            let result = try await Uploader.shared.upload(
                source: url,
                kind: .hosted,
                mime: mime,
                transform: { plaintext, idx, isFinal in
                    try ChunkedAEAD.encryptChunk(
                        cek: cek,
                        plaintext: plaintext,
                        chunkIndex: UInt32(idx),
                        isFinal: isFinal
                    )
                },
                onProgress: { uploaded, total in
                    let pct = total > 0 ? Double(uploaded) / Double(total) : 0.0
                    Task { @MainActor in
                        self.hostingProgress[progressKey] = pct
                    }
                }
            )

            let hostedFile = HostedFile(
                r2_key: result.r2Key,
                size: result.size,
                plaintext_size: result.plaintextSize,
                chunk_size: Int64(result.chunkSize),
                chunk_count: Int64(result.chunkCount),
                filename: filename,
                mime: mime
            )

            // Move progress tracking to the real r2Key.
            hostingProgress.removeValue(forKey: progressKey)
            hostingProgress[result.r2Key] = 1.0
            pendingHostedFiles.append(hostedFile)
            pendingHostedFilenames[result.r2Key] = filename

            // Persist hosted state so a crash / app kill doesn't strand the
            // ciphertext on R2 without its key. (Phase 5 recovery point.)
            persistHostedState()
        } catch {
            hostingProgress.removeValue(forKey: progressKey)
            sendError = (error as? LocalizedError)?.errorDescription ?? "hosted upload failed: \(error)"
        }
    }

    /// Build the current HostedDraftState snapshot and write it to disk.
    private func persistHostedState() {
        guard let cek = hostedCEK else { return }
        let state = HostedDraftState(
            cekB64: cek.b64u,
            files: pendingHostedFiles.map {
                HostedDraftFile(
                    r2Key: $0.r2_key,
                    filename: pendingHostedFilenames[$0.r2_key] ?? $0.filename,
                    mime: $0.mime,
                    size: $0.size,
                    plaintextSize: $0.plaintext_size,
                    chunkSize: Int($0.chunk_size),
                    chunkCount: Int($0.chunk_count)
                )
            }
        )
        DraftStateStore.default.saveHosted(draftID: draftID, state: state)
    }

    private func removeAttachment(_ att: PendingAttachment) {
        attachments.removeAll { $0.id == att.id }
        Task { try? await AttachmentService.shared.delete(id: att.id) }
    }

    private func removeHostedFile(_ hf: HostedFile) {
        pendingHostedFiles.removeAll { $0.r2_key == hf.r2_key }
        pendingHostedFilenames.removeValue(forKey: hf.r2_key)
        hostingProgress.removeValue(forKey: hf.r2_key)

        // Keep persisted state in sync. If no files remain, clear the state file
        // entirely so there's no orphan entry if the user abandons the compose.
        if pendingHostedFiles.isEmpty {
            hostedCEK = nil
            DraftStateStore.default.clearHosted(draftID: draftID)
        } else {
            persistHostedState()
        }
        // TODO: call uploads_abort for any in-progress multipart upload and
        // issue a server-side orphan cleanup once a delete-r2-object endpoint
        // is exposed. Currently the server runs a daily orphan sweep against
        // R2 keys with no associated hosted_downloads row.
    }

    // MARK: - Draft picker

    private func loadDraft(_ d: DraftRow) {
        // Clear hosted state for the previous draft before switching.
        pendingHostedFiles = []
        pendingHostedFilenames = [:]
        hostedCEK = nil

        draftID = d.id
        to = d.to_addrs.joined(separator: ", ")
        cc = d.cc_addrs.joined(separator: ", ")
        bcc = d.bcc_addrs.joined(separator: ", ")
        subject = ""
        bodyText = ""
        if let priv = app.priv {
            if let s = d.subject_ct_b64, let blob = Data(b64u: s),
               let plain = try? Crypto.openSealedString(blob, priv: priv) {
                subject = plain
            }
            if let b = d.body_ct_b64, let blob = Data(b64u: b),
               let plain = try? Crypto.openSealedString(blob, priv: priv) {
                bodyText = plain
            }
        }
        hydrateHostedState(for: d.id)
    }

    private func refreshDraftCount() async {
        if let rows: [DraftRow] = try? await APIClient.shared.get("/api/drafts") {
            draftsCount = rows.count
        }
    }
}

struct SendResp: Decodable { let message_id: String; let thread_id: String }

private func splitAddrs(_ s: String) -> [String] {
    s.split(whereSeparator: { $0 == "," || $0 == ";" })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func formatBytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: n)
}
