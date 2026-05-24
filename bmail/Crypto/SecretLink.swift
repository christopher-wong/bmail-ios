// SecretLink.swift
// Password-derived key material for secret links.
//
// Mirrors web/src/lib/secret-link.ts :: deriveArgonOutput + deriveCheckAndWrap.
//
// Pipeline:
//   1. Argon2id(password.NFKC, salt, kdfParams) → 32 bytes of raw material
//   2. HKDF-SHA256(ikm=raw, salt=nil, info="cfemail/secret-link/check/v1", L=32) → check
//   3. HKDF-SHA256(ikm=raw, salt=nil, info="cfemail/secret-link/wrap/v1",  L=32) → wrapKey
//
// The `check` is sent to the server to verify the password without ever
// transmitting a key that could decrypt content. The `wrapKey` stays local
// and is used to AES-GCM-unwrap the CEK returned by the server on success.
//
// Wire format for AES-GCM-wrapped CEK: iv(12) ‖ ct(32) ‖ tag(16) — 60 bytes total.
// Matches the web's wrapCek / unwrapCek functions.

import Argon2Swift
import CryptoKit
import Foundation

// MARK: - ArgonParams

/// KDF parameters for the Argon2id step. JSON-serialised as `kdf_params` on
/// the wire (mirrors the web's `KdfParams` interface).
struct ArgonParams: Codable, Equatable, Sendable {
    var algorithm: String  // always "argon2id"
    var version: Int       // always 19 (0x13)
    var m: Int             // memory in KiB
    var t: Int             // iterations
    var p: Int             // parallelism
    var hash_len: Int      // output length in bytes (always 32)

    /// Default parameters — matches web's ARGON_PARAMS constant.
    static let `default` = ArgonParams(
        algorithm: "argon2id",
        version: 19,
        m: 65536,
        t: 3,
        p: 4,
        hash_len: 32
    )

    // Validate against safe bounds (mirrors Argon2.swift's limits).
    func validate() throws {
        guard algorithm == "argon2id" else {
            throw SecretLinkCrypto.Error.unsupportedAlgorithm(algorithm)
        }
        let mRange   = Argon2.minMemoryKiB...Argon2.maxMemoryKiB
        let tRange   = Argon2.minIterations...Argon2.maxIterations
        let pRange   = Argon2.minParallelism...Argon2.maxParallelism
        let lenRange = Argon2.minHashLen...Argon2.maxHashLen
        guard mRange.contains(m) else {
            throw SecretLinkCrypto.Error.paramsOutOfRange("m=\(m) KiB outside [\(Argon2.minMemoryKiB), \(Argon2.maxMemoryKiB)]")
        }
        guard tRange.contains(t) else {
            throw SecretLinkCrypto.Error.paramsOutOfRange("t=\(t) outside [\(Argon2.minIterations), \(Argon2.maxIterations)]")
        }
        guard pRange.contains(p) else {
            throw SecretLinkCrypto.Error.paramsOutOfRange("p=\(p) outside [\(Argon2.minParallelism), \(Argon2.maxParallelism)]")
        }
        guard lenRange.contains(hash_len) else {
            throw SecretLinkCrypto.Error.paramsOutOfRange("hash_len=\(hash_len) outside [\(Argon2.minHashLen), \(Argon2.maxHashLen)]")
        }
    }
}

// MARK: - SecretLinkKDF

/// Result of the full KDF pipeline (Argon2 → HKDF split).
struct SecretLinkKDF: Sendable {
    /// 32 bytes. Sent to the server as `password_check_b64` to gate access.
    /// Domain-separated from `wrapKey` so a server leak doesn't yield decryption keys.
    let check: Data
    /// AES-GCM-256 key used to unwrap the CEK returned by the server on a successful open.
    let wrapKey: SymmetricKey
}

// MARK: - SecretLinkCrypto

/// High-level helpers for the password-protected secret-link crypto flow.
///
/// Callers run this on a detached / background task because Argon2id is
/// intentionally slow (hundreds of ms at the default 64 MiB / 3-iter params).
enum SecretLinkCrypto {

    // MARK: - HKDF info strings
    //
    // Must match secret-link.ts lines 191–193 exactly:
    //   const check       = hkdf(sha256, argonOutput, undefined, utf8('cfemail/secret-link/check/v1'), 32);
    //   const wrapKeyBytes = hkdf(sha256, argonOutput, undefined, utf8('cfemail/secret-link/wrap/v1'), 32);

    private static let checkInfo   = Data("cfemail/secret-link/check/v1".utf8)
    private static let wrapKeyInfo = Data("cfemail/secret-link/wrap/v1".utf8)

    // MARK: - Errors

