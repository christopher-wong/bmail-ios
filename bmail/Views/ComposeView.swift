import SwiftUI
import Security
import UniformTypeIdentifiers

// MARK: - Attachment icon helper

extension Image {
    /// Returns an SF Symbol appropriate for a given MIME type.
    static func attachmentIcon(for mime: String) -> Image {
        let lower = mime.lowercased()
        if lower.hasPrefix("image/") {
            return Image(systemName: "photo.fill")
        } else if lower.hasPrefix("video/") {
            return Image(systemName: "video.fill")
        } else if lower.hasPrefix("audio/") {
            return Image(systemName: "music.note")
        } else if lower.contains("pdf") || lower.contains("word") || lower.contains("text") {
            return Image(systemName: "doc.fill")
        } else if lower.contains("zip") || lower.contains("gzip") || lower.contains("tar") || lower.contains("compressed") {
            return Image(systemName: "archivebox.fill")
        } else {
            return Image(systemName: "doc.fill")
        }
    }
}

// MARK: - ComposeView

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
    @State private var pendingHostedFilenames: [String: String] = [:]
    @State private var hostedCEK: Data?
    @State private var hostingProgress: [String: Double] = [:]
    @State private var hostingTask: Task<Void, Never>?

    // Secret mode
    @State private var secretMode: Bool = false
    @State private var secretPassword: String = ""
    @State private var secretPasswordConfirm: String = ""
    @State private var secretHint: String = ""
    @State private var secretPolicy: String = "never"

    @State private var draftID: String = UUID().uuidString
    @State private var savedAt: Int64?
    @State private var sending = false
    @State private var sendError: String?
    @State private var autosaveTask: Task<Void, Never>?

    @State private var showCancelConfirm = false
    @State private var showDraftsPicker = false
    @State private var draftsCount: Int = 0

    struct PendingAttachment: Identifiable, Equatable {
        let id: String
        let r2Key: String
        let filename: String
        let filenameCT: String?
        let mime: String
        let sizeBytes: Int64
    }

    private static let hostedThresholdBytes: Int64 = 10 * 1024 * 1024

    @FocusState private var focusedField: Field?
    enum Field: Hashable { case to, cc, bcc, subject, body, secretPassword, secretConfirm, secretHint }

    var addresses: [String] { app.me?.addresses ?? [] }

    /// In-reply-to id (nil for new messages and forwards). Optional chaining
    /// already flattens `messageId`'s own optionality.
    private var inReplyToID: String? { reply?.messageId }

    private var composeTitle: String {
        guard let r = reply else { return "New message" }
        if r.isForward { return "Forward" }
        return r.ccAddrs.isEmpty ? "Reply" : "Reply all"
    }

    private var hasDraftContent: Bool {
        !to.isEmpty || !subject.isEmpty || !bodyText.isEmpty
    }

    private var canSend: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty && !sending
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Secret mode toggle — always visible at top
                    Toggle(isOn: $secretMode.animation(.snappy(duration: 0.22))) {
                        Label("Lock with password", systemImage: secretMode ? "lock.fill" : "lock.open")
                    }
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.m)
                    .onChange(of: secretMode) { _, _ in DSHaptics.impactLight() }

                    Divider()

                    // Secret mode fields
                    if secretMode {
                        secretSection
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Address + subject fields
                    formFieldsSection

                    // Body
                    bodySection

                    // Attachments / uploads
                    if !attachments.isEmpty || !pendingHostedFiles.isEmpty || attaching || hostingTask != nil {
                        attachmentsSection
                    }

                    // Error banner
                    if let e = sendError {
                        errorBanner(e)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(.clear)
            .navigationTitle(composeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if hasDraftContent {
                            showCancelConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(.primary)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Draft saved indicator
                    if let savedAt {
                        Text(RelativeDate.format(savedAt))
                            .font(.footnote)
                            .foregroundStyle(DS.Color.inkFaint)
                    }

                    // Drafts picker button
                    Button {
                        showDraftsPicker = true
                    } label: {
                        Label {
                            if draftsCount > 0 {
                                Text("\(draftsCount)")
                            }
                        } icon: {
                            Image(systemName: draftsCount > 0 ? "tray.full" : "tray")
                        }
                    }
                    .accessibilityLabel(draftsCount > 0 ? "Drafts, \(draftsCount) saved" : "Drafts")

                    // Attach button
                    Button {
                        showFilePicker = true
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .disabled(attaching)
                    .accessibilityLabel("Attach files")

                    // Send button
                    Button {
                        Task { await send() }
                        DSHaptics.notifySuccess()
                    } label: {
                        if sending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(!canSend)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thickMaterial)
        .presentationCornerRadius(DS.Radius.sheet)
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard draft", role: .destructive) {
                DSHaptics.notifyWarning()
                dismiss()
            }
            Button("Keep editing", role: .cancel) {}
        }
        .sheet(isPresented: $showDraftsPicker) {
            DraftPickerSheet(currentDraftID: draftID) { picked in
                loadDraft(picked)
                showDraftsPicker = false
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await handlePicked(result: result) }
        }
        .onAppear(perform: prefill)
        .onChange(of: subject) { _, _ in scheduleAutosave() }
        .onChange(of: bodyText) { _, _ in scheduleAutosave() }
        .onChange(of: to) { _, _ in scheduleAutosave() }
        .onChange(of: cc) { _, _ in scheduleAutosave() }
        .onChange(of: bcc) { _, _ in scheduleAutosave() }
        .task { await refreshDraftCount() }
    }

    // MARK: - Form sections

    private var formFieldsSection: some View {
        VStack(spacing: 0) {
            // From
            fromRow

            Divider().padding(.leading, DS.Space.l)

            // To
            addressRow(
                label: "To",
                text: $to,
                placeholder: "someone@example.com",
                field: .to
            )

            Divider().padding(.leading, DS.Space.l)

            addressRow(label: "Cc", text: $cc, placeholder: "", field: .cc)

            Divider().padding(.leading, DS.Space.l)

            addressRow(label: "Bcc", text: $bcc, placeholder: "", field: .bcc)

            Divider().padding(.leading, DS.Space.l)

            // Subject
            HStack(spacing: DS.Space.m) {
                Text("Subject")
                    .font(.callout)
                    .foregroundStyle(DS.Color.inkFaint)
                    .frame(width: 64, alignment: .leading)
                TextField("", text: $subject)
                    .font(.body)
                    .textInputAutocapitalization(.sentences)
                    .focused($focusedField, equals: .subject)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
        }
    }

    private var fromRow: some View {
        HStack(spacing: DS.Space.m) {
            Text("From")
                .font(.callout)
                .foregroundStyle(DS.Color.inkFaint)
                .frame(width: 64, alignment: .leading)
            Menu {
                ForEach(addresses, id: \.self) { a in
                    Button(a) { from = a }
                }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Text(from.isEmpty ? "—" : from)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DS.Color.inkFaint)
                    Spacer(minLength: 0)
                }
            }
            .accessibilityLabel("From address")
            .accessibilityValue(from)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private func addressRow(
        label: String,
        text: Binding<String>,
        placeholder: String,
        field: Field
    ) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(label)
                .font(.callout)
                .foregroundStyle(DS.Color.inkFaint)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.dsMono(.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .focused($focusedField, equals: field)
                .submitLabel(.next)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private var bodySection: some View {
        VStack(spacing: 0) {
            Divider()
            TextEditor(text: $bodyText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .focused($focusedField, equals: .body)
        }
    }

    // MARK: - Secret mode section

    private var secretSection: some View {
        GlassCard(radius: DS.Radius.card) {
            VStack(spacing: 0) {
                // Header pill
                HStack {
                    DSEncryptionPill(label: "password-locked")
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.xs)

                Divider().padding(.leading, DS.Space.l)

                secretPasswordRow(
                    label: "Password",
                    text: $secretPassword,
                    placeholder: "Choose a password",
                    field: .secretPassword
                )

                Divider().padding(.leading, DS.Space.l)

                secretPasswordRow(
                    label: "Confirm",
                    text: $secretPasswordConfirm,
                    placeholder: "Confirm password",
                    field: .secretConfirm
                )

                Divider().padding(.leading, DS.Space.l)

                // Hint
                HStack(spacing: DS.Space.m) {
                    Text("Hint")
                        .font(.callout)
                        .foregroundStyle(DS.Color.inkFaint)
                        .frame(width: 72, alignment: .leading)
                    TextField("Optional hint for recipient", text: $secretHint)
                        .font(.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .secretHint)
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)

                Divider().padding(.leading, DS.Space.l)

                // Expiry picker
                HStack(spacing: DS.Space.m) {
                    Text("Expires")
                        .font(.callout)
                        .foregroundStyle(DS.Color.inkFaint)
                        .frame(width: 72, alignment: .leading)
                    Picker("Expiry", selection: $secretPolicy) {
                        Text("Never (1 year max)").tag("never")
                        Text("One-time view").tag("one_time")
                        Text("1 hour after open").tag("1h")
                        Text("24 hours after open").tag("24h")
                        Text("14 days after open").tag("14d")
                    }
                    .pickerStyle(.menu)
                    .tint(.accentColor)
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)

                // Info note
                Text("Subject and body are encrypted with the password above. Share the password separately — not in this email.")
                    .font(.footnote)
                    .foregroundStyle(DS.Color.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, DS.Space.m)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }

    private func secretPasswordRow(
        label: String,
        text: Binding<String>,
        placeholder: String,
        field: Field
    ) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(label)
                .font(.callout)
                .foregroundStyle(DS.Color.inkFaint)
                .frame(width: 72, alignment: .leading)
            SecureField(placeholder, text: text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    // MARK: - Attachments section

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Divider()

            // Hosted attachments banner
            if !pendingHostedFiles.isEmpty {
                HStack {
                    DSEncryptionPill(label: "Encrypted attachments")
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.s)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    // Inline attachments
                    ForEach(attachments) { att in
                        inlineAttachmentChip(att)
                    }

                    // Hosted attachments
                    ForEach(pendingHostedFiles, id: \.r2_key) { hf in
                        hostedAttachmentChip(hf)
                    }

                    if attaching || hostingTask != nil {
                        ProgressView()
                            .padding(.horizontal, DS.Space.m)
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s)
            }
        }
    }

    private func inlineAttachmentChip(_ att: PendingAttachment) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image.attachmentIcon(for: att.mime)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkFaint)

            VStack(alignment: .leading, spacing: 1) {
                Text(att.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatBytes(att.sizeBytes))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                removeAttachment(att)
                DSHaptics.impactLight()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DS.Color.inkFaint)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(att.filename)")
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
        .glassEdge(radius: DS.Radius.button)
    }

    private func hostedAttachmentChip(_ hf: HostedFile) -> some View {
        let name = pendingHostedFilenames[hf.r2_key] ?? hf.filename
        let progress = hostingProgress[hf.r2_key]
        let isUploading = progress != nil && progress! < 1.0

        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                if isUploading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(formatBytes(hf.plaintext_size))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    removeHostedFile(hf)
                    DSHaptics.impactLight()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DS.Color.inkFaint)
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isUploading)
                .accessibilityLabel("Remove \(name)")
            }

            // Upload progress bar
            if let p = progress, p < 1.0 {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(maxWidth: 120)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
        .glassEdge(radius: DS.Radius.button)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation { sendError = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(Color(.systemRed).opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Logic (unchanged from original)

    private func prefill() {
        if from.isEmpty, let a = addresses.first { from = a }
        if let r = reply, to.isEmpty {
            to = r.toAddrs.joined(separator: ", ")
            cc = r.ccAddrs.joined(separator: ", ")
            subject = r.subject
            if bodyText.isEmpty, !r.bodyPrefill.isEmpty {
                bodyText = r.bodyPrefill
            }
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
            hydrateHostedState(for: d.id)
        }
    }

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
                in_reply_to_message_id: inReplyToID,
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
        guard !secretPassword.isEmpty else {
            sendError = "Enter a password for the secret link"
            return
        }
        guard secretPassword == secretPasswordConfirm else {
            sendError = "Passwords don't match"
            return
        }
        do {
            let cek = try SecretLinkCrypto.randomCEK()
            let salt = try SecretLinkCrypto.randomSalt(length: 16)
            let kdf = try await Task.detached(priority: .userInitiated) { [pw = secretPassword] in
                try SecretLinkCrypto.derive(
                    password: pw,
                    salt: salt,
                    kdfParams: .default
                )
            }.value
            let passwordWrap = try SecretLinkCrypto.wrapCEK(cek, wrapKey: kdf.wrapKey)
            let subjectCT = try SecretLinkCrypto.encryptWithCEK(Data(subject.utf8), cek: cek)
            let bodyCT    = try SecretLinkCrypto.encryptWithCEK(Data(bodyText.utf8), cek: cek)
            var secretAttachments: [SecretAttachmentRef] = []
            for att in attachments {
                let filenameCT = try ChunkedAEAD.encryptChunk(
                    cek: cek,
                    plaintext: Data(att.filename.utf8),
                    chunkIndex: 0,
                    isFinal: true
                )
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
            let resp = try await APIClient.shared.secretCreate(req: req)
            let shareURL = resp.url
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
                in_reply_to: inReplyToID,
                references: nil,
                attachments: []
            )
            let _: SendResp = try await APIClient.shared.post("/api/messages/send", sendReq)
            _ = try? await APIClient.shared.delete("/api/drafts/\(draftID)")
            DraftStateStore.default.clearHosted(draftID: draftID)
            dismiss()
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: Plain send pipeline

    private func sendPlain() async {
        do {
            var finalBodyText = bodyText
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
                in_reply_to: inReplyToID,
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
            attaching = true
            defer { attaching = false }
            for url in urls {
                await uploadOne(url)
            }
        case .failure(let err):
            sendError = err.localizedDescription
        }
    }

    private func uploadOne(_ url: URL) async {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = resourceValues.fileSize.map { Int64($0) } ?? 0
            let filename = url.lastPathComponent
            let mime = (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) ?? "application/octet-stream"
            if fileSize >= Self.hostedThresholdBytes {
                await uploadHosted(url: url, filename: filename, mime: mime, fileSize: fileSize)
            } else {
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
        if hostedCEK == nil {
            do {
                hostedCEK = try SecretLinkCrypto.randomCEK()
            } catch {
                sendError = "Couldn't mint hosted CEK: \(error)"
                return
            }
        }
        guard let cek = hostedCEK else { return }
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
            hostingProgress.removeValue(forKey: progressKey)
            hostingProgress[result.r2Key] = 1.0
            pendingHostedFiles.append(hostedFile)
            pendingHostedFilenames[result.r2Key] = filename
            persistHostedState()
        } catch {
            hostingProgress.removeValue(forKey: progressKey)
            sendError = (error as? LocalizedError)?.errorDescription ?? "hosted upload failed: \(error)"
        }
    }

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
        if pendingHostedFiles.isEmpty {
            hostedCEK = nil
            DraftStateStore.default.clearHosted(draftID: draftID)
        } else {
            persistHostedState()
        }
    }

    // MARK: - Draft picker

    private func loadDraft(_ d: DraftRow) {
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
