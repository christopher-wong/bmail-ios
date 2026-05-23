import CryptoKit
import Foundation

/// XChaCha20-Poly1305 AEAD built on CryptoKit's IETF ChaCha20-Poly1305.
/// Same construction libsodium / draft-irtf-cfrg-xchacha defines:
///
///     subkey = HChaCha20(key, nonce24[0..16])
///     ietfNonce = 0x00_00_00_00 || nonce24[16..24]
///     ct = ChaCha20Poly1305(subkey, ietfNonce, plaintext, aad)
enum XChaCha20Poly1305 {
    enum Error: Swift.Error { case badParam }

    static func seal(_ plaintext: Data, key: Data, nonce24: Data, aad: Data = .init()) throws -> Data {
        guard key.count == 32, nonce24.count == 24 else { throw Error.badParam }
        let subkey = HChaCha20.derive(key: key, nonce16: nonce24.prefix(16))
        var ietfNonce = Data(count: 4)
        ietfNonce.append(nonce24.suffix(8))
        let symKey = SymmetricKey(data: subkey)
        let n = try ChaChaPoly.Nonce(data: ietfNonce)
        let sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: n, authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }

    static func open(_ ctAndTag: Data, key: Data, nonce24: Data, aad: Data = .init()) throws -> Data {
        guard key.count == 32, nonce24.count == 24, ctAndTag.count >= 16 else { throw Error.badParam }
        let subkey = HChaCha20.derive(key: key, nonce16: nonce24.prefix(16))
        var ietfNonce = Data(count: 4)
        ietfNonce.append(nonce24.suffix(8))
        let symKey = SymmetricKey(data: subkey)
        let n = try ChaChaPoly.Nonce(data: ietfNonce)
        let ct = ctAndTag.dropLast(16)
        let tag = ctAndTag.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: n, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: symKey, authenticating: aad)
    }
}
