// APIClientSecret.swift
// Generated-API wrappers for the password-protected secret-link pipeline.
// Follows the same pattern as APIClientHosted.swift / APIClientOps.swift.
//
// Error mapping:
//   secretOpen / secretAttachment return SecretLinkError (not the generic
//   APIError) so the UI can render distinct states for wrong-password,
//   self-destruct, revoked, and expired without string-matching.

import Foundation
import OpenAPIRuntime

// MARK: - SecretLinkError

/// Structured errors for the secret-link open + attachment flows.
/// Maps over the nuanced 401 / 410 responses the server can return.
enum SecretLinkError: Error, LocalizedError {
    /// Wrong password. `attemptsRemaining` is non-nil when the server included
    /// an `attempts_remaining` value in the error message (≤ 10 from the server).
    case wrongPassword(attemptsRemaining: Int?)
    /// The link crossed the max-failure threshold. Content has been wiped.
    case selfDestructed
    /// Sender manually revoked the link (or it was already used under one-time policy).
    case revoked
    /// Link past its expiry timestamp.
    case expired
    /// Unexpected HTTP error.
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword(let n):
            if let n {
                return n <= 3
                    ? "Wrong password — \(n) attempt\(n == 1 ? "" : "s") left before this link self-destructs."
                    : "Wrong password (\(n) attempts left)."
            }
            return "Wrong password."
        case .selfDestructed:
            return "Too many failed attempts — this link has self-destructed and the content has been deleted."
        case .revoked:
            return "This link was revoked or already used."
        case .expired:
            return "This link has expired."
        case .http(let s, let m):
            return "\(s): \(m)"
        }
    }
}

// MARK: - Model aliases

typealias SecretCreateReq    = Components.Schemas.SecretCreateReq
typealias SecretCreateResp   = Components.Schemas.SecretCreateResp
typealias SecretSenderRow    = Components.Schemas.SecretSenderRow
typealias SecretRevokeResp   = Components.Schemas.SecretRevokeResp
typealias SecretLinkOpenReq  = Components.Schemas.SecretLinkOpenReq
typealias SecretLinkOpenResp = Components.Schemas.SecretLinkOpenResp
typealias SecretAttachmentRef = Components.Schemas.SecretAttachmentRef
typealias SecretAttachmentReq = Components.Schemas.SecretAttachmentReq

// MARK: - APIClient extension

extension APIClient {

    // MARK: - secret_create

