import SwiftUI
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

    @State private var draftID: String?
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
                }

                TextEditor(text: $bodyText)
                    .font(.mono(.subheadline))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(maxHeight: .infinity)
                    .focused($keyboardFocused)

                if !attachments.isEmpty || attaching {
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

    private var attachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
                if attaching {
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
        if let d = resumeDraft, draftID == nil {
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
        do {
            let req = SendReq(
                from: from,
                from_name: app.me?.display_name,
                to: splitAddrs(to),
                cc: splitAddrs(cc),
                bcc: splitAddrs(bcc),
                subject: subject,
                text: bodyText,
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
            if let id = draftID {
                _ = try? await APIClient.shared.delete("/api/drafts/\(id)")
            }
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
            let bytes = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            let mime = (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) ?? "application/octet-stream"
            let filenameCT: String? = {
                guard let pub = app.pub else { return nil }
                return (try? Crypto.sealToSelf(Data(filename.utf8), pub: pub))?.b64u
            }()
            let resp = try await AttachmentService.shared.upload(
                bytes: bytes, mime: mime, filenameCT: filenameCT, draftID: draftID
            )
            attachments.append(PendingAttachment(
                id: resp.id,
                r2Key: resp.r2_key,
                filename: filename,
                filenameCT: filenameCT,
                mime: resp.mime,
                sizeBytes: resp.size_bytes
            ))
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? "upload failed: \(error)"
        }
    }

    private func removeAttachment(_ att: PendingAttachment) {
        attachments.removeAll { $0.id == att.id }
        Task { try? await AttachmentService.shared.delete(id: att.id) }
    }

    // MARK: - Draft picker

    private func loadDraft(_ d: DraftRow) {
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
