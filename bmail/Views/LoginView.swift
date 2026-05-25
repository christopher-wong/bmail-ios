import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var signingIn = false
    @State private var showRecovery = false
    @State private var showEnroll = false

    var body: some View {
        ZStack {
            Wallpaper()

            VStack(spacing: DS.Space.xl) {
                Spacer()

                // Glass card centred on screen
                GlassCard(radius: DS.Radius.sheet) {
                    VStack(spacing: DS.Space.xl) {
                        // App identity
                        VStack(spacing: DS.Space.s) {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .symbolRenderingMode(.hierarchical)

                            Text("bmail")
                                .font(.largeTitle.weight(.semibold))
                                .tracking(-0.5)

                            Text("Encrypted email")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }

                        Spacer().frame(height: DS.Space.s)

                        // Primary action
                        Button {
                            Task {
                                signingIn = true
                                await app.loginWithPasskey()
                                signingIn = false
                            }
                        } label: {
                            if signingIn {
                                ProgressView()
                                    .controlSize(.regular)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DS.Space.xs)
                            } else {
                                Label("Sign in with passkey", systemImage: "person.badge.key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)
                        .controlSize(.large)
                        .disabled(signingIn)

                        // Secondary action
                        Button("Use recovery phrase") {
                            showRecovery = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .font(.subheadline)

                        // Inline error
                        if let err = app.lastError {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(DS.Space.xl)
                }
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: 400)

                Spacer()

                // Invite-only hint
                Button {
                    showEnroll = true
                } label: {
                    Text("New here? Open an invite link to enroll.")
                        .font(.footnote)
                        .foregroundStyle(DS.Color.inkFaint)
                }
                .buttonStyle(.plain)
                .padding(.bottom, DS.Space.l)
            }
        }
        .sheet(isPresented: $showRecovery) {
            RecoveryLoginView()
        }
        .sheet(isPresented: $showEnroll) {
            EnrollView()
        }
    }
}
