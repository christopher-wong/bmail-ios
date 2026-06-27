import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var addingPasskey = false
    @State private var addPasskeyResult: String?
    @State private var passkeys: [PasskeyView] = []
    @State private var passkeysLoading = false
    @State private var removing: Set<String> = []
    @State private var biometryLockOn: Bool = false
    @State private var showLogoutConfirm = false

    // Navigation destinations
    @State private var showHostedMine = false
    @State private var showSecretMine = false
    @State private var showLabels = false

    var body: some View {
        NavigationStack {
            ZStack {
                Wallpaper()

                Form {
                    accountSection
                    if app.biometryAvailable {
                        securitySection
                    }
                    passkeysSection
                    filesSection
                    labelsSection
                    imagesSection
                    aboutSection
                    logoutSection
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(isPresented: $showHostedMine) {
                    HostedMineView()
                }
                .navigationDestination(isPresented: $showSecretMine) {
                    SecretMineView()
                }
                .navigationDestination(isPresented: $showLabels) {
                    LabelsView()
                }
            }
        }
        .task {
            biometryLockOn = app.biometryLockEnabled
            await app.loadImageSettingsIfNeeded()
            await loadPasskeys()
        }
        .confirmationDialog(
            "Log out?",
            isPresented: $showLogoutConfirm,
            titleVisibility: .visible
        ) {
            Button("Log out", role: .destructive) {
                DSHaptics.notifyWarning()
                Task { await app.logout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need your passkey to sign back in.")
        }
    }

    // MARK: - Account section

    private var accountSection: some View {
        Section {
            // Avatar header row
            HStack(spacing: DS.Space.m) {
                DSAvatar(
                    initials: initials(from: app.me?.display_name ?? app.me?.handle ?? "?"),
                    size: .header
                )
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if let name = app.me?.display_name, !name.isEmpty {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    Text("@\(app.me?.handle ?? "—")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, DS.Space.xs)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.l, bottom: DS.Space.s, trailing: DS.Space.l))

            // Addresses
            ForEach(app.me?.addresses ?? [], id: \.self) { address in
                HStack {
                    Text(address)
                        .font(.dsMono(.subheadline))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Spacer()
                }
            }

            // Display name read-only row
            DSRow(icon: "person.fill", title: "Display name") {
                Text(app.me?.display_name ?? "—")
                    .foregroundStyle(.secondary)
            }

            // Role
            DSRow(icon: "shield.fill", title: "Role") {
                Text(app.me?.is_admin == true ? "Admin" : "User")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Account")
        }
    }

    // MARK: - Security section

    private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { biometryLockOn },
                set: { newValue in
                    DSHaptics.impactLight()
                    biometryLockOn = newValue
                    if !app.setBiometryLock(enabled: newValue) {
                        biometryLockOn = !newValue
                    }
                }
            )) {
                DSRow(
                    icon: biometryLockOn ? "faceid" : "lock.fill",
                    title: "Lock with \(app.biometryLabel)",
                    subtitle: "Require biometrics on launch"
                ) { EmptyView() }
            }
            .tint(.accentColor)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Security")
        }
    }

    // MARK: - Passkeys section

    private var passkeysSection: some View {
        Section {
            if passkeysLoading && passkeys.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading passkeys…")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(passkeys) { p in
                passkeyRow(p)
            }

            // Add passkey button
            HStack {
                if let msg = addPasskeyResult {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(addingPasskey ? "Adding…" : "Add passkey") {
                    Task { await runAddPasskey() }
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(addingPasskey)
            }
        } header: {
            Text("Passkeys")
        }
    }

    // MARK: - Files section

    private var filesSection: some View {
        Section {
            Button {
                showHostedMine = true
            } label: {
                DSRow(icon: "externaldrive.fill", title: "Hosted links") {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Color.inkFaint)
                }
            }
            .buttonStyle(.plain)

            Button {
                showSecretMine = true
            } label: {
                DSRow(icon: "lock.fill", title: "Secret links") {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Color.inkFaint)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Files")
        }
    }

    // MARK: - Labels section

    private var labelsSection: some View {
        Section {
            Button {
                showLabels = true
            } label: {
                DSRow(icon: "tag.fill", title: "Labels") {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Color.inkFaint)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Labels")
        }
    }

    // MARK: - Remote images section

    private var imagesSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { app.imageLoadByDefault },
                set: { newValue in
                    DSHaptics.impactLight()
                    Task { await app.setImagesLoadByDefault(newValue) }
                }
            )) {
                DSRow(
                    icon: "photo",
                    title: "Load remote images",
                    subtitle: "Automatically, for every sender"
                ) { EmptyView() }
            }
            .tint(.accentColor)
            .listRowInsets(EdgeInsets())

            ForEach(app.imageDomains.sorted(), id: \.self) { domain in
                DSRow(icon: "checkmark.shield.fill", title: domain) {
                    Button("Remove") {
                        DSHaptics.impactLight()
                        Task { await app.removeImageDomain(domain) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .listRowInsets(EdgeInsets())
            }
        } header: {
            Text("Remote images")
        } footer: {
            Text("Blocked by default. Senders embed remote images — including invisible tracking pixels — to learn your IP address, approximate location, and the exact moment you open a message. When you load them, bmail fetches them through its own server, so the sender never sees your device or IP. Senders you allow load automatically.")
        }
    }

    // MARK: - About section

    private var aboutSection: some View {
        Section {
            if let domain = app.publicConfig?.primary_domain {
                DSRow(icon: "globe", title: "Primary domain") {
                    Text(domain)
                        .font(.dsMono(.footnote))
                        .foregroundStyle(.secondary)
                }
            }

            DSRow(icon: "info.circle.fill", title: "Version") {
                Text(appVersionString)
                    .font(.dsMono(.footnote))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        }
    }

    // MARK: - Logout section

    private var logoutSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Log out")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Passkey row

    private func passkeyRow(_ p: PasskeyView) -> some View {
        let isCurrent = removing.contains(p.id)
        let label = p.label?.isEmpty == false ? p.label! : shortID(p.credential_id_b64)
        return DSRow(
            icon: "key.fill",
            title: label,
            subtitle: RelativeDate.format(p.created_at)
        ) {
            Button(isCurrent ? "Removing…" : "Remove") {
                Task { await removePasskey(p) }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(isCurrent)
        }
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Helpers

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func shortID(_ s: String) -> String {
        s.count > 10 ? String(s.prefix(6)) + "…" + String(s.suffix(4)) : s
    }

    /// Extracts up to two initials from a display name or handle.
    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        if parts.count >= 2,
           let f = parts[0].first,
           let s = parts[1].first {
            return "\(f)\(s)"
        }
        return String(name.prefix(2))
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
        addPasskeyResult = ok ? "Passkey added" : (app.lastError ?? "Failed")
        if ok { await loadPasskeys() }
    }

    private func removePasskey(_ p: PasskeyView) async {
        removing.insert(p.id)
        defer { removing.remove(p.id) }
        let ok = await app.removePasskey(credentialIDB64: p.credential_id_b64)
        if ok {
            passkeys.removeAll { $0.id == p.id }
        } else {
            addPasskeyResult = app.lastError ?? "Remove failed"
        }
    }
}
