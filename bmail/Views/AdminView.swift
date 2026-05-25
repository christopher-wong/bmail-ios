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
        Form {
            // MARK: New invite
            Section {
                TextField("Handle (optional)", text: $newHandle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Address (local part or full)", text: $newLocal)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)

                Toggle("Grant admin role", isOn: $newAdmin)
                    .tint(Color.accentColor)

                Button("Create invite") {
                    Task { await createInvite() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(newLocal.isEmpty)
            } header: {
                Text("New invite")
            }

            // MARK: Pending invites
            Section {
                if loading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if invites.isEmpty {
                    Text("No pending invites")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(invites, id: \.token) { invite in
                        InviteRow(invite: invite)
                    }
                }
            } header: {
                Text("Pending invites")
            }

            // MARK: Users
            Section {
                if loading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if users.isEmpty {
                    Text("No users")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(users, id: \.id) { user in
                        UserRow(user: user)
                    }
                }
            } header: {
                Text("Users")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    // MARK: - Data helpers

    private var primaryDomain: String { status?.primary_domain ?? "" }

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

// MARK: - Model types

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

// MARK: - Row components

private struct InviteRow: View {
    let invite: InviteView

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Text(invite.handle ?? "(no handle)")
                    .font(.callout.weight(.medium))

                if invite.is_admin {
                    Label("Admin", systemImage: "key.fill")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                Text(RelativeDate.format(invite.created_at))
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkFaint)
            }

            Text(invite.addresses.joined(separator: ", "))
                .font(.dsMono(.footnote))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DS.Space.xs)
    }
}

private struct UserRow: View {
    let user: UserView

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Text(user.handle)
                    .font(.callout.weight(.medium))

                if user.is_admin {
                    Label("Admin", systemImage: "key.fill")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()
            }

            Text(user.addresses.joined(separator: ", "))
                .font(.dsMono(.footnote))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DS.Space.xs)
    }
}
