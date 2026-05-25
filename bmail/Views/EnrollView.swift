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
    @State private var phraseConfirmed = false
    @State private var copied = false

    var body: some View {
        ZStack {
            Wallpaper()

            if let phrase = recoveryPhrase {
                recoveryStep(phrase: phrase)
            } else {
                inviteStep
            }
        }
        // Prevent accidental swipe-to-dismiss while the phrase is visible —
        // it is generated exactly once and cannot be recovered.
        .interactiveDismissDisabled(recoveryPhrase != nil)
    }

    // MARK: - Step 1: Invite token entry

    private var inviteStep: some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                Spacer().frame(height: DS.Space.xl)

                // Header outside card
                HStack {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Enroll")
                            .font(.largeTitle.weight(.semibold))
                        Text("Paste your invite link or token to create an account.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 480)

                GlassCard(radius: DS.Radius.sheet) {
                    VStack(spacing: 0) {
                        formRow(label: "Invite token") {
                            TextEditor(text: $token)
                                .font(.dsMono(.footnote))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 60)
                        }
                        Divider().padding(.leading, DS.Space.l)
                        formRow(label: "Handle") {
                            TextField("Optional", text: $handle)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Divider().padding(.leading, DS.Space.l)
                        formRow(label: "Display name") {
                            TextField("Optional", text: $displayName)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                        }
                        Divider().padding(.leading, DS.Space.l)
                        formRow(label: "Device") {
                            TextField("This iPhone", text: $credLabel)
                                .textInputAutocapitalization(.words)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 480)

                if let err = app.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Space.xl)
                }

                Button {
                    Task { await enroll() }
                } label: {
                    if busy {
                        ProgressView()
                            .controlSize(.regular)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Space.xs)
                    } else {
                        Text("Create account")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.large)
                .disabled(busy || normalizedToken.isEmpty)
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 480)

                Spacer().frame(height: DS.Space.xl)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Step 2: Recovery phrase reveal

    @ViewBuilder
    private func recoveryStep(phrase: String) -> some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                Spacer().frame(height: DS.Space.xl)

                // Title block
                VStack(spacing: DS.Space.m) {
                    Text("Save your recovery phrase")
                        .font(.largeTitle.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text("Twelve words. Write them down. Without them, you cannot recover this account.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)

                    DSEncryptionPill(label: "Read once")
                        .accessibilityLabel("Shown one time only")
                }
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 480)

                // Phrase grid
                GlassCard(radius: DS.Radius.sheet) {
                    VStack(spacing: DS.Space.l) {
                        phraseGrid(phrase: phrase)

                        // Copy button
                        Button {
                            copyPhrase(phrase)
                        } label: {
                            Label(
                                copied ? "Copied" : "Copy phrase",
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.accentColor)
                        .animation(.easeInOut(duration: 0.2), value: copied)
                    }
                    .padding(DS.Space.l)
                }
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 480)

                // Confirmation toggle
                GlassCard(radius: DS.Radius.card) {
                    Toggle(isOn: $phraseConfirmed) {
                        Text("I've saved my recovery phrase somewhere safe.")
                            .font(.subheadline)
                    }
                    .tint(Color.accentColor)
                    .padding(DS.Space.l)
                }
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 480)

                // Primary action
                Button {
                    app.finishEnrollment()
                    dismiss()
                } label: {
                    Text("I've saved it")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.large)
                .disabled(!phraseConfirmed)
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 480)

                Spacer().frame(height: DS.Space.xl)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Phrase grid

    private func phraseGrid(phrase: String) -> some View {
        let words = phrase.split(separator: " ").map(String.init)
        return LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: DS.Space.s
        ) {
            ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: DS.Space.s) {
                    Text("\(idx + 1)")
                        .font(.dsMono(.footnote))
                        .foregroundStyle(DS.Color.inkFaint)
                        .frame(width: 20, alignment: .trailing)
                    Text(word)
                        .font(.dsMono(.body, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .fill(.thinMaterial)
                )
            }
        }
    }

    // MARK: - Helpers

    private func formRow<Field: View>(label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            field()
                .font(.body)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private var normalizedToken: String {
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

    private func copyPhrase(_ phrase: String) {
        // Auto-expiring, local-only pasteboard entry — the recovery phrase is
        // the master mailbox secret and must not linger on the system pasteboard
        // or sync to other devices.
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: phrase]],
            options: [
                .expirationDate: Date().addingTimeInterval(60),
                .localOnly: true,
            ]
        )
        DSHaptics.notifySuccess()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