    enum Error: Swift.Error, LocalizedError {
        case unsupportedAlgorithm(String)
        case paramsOutOfRange(String)
        case argon2Failed(String)
        case badWrappedCek(String)
        case rngFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let a): return "unsupported KDF algorithm: \(a)"
            case .paramsOutOfRange(let m):     return "KDF params out of range: \(m)"
            case .argon2Failed(let m):         return "Argon2 failed: \(m)"
            case .badWrappedCek(let m):        return "bad wrapped CEK: \(m)"
            case .rngFailed(let s):            return "secure RNG failed (OSStatus \(s))"
            }
        }
    }

    // MARK: - Key derivation

    /// Derive check + wrapKey from a user-supplied password and server-supplied salt/params.
    ///
    /// This runs Argon2id (slow) synchronously. Always call from a detached task.
    ///
    /// - Parameters:
    ///   - password: The user's plaintext password. Normalised to NFKC before hashing,
    ///               matching the web client's `password.normalize('NFKC')`.
    ///   - salt:     16-byte random salt supplied by the server in `SecretLinkPublicView`.
    ///   - kdfParams: Argon2id parameters. Validated before use.
    static func derive(password: String, salt: Data, kdfParams: ArgonParams) throws -> SecretLinkKDF {
        try kdfParams.validate()

        // NFKC normalisation — matches web: `password.normalize('NFKC')`
        let normalised = password.precomposedStringWithCompatibilityMapping
        let passwordBytes = Data(normalised.utf8)

        // Argon2id synchronous hash.
        let result: Argon2SwiftResult
        do {
            result = try Argon2Swift.hashPasswordBytes(
                password: passwordBytes,
                salt: Salt(bytes: salt),
                iterations: kdfParams.t,
                memory: kdfParams.m,
                parallelism: kdfParams.p,
                length: kdfParams.hash_len,
                type: .id,
                version: .V13
            )
        } catch {
            throw Error.argon2Failed("\(error)")
        }
        let argonOut = SymmetricKey(data: result.hashData())

        // HKDF-SHA256 split with no salt (undefined in JS = zero-length salt
        // in CryptoKit when you omit the parameter — CryptoKit HKDF with no
        // salt uses a zero-length salt, matching @noble/hashes behaviour for
        // `hkdf(sha256, ikm, undefined, info, len)`).
        let check = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: argonOut,
            info: checkInfo,
            outputByteCount: 32
        )
        let wrapKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: argonOut,
            info: wrapKeyInfo,
            outputByteCount: 32
        )

        return SecretLinkKDF(
            check: check.withUnsafeBytes { Data($0) },
            wrapKey: wrapKey
        )
    }

    // MARK: - CEK wrap / unwrap

    /// AES-GCM-wrap a 32-byte CEK. Wire layout: iv(12) ‖ ct(32) ‖ tag(16) = 60 bytes.
    /// Matches web's `wrapCek` function.
    static func wrapCEK(_ cek: Data, wrapKey: SymmetricKey) throws -> Data {
        var iv = Data(count: 12)
        let status = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw Error.rngFailed(status) }

        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(cek, using: wrapKey, nonce: nonce)
        var out = Data()
        out.append(iv)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// AES-GCM-unwrap a CEK. Expects iv(12) ‖ ct ‖ tag(16).
    /// Matches web's `unwrapCek` function.
    static func unwrapCEK(_ wrapped: Data, wrapKey: SymmetricKey) throws -> Data {
        guard wrapped.count >= 12 + 16 else {
            throw Error.badWrappedCek("too short: \(wrapped.count) bytes")
        }
        let iv  = wrapped.prefix(12)
        let ct  = wrapped.dropFirst(12).dropLast(16)
        let tag = wrapped.suffix(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: wrapKey)
    }

    // MARK: - Subject / body encrypt / decrypt
    //
    // Subject and body use the `encryptWithCek` / `decryptWithCek` format
    // from secret-link.ts: nonce(24) ‖ ct+tag (XChaCha20-Poly1305, no AAD).
    // This is NOT the ChunkedAEAD framing — it's the legacy single-blob format
    // used for small payloads (subject/body) that are inlined on the server row.

    /// Encrypt `plaintext` with the CEK using the single-blob (non-chunked) format.
    static func encryptWithCEK(_ plaintext: Data, cek: Data) throws -> Data {
        var nonce = Data(count: 24)
        let status = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 24, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw Error.rngFailed(status) }
        let ct = try XChaCha20Poly1305.seal(plaintext, key: cek, nonce24: nonce)
        var out = Data()
        out.append(nonce)
        out.append(ct)
        return out
    }

    /// Decrypt a single-blob (non-chunked) ciphertext.
    static func decryptWithCEK(_ blob: Data, cek: Data) throws -> Data {
        guard blob.count >= 24 + 16 else {
            throw Crypto.Error.badCiphertext
        }
        let nonce24 = blob.prefix(24)
        let ct = blob.dropFirst(24)
        return try XChaCha20Poly1305.open(Data(ct), key: cek, nonce24: Data(nonce24))
    }

    // MARK: - Random helpers

    static func randomCEK() -> Data {
        var raw = Data(count: 32)
        _ = raw.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        return raw
    }

    static func randomSalt(length: Int = 16) -> Data {
        var raw = Data(count: length)
        _ = raw.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!)
        }
        return raw
    }
}