    /// Mint a new secret link. Returns the token + URL.
    func secretCreate(req: SecretCreateReq) async throws -> SecretCreateResp {
        let out = try await openAPI.secret_create(
            .init(body: .json(req))
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .badRequest(let b):
            throw secretAPIError(400, b.body)
        case .unauthorized(let u):
            throw secretAPIError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "secret_create")
        }
    }

    // MARK: - secret_mine

    /// Sender dashboard — list all secret links created by the current user.
    func secretMine() async throws -> [SecretSenderRow] {
        let out = try await openAPI.secret_mine(.init())
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .unauthorized(let u):
            throw secretAPIError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "secret_mine")
        }
    }

    // MARK: - secret_revoke

    /// Revoke a secret link and delete its R2 blobs.
    @discardableResult
    func secretRevoke(token: String) async throws -> SecretRevokeResp {
        let out = try await openAPI.secret_revoke(
            .init(path: .init(token: token))
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .unauthorized(let u):
            throw secretAPIError(401, u.body)
        case .forbidden(let f):
            throw secretAPIError(403, f.body)
        case .notFound(let n):
            throw secretAPIError(404, n.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "secret_revoke")
        }
    }

    // MARK: - secret_view

    /// Public metadata for the recipient landing page. Unauthenticated.
    ///
    /// On HTTP 410 the server signals the link has self-destructed and its
    /// content has been wiped — we surface that as the structured
    /// `SecretLinkError.selfDestructed` so the recipient UI can render the
    /// distinct dead screen instead of a generic error. Revoked / expired
    /// states are still discoverable on the live 200 path through the
    /// `revoked` / `expired` fields of the returned `SecretLinkPublicView`.
    func secretView(token: String) async throws -> SecretLinkPublicView {
        let out = try await openAPI.secret_view(
            .init(path: .init(token: token))
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .notFound(let n):
            throw secretAPIError(404, n.body)
        case .gone(let g):
            // 410 from GET → self-destructed. Inspect the error message in case
            // a future server build distinguishes self-destruct vs revoked/expired
            // here too; default to selfDestructed.
            let msg = (try? g.body.json.error) ?? ""
            throw mapOpenError(status: 410, errorMessage: msg.isEmpty ? "self_destructed" : msg)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "secret_view")
        }
    }

    // MARK: - secret_open

    /// Attempt to open a secret link with the derived password check.
    /// Throws `SecretLinkError` for the nuanced auth failures.
    func secretOpen(token: String, req: SecretLinkOpenReq) async throws -> SecretLinkOpenResp {
        let out = try await openAPI.secret_open(
            .init(
                path: .init(token: token),
                body: .json(req)
            )
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .unauthorized(let u):
            let errorMsg = (try? u.body.json.error) ?? ""
            throw mapOpenError(status: 401, errorMessage: errorMsg)
        case .gone(let g):
            let errorMsg = (try? g.body.json.error) ?? ""
            throw mapOpenError(status: 410, errorMessage: errorMsg)
        case .undocumented(let s, _):
            throw SecretLinkError.http(status: s, message: "secret_open")
        }
    }

    // MARK: - secret_attachment

    /// Fetch (and optionally range) one chunk of an attachment's ciphertext.
    /// Throws `SecretLinkError` for the same auth failures as `secretOpen`.
    func secretAttachment(token: String, req: SecretAttachmentReq) async throws -> Data {
        let out = try await openAPI.secret_attachment(
            .init(
                path: .init(token: token),
                body: .json(req)
            )
        )
        let httpBody: HTTPBody
        switch out {
        case .ok(let ok):
            httpBody = try ok.body.binary
        case .unauthorized(let u):
            let errorMsg = (try? u.body.json.error) ?? ""
            throw mapOpenError(status: 401, errorMessage: errorMsg)
        case .notFound(let n):
            let errorMsg = (try? n.body.json.error) ?? ""
            throw SecretLinkError.http(status: 404, message: errorMsg)
        case .gone(let g):
            let errorMsg = (try? g.body.json.error) ?? ""
            throw mapOpenError(status: 410, errorMessage: errorMsg)
        case .undocumented(let s, _):
            throw SecretLinkError.http(status: s, message: "secret_attachment")
        }
        // Collect the async bytes into a contiguous Data blob.
        // Chunk requests are bounded (~5 MiB + 44 bytes overhead), safe to materialise.
        var collected = Data()
        for try await chunk in httpBody {
            collected.append(contentsOf: chunk)
        }
        return collected
    }

    // MARK: - Internal helpers

    /// Map a 401 / 410 error message into the appropriate SecretLinkError.
    ///
    /// Server error messages for the open endpoint contain structured hints:
    ///   - 401: "bad password" or "attempts_remaining":N  → wrongPassword
    ///   - 410: "self_destructed"                         → selfDestructed
    ///   - 410: "revoked"                                 → revoked
    ///   - 410: "expired"                                 → expired
    private func mapOpenError(status: Int, errorMessage: String) -> SecretLinkError {
        let msg = errorMessage.lowercased()
        if msg.contains("self_destructed") || msg.contains("self-destruct") {
            return .selfDestructed
        }
        if status == 410 {
            if msg.contains("revoked") { return .revoked }
            if msg.contains("expired") { return .expired }
            return .http(status: 410, message: errorMessage)
        }
        // 401 — wrong password. Pull out attempts_remaining if embedded.
        // Server encodes this as e.g. {"error":"bad password","attempts_remaining":7}
        // The generated ErrorResponse only has `error: String`, so the server
        // may embed the integer in the error string itself.
        let remaining: Int? = {
            // Match patterns like "attempts_remaining":3 or "3 attempts remaining"
            let patterns = [
                #""attempts_remaining"\s*:\s*(\d+)"#,
                #"(\d+) attempt"#,
            ]
            for pattern in patterns {
                if let range = errorMessage.range(of: pattern, options: .regularExpression),
                   let numRange = errorMessage[range].firstMatch(of: /(\d+)/) {
                    return Int(numRange.1)
                }
            }
            return nil
        }()
        return .wrongPassword(attemptsRemaining: remaining)
    }

    private func secretAPIError<Body>(_ status: Int, _ body: Body) -> APIError {
        let msg: String
        switch body {
        case let json as any HasSecretJSONErrorResponse:
            msg = (try? json.secretErrorMessage()) ?? "\(status)"
        default:
            msg = "\(status)"
        }
        return APIError.http(status: status, message: msg)
    }
}

// MARK: - Protocol for extracting error messages from generated output bodies

private protocol HasSecretJSONErrorResponse {
    func secretErrorMessage() throws -> String
}

extension Operations.secret_create.Output.BadRequest.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
extension Operations.secret_create.Output.Unauthorized.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
extension Operations.secret_mine.Output.Unauthorized.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
extension Operations.secret_revoke.Output.Unauthorized.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
extension Operations.secret_revoke.Output.Forbidden.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
extension Operations.secret_revoke.Output.NotFound.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
extension Operations.secret_view.Output.NotFound.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
extension Operations.secret_view.Output.Gone.Body: HasSecretJSONErrorResponse {
    fileprivate func secretErrorMessage() throws -> String { try json.error }
}
