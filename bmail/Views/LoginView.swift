import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var signingIn = false
    @State private var tab: Tab = .passkey
    @State private var showEnroll = false

    enum Tab: Hashable { case passkey, recovery }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text("CFEMAIL")
                        .font(.mono(14, .medium))
                        .tracking(2.5)
                        .foregroundStyle(Theme.ink)
                    Text("enter")
                        .font(.mono(40, .regular))
                        .foregroundStyle(Theme.ink)
                }

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        TabButton(label: "PASSKEY", active: tab == .passkey) { tab = .passkey }
                        TabButton(label: "RECOVERY PHRASE", active: tab == .recovery) { tab = .recovery }
                    }
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))

                    switch tab {
                    case .passkey:
                        passkeyPanel
                    case .recovery:
                        RecoveryLoginView()
                    }
                }
                .frame(maxWidth: 360)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))

                if let err = app.lastError {
                    Text(err)
                        .font(.mono(12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                Button {
                    showEnroll = true
                } label: {
                    Text("no account? enroll with invite ▸")
                        .font(.mono(11))
                        .foregroundStyle(Theme.mute)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.inverseInk)
        .sheet(isPresented: $showEnroll) {
            EnrollView()
        }
    }

    private var passkeyPanel: some View {
        VStack(spacing: 0) {
            Button {
                Task {
                    signingIn = true
                    await app.loginWithPasskey()
                    signingIn = false
                }
            } label: {
                HStack {
                    Spacer()
                    if signingIn {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Theme.inverseInk)
                    } else {
                        Text("SIGN IN WITH PASSKEY ▸")
                            .font(.mono(13, .medium))
                            .tracking(1.5)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
                .background(Theme.inverseBg)
                .foregroundStyle(Theme.inverseInk)
            }
            .buttonStyle(.plain)
            .disabled(signingIn)

            Text("uses face id / touch id / your security key")
                .font(.mono(11))
                .foregroundStyle(Theme.mute)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Hairline() }
        }
    }
}

private struct TabButton: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.mono(11, .medium))
                .tracking(1.0)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .foregroundStyle(active ? Theme.inverseInk : Theme.ink)
                .background(active ? Theme.inverseBg : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
