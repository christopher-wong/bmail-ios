import SwiftUI

struct RecoveryLoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var handle: String = ""
    @State private var phrase: String = ""
    @State private var busy = false

    private var canSubmit: Bool {
        !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        phrase.split(whereSeparator: \.isWhitespace).count == 12
    }

    var body: some View {
        ZStack {
            Wallpaper()

            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    Spacer().frame(height: DS.Space.xl)

                    GlassCard(radius: DS.Radius.sheet) {
                        VStack(alignment: .leading, spacing: DS.Space.xl) {

                            // Header
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Text("Recover account")
                                    .font(.title2.weight(.semibold))

                                Text("Enter your handle and the 12-word recovery phrase.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            // Fields
                            VStack(spacing: DS.Space.m) {
                                TextField("Handle", text: $handle)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.asciiCapable)

                                TextEditor(text: $phrase)
                                    .font(.dsMono(.body))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 100)
                                    .padding(DS.Space.s)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
                                            .strokeBorder(Color(.separator), lineWidth: 0.5)
                                    )
                                    .overlay(alignment: .topLeading) {
                                        if phrase.isEmpty {
                                            Text("Recovery phrase")
                                                .font(.dsMono(.body))
                                                .foregroundStyle(DS.Color.inkFaint)
                                                .padding(DS.Space.m)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }

                            // Primary action
                            Button {
                                Task {
                                    busy = true
                                    await app.loginWithRecovery(
                                        handle: handle.trimmingCharacters(in: .whitespacesAndNewlines),
                                        phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                                    )
                                    busy = false
                                }
                            } label: {
                                if busy {
                                    ProgressView()
                                        .controlSize(.regular)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, DS.Space.xs)
                                } else {
                                    Text("Sign in")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.accentColor)
                            .controlSize(.large)
                            .disabled(!canSubmit || busy)

                            // Error
                            if let err = app.lastError {
                                Text(err)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.leading)
                            }

                            // Secondary
                            Button("Back to sign in") {
                                dismiss()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(DS.Space.xl)
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .frame(maxWidth: 480)

                    Spacer().frame(height: DS.Space.xl)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
