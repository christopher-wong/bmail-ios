// APIClientUploads.swift
// Generated-API wrappers for the multipart upload pipeline.
// Follows the same pattern as APIClientOps.swift — extract .ok, throw on errors.

import Foundation
import OpenAPIRuntime

extension APIClient {

    // MARK: - uploads_init

    /// Begin an R2 multipart upload. Returns (r2_key, upload_id).
    func uploadsInit(kind: UploadKindSchema, mime: String?) async throws -> UploadInitResp {
        let req = UploadInitReq(kind: kind, mime: mime)
        let out = try await openAPI.uploads_init(.init(body: .json(req)))
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .unauthorized(let u):
            throw uploadsAPIError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "uploads_init")
        }
    }

    // MARK: - uploads_parts

    /// Upload one raw part (≤ 6 MiB) to an in-flight multipart upload.
    /// Headers carry r2_key, upload_id, and the 1-indexed part number.
    /// Returns the server-assigned part number and ETag for use in /complete.
    func uploadsPart(
        r2Key: String,
        uploadId: String,
        partNumber: Int32,
        body: Data
    ) async throws -> UploadPartResp {
        let headers = Operations.uploads_parts.Input.Headers(
            x_hyphen_r2_hyphen_key: r2Key,
            x_hyphen_upload_hyphen_id: uploadId,
            x_hyphen_part_hyphen_number: partNumber
        )
        let httpBody = HTTPBody(body)
        let out = try await openAPI.uploads_parts(
            .init(headers: headers, body: .binary(httpBody))
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .badRequest(let b):
            throw uploadsAPIError(400, b.body)
        case .unauthorized(let u):
            throw uploadsAPIError(401, u.body)
        case .forbidden(let f):
            throw uploadsAPIError(403, f.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "uploads_parts")
        }
    }

    // MARK: - uploads_complete

    /// Finalize the multipart upload. For kind=attach, also registers an
    /// attachment row and returns attachment_id.
    func uploadsComplete(req: UploadCompleteReq) async throws -> UploadCompleteResp {
        let out = try await openAPI.uploads_complete(.init(body: .json(req)))
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .badRequest(let b):
            throw uploadsAPIError(400, b.body)
        case .unauthorized(let u):
            throw uploadsAPIError(401, u.body)
        case .forbidden(let f):
            throw uploadsAPIError(403, f.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "uploads_complete")
        }
    }

    // MARK: - uploads_abort

    /// Best-effort abort of an in-flight multipart upload. Swallows server
    /// errors — the caller should still re-throw the original failure after
    /// calling this.
    func uploadsAbort(r2Key: String, uploadId: String) async throws {
        let req = UploadAbortReq(r2_key: r2Key, upload_id: uploadId)
        let out = try await openAPI.uploads_abort(.init(body: .json(req)))
        switch out {
        case .ok: return
        case .unauthorized(let u):
            throw uploadsAPIError(401, u.body)
        case .forbidden(let f):
            throw uploadsAPIError(403, f.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "uploads_abort")
        }
    }

    // MARK: - Internal

    private func uploadsAPIError<Body>(_ status: Int, _ body: Body) -> APIError {
        let msg: String
        switch body {
        case let json as any HasUploadsJSONErrorResponse:
            msg = (try? json.uploadsErrorMessage()) ?? "\(status)"
        default:
            msg = "\(status)"
        }
        return APIError.http(status: status, message: msg)
    }
}

// Mirror of the private HasJSONErrorResponse pattern in APIClientOps.swift.
private protocol HasUploadsJSONErrorResponse {
    func uploadsErrorMessage() throws -> String
}

extension Operations.uploads_init.Output.Unauthorized.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_parts.Output.BadRequest.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_parts.Output.Unauthorized.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_parts.Output.Forbidden.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_complete.Output.BadRequest.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_complete.Output.Unauthorized.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_complete.Output.Forbidden.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_abort.Output.Unauthorized.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
extension Operations.uploads_abort.Output.Forbidden.Body: HasUploadsJSONErrorResponse {
    fileprivate func uploadsErrorMessage() throws -> String { try json.error }
}
