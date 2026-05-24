import Foundation

/// Uploads / downloads / lists attachments. Keeps the binary parts off the
/// JSON path: bytes go up as raw `application/octet-stream`, metadata via
/// query string, and downloads come back as raw bytes that we seal-open in
/// the caller.
struct AttachmentService {
    static let shared = AttachmentService()
    private let api = APIClient.shared

    enum Error: Swift.Error, LocalizedError {
        case http(Int, String)
        case bad(String)
        var errorDescription: String? {
            switch self {
            case .http(let s, let m): return "\(s): \(m)"
            case .bad(let m): return m
            }
        }
    }

    // Upload is now handled by Uploader.swift via the unified `uploads_*`
    // pipeline (kind=.attach). The legacy POST /api/attachments endpoint was
    // removed from the server spec.

    // MARK: - Per-message list

    func list(forMessageID id: String) async throws -> [AttachmentRow] {
        try await api.get("/api/messages/\(percent(id))/attachments")
    }

    // MARK: - Download

    func download(id: String) async throws -> Data {
        var req = URLRequest(url: api.baseURL.appendingPathComponent("/api/attachments/\(percent(id))"))
        req.httpMethod = "GET"
        let (data, resp) = try await api.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Error.bad("non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    // MARK: - Delete

    func delete(id: String) async throws {
        _ = try await api.delete("/api/attachments/\(percent(id))")
    }

    private func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
