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

    private let auth: AuthService

    init() {
        self.auth = AuthService()
    }

    var pub: Data? {
        guard let s = me?.pub_key_b64, let d = Data(b64u: s) else { return nil }
        return d
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        do {
            let me = try await auth.currentMe()
            // We had a live session cookie — but no priv. Force a fresh
            // passkey assert so we can recover the priv key. Until then,
            // keep the session but stay on login.
            self.me = me
            self.phase = .unauthenticated
        } catch {
            self.phase = .unauthenticated
        }
    }

    func loginWithPasskey() async {
        lastError = nil
        do {
            let s = try await auth.loginWithPasskey()
            self.me = s.me
            self.priv = s.priv
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
        await auth.logout()
        self.priv = nil
        self.me = nil
        self.phase = .unauthenticated
    }
}
