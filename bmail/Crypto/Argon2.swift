import Argon2Swift
import CryptoKit
import Foundation

/// Recovery-phrase wrap-key derivation. Matches the web client:
///   wrap_key = Argon2id(entropy = BIP39_raw_bytes, salt, m=64MiB, t=3, p=4, len=32)
///
/// We only ever derive an AES-GCM key — the actual unwrap uses the same
/// AES-GCM blob format as the passkey path.
enum Argon2 {
    struct Params: Codable, Equatable, Sendable {
        let algorithm: String
        let version: Int
        let m: Int        // KiB
        let t: Int
        let p: Int
        let hash_len: Int
        let salt_b64: String

        /// Defaults match the web client (see `crypto.ts ARGON_PARAMS`).
        static func defaults(salt: Data) -> Params {
            Params(
                algorithm: "argon2id",
                version: 19,
                m: 65536,
                t: 3,
                p: 4,
                hash_len: 32,
                salt_b64: salt.b64u
            )
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case unsupportedAlgorithm(String)
        case hashFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let a): return "unsupported Argon2 algorithm: \(a)"
            case .hashFailed(let m): return "Argon2 failed: \(m)"
            }
        }
    }

    /// Server-roundtrippable form: pass either a fresh 16-byte salt (new
    /// enrollment) or a `Params` blob returned by the server (recovery).
    static func deriveWrapKey(entropy: Data, params source: ParamsSource) throws
        -> (wrapKey: SymmetricKey, params: Params)
    {
        let params: Params
        switch source {
        case .new:
            var s = Data(count: 16)
            _ = s.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            params = Params.defaults(salt: s)
        case .existing(let p):
            params = p
        }

        if params.algorithm != "argon2id" {
            throw Error.unsupportedAlgorithm(params.algorithm)
        }
        guard let salt = Data(b64u: params.salt_b64) else {
            throw Error.hashFailed("bad salt encoding")
        }

        let result: Argon2SwiftResult
        do {
            result = try Argon2Swift.hashPasswordBytes(
                password: entropy,
                salt: Salt(bytes: salt),
                iterations: params.t,
                memory: params.m,
                parallelism: params.p,
                length: params.hash_len,
                type: .id,
                version: .V13
            )
        } catch {
            throw Error.hashFailed("\(error)")
        }

        let raw = result.hashData()
        let key = SymmetricKey(data: raw)
        return (key, params)
    }

    enum ParamsSource {
        case new
        case existing(Params)
    }
}
