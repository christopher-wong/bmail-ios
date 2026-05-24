// ModelAliases.swift
// Type aliases bridging generated Components.Schemas.* to the names used
// throughout the existing codebase. Adding an alias here is a zero-diff way
// to adopt a new schema name without touching every call site.
//
// IMPORTANT: only add an alias when the generated schema is structurally
// compatible with the hand-written type it replaces. When shapes diverge
// (e.g. the spec adds a required field that the hand-written type omits as
// optional), migrate the call site instead.

import Foundation

// MARK: - Upcoming-phase types (not yet wired to call sites)
// These aliases are the sanity-check deliverable: confirm the generated
// code covers the schemas the uploads/hosted/secret work will need.

typealias HostedFile           = Components.Schemas.HostedFile
typealias HostedCreateReq      = Components.Schemas.HostedCreateReq
typealias HostedCreateResp     = Components.Schemas.HostedCreateResp
typealias HostedPublicView     = Components.Schemas.HostedPublicView
typealias HostedSenderRow      = Components.Schemas.HostedSenderRow
typealias HostedRevokeResp     = Components.Schemas.HostedRevokeResp
typealias UploadInitReq        = Components.Schemas.UploadInitReq
typealias UploadInitResp       = Components.Schemas.UploadInitResp
typealias UploadPartResp       = Components.Schemas.UploadPartResp
typealias UploadCompleteReq    = Components.Schemas.UploadCompleteReq
typealias UploadCompleteResp   = Components.Schemas.UploadCompleteResp
typealias UploadAbortReq       = Components.Schemas.UploadAbortReq
typealias UploadedPartRef      = Components.Schemas.UploadedPartRef
/// Mirrors the `UploadKind` enum in the generated types. Declared as a
/// distinct type here so callers don't need to import `Components.Schemas`.
typealias UploadKindSchema     = Components.Schemas.UploadKind
typealias SecretLinkPublicView = Components.Schemas.SecretLinkPublicView
// Secret link create/open/sender types are aliased in APIClientSecret.swift to
// keep them co-located with the error type that depends on them.

// MARK: - Wired in this PR

typealias PublicConfig    = Components.Schemas.PublicConfig
typealias BootstrapResp   = Components.Schemas.BootstrapResp
typealias DeleteThreadResp = Components.Schemas.DeleteThreadResp
