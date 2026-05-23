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
        case paramsOutOfRange(String)
        case rngFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedAlgorithm(let a): return "unsupported Argon2 algorithm: \(a)"
            case .hashFailed(let m): return "Argon2 failed: \(m)"
            case .paramsOutOfRange(let m): return "Argon2 parameters out of range: \(m)"
            case .rngFailed(let s): return "secure RNG failed (OSStatus \(s))"
            }
        }
    }

    // Hard caps on server-supplied params. A malicious or compromised server
    // can otherwise force the device to allocate gigabytes of RAM or spin for
    // minutes inside Argon2id during a recovery-phrase login. These bounds
    // bracket the defaults (m=65536 KiB, t=3, p=4) with comfortable headroom
    // while keeping derivation under a few seconds on any supported device.
    static let maxMemoryKiB = 512 * 1024   // 512 MiB
    static let maxIterations = 12
    static let maxParallelism = 8
    static let maxHashLen = 64
    static let minMemoryKiB = 8 * 1024     // 8 MiB
    static let minIterations = 1
    static let minParallelism = 1
    static let minHashLen = 16

    /// Server-roundtrippable form: pass either a fresh 16-byte salt (new
    /// enrollment) or a `Params` blob returned by the server (recovery).
    /// Off-loads the synchronous Argon2 work to a detached task so it doesn't
    /// freeze the main actor (this function is itself called from @MainActor
    /// flows on AuthService).
    static func deriveWrapKey(entropy: Data, params source: ParamsSource) async throws
        -> (wrapKey: SymmetricKey, params: Params)
    {
        let params: Params
        switch source {
        case .new:
            var s = Data(count: 16)
            let status = s.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
            }
            guard status == errSecSuccess else { throw Error.rngFailed(status) }
            params = Params.defaults(salt: s)
        case .existing(let p):
            params = p
        }

        if params.algorithm != "argon2id" {
            throw Error.unsupportedAlgorithm(params.algorithm)
        }
        guard (minMemoryKiB...maxMemoryKiB).contains(params.m) else {
            throw Error.paramsOutOfRange("m=\(params.m) KiB outside [\(minMemoryKiB), \(maxMemoryKiB)]")
        }
        guard (minIterations...maxIterations).contains(params.t) else {
            throw Error.paramsOutOfRange("t=\(params.t) outside [\(minIterations), \(maxIterations)]")
        }
        guard (minParallelism...maxParallelism).contains(params.p) else {
            throw Error.paramsOutOfRange("p=\(params.p) outside [\(minParallelism), \(maxParallelism)]")
        }
        guard (minHashLen...maxHashLen).contains(params.hash_len) else {
            throw Error.paramsOutOfRange("hash_len=\(params.hash_len) outside [\(minHashLen), \(maxHashLen)]")
        }
        guard let salt = Data(b64u: params.salt_b64) else {
            throw Error.hashFailed("bad salt encoding")
        }

        let raw: Data = try await Task.detached(priority: .userInitiated) {
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
            return result.hashData()
        }.value

        let key = SymmetricKey(data: raw)
        return (key, params)
    }

    enum ParamsSource {
        case new
        case existing(Params)
    }
}
