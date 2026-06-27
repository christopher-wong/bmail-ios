import Foundation

// MARK: - Status / Config

struct StatusResp: Decodable {
    let needs_bootstrap: Bool
    let is_authed: Bool
    let primary_domain: String
    let additional_domains: [String]
    let app_host: String
    let app_name: String
    let user_count: Int
}

// PublicConfig is now an alias to Components.Schemas.PublicConfig (see ModelAliases.swift).

// MARK: - Me

/// Per-user remote-image preferences, mirrored from the server.
struct ImageSettings: Codable, Sendable {
    var load_by_default: Bool
    var domains: [String]

    static let blocked = ImageSettings(load_by_default: false, domains: [])
}

struct MeResp: Codable, Sendable {
    let id: String
    let handle: String
    let display_name: String?
    let is_admin: Bool
    let addresses: [String]
    let pub_key_b64: String?
}

// MARK: - Threads / Messages

enum Direction: String, Codable, Hashable, Sendable { case `in`, out, draft }

struct ThreadRow: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let subject_hint: String?
    let first_subject_ct_b64: String?
    let snippet_ct_b64: String?
    let first_from_addr: String?
    let first_direction: Direction?
    let participants: [String]
    let last_message_at: Int64
    let message_count: Int
    let unread_count: Int
    let has_starred: Bool
    let archived: Bool
}

extension ThreadRow {
    /// Decrypt the first message's subject for a list row.
    func decryptedSubject(priv: Data) -> String? {
        guard let s = first_subject_ct_b64, let blob = Data(b64u: s) else { return nil }
        return try? Crypto.openSealedString(blob, priv: priv)
    }

    /// Decrypt the body snippet and reduce it to a plain-text preview (nil if
    /// absent or empty after HTML stripping).
    func decryptedPreview(priv: Data) -> String? {
        guard let s = snippet_ct_b64, let blob = Data(b64u: s),
              let plain = try? Crypto.openSealedString(blob, priv: priv) else { return nil }
        let preview = plain.strippingHTML
        return preview.isEmpty ? nil : preview
    }
}

struct MessageRow: Decodable, Identifiable, Sendable {
    let id: String
    let thread_id: String
    let message_id: String?
    let in_reply_to: String?
    let from_addr: String
    let from_name: String?
    let to_addrs: [String]
    let cc_addrs: [String]
    let bcc_addrs: [String]
    let sent_at: Int64
    let received_at: Int64
    let direction: Direction
    let read: Bool
    let starred: Bool
    let snippet_ct_b64: String?
    let subject_ct_b64: String
    let body_ct_b64: String
    let body_html_ct_b64: String?
    let size_bytes: Int
    let labels: [String]
}

// MARK: - Drafts

struct DraftRow: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let in_reply_to_message_id: String?
    let to_addrs: [String]
    let cc_addrs: [String]
    let bcc_addrs: [String]
    let subject_ct_b64: String?
    let body_ct_b64: String?
    let attachments: [String]
    let updated_at: Int64
}

struct DraftSaveReq: Encodable, Sendable {
    let id: String?
    let in_reply_to_message_id: String?
    let to_addrs: [String]
    let cc_addrs: [String]
    let bcc_addrs: [String]
    let subject_ct_b64: String?
    let body_ct_b64: String?
    let attachments: [String]
}

struct DraftSaveResp: Decodable, Sendable {
    let id: String
    let updated_at: Int64
}

// MARK: - Send

struct SendReq: Encodable, Sendable {
    let from: String
    let from_name: String?
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let subject: String
    let text: String
    let html: String?
    let in_reply_to: String?
    let references: String?
    let attachments: [AttachmentRef]
}

struct AttachmentRef: Encodable, Sendable {
    let r2_key: String
    /// Plain filename for outbound MIME headers.
    let filename: String
    /// Same filename sealed to our own pubkey, for the sender's at-rest copy.
    let filename_ct_b64: String?
    let mime: String
}

// MARK: - Attachments

// AttachmentUploadResp was for the legacy POST /api/attachments endpoint.
// Uploads now flow through Uploader.swift and return UploadResult.

