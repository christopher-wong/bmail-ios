import Foundation
import CryptoKit

/// High-level login / register flows. Talks to APIClient, drives a
/// PasskeyCoordinator, and returns the unwrapped X25519 priv that the rest
/// of the app uses to decrypt mail.
@MainActor
final class AuthService {
    struct Session {
        let me: MeResp
        /// 32-byte X25519 private key. Hold in memory only; persist to
        /// Keychain only if the user opts in (not the default — losing the
        /// device should not lose the mailbox key but losing the device +
        /// passcode shouldn't unlock it either).
        let priv: Data
    }

    private let api: APIClient
    private let coordinator: PasskeyCoordinator

    init() {
        self.api = .shared
        self.coordinator = PasskeyCoordinator()
    }

    // MARK: - Login

    func loginWithPasskey() async throws -> Session {
        struct EmptyBody: Encodable {}
        let options: LoginOptionsResp = try await api.post("/api/auth/login/options", EmptyBody())

        guard
            let challenge = Data(b64u: options.challenge),
            let prfSalt = Data(b64u: options.prf_salt_b64)
        else { throw APIError.other("server returned non-base64url challenge") }

        let assertion = try await coordinator.assert(
            rpID: options.rp_id, challenge: challenge, prfSalt: prfSalt
        )

        let verify = LoginVerifyReq(
            challenge_id: options.challenge_id,
            credential_id_b64: assertion.credentialID.b64u,
            client_data_json_b64: assertion.clientDataJSON.b64u,
            authenticator_data_b64: assertion.authenticatorData.b64u,
            signature_b64: assertion.signature.b64u
        )
        let resp: LoginVerifyResp = try await api.post("/api/auth/login/verify", verify)

        guard let wrapped = Data(b64u: resp.wrap.wrapped_blob_b64) else {
            throw APIError.other("server returned bad wrap")
        }
        let wrapKey = Crypto.deriveWrapKey(prfOutput: assertion.prfFirst)
        let priv = try Crypto.unwrapPrivKey(wrapped, with: wrapKey)
        return Session(me: resp.user, priv: priv)
    }

    // MARK: - Recovery-phrase login

    func loginWithRecovery(handle: String, phrase: String) async throws -> Session {
        let entropy = try BIP39.entropy(fromMnemonic: phrase)
        struct Body: Encodable { let handle: String }
        let begin: RecoveryBeginResp = try await api.post("/api/auth/recovery/begin", Body(handle: handle))

        guard let kdfJSON = begin.wrap.kdf_params,
              let kdfData = kdfJSON.data(using: .utf8),
              let params = try? JSONDecoder().decode(Argon2.Params.self, from: kdfData),
              let wrapped = Data(b64u: begin.wrap.wrapped_blob_b64),
              let sealedProof = Data(b64u: begin.sealed_proof_b64) else {
            throw APIError.other("server returned unexpected recovery payload")
        }
        let (wrapKey, _) = try Argon2.deriveWrapKey(entropy: entropy, params: .existing(params))
        let priv = try Crypto.unwrapPrivKey(wrapped, with: wrapKey)
        let proof = try Crypto.openSealedBox(sealedProof, priv: priv)

        struct VerifyBody: Encodable { let challenge_id: String; let proof_b64: String }
        let user: MeResp = try await api.post(
            "/api/auth/recovery/verify",
            VerifyBody(challenge_id: begin.challenge_id, proof_b64: proof.b64u)
        )
        return Session(me: user, priv: priv)
    }

    // MARK: - Invite enrollment

    struct EnrollmentResult {
        let session: Session
        let recoveryPhrase: String
    }

