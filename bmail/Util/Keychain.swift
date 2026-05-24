import Foundation
import LocalAuthentication
import Security

nonisolated enum Keychain {
    static let service = "middleseat.bmail"

    enum SetError: Swift.Error {
        /// SecAccessControlCreateWithFlags returned nil while building the
        /// biometry-required attribute. Caller asked for biometry; refusing to
        /// silently downgrade to non-biometric storage.
        case accessControlUnavailable
        /// Underlying SecItemAdd failed with the given OSStatus.
        case secItemAdd(OSStatus)
    }

    /// Store `data` under `key`. When `requireBiometry` is true, refuses to
    /// fall back to non-biometric storage: throws `SetError.accessControlUnavailable`
    /// so the caller can surface the failure and not pretend the key is gated.
    @discardableResult
    static func set(_ data: Data, for key: String, requireBiometry: Bool = false) throws -> Bool {
        delete(key)
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        if requireBiometry {
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                .userPresence,
                nil
            ) else {
                throw SetError.accessControlUnavailable
            }
            q[kSecAttrAccessControl as String] = access
        } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SetError.secItemAdd(status)
        }
        return true
    }

    /// True if the device has biometry enrolled (Face ID or Touch ID) and a
    /// passcode set — i.e. we can store a Keychain item gated by `.userPresence`.
    static var biometryAvailable: Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    static var biometryLabel: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "biometrics"
        }
    }

    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}
