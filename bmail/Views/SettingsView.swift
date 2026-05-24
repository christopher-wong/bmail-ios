import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var addingPasskey = false
    @State private var addPasskeyResult: String?
    @State private var passkeys: [PasskeyView] = []
    @State private var passkeysLoading = false
    @State private var removing: Set<String> = []
    @State private var biometryLockOn: Bool = false
    @State private var showHostedMine = false
    @State private var showSecretMine = false
    @ScaledMetric(relativeTo: .footnote) private var labelColumn: CGFloat = 130

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "SETTINGS")

                ScrollView {
                    VStack(spacing: 0) {
                        block(title: "ACCOUNT") {
                            row("handle", app.me?.handle ?? "—")
                            row("display name", app.me?.display_name ?? "—")
                            row("user id", app.me?.id ?? "—")
                            row("role", app.me?.is_admin == true ? "admin" : "user")
                        }
                        block(title: "ADDRESSES") {
                            ForEach(app.me?.addresses ?? [], id: \.self) { a in
                                Text(a)
                                    .font(.mono(13))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Hairline()
                            }
                        }
                        block(title: "PASSKEYS") {
                            if passkeysLoading && passkeys.isEmpty {
                                ProgressView()
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Hairline()
                            }
                            ForEach(passkeys) { p in
                                passkeyRow(p)
                                Hairline()
                            }
                            HStack {
                                if let msg = addPasskeyResult {
                                    Text(msg)
                                        .font(.mono(11))
                                        .foregroundStyle(Theme.mute)
                                }
                                Spacer()
                                Button(addingPasskey ? "ADDING…" : "ADD PASSKEY ▸") {
                                    Task { await runAddPasskey() }
                                }
                                .monoButton(prominent: true, disabled: addingPasskey)
                                .disabled(addingPasskey)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        if app.biometryAvailable {
                            block(title: "SECURITY") {
                                biometryRow
                            }
                        }
                        block(title: "FILES") {
                            Button {
                                showHostedMine = true
                            } label: {
                                HStack {
                                    Text("hosted attachments")
                                        .font(.mono(13))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.mute)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Hairline()
                            Button {
                                showSecretMine = true
                            } label: {
                                HStack {
                                    Text("secret links")
                                        .font(.mono(13))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.mute)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .navigationDestination(isPresented: $showHostedMine) {
                            HostedMineView()
                        }
                        .navigationDestination(isPresented: $showSecretMine) {
                            SecretMineView()
                        }
                        block(title: "SESSION") {
                            Button {
                                Task { await app.logout() }
                            } label: {
                                Text("LOG OUT")
                                    .monoButton()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
            .background(Theme.inverseInk)
            .task {
                biometryLockOn = app.biometryLockEnabled
                await loadPasskeys()
            }
        }
    }

    private var biometryRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("require \(app.biometryLabel.lowercased())")
                    .font(.mono(13, .medium))
                Text("unlock the app on launch")
                    .font(.mono(10))
                    .foregroundStyle(Theme.mute)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { biometryLockOn },
                set: { newValue in
                    biometryLockOn = newValue
                    if !app.setBiometryLock(enabled: newValue) {
                        biometryLockOn = !newValue
                    }
                }
            ))
            .labelsHidden()
            .tint(Theme.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func passkeyRow(_ p: PasskeyView) -> some View {
        let isCurrent = removing.contains(p.id)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.label?.isEmpty == false ? p.label! : shortID(p.credential_id_b64))
                    .font(.mono(13, .medium))
                Text(RelativeDate.format(p.created_at))
                    .font(.mono(10))
                    .foregroundStyle(Theme.mute)
            }
            Spacer()
            Button(isCurrent ? "REMOVING…" : "REMOVE") {
                Task { await removePasskey(p) }
            }
            .monoButton(disabled: isCurrent)
            .disabled(isCurrent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func shortID(_ s: String) -> String {
        s.count > 10 ? String(s.prefix(6)) + "…" + String(s.suffix(4)) : s
    }

    private func loadPasskeys() async {
        passkeysLoading = true
        passkeys = await app.listPasskeys()
        passkeysLoading = false
    }

    private func runAddPasskey() async {
        addPasskeyResult = nil
        addingPasskey = true
        let ok = await app.addPasskey(label: UIDevice.current.name)
        addingPasskey = false
        addPasskeyResult = ok ? "passkey added ✓" : (app.lastError ?? "failed")
        if ok { await loadPasskeys() }
    }

    private func removePasskey(_ p: PasskeyView) async {
        removing.insert(p.id)
        defer { removing.remove(p.id) }
        let ok = await app.removePasskey(credentialIDB64: p.credential_id_b64)
        if ok {
            passkeys.removeAll { $0.id == p.id }
        } else {
            addPasskeyResult = app.lastError ?? "remove failed"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .monoLabel()
                .frame(width: labelColumn, alignment: .leading)
            Text(value)
                .font(.mono(13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder
    private func block<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.mono(11, .medium))
                .tracking(1.5)
                .foregroundStyle(Theme.mute)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            Hairline()
            content()
        }
    }
}
