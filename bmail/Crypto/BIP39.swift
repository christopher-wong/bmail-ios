import CryptoKit
import Foundation

/// BIP-39 12-word mnemonics, fixed at 128 bits of entropy (what the web
/// client generates). The recovery flow keys off the raw 16-byte entropy,
/// never the phrase string, so bit-exact compatibility here is what makes
/// recovery interoperable with web-enrolled accounts.
enum BIP39 {
    enum Error: Swift.Error, LocalizedError {
        case invalidLength
        case unknownWord(String)
        case checksumMismatch
        case rngFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidLength: return "recovery phrase must be 12 words"
            case .unknownWord(let w): return "“\(w)” is not in the BIP39 wordlist"
            case .checksumMismatch: return "recovery phrase checksum doesn't match"
            case .rngFailed(let s): return "secure RNG failed (OSStatus \(s))"
            }
        }
    }

    static func newMnemonic() throws -> String {
        var entropy = Data(count: 16)
        let status = entropy.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw Error.rngFailed(status) }
        return mnemonic(fromEntropy: entropy)
    }

    static func mnemonic(fromEntropy entropy: Data) -> String {
        precondition(entropy.count == 16, "BIP39 12-word phrase requires 16-byte entropy")
        let checksumNibble = Data(SHA256.hash(data: entropy))[0] >> 4
        // 132-bit stream: 128 entropy bits + 4 checksum bits, packed big-endian.
        var stream: UInt64 = 0
        var bitsInStream = 0
        var words: [String] = []
        var byteIndex = 0
        var checksumConsumed = false
        for _ in 0..<12 {
            while bitsInStream < 11 {
                let nextByte: UInt8
                if byteIndex < entropy.count {
                    nextByte = entropy[byteIndex]
                    byteIndex += 1
                } else if !checksumConsumed {
                    // Top 4 bits of next byte are the checksum, low 4 are zero.
                    nextByte = checksumNibble << 4
                    checksumConsumed = true
                } else {
                    preconditionFailure("ran out of bits")
                }
                stream = (stream << 8) | UInt64(nextByte)
                bitsInStream += 8
            }
            let shift = bitsInStream - 11
            let index = Int((stream >> shift) & 0x7FF)
            bitsInStream -= 11
            stream &= (UInt64(1) << bitsInStream) &- 1
            words.append(BIP39Wordlist.english[index])
        }
        return words.joined(separator: " ")
    }

    static func entropy(fromMnemonic phrase: String) throws -> Data {
        // Use the POSIX locale: BIP-39 words are ASCII and `.lowercased()` is
        // locale-sensitive (e.g. in tr_TR, "I" → "ı" which isn't in the wordlist).
        let words = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard words.count == 12 else { throw Error.invalidLength }

        var stream: UInt64 = 0
        var bitsInStream = 0
        var output: [UInt8] = []
        output.reserveCapacity(17) // 132 bits = 17 bytes (last byte half-full)
        for w in words {
            guard let idx = BIP39Wordlist.englishIndex[w] else { throw Error.unknownWord(w) }
            stream = (stream << 11) | UInt64(idx & 0x7FF)
            bitsInStream += 11
            while bitsInStream >= 8 {
                let shift = bitsInStream - 8
                output.append(UInt8((stream >> shift) & 0xFF))
                bitsInStream -= 8
                stream &= (UInt64(1) << bitsInStream) &- 1
            }
        }
        // Final 4 bits are the checksum, left-aligned in a last byte.
        guard bitsInStream == 4 else { throw Error.invalidLength }
        output.append(UInt8((stream << 4) & 0xFF))
        guard output.count == 17 else { throw Error.invalidLength }

        let entropy = Data(output.prefix(16))
        let supplied = (output[16] & 0xF0) >> 4
        let expected = Data(SHA256.hash(data: entropy))[0] >> 4
        guard supplied == expected else { throw Error.checksumMismatch }
        return entropy
    }

    static func isValid(_ phrase: String) -> Bool {
        (try? entropy(fromMnemonic: phrase)) != nil
    }
}

extension BIP39Wordlist {
    /// Word → 11-bit index lookup, computed once.
    static let englishIndex: [String: Int] = {
        var d: [String: Int] = [:]
        d.reserveCapacity(english.count)
        for (i, w) in english.enumerated() { d[w] = i }
        return d
    }()
}
