// APIClientHosted.swift
// Generated-API wrappers for the hosted attachment pipeline.
// Follows the same pattern as APIClientOps.swift / APIClientUploads.swift.

import Foundation
import OpenAPIRuntime

extension APIClient {

    // MARK: - hosted_create

    /// Mint a hosted-download row. Returns token, url_prefix, and expiry.
    /// Pass `senderCekWrapB64` so the sender can re-decrypt from the
    /// /hosted dashboard later (sealed box of CEK under the sender's pubkey).
    func hostedCreate(
        files: [HostedFile],
        senderCekWrapB64: String,
        recipientAddrs: [String] = [],
        subject: String? = nil
    ) async throws -> HostedCreateResp {
        let req = HostedCreateReq(
            recipient_addrs: recipientAddrs.isEmpty ? nil : recipientAddrs,
            subject: subject,
            files: files,
            ttl_days: nil,
            sender_cek_wrap_b64: senderCekWrapB64
        )
        let out = try await openAPI.hosted_create(.init(body: .json(req)))
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .badRequest(let b):
            throw hostedAPIError(400, b.body)
        case .unauthorized(let u):
            throw hostedAPIError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "hosted_create")
        }
    }

    // MARK: - hosted_mine

    /// Sender dashboard — lists all hosted rows with per-row sender_cek_wrap_b64.
    func hostedMine() async throws -> [HostedSenderRow] {
        let out = try await openAPI.hosted_mine(.init())
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .unauthorized(let u):
            throw hostedAPIError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "hosted_mine")
        }
    }

    // MARK: - hosted_revoke

    /// Revoke a hosted-download link and delete its R2 blobs.
    @discardableResult
    func hostedRevoke(token: String) async throws -> HostedRevokeResp {
        let out = try await openAPI.hosted_revoke(
            .init(path: .init(token: token))
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .unauthorized(let u):
            throw hostedAPIError(401, u.body)
        case .forbidden(let f):
            throw hostedAPIError(403, f.body)
        case .notFound(let n):
            throw hostedAPIError(404, n.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "hosted_revoke")
        }
    }

    // MARK: - hosted_view

    /// Public landing page metadata. Unauthenticated — anyone with the token
    /// can fetch metadata; the CEK is never transmitted to the server.
    func hostedView(token: String) async throws -> HostedPublicView {
        let out = try await openAPI.hosted_view(
            .init(path: .init(token: token))
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .notFound(let n):
            throw hostedAPIError(404, n.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "hosted_view")
        }
    }

    // MARK: - hosted_download

    /// Stream one chunk of a hosted file's ciphertext via an HTTP Range
    /// request. Returns the raw bytes for the requested range.
    ///
    /// The generated client exposes a `Range` header parameter — use that
    /// so we stay inside the typed transport layer and share the same
    /// cookie-bearing URLSession.
    func hostedDownload(
        token: String,
        r2Key: String,
        rangeStart: Int64,
        rangeEnd: Int64
    ) async throws -> Data {
        let rangeHeader = "bytes=\(rangeStart)-\(rangeEnd)"
        let out = try await openAPI.hosted_download(
            .init(
                path: .init(token: token),
                query: .init(r2_key: r2Key),
                headers: .init(Range: rangeHeader)
            )
        )
        let httpBody: HTTPBody
        switch out {
        case .ok(let ok):
            httpBody = try ok.body.binary
        case .partialContent(let pc):
            httpBody = try pc.body.binary
        case .notFound(let n):
            throw hostedAPIError(404, n.body)
        case .conflict(let c):
            throw hostedAPIError(409, c.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "hosted_download")
        }
        // Collect the async sequence into a contiguous Data blob.
        // Chunk requests are bounded (4 + 24 + chunkSize + 16 ~ 5 MiB),
        // so full materialisation is safe here.
        var collected = Data()
        for try await chunk in httpBody {
            collected.append(contentsOf: chunk)
        }
        return collected
    }

    // MARK: - Internal

    private func hostedAPIError<Body>(_ status: Int, _ body: Body) -> APIError {
        let msg: String
        switch body {
        case let json as any HasHostedJSONErrorResponse:
            msg = (try? json.hostedErrorMessage()) ?? "\(status)"
        default:
            msg = "\(status)"
        }
        return APIError.http(status: status, message: msg)
    }
}

// Mirror of the private HasJSONErrorResponse pattern in APIClientOps.swift.
private protocol HasHostedJSONErrorResponse {
    func hostedErrorMessage() throws -> String
}

extension Operations.hosted_create.Output.BadRequest.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_create.Output.Unauthorized.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_mine.Output.Unauthorized.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_revoke.Output.Unauthorized.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_revoke.Output.Forbidden.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_revoke.Output.NotFound.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_view.Output.NotFound.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_download.Output.NotFound.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
extension Operations.hosted_download.Output.Conflict.Body: HasHostedJSONErrorResponse {
    fileprivate func hostedErrorMessage() throws -> String { try json.error }
}
