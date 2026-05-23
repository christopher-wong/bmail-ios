import Foundation

/// HChaCha20 subkey derivation per draft-irtf-cfrg-xchacha. Given a 32-byte key
/// and a 16-byte nonce, produces a 32-byte subkey. Used to convert XChaCha20's
/// 24-byte nonce + key into a (subkey, 12-byte nonce) pair that the IETF
/// ChaCha20-Poly1305 AEAD in CryptoKit can consume.
enum HChaCha20 {
    static let constants: [UInt32] = [
        0x6170_7865, // "expa"
        0x3320_646e, // "nd 3"
        0x7962_2d32, // "2-by"
        0x6b20_6574, // "te k"
    ]

    static func derive(key: Data, nonce16: Data) -> Data {
        precondition(key.count == 32, "HChaCha20 key must be 32 bytes")
        precondition(nonce16.count == 16, "HChaCha20 nonce must be 16 bytes")

        var s = [UInt32](repeating: 0, count: 16)
        s[0] = constants[0]; s[1] = constants[1]; s[2] = constants[2]; s[3] = constants[3]
        for i in 0..<8 { s[4 + i] = readLE32(key, offset: i * 4) }
        for i in 0..<4 { s[12 + i] = readLE32(nonce16, offset: i * 4) }

        // 20 rounds = 10 double-rounds
        for _ in 0..<10 {
            qr(&s, 0, 4, 8, 12)
            qr(&s, 1, 5, 9, 13)
            qr(&s, 2, 6, 10, 14)
            qr(&s, 3, 7, 11, 15)
            qr(&s, 0, 5, 10, 15)
            qr(&s, 1, 6, 11, 12)
            qr(&s, 2, 7, 8, 13)
            qr(&s, 3, 4, 9, 14)
        }

        var out = Data(count: 32)
        // First 4 words ‖ last 4 words, little-endian.
        for i in 0..<4 { writeLE32(&out, offset: i * 4, value: s[i]) }
        for i in 0..<4 { writeLE32(&out, offset: 16 + i * 4, value: s[12 + i]) }
        return out
    }

    @inline(__always)
    private static func qr(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] &+= s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] &+= s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x &<< n) | (x &>> (32 &- n))
    }

    @inline(__always)
    private static func readLE32(_ d: Data, offset: Int) -> UInt32 {
        UInt32(d[d.startIndex + offset])
            | (UInt32(d[d.startIndex + offset + 1]) << 8)
            | (UInt32(d[d.startIndex + offset + 2]) << 16)
            | (UInt32(d[d.startIndex + offset + 3]) << 24)
    }

    @inline(__always)
    private static func writeLE32(_ d: inout Data, offset: Int, value: UInt32) {
        d[d.startIndex + offset]     = UInt8(value & 0xFF)
        d[d.startIndex + offset + 1] = UInt8((value >> 8)  & 0xFF)
        d[d.startIndex + offset + 2] = UInt8((value >> 16) & 0xFF)
        d[d.startIndex + offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