    func enrollWithInvite(token: String, handle: String?, displayName: String?, credentialLabel: String?) async throws -> EnrollmentResult {
        let options: RegisterOptions = try await api.post(
            "/api/auth/register/options",
            RegisterOptionsReq(invite_token: token)
        )
        guard let challenge = Data(b64u: options.challenge),
              let prfSalt = Data(b64u: options.prf_salt_b64),
              let userID = Data(b64u: options.user.id) else {
            throw APIError.other("server returned bad register options")
        }

        let reg = try await coordinator.register(
            rpID: options.rp.id,
            rpName: options.rp.name,
            userID: userID,
            userName: options.user.name,
            userDisplayName: options.user.display_name,
            challenge: challenge,
            prfSalt: prfSalt
        )
        guard let prfData = reg.prfFirst else {
            throw PasskeyCoordinator.Failure.missingPRFOutput
        }

        // Generate the X25519 keypair this account will use forever.
        let (priv, pub) = Crypto.newX25519Keypair()

        // Wrap #1: passkey wrap (PRF → AES-GCM)
        let passkeyWrapKey = Crypto.deriveWrapKey(prfOutput: prfData)
        let (passkeyWrapped, passkeyWrapSalt) = try Crypto.wrapPrivKey(priv, with: passkeyWrapKey)

        // Wrap #2: recovery wrap (Argon2id(BIP39 entropy) → AES-GCM)
        let phrase = BIP39.newMnemonic()
        let entropy = try BIP39.entropy(fromMnemonic: phrase)
        let (recoveryWrapKey, recoveryParams) = try Argon2.deriveWrapKey(entropy: entropy, params: .new)
        let (recoveryWrapped, _) = try Crypto.wrapPrivKey(priv, with: recoveryWrapKey)
        let kdfJSON = String(
            data: try JSONEncoder().encode(recoveryParams), encoding: .utf8
        )

        let attestation = AttestationPayload(
            credential_id_b64: reg.credentialID.b64u,
            client_data_json_b64: reg.clientDataJSON.b64u,
            attestation_object_b64: reg.attestationObject.b64u,
            transports: []
        )
        let verifyReq = RegisterVerifyReq(
            invite_token: token,
            challenge_id: options.challenge_id,
            handle: handle,
            display_name: displayName,
            cred_label: credentialLabel,
            attestation: attestation,
            pub_key_b64: pub.b64u,
            wraps: [
                WrapPayload(
                    kind: "passkey",
                    credential_id_b64: reg.credentialID.b64u,
                    wrapped_blob_b64: passkeyWrapped.b64u,
                    wrap_salt_b64: passkeyWrapSalt.b64u,
                    kdf_params: nil,
                    label: credentialLabel
                ),
                WrapPayload(
                    kind: "recovery",
                    credential_id_b64: nil,
                    wrapped_blob_b64: recoveryWrapped.b64u,
                    wrap_salt_b64: nil,
                    kdf_params: kdfJSON,
                    label: nil
                ),
            ]
        )
        let resp: RegisterVerifyResp = try await api.post("/api/auth/register/verify", verifyReq)

        // We don't get a full MeResp back from /register/verify — synthesize
        // one from what we have so callers can flip the app into authenticated
        // immediately. A subsequent /api/me call will refresh it if needed.
        let me = MeResp(
            id: resp.user_id,
            handle: handle ?? options.invite_handle ?? "",
            display_name: displayName,
            is_admin: resp.is_admin,
            addresses: resp.addresses,
            pub_key_b64: pub.b64u
        )
        return EnrollmentResult(session: Session(me: me, priv: priv), recoveryPhrase: phrase)
    }

    // MARK: - Add an additional passkey (user is logged in)

    func addPasskey(currentPriv: Data, label: String?) async throws {
        struct EmptyBody: Encodable {}
        let options: AddPasskeyOptions = try await api.post("/api/me/passkeys/add/options", EmptyBody())

        guard let challenge = Data(b64u: options.challenge),
              let prfSalt = Data(b64u: options.prf_salt_b64),
              let userID = Data(b64u: options.user.id) else {
            throw APIError.other("server returned bad add-passkey options")
        }
        let exclude = options.exclude_credentials.compactMap { Data(b64u: $0.id) }

        let reg = try await coordinator.register(
            rpID: options.rp.id,
            rpName: options.rp.name,
            userID: userID,
            userName: options.user.name,
            userDisplayName: options.user.display_name,
            challenge: challenge,
            prfSalt: prfSalt,
            excludeCredentialIDs: exclude
        )
        guard let prfData = reg.prfFirst else {
            throw PasskeyCoordinator.Failure.missingPRFOutput
        }

        let wrapKey = Crypto.deriveWrapKey(prfOutput: prfData)
        let (wrapped, salt) = try Crypto.wrapPrivKey(currentPriv, with: wrapKey)

        struct VerifyBody: Encodable {
            let challenge_id: String
            let cred_label: String?
            let attestation: AttestationPayload
            let wrapped_blob_b64: String
            let wrap_salt_b64: String
        }
        struct Ok: Decodable {}
        let _: Ok = try await api.post(
            "/api/me/passkeys/add/verify",
            VerifyBody(
                challenge_id: options.challenge_id,
                cred_label: label,
                attestation: AttestationPayload(
                    credential_id_b64: reg.credentialID.b64u,
                    client_data_json_b64: reg.clientDataJSON.b64u,
                    attestation_object_b64: reg.attestationObject.b64u,
                    transports: []
                ),
                wrapped_blob_b64: wrapped.b64u,
                wrap_salt_b64: salt.b64u
            )
        )
    }

    // MARK: - Passkey management

    func listPasskeys() async throws -> [PasskeyView] {
        try await api.get("/api/me/passkeys")
    }

    func removePasskey(credentialIDB64: String) async throws {
        // Percent-encode for the URL path; base64url shouldn't contain '/' or '+' but be safe.
        let encoded = credentialIDB64.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentialIDB64
        _ = try await api.delete("/api/me/passkeys/\(encoded)")
    }

    // MARK: - Logout

    func logout() async {
        struct EmptyBody: Encodable {}
        _ = try? await api.postVoid("/api/auth/logout", EmptyBody())
        api.clearCookies()
    }

    // MARK: - Status / me probe

    func currentMe() async throws -> MeResp {
        try await api.get("/api/me")
    }
}
