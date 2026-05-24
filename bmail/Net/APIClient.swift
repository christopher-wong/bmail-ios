import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

enum APIError: Error, LocalizedError {
    case http(status: Int, message: String)
    case transport(URLError)
    case decode(Error)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .http(let s, let m): return "\(s): \(m)"
        case .transport(let e): return e.localizedDescription
        case .decode(let e): return "decode: \(e.localizedDescription)"
        case .other(let m): return m
        }
    }

    var isUnauthorized: Bool {
        if case .http(let s, _) = self { return s == 401 }
        return false
    }
}

final class APIClient {
    static let shared = APIClient()

    /// Base URL of the API. Resolution order:
    ///   1. `BMAIL_API_BASE_URL` env var (set via the Xcode scheme for dev/staging)
    ///   2. `BMAIL_API_BASE_URL` Info.plist key (set via xcconfig)
    ///   3. Production fallback (`https://mail.middleseat.vc`)
    /// Point at a wrangler-dev server during local development without
    /// modifying source: `BMAIL_API_BASE_URL=http://localhost:8787 xcrun ...`.
    static let baseURL: URL = {
        if let raw = ProcessInfo.processInfo.environment["BMAIL_API_BASE_URL"],
           let url = URL(string: raw) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "BMAIL_API_BASE_URL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://mail.middleseat.vc")!
    }()

    let baseURL: URL = APIClient.baseURL

    let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    /// Generated typed client backed by the same cookie-carrying URLSession.
    /// Use this for new operations; existing call sites continue using the
    /// generic `get`/`post`/`patch`/`delete` helpers below.
    let openAPI: Client

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        let urlSession = URLSession(configuration: cfg)
        session = urlSession
        decoder = JSONDecoder()
        encoder = JSONEncoder()
        // The generated Client uses the same URLSession so cookies are shared
        // automatically — no separate cookie-jar management needed.
        let transport = URLSessionTransport(configuration: .init(session: urlSession))
        openAPI = Client(
            serverURL: APIClient.baseURL,
            transport: transport
        )
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, as _: T.Type) async throws -> T {
        let (data, _) = try await perform(req)
        if T.self == Empty.self { return Empty() as! T }
        if data.isEmpty { throw APIError.other("empty body") }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.decode(error) }
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw APIError.other("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let msg: String
                if let payload = try? decoder.decode(APIErrorPayload.self, from: data),
                   let err = payload.error {
                    msg = err
                } else {
                    msg = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                }
                throw APIError.http(status: http.statusCode, message: msg)
            }
            return (data, http)
        } catch let e as URLError {
            throw APIError.transport(e)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.other(error.localizedDescription)
        }
    }

    struct Empty: Decodable {}

    // MARK: - Public API

    func get<T: Decodable>(_ path: String, as _: T.Type = T.self) async throws -> T {
        try await run(request("GET", path), as: T.self)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, _ body: B, as _: T.Type = T.self) async throws -> T {
        let data = try encoder.encode(body)
        return try await run(request("POST", path, body: data), as: T.self)
    }

    func patch<T: Decodable, B: Encodable>(_ path: String, _ body: B, as _: T.Type = T.self) async throws -> T {
        let data = try encoder.encode(body)
        return try await run(request("PATCH", path, body: data), as: T.self)
    }

    @discardableResult
    func delete(_ path: String) async throws -> Empty {
        try await run(request("DELETE", path), as: Empty.self)
    }

    @discardableResult
    func postVoid<B: Encodable>(_ path: String, _ body: B) async throws -> Empty {
        let data = try encoder.encode(body)
        return try await run(request("POST", path, body: data), as: Empty.self)
    }

    /// Clear all cookies for the API host — for logout.
    func clearCookies() {
        let store = session.configuration.httpCookieStorage ?? HTTPCookieStorage.shared
        if let cookies = store.cookies(for: baseURL) {
            for c in cookies { store.deleteCookie(c) }
        }
    }
}
