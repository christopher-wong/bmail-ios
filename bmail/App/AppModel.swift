import Foundation
import Observation

/// Root app state. SwiftUI views observe this directly via @Environment.
@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable {
        case bootstrap          // checking session
        case unauthenticated
        case authenticated
    }

    var phase: Phase = .bootstrap
    var me: MeResp?

    /// X25519 private key (32 bytes). In-memory only. Cleared on logout.
    var priv: Data?

    var lastError: String?

    var primaryDomain: String?
    var addAddresses: [String] = []

    /// Public server config — populated once at launch and after login.
    /// Unauthenticated, safe to refresh from `.unauthenticated`.
    var publicConfig: PublicConfig?

    private let auth: AuthService

    init() {
        self.auth = AuthService()
    }

    private static func privKey(for userID: String) -> String { "priv:\(userID)" }
    private static let biometryDefaultsKey = "biometryLockEnabled"

    var biometryLockEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.biometryDefaultsKey)
    }

    var biometryAvailable: Bool { Keychain.biometryAvailable }
    var biometryLabel: String { Keychain.biometryLabel }

    /// Toggle the biometric gate on the cached priv. Returns true if the
    /// Keychain item was re-stored successfully, false if `priv` isn't
    /// loaded yet (caller is logged out).
    @discardableResult
    func setBiometryLock(enabled: Bool) -> Bool {
        guard let me, let priv else { return false }
        UserDefaults.standard.set(enabled, forKey: Self.biometryDefaultsKey)
        Keychain.set(priv, for: Self.privKey(for: me.id), requireBiometry: enabled)
        return true
    }

    var pub: Data? {
        guard let s = me?.pub_key_b64, let d = Data(b64u: s) else { return nil }
        return d
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        // Best-effort GC for stale per-draft hosted state files. Fire-and-forget;
        // we don't await so it can't delay the auth check.
        Task.detached(priority: .background) { DraftStateStore.default.gcStale() }

        // Server config is unauthenticated — fetch it concurrently with the
        // session probe so launch isn't serialized on two round-trips.
        async let cfg: PublicConfig? = (try? APIClient.shared.publicConfig())
        do {
            let me = try await auth.currentMe()
            self.me = me
            let key = Self.privKey(for: me.id)
            // Read off the main actor — if the item is biometry-gated this
            // will block the calling thread on the Face ID / Touch ID prompt.
            let cached = await Task.detached { Keychain.get(key) }.value
            if let cached {
                self.priv = cached
                self.phase = .authenticated
                RealtimeClient.shared.start()
            } else {
                self.phase = .unauthenticated
            }
        } catch {
            self.phase = .unauthenticated
        }
        if let cfg = await cfg {
            self.publicConfig = cfg
            self.primaryDomain = cfg.primary_domain
            self.addAddresses = cfg.additional_domains
        }
    }

    func loginWithPasskey() async {
        lastError = nil
        do {
            let s = try await auth.loginWithPasskey()
            self.me = s.me
            self.priv = s.priv
            Keychain.set(s.priv, for: Self.privKey(for: s.me.id), requireBiometry: biometryLockEnabled)
            self.phase = .authenticated
            RealtimeClient.shared.start()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func loginWithRecovery(handle: String, phrase: String) async {
        lastError = nil
        do {
            let s = try await auth.loginWithRecovery(handle: handle, phrase: phrase)
            self.me = s.me
            self.priv = s.priv
            Keychain.set(s.priv, for: Self.privKey(for: s.me.id), requireBiometry: biometryLockEnabled)
            self.phase = .authenticated
            RealtimeClient.shared.start()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Enroll via invite. Returns the freshly minted recovery phrase so the
    /// view can show it to the user once; we don't keep a copy.
    func enrollWithInvite(token: String, handle: String?, displayName: String?, credentialLabel: String?) async -> String? {
        lastError = nil
        do {
            let r = try await auth.enrollWithInvite(
                token: token, handle: handle, displayName: displayName, credentialLabel: credentialLabel
            )
            self.me = r.session.me
            self.priv = r.session.priv
            // Stay on the recovery-display screen first; the EnrollView will
            // flip to .authenticated once the user has confirmed they saved it.
            return r.recoveryPhrase
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func finishEnrollment() {
        if let me, let priv {
            Keychain.set(priv, for: Self.privKey(for: me.id), requireBiometry: biometryLockEnabled)
        }
        self.phase = .authenticated
        RealtimeClient.shared.start()
    }

    func addPasskey(label: String?) async -> Bool {
        guard let priv else { lastError = "not signed in"; return false }
        lastError = nil
        do {
            try await auth.addPasskey(currentPriv: priv, label: label)
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return false
        }
    }

    func listPasskeys() async -> [PasskeyView] {
        do {
            return try await auth.listPasskeys()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return []
        }
    }

    /// Returns true on success. 409 means "this is your last passkey — keep at
    /// least one"; the caller surfaces the server's message in `lastError`.
    func removePasskey(credentialIDB64: String) async -> Bool {
        lastError = nil
        do {
            try await auth.removePasskey(credentialIDB64: credentialIDB64)
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return false
        }
    }

    func logout() async {
        RealtimeClient.shared.stop()
        if let me {
            Keychain.delete(Self.privKey(for: me.id))
        }
        UserDefaults.standard.removeObject(forKey: Self.biometryDefaultsKey)
        await auth.logout()
        self.priv = nil
        self.me = nil
        self.phase = .unauthenticated
    }
}