struct AttachmentRow: Decodable, Identifiable, Sendable {
    let id: String
    let message_id: String?
    let draft_id: String?
    let r2_key: String
    let filename_ct_b64: String?
    let mime: String
    let size_bytes: Int64
    let created_at: Int64
}

// MARK: - Labels

struct MailLabel: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let created_at: Int64
}

// MARK: - Auth

struct RegisterOptionsReq: Encodable { let invite_token: String }

struct WAUser: Decodable, Sendable {
    let id: String
    let name: String
    let display_name: String
}
struct WARP: Decodable, Sendable { let id: String; let name: String }
struct WAParam: Decodable, Sendable { let type: String; let alg: Int }
struct WASelection: Decodable, Sendable {
    let user_verification: String
    let resident_key: String
    let require_resident_key: Bool
}

struct RegisterOptions: Decodable, Sendable {
    let rp: WARP
    let user: WAUser
    let challenge: String
    let pub_key_cred_params: [WAParam]
    let authenticator_selection: WASelection
    let timeout: Int
    let attestation: String
    let challenge_id: String
    let prf_salt_b64: String
    let invite_handle: String?
    let invite_addresses: [String]?
    let invite_is_admin: Bool?
    let exclude_credentials: [ExcludeCred]?

    struct ExcludeCred: Decodable, Sendable { let type: String; let id: String }
}

struct LoginOptionsResp: Decodable, Sendable {
    let rp_id: String
    let challenge: String
    let challenge_id: String
    let timeout: Int
    let user_verification: String
    let prf_salt_b64: String
}

struct AttestationPayload: Encodable {
    let credential_id_b64: String
    let client_data_json_b64: String
    let attestation_object_b64: String
    let transports: [String]
}

struct WrapPayload: Encodable {
    let kind: String
    let credential_id_b64: String?
    let wrapped_blob_b64: String
    let wrap_salt_b64: String?
    let kdf_params: String?
    let label: String?
}

struct RegisterVerifyReq: Encodable {
    let invite_token: String
    let challenge_id: String
    let handle: String?
    let display_name: String?
    let cred_label: String?
    let attestation: AttestationPayload
    let pub_key_b64: String
    let wraps: [WrapPayload]
}

struct RegisterVerifyResp: Decodable {
    let user_id: String
    let is_admin: Bool
    let addresses: [String]
}

struct LoginVerifyReq: Encodable {
    let challenge_id: String
    let credential_id_b64: String
    let client_data_json_b64: String
    let authenticator_data_b64: String
    let signature_b64: String
}

struct LoginVerifyResp: Decodable {
    struct Wrap: Decodable {
        let wrapped_blob_b64: String
        let wrap_salt_b64: String?
    }
    let user: MeResp
    let wrap: Wrap
}

// MARK: - Recovery

struct RecoveryBeginResp: Decodable {
    struct Wrap: Decodable {
        let wrapped_blob_b64: String
        let wrap_salt_b64: String?
        let kdf_params: String?
    }
    let user_id: String
    let wrap: Wrap
    let sealed_proof_b64: String
    let challenge_id: String
}

// MARK: - Passkey list

struct PasskeyView: Decodable, Identifiable, Sendable {
    /// Server returns the credential id as base64url here (not "id_b64" like the openapi suggests).
    let credential_id_b64: String
    let label: String?
    let created_at: Int64
    let aaguid_b64: String?
    let transports: String?

    var id: String { credential_id_b64 }
}

// MARK: - Add passkey

struct AddPasskeyOptions: Decodable, Sendable {
    let rp: WARP
    let user: WAUser
    let challenge: String
    let pub_key_cred_params: [WAParam]
    let authenticator_selection: WASelection
    let timeout: Int
    let attestation: String
    let challenge_id: String
    let prf_salt_b64: String
    let exclude_credentials: [ExcludeCred]

    struct ExcludeCred: Decodable, Sendable { let type: String; let id: String }
}

// MARK: - Errors

struct APIErrorPayload: Decodable, Sendable {
    let error: String?
}
