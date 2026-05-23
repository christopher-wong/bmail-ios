import CryptoKit
import Foundation

/// Mirrors web/src/lib/crypto.ts. The X25519 private key never leaves this
/// process. It is unwrapped from a server-stored AES-GCM blob using a key
/// derived from a passkey's PRF output (or, on recovery, Argon2id over the
/// 12-word phrase — not yet implemented natively).
enum Crypto {
    enum Error: Swift.Error, LocalizedError {
        case badCiphertext
        case decryptFailed
        case other(String)

        var errorDescription: String? {
            switch self {
            case .badCiphertext: return "ciphertext too short"
            case .decryptFailed: return "decryption failed"
            case .other(let m): return m
            }
        }
    }

    static let sealedBoxInfo  = "cfemail/sealed-box/v1".data(using: .utf8)!
    static let wrapKeyInfo    = "cfemail/wrap-key/v1".data(using: .utf8)!

    // MARK: - PRF → AES-GCM wrap key

    /// HKDF-SHA256(prfOutput, info="cfemail/wrap-key/v1") → 32-byte AES-GCM key.
    static func deriveWrapKey(prfOutput: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: prfOutput)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: wrapKeyInfo,
            outputByteCount: 32
        )
    }

    /// Wrap = 12B random IV ‖ AES-GCM(priv, key=wrapKey, iv).
    /// Returns (wrappedBlob, 16B random salt) — salt is stored alongside.
    static func wrapPrivKey(_ priv: Data, with wrapKey: SymmetricKey) throws -> (wrapped: Data, salt: Data) {
        var iv = Data(count: 12)
        _ = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(priv, using: wrapKey, nonce: nonce)
        var blob = Data()
        blob.append(iv)
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)

        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return (blob, salt)
    }

    static func unwrapPrivKey(_ wrapped: Data, with wrapKey: SymmetricKey) throws -> Data {
        guard wrapped.count >= 12 + 16 else { throw Error.badCiphertext }
        let iv = wrapped.prefix(12)
        let ctAndTag = wrapped.dropFirst(12)
        let ct = ctAndTag.dropLast(16)
        let tag = ctAndTag.suffix(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: wrapKey)
    }

    // MARK: - X25519 keypair

    static func newX25519Keypair() -> (priv: Data, pub: Data) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key.rawRepresentation, key.publicKey.rawRepresentation)
    }

    static func publicKey(forPrivate priv: Data) throws -> Data {
        let k = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
        return k.publicKey.rawRepresentation
    }

    // MARK: - Sealed box (open)

    /// Wire layout: ephemeral_pub (32) ‖ nonce (24) ‖ ciphertext+tag.
    static func openSealedBox(_ blob: Data, priv: Data) throws -> Data {
        guard blob.count >= 32 + 24 + 16 else { throw Error.badCiphertext }
        let ephPub = blob.prefix(32)
        let nonce = blob.dropFirst(32).prefix(24)
        let ct = blob.dropFirst(56)

        let privKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
        let pubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPub)
        let shared = try privKey.sharedSecretFromKeyAgreement(with: pubKey)

        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: sealedBoxInfo, outputByteCount: 32
        )

        let keyData = aeadKey.withUnsafeBytes { Data($0) }
        return try XChaCha20Poly1305.open(Data(ct), key: keyData, nonce24: Data(nonce))
    }

    static func openSealedString(_ blob: Data, priv: Data) throws -> String {
        let pt = try openSealedBox(blob, priv: priv)
        guard let s = String(data: pt, encoding: .utf8) else { throw Error.decryptFailed }
        return s
    }

    // MARK: - Seal to self (for drafts)

    /// Encrypt-to-self for drafts. Deterministic nonce derived from
    /// SHA-512(eph_pub ‖ recipient_pub)[..24] — matches the server's seal_to.
    static func sealToSelf(_ plaintext: Data, pub: Data) throws -> Data {
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = ephPriv.publicKey.rawRepresentation
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
        let shared = try ephPriv.sharedSecretFromKeyAgreement(with: recipient)
        let aeadKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: sealedBoxInfo, outputByteCount: 32
        )

        var hasher = SHA512()
        hasher.update(data: ephPub)
        hasher.update(data: pub)
        let nonce = Data(hasher.finalize().prefix(24))

        let keyData = aeadKey.withUnsafeBytes { Data($0) }
        let ct = try XChaCha20Poly1305.seal(plaintext, key: keyData, nonce24: nonce)

        var out = Data()
        out.append(ephPub)
        out.append(nonce)
        out.append(ct)
        return out
    }
}
