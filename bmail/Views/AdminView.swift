import SwiftUI

struct AdminView: View {
    @State private var loading = true
    @State private var status: StatusResp?
    @State private var invites: [InviteView] = []
    @State private var users: [UserView] = []

    @State private var newHandle = ""
    @State private var newLocal = ""
    @State private var newAdmin = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionHeader(title: "ADMIN")

                ScrollView {
                    VStack(spacing: 0) {
                        newInviteCard
                        section("INVITES — PENDING") {
                            if invites.isEmpty {
                                placeholder("no pending invites")
                            } else {
                                ForEach(invites, id: \.token) { i in
                                    InviteRow(invite: i)
                                    Hairline()
                                }
                            }
                        }
                        section("USERS") {
                            if users.isEmpty {
                                placeholder("no users")
                            } else {
                                ForEach(users, id: \.id) { u in
                                    UserRow(user: u)
                                    Hairline()
                                }
                            }
                        }
                    }
                }
            }
            .background(Theme.inverseInk)
            .task { await load() }
        }
    }

    private var primaryDomain: String { status?.primary_domain ?? "" }

    private var newInviteCard: some View {
        section("NEW INVITE") {
            VStack(spacing: 0) {
                inputRow(label: "handle", text: $newHandle, placeholder: "optional")
                Hairline()
                inputRow(label: "address", text: $newLocal, placeholder: "@\(primaryDomain)")
                Hairline()
                Toggle(isOn: $newAdmin) {
                    HStack {
                        Text("admin")
                            .monoLabel()
                            .frame(width: 100, alignment: .leading)
                        Text("grant admin role")
                            .font(.mono(13))
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                Hairline()
                HStack {
                    Spacer()
                    Button("CREATE INVITE ▸") { Task { await createInvite() } }
                        .monoButton(prominent: true, disabled: newLocal.isEmpty)
                        .disabled(newLocal.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func inputRow(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 0) {
            Text(label).monoLabel().frame(width: 100, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.mono(13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.mono(11, .medium))
                    .tracking(1.5)
                    .foregroundStyle(Theme.mute)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            Hairline()
            content()
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s)
            .font(.mono(12))
            .foregroundStyle(Theme.mute)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        loading = true
        do {
            self.status = try await APIClient.shared.get("/api/admin/status")
            self.invites = try await APIClient.shared.get("/api/admin/invites")
            self.users = try await APIClient.shared.get("/api/admin/users")
        } catch {}
        loading = false
    }

    private func createInvite() async {
        struct Body: Encodable {
            let handle: String?
            let address: String
            let is_admin: Bool
        }
        let address = newLocal.contains("@") ? newLocal : "\(newLocal)@\(primaryDomain)"
        let body = Body(
            handle: newHandle.isEmpty ? nil : newHandle,
            address: address,
            is_admin: newAdmin
        )
        struct R: Decodable { let token: String }
        _ = try? await APIClient.shared.post("/api/admin/invites", body, as: R.self)
        newHandle = ""; newLocal = ""; newAdmin = false
        await load()
    }
}

struct InviteView: Decodable, Sendable {
    let token: String
    let handle: String?
    let addresses: [String]
    let is_admin: Bool
    let created_at: Int64
    let expires_at: Int64
    let redeemed_at: Int64?
}

struct UserView: Decodable, Sendable {
    let id: String
    let handle: String
    let display_name: String?
    let is_admin: Bool
    let addresses: [String]
}

private struct InviteRow: View {
    let invite: InviteView
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(invite.handle ?? "(no handle)")
                    .font(.mono(13, .medium))
                if invite.is_admin {
                    Text("ADMIN")
                        .font(.mono(9, .medium))
                        .tracking(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
                Spacer()
                Text(RelativeDate.format(invite.created_at))
                    .font(.mono(11)).foregroundStyle(Theme.mute)
            }
            Text(invite.addresses.joined(separator: ", "))
                .font(.mono(11))
                .foregroundStyle(Theme.mute)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct UserRow: View {
    let user: UserView
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(user.handle).font(.mono(13, .medium))
                if user.is_admin {
                    Text("ADMIN")
                        .font(.mono(9, .medium))
                        .tracking(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
                Spacer()
            }
            Text(user.addresses.joined(separator: ", "))
                .font(.mono(11))
                .foregroundStyle(Theme.mute)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
