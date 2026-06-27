import Foundation

/// Remote-image endpoints: the per-user settings (global default + allowed
/// sender domains) and the authenticated image proxy.
///
/// The proxy (`GET /api/img?u=…`) fetches a remote image server-side so the
/// sender never sees the recipient's IP. We pull the bytes over the same
/// cookie-carrying URLSession used everywhere else and hand them to the HTML
/// renderer as a `data:` URI, which keeps the WKWebView fully sandboxed
/// (it never makes a network request of its own).
extension APIClient {

    // MARK: - Settings

    func imageSettings() async throws -> ImageSettings {
        try await get("/api/me/image-settings")
    }

    func setImageLoadByDefault(_ on: Bool) async throws -> ImageSettings {
        try await put("/api/me/image-settings", ["load_by_default": on])
    }

    func addImageDomain(_ domain: String) async throws -> ImageSettings {
        try await post("/api/me/image-settings/domains", ["domain": domain])
    }

    func removeImageDomain(_ domain: String) async throws -> ImageSettings {
        let enc = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? domain
        return try await delete("/api/me/image-settings/domains/\(enc)", as: ImageSettings.self)
    }

    // MARK: - Proxy

    /// Fetch a remote image through the worker proxy and return it as a
    /// base64 `data:` URI ready to drop into an `<img src>`.
    func proxyImageDataURI(remoteURL: String) async throws -> String {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.other("bad base url")
        }
        comps.path = "/api/img"
        comps.queryItems = [URLQueryItem(name: "u", value: remoteURL)]
        guard let url = comps.url else { throw APIError.other("bad image url") }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.other("non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, message: "image proxy")
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}
