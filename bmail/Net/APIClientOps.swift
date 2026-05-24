// APIClientOps.swift
// Wrappers around the generated OpenAPI client (`APIClient.shared.openAPI`)
// that expose a small Swift-friendly surface for ops not yet covered by the
// legacy URLSession helpers. Each wrapper:
//   - Pulls the .ok case from the generated Output enum
//   - Throws APIError on non-2xx (matching the legacy helpers' contract)

import Foundation
import OpenAPIRuntime

extension APIClient {

    // MARK: - Threads

    /// Permanently delete a thread and every blob it owns.
    @discardableResult
    func deleteThread(id: String) async throws -> DeleteThreadResp {
        let out = try await openAPI.delete_thread(
            .init(path: .init(thread_id: id))
        )
        switch out {
        case .ok(let ok):
            return try ok.body.json
        case .unauthorized(let u):
            throw apiError(401, u.body)
        case .notFound(let n):
            throw apiError(404, n.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "delete_thread")
        }
    }

    // MARK: - Messages

    /// Permanently delete a single message.
    func deleteMessage(id: String) async throws {
        let out = try await openAPI.delete_message(
            .init(path: .init(message_id: id))
        )
        switch out {
        case .ok: return
        case .unauthorized(let u): throw apiError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "delete_message")
        }
    }

    /// Partially update a message. Pass only the fields you want to change;
    /// `nil` means leave-unchanged.
    func patchMessage(
        id: String,
        starred: Bool? = nil,
        read: Bool? = nil,
        archived: Bool? = nil,
        threadId: String? = nil
    ) async throws {
        let body = Components.Schemas.PatchMessageReq(
            starred: starred,
            read: read,
            archived: archived,
            thread_id: threadId
        )
        let out = try await openAPI.patch_message(
            .init(path: .init(message_id: id), body: .json(body))
        )
        switch out {
        case .ok: return
        case .unauthorized(let u): throw apiError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "patch_message")
        }
    }

    /// Attach or detach a label on a message.
    func toggleMessageLabel(messageId: String, labelId: String, set: Bool) async throws {
        let body = Components.Schemas.ToggleMessageLabelReq(
            message_id: messageId,
            label_id: labelId,
            set: set
        )
        let out = try await openAPI.message_labels_toggle(.init(body: .json(body)))
        switch out {
        case .ok: return
        case .unauthorized(let u): throw apiError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "message_labels_toggle")
        }
    }

    // MARK: - Me / addresses

    /// Fresh list of the current user's email addresses.
    func listAddresses() async throws -> [String] {
        let out = try await openAPI.list_addresses(.init())
        switch out {
        case .ok(let ok): return try ok.body.json
        case .unauthorized(let u): throw apiError(401, u.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "list_addresses")
        }
    }

    // MARK: - Server config

    /// Unauthenticated server config — primary domain, additional domains, app host/name.
    /// Safe to call before login.
    func publicConfig() async throws -> PublicConfig {
        let out = try await openAPI.public_config(.init())
        switch out {
        case .ok(let ok): return try ok.body.json
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "public_config")
        }
    }

    // MARK: - First-run bootstrap (server-side, admin)

    /// First-run server bootstrap: mints the admin invite. Returns the invite
    /// token and an enrollment URL. Used once per server, before any user
    /// exists. Returns 409 if bootstrap has already happened.
    func bootstrap(handle: String, addresses: [String]) async throws -> BootstrapResp {
        let body = Components.Schemas.BootstrapReq(handle: handle, addresses: addresses)
        let out = try await openAPI.bootstrap(.init(body: .json(body)))
        switch out {
        case .ok(let ok): return try ok.body.json
        case .conflict(let c): throw apiError(409, c.body)
        case .undocumented(let s, _):
            throw APIError.http(status: s, message: "bootstrap")
        }
    }

    // MARK: - Internal

    private func apiError<Body>(_ status: Int, _ body: Body) -> APIError {
        let msg: String
        switch body {
        case let json as any HasJSONErrorResponse:
            msg = (try? json.errorMessage()) ?? "\(status)"
        default:
            msg = "\(status)"
        }
        return APIError.http(status: status, message: msg)
    }
}

// Lightweight protocol so apiError(_:_:) can extract the human-readable
// message out of any generated error-body enum that wraps an ErrorResponse.
private protocol HasJSONErrorResponse {
    func errorMessage() throws -> String
}

// Conform the generated bodies we hit above. Add more as new ops are wired.
extension Operations.delete_thread.Output.Unauthorized.Body: HasJSONErrorResponse {
    fileprivate func errorMessage() throws -> String { try json.error }
}
extension Operations.delete_thread.Output.NotFound.Body: HasJSONErrorResponse {
    fileprivate func errorMessage() throws -> String { try json.error }
}
extension Operations.delete_message.Output.Unauthorized.Body: HasJSONErrorResponse {
    fileprivate func errorMessage() throws -> String { try json.error }
}
extension Operations.patch_message.Output.Unauthorized.Body: HasJSONErrorResponse {
    fileprivate func errorMessage() throws -> String { try json.error }
}
extension Operations.message_labels_toggle.Output.Unauthorized.Body: HasJSONErrorResponse {
    fileprivate func errorMessage() throws -> String { try json.error }
}
extension Operations.list_addresses.Output.Unauthorized.Body: HasJSONErrorResponse {
    fileprivate func errorMessage() throws -> String { try json.error }
}
extension Operations.bootstrap.Output.Conflict.Body: HasJSONErrorResponse {
    fileprivate func errorMessage() throws -> String { try json.error }
}
