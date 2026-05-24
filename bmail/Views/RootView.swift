import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    /// Pending hosted link to open once the user is authenticated.
    /// Set by the Universal Link / deep link handler; consumed by MainShellView.
    @State private var pendingHostedLink: HostedLinkTarget?

    /// Pending secret link token. Secret links don't carry keys in the URL
    /// (password is the key), so we only need the token.
    @State private var pendingSecretToken: String?

    var body: some View {
        ZStack {
            switch app.phase {
            case .bootstrap:
                BootstrapView()
            case .unauthenticated:
                LoginView()
            case .authenticated:
                MainShellView(
                    pendingHostedLink: $pendingHostedLink,
                    pendingSecretToken: $pendingSecretToken
                )
            }
        }
        .task {
            if app.phase == .bootstrap { await app.bootstrap() }
        }
        // Universal Link handler.
        //   Hosted: https://mail.middleseat.vc/d/<token>#k=<cek>
        //   Secret: https://mail.middleseat.vc/s/<token>
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            if let target = HostedLinkTarget(universalLink: url) {
                pendingHostedLink = target
            } else if let token = SecretLinkToken(universalLink: url)?.token {
                pendingSecretToken = token
            }
        }
        // Dev deep links (simulator testing without DNS / AASA):
        //   bmail://hosted?token=<>&k=<>
        //   bmail://secret?token=<>
        .onOpenURL { url in
            if let target = HostedLinkTarget(deepLink: url) {
                pendingHostedLink = target
            } else if let token = SecretLinkToken(deepLink: url)?.token {
                pendingSecretToken = token
            }
        }
    }
}

// MARK: - HostedLinkTarget

/// Parsed token + CEK from either a Universal Link or the dev deep link scheme.
struct HostedLinkTarget: Identifiable {
    let id: String   // token doubles as identity
    let token: String
    let cek: Data

    /// Parse `https://mail.middleseat.vc/d/<token>#k=<base64url_cek>`.
    /// The fragment is treated as a query-string of `&`-separated `key=value`
    /// pairs so additional, unknown params don't pollute the CEK.
    init?(universalLink url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pathComponents = url.pathComponents  // ["", "d", "<token>"]
        guard pathComponents.count == 3,
              pathComponents[1] == "d" else { return nil }
        let token = pathComponents[2]
        guard let fragment = components?.fragment,
              let cekB64u = Self.fragmentValue(named: "k", in: fragment),
              let cek = Data(b64u: cekB64u) else { return nil }
        self.token = token
        self.cek = cek
        self.id = token
    }

    /// Extract a single `name=value` entry from a fragment string. Treats the
    /// fragment as a query-style `&`-separated list. Returns `nil` when the
    /// key is absent or its value is empty.
    private static func fragmentValue(named key: String, in fragment: String) -> String? {
        for pair in fragment.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == key else { continue }
            let value = String(parts[1])
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Parse `bmail://hosted?token=<>&k=<base64url_cek>`
    init?(deepLink url: URL) {
        guard url.scheme == "bmail", url.host == "hosted" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let token = components?.queryItems?.first(where: { $0.name == "token" })?.value,
              let kValue = components?.queryItems?.first(where: { $0.name == "k" })?.value,
              let cek = Data(b64u: kValue) else { return nil }
        self.token = token
        self.cek = cek
        self.id = token
    }
}

// MARK: - SecretLinkToken

/// Parsed token from a secret link Universal Link or dev deep link.
/// Secret links have no key in the URL — the password is the key.
struct SecretLinkToken: Identifiable {
    let id: String   // token doubles as identity
    let token: String

    /// Direct init from a known token string.
    init(token: String) {
        self.token = token
        self.id = token
    }

    /// Parse `https://mail.middleseat.vc/s/<token>`
    init?(universalLink url: URL) {
        let parts = url.pathComponents  // ["", "s", "<token>"]
        guard parts.count == 3, parts[1] == "s" else { return nil }
        let token = parts[2]
        guard !token.isEmpty else { return nil }
        self.token = token
        self.id = token
    }

    /// Parse `bmail://secret?token=<token>`
    init?(deepLink url: URL) {
        guard url.scheme == "bmail", url.host == "secret" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let token = components?.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else { return nil }
        self.token = token
        self.id = token
    }
}

private struct BootstrapView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("CFEMAIL")
                .font(.mono(16, .bold))
                .tracking(2)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.inverseInk)
    }
}
