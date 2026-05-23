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

    // MARK: - Upload

    /// Uploads raw bytes. The server stores them as-is. For outbound mail the
    /// recipient eventually receives plaintext (server MIME-bundles before
    /// SMTP delivery); for the sender's at-rest copy the filename is sealed
    /// to the user's own pubkey so the DO row only holds ciphertext.
    func upload(
        bytes: Data,
        mime: String,
        filenameCT: String?,
        draftID: String?
    ) async throws -> AttachmentUploadResp {
        var comps = URLComponents(url: api.baseURL.appendingPathComponent("/api/attachments"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "mime", value: mime)]
        if let filenameCT { items.append(URLQueryItem(name: "filename_ct_b64", value: filenameCT)) }
        if let draftID { items.append(URLQueryItem(name: "draft_id", value: draftID)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = bytes
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await api.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Error.bad("non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let msg: String
            if let p = try? api.decoder.decode(APIErrorPayload.self, from: data), let e = p.error { msg = e }
            else { msg = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) }
            throw Error.http(http.statusCode, msg)
        }
        return try api.decoder.decode(AttachmentUploadResp.self, from: data)
    }

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
