import SwiftUI

struct EnrollView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var token: String = ""
    @State private var handle: String = ""
    @State private var displayName: String = ""
    @State private var credLabel: String = "iPhone"
    @State private var busy = false
    @State private var recoveryPhrase: String?
    @State private var savedConfirmed = false
    @State private var copied = false

    @ScaledMetric(relativeTo: .footnote) private var labelColumn: CGFloat = 110
    @ScaledMetric(relativeTo: .caption) private var phraseIndexWidth: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            if let phrase = recoveryPhrase {
                recoveryStep(phrase: phrase)
            } else {
                inviteStep
            }
        }
        .background(Theme.inverseInk)
        // Block swipe-to-dismiss once we're showing the recovery phrase —
        // the phrase is generated exactly once and would be unrecoverable
        // if the sheet closed before the user copied/wrote it down.
        .interactiveDismissDisabled(recoveryPhrase != nil)
    }

    // MARK: - Step 1: invite + passkey

    private var inviteStep: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ENROLL")
                    .font(.mono(12, .medium))
                    .tracking(1.5)
                Spacer()
                Button("CANCEL") { dismiss() }.monoButton()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline()

            ScrollView {
                VStack(spacing: 0) {
                    intro
                    fieldGroup
                    if let err = app.lastError {
                        Text(err)
                            .font(.mono(12))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actionRow
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("paste the invite link or token below.")
                .font(.mono(13))
            Text("we'll create a passkey on this device and show you a one-time 12-word recovery phrase. write it down — without it or a passkey, your mailbox is unrecoverable.")
                .font(.mono(11))
                .foregroundStyle(Theme.mute)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fieldGroup: some View {
        VStack(spacing: 0) {
            Hairline()
            inputRow(label: "token", text: $token, placeholder: "paste invite token", multiline: true)
            Hairline()
            inputRow(label: "handle", text: $handle, placeholder: "optional — server may already have one")
            Hairline()
            inputRow(label: "display name", text: $displayName, placeholder: "optional")
            Hairline()
            inputRow(label: "device", text: $credLabel, placeholder: "this iPhone")
            Hairline()
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            Button(busy ? "ENROLLING…" : "CREATE ACCOUNT ▸") {
                Task { await enroll() }
            }
            .monoButton(prominent: true, disabled: busy || normalizedToken.isEmpty)
            .disabled(busy || normalizedToken.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var normalizedToken: String {
        // Accept a full enrollment URL ("https://.../enroll/abc") or just the token.
        let raw = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = raw.split(separator: "/").last { return String(last) }
        return raw
    }

    private func enroll() async {
        busy = true
        defer { busy = false }
        let phrase = await app.enrollWithInvite(
            token: normalizedToken,
            handle: handle.isEmpty ? nil : handle,
            displayName: displayName.isEmpty ? nil : displayName,
            credentialLabel: credLabel.isEmpty ? nil : credLabel
        )
        if let phrase { recoveryPhrase = phrase }
    }

    // MARK: - Step 2: recovery phrase reveal

    @ViewBuilder
    private func recoveryStep(phrase: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("RECOVERY PHRASE")
                    .font(.mono(12, .medium))
                    .tracking(1.5)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("write these 12 words down. you'll need them if you ever lose this device.")
                        .font(.mono(12))
                        .foregroundStyle(Theme.mute)

                    phraseGrid(phrase: phrase)

                    HStack {
                        Spacer()
                        Button(copied ? "COPIED ✓" : "COPY") {
                            // Auto-expire the pasteboard entry and keep it on
                            // this device — the recovery phrase is the master
                            // mailbox secret; we don't want it on the system
                            // pasteboard indefinitely or synced to other Macs.
                            UIPasteboard.general.setItems(
                                [[UIPasteboard.typeAutomatic: phrase]],
                                options: [
                                    .expirationDate: Date().addingTimeInterval(60),
                                    .localOnly: true,
                                ]
                            )
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        }
                        .monoButton()
                    }

                    Toggle(isOn: $savedConfirmed) {
                        Text("i've saved my recovery phrase somewhere safe.")
                            .font(.mono(12))
                    }
                    .tint(Theme.ink)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            Hairline()
            HStack {
                Spacer()
                Button("ENTER MAILBOX ▸") {
                    app.finishEnrollment()
                    dismiss()
                }
                .monoButton(prominent: true, disabled: !savedConfirmed)
                .disabled(!savedConfirmed)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func phraseGrid(phrase: String) -> some View {
        let words = phrase.split(separator: " ").map(String.init)
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: 8) {
                    Text("\(idx + 1)".padded(to: 2))
                        .font(.mono(11))
                        .foregroundStyle(Theme.mute)
                        .frame(width: phraseIndexWidth, alignment: .trailing)
                    Text(word)
                        .font(.mono(14, .medium))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
        }
    }

    // MARK: - Helpers

    private func inputRow(label: String, text: Binding<String>, placeholder: String, multiline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .monoLabel()
                .frame(width: labelColumn, alignment: .leading)
                .padding(.top, 12)
            if multiline {
                TextEditor(text: text)
                    .font(.mono(13))
                    .frame(minHeight: 60)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
            } else {
                TextField(placeholder, text: text)
                    .font(.mono(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 16)
    }
}

private extension String {
    func padded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
