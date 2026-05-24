import Foundation
import Security

/// Chunked AEAD framing — mirrors `web/src/lib/secret-link.ts`
/// (`encryptChunk` / `decryptChunk`).
///
/// # Wire format per chunk
///
///     [ 4-byte big-endian header ] [ 24-byte nonce ] [ ciphertext + 16-byte Poly1305 tag ]
///
/// Header layout (big-endian u32):
/// - bit 31:       `isFinal` flag  (1 = last chunk of the stream)
/// - bits 0..30:   plaintext length (max ~2 GiB; in practice ≤ 5 MiB)
///
/// # AAD (Additional Authenticated Data)
///
///     u32_be(chunkIndex)  ||  u8(isFinal ? 1 : 0)   →  5 bytes total
///
/// Binding each chunk to its stream position prevents reordering and
/// final-chunk substitution attacks.
enum ChunkedAEAD {
    enum Error: Swift.Error, LocalizedError {
        case badCekLength(Int)
        case frameTooShort(have: Int, need: Int)
        case plaintextLengthMismatch(framed: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .badCekLength(let n):
                return "CEK must be 32 bytes, got \(n)"
            case .frameTooShort(let have, let need):
                return "framed chunk truncated: have \(have) bytes, need \(need)"
            case .plaintextLengthMismatch(let framed, let actual):
                return "plaintext length mismatch: header says \(framed), got \(actual)"
            }
        }
    }

    // MARK: - Public API

    /// Encrypt `plaintext` as a single framed chunk.
    ///
    /// - Parameters:
    ///   - cek:        32-byte content-encryption key.
    ///   - plaintext:  Raw bytes to encrypt (any length ≤ 2^31 − 1).
    ///   - chunkIndex: Zero-based index of this chunk within the stream.
    ///   - isFinal:    `true` if this is the last (or only) chunk.
    /// - Returns: `header(4) || nonce(24) || ct+tag` as a contiguous `Data` blob.
    static func encryptChunk(
        cek: Data,
        plaintext: Data,
        chunkIndex: UInt32,
        isFinal: Bool
    ) throws -> Data {
        guard cek.count == 32 else { throw Error.badCekLength(cek.count) }

        // Generate a random 24-byte nonce.
        var nonceBytes = Data(count: 24)
        let status = nonceBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 24, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw Crypto.Error.rngFailed(status)
        }

        return try encryptChunkWithNonce(
            cek: cek,
            plaintext: plaintext,
            chunkIndex: chunkIndex,
            isFinal: isFinal,
            nonce24: nonceBytes
        )
    }

    /// Decrypt a framed chunk produced by `encryptChunk`.
    ///
    /// - Parameters:
    ///   - cek:          32-byte content-encryption key.
    ///   - framedChunk:  The complete framed blob: `header(4) || nonce(24) || ct+tag`.
    ///   - chunkIndex:   The expected position of this chunk in the stream.
    ///                   Must match the value used during encryption — any
    ///                   mismatch causes an AEAD tag failure.
    /// - Returns: `(plaintext, isFinal)` tuple; `isFinal` is parsed from the header.
    static func decryptChunk(
        cek: Data,
        framedChunk: Data,
        chunkIndex: UInt32
    ) throws -> (plaintext: Data, isFinal: Bool) {
        guard cek.count == 32 else { throw Error.badCekLength(cek.count) }

        // Minimum frame: 4 header + 24 nonce + 16 tag (empty plaintext).
        guard framedChunk.count >= 44 else {
            throw Error.frameTooShort(have: framedChunk.count, need: 44)
        }

        // Parse header.
        let (plaintextLength, isFinal) = parseHeader(framedChunk.prefix(4))

        // Validate the declared total frame length.
        let expectedTotal = 4 + 24 + plaintextLength + 16
        guard framedChunk.count >= expectedTotal else {
            throw Error.frameTooShort(have: framedChunk.count, need: expectedTotal)
        }

        let nonce24 = framedChunk[framedChunk.startIndex + 4 ..< framedChunk.startIndex + 28]
        let ctAndTag = framedChunk[framedChunk.startIndex + 28 ..< framedChunk.startIndex + expectedTotal]
        let aad = makeAAD(chunkIndex: chunkIndex, isFinal: isFinal)

        let pt = try XChaCha20Poly1305.open(
            Data(ctAndTag),
            key: cek,
            nonce24: Data(nonce24),
            aad: aad
        )

        // Belt-and-suspenders: the AEAD tag already covers the header content,
        // but an explicit length check defends against any future refactor.
        guard pt.count == plaintextLength else {
            throw Error.plaintextLengthMismatch(framed: plaintextLength, actual: pt.count)
        }

        return (pt, isFinal)
    }

    // MARK: - Internal helpers (exposed for testing with fixed nonces)

    /// Encrypt with an explicit nonce (used by the test vector generator
    /// and unit tests to produce deterministic output).
    static func encryptChunkWithNonce(
        cek: Data,
        plaintext: Data,
        chunkIndex: UInt32,
        isFinal: Bool,
        nonce24: Data
    ) throws -> Data {
        let aad = makeAAD(chunkIndex: chunkIndex, isFinal: isFinal)
        let ctAndTag = try XChaCha20Poly1305.seal(plaintext, key: cek, nonce24: nonce24, aad: aad)

        var out = Data(capacity: 4 + 24 + ctAndTag.count)
        out.append(makeHeader(plaintextLength: plaintext.count, isFinal: isFinal))
        out.append(nonce24)
        out.append(ctAndTag)
        return out
    }

    // MARK: - Private primitives

    /// Build the 4-byte big-endian frame header.
    private static func makeHeader(plaintextLength: Int, isFinal: Bool) -> Data {
        var header = Data(count: 4)
        let len = UInt32(plaintextLength)
        let finalBit: UInt8 = isFinal ? 0x80 : 0x00
        header[0] = UInt8((len >> 24) & 0x7f) | finalBit
        header[1] = UInt8((len >> 16) & 0xff)
        header[2] = UInt8((len >>  8) & 0xff)
        header[3] = UInt8( len        & 0xff)
        return header
    }

    /// Parse the `isFinal` flag and plaintext length from a 4-byte header slice.
    private static func parseHeader(_ header: Data) -> (plaintextLength: Int, isFinal: Bool) {
        let b = header
        let isFinal = (b[b.startIndex] & 0x80) != 0
        let len = (Int(b[b.startIndex    ] & 0x7f) << 24)
                | (Int(b[b.startIndex + 1])         << 16)
                | (Int(b[b.startIndex + 2])         <<  8)
                |  Int(b[b.startIndex + 3])
        return (len, isFinal)
    }

    /// Build the 5-byte AAD: `u32_be(chunkIndex) || u8(isFinal ? 1 : 0)`.
    static func makeAAD(chunkIndex: UInt32, isFinal: Bool) -> Data {
        var aad = Data(count: 5)
        aad[0] = UInt8((chunkIndex >> 24) & 0xff)
        aad[1] = UInt8((chunkIndex >> 16) & 0xff)
        aad[2] = UInt8((chunkIndex >>  8) & 0xff)
        aad[3] = UInt8( chunkIndex        & 0xff)
        aad[4] = isFinal ? 1 : 0
        return aad
    }
}
