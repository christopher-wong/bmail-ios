// Uploader.swift
// Unified multipart upload pipeline for bmail.
//
// Mirrors the semantics of `web/src/lib/uploads.ts` exactly:
//   1. uploads_init  → get (r2_key, upload_id)
//   2. For each 5 MiB plaintext chunk → optionally transform → POST to /parts
//   3. uploads_complete → finalize, get UploadResult
//   On any failure after init → uploads_abort (best-effort)
//
// Upload kind matrix:
//   .attach  — plaintext bytes, draftID tied to mailbox row
//   .hosted  — caller-supplied ChunkTransform (AEAD encryption)
//   .secret  — caller-supplied ChunkTransform (AEAD encryption)

import Foundation

// MARK: - Public types

/// The result of a completed multipart upload.
struct UploadResult {
    /// R2 object key for the stored ciphertext (or plaintext for attach).
    let r2Key: String
    /// Total ciphertext bytes uploaded to R2.
    let size: Int64
    /// Only present for kind == .attach — MailboxDO attachment row id.
    let attachmentId: String?
    /// Total plaintext bytes consumed (the source file size).
    let plaintextSize: Int64
    /// Uniform plaintext chunk size used during this upload (5 MiB).
    let chunkSize: Int
    /// Number of chunks / R2 parts.
    let chunkCount: Int
}

/// Per-chunk transform. Receives the plaintext bytes, zero-based chunk
/// index, and whether this is the final chunk. Returns ciphertext bytes.
/// For kind=.attach, pass `nil` — bytes upload as-is.
typealias ChunkTransform = (Data, Int, Bool) throws -> Data

// MARK: - Uploader

/// Stateless multipart upload actor. `shared` is a convenience singleton;
/// callers may also create fresh instances for testing.
actor Uploader {

    static let shared = Uploader()

    // Plaintext chunk size — matches UPLOAD_CHUNK_BYTES in uploads.ts.
    static let chunkSize = 5 * 1024 * 1024   // 5 MiB

    // MARK: - Public API

    /// Upload the file at `source` to R2 using the server-side multipart API.
    ///
    /// - Parameters:
    ///   - source:     URL of the local file to upload.
    ///   - kind:       Upload category (attach / hosted / secret).
    ///   - mime:       MIME type of the source file.
    ///   - draftID:    For kind=.attach — associate with a draft row (optional).
    ///   - transform:  Per-chunk encryption function. Pass `nil` for kind=.attach.
    ///   - onProgress: Called after each part completes with cumulative ciphertext
    ///                 bytes uploaded and the total plaintext size. Invoked on the
    ///                 actor's executor; callers should hop to MainActor if needed.
    func upload(
        source: URL,
        kind: UploadKindSchema,
        mime: String,
        draftID: String? = nil,
        filenameCTb64: String? = nil,
        transform: ChunkTransform? = nil,
        onProgress: ((_ uploaded: Int64, _ total: Int64) -> Void)? = nil
    ) async throws -> UploadResult {

        // 1. Determine plaintext size and chunk count.
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let plaintextSize = (attributes[.size] as? NSNumber).map({ Int64($0.int64Value) }) else {
            throw UploaderError.cannotReadFileSize(source)
        }
        let chunkSize = Uploader.chunkSize
        // Single empty chunk for zero-byte files — mirrors web's Math.max(1, ceil(0/5MiB)) = 1.
        let chunkCount = max(1, Int((plaintextSize + Int64(chunkSize) - 1) / Int64(chunkSize)))

        // 2. Open file handle (close in defer so it's always released).
        let fileHandle = try FileHandle(forReadingFrom: source)
        defer { try? fileHandle.close() }

        // 3. Init the multipart upload on the server.
        let initResp = try await APIClient.shared.uploadsInit(kind: kind, mime: mime)
        let r2Key    = initResp.r2_key
        let uploadId = initResp.upload_id

        // 4. Upload parts, accumulating ETag refs. Abort on any failure.
        var parts: [UploadedPartRef] = []
        var totalCiphertext: Int64   = 0

        do {
            for chunkIndex in 0 ..< chunkCount {
                let isFinal  = chunkIndex == chunkCount - 1
                // Read next plaintext slice (may be empty for the zero-byte file case;
                // read(upToCount:) returns nil on some SDK variants when EOF is hit immediately).
                let plaintext: Data = (try fileHandle.read(upToCount: chunkSize)) ?? Data()

                // Apply optional transform (encryption).
                let wire: Data
                if let transform {
                    wire = try transform(plaintext, chunkIndex, isFinal)
                } else {
                    wire = plaintext
                }

                let partNumber = Int32(chunkIndex + 1) // R2 part numbers are 1-indexed.
                let partResp = try await APIClient.shared.uploadsPart(
                    r2Key: r2Key,
                    uploadId: uploadId,
                    partNumber: partNumber,
                    body: wire
                )

                parts.append(UploadedPartRef(
                    part_number: partResp.part_number,
                    etag: partResp.etag
                ))

                totalCiphertext += Int64(wire.count)
                onProgress?(totalCiphertext, plaintextSize)
            }
        } catch {
            // Best-effort abort — swallow any secondary error.
            try? await APIClient.shared.uploadsAbort(r2Key: r2Key, uploadId: uploadId)
            throw error
        }

        // 5. Finalize.
        let completeReq = UploadCompleteReq(
            r2_key:           r2Key,
            upload_id:        uploadId,
            parts:            parts,
            size:             totalCiphertext,
            filename_ct_b64:  kind == .attach ? filenameCTb64 : nil,
            mime:             kind == .attach ? mime : nil,
            draft_id:         kind == .attach ? draftID : nil
        )

        let completeResp: UploadCompleteResp
        do {
            completeResp = try await APIClient.shared.uploadsComplete(req: completeReq)
        } catch {
            try? await APIClient.shared.uploadsAbort(r2Key: r2Key, uploadId: uploadId)
            throw error
        }

        return UploadResult(
            r2Key:         completeResp.r2_key,
            size:          completeResp.size,
            attachmentId:  completeResp.attachment_id,
            plaintextSize: plaintextSize,
            chunkSize:     chunkSize,
            chunkCount:    chunkCount
        )
    }

    // MARK: - Testable chunking primitive

    /// Iterate over the chunks of a file without touching the network.
    /// Extracted so tests can exercise chunking + transform logic in isolation.
    ///
    /// - Parameters:
    ///   - source:    URL of the local file.
    ///   - chunkSize: Bytes per chunk (default: `Uploader.chunkSize`).
    ///   - transform: Optional per-chunk transform.
    ///   - onChunk:   Called for each `(partNumber, ciphertextBytes)` pair.
    ///               Part numbers are 1-indexed (matching R2 convention).
    static func iterateChunks(
        source: URL,
        chunkSize: Int = Uploader.chunkSize,
        transform: ChunkTransform?,
        onChunk: (_ partNumber: Int, _ ciphertext: Data) throws -> Void
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let plaintextSize = (attributes[.size] as? NSNumber).map({ Int64($0.int64Value) }) else {
            throw UploaderError.cannotReadFileSize(source)
        }
        let chunkCount = max(1, Int((plaintextSize + Int64(chunkSize) - 1) / Int64(chunkSize)))

        let fileHandle = try FileHandle(forReadingFrom: source)
        defer { try? fileHandle.close() }

        for chunkIndex in 0 ..< chunkCount {
            let isFinal  = chunkIndex == chunkCount - 1
            let plaintext: Data = (try fileHandle.read(upToCount: chunkSize)) ?? Data()
            let wire: Data
            if let transform {
                wire = try transform(plaintext, chunkIndex, isFinal)
            } else {
                wire = plaintext
            }
            try onChunk(chunkIndex + 1, wire)
        }
    }
}

// MARK: - Errors

enum UploaderError: Error, LocalizedError {
    case cannotReadFileSize(URL)

    var errorDescription: String? {
        switch self {
        case .cannotReadFileSize(let url):
            return "Could not read file size for \(url.lastPathComponent)"
        }
    }
}

// MARK: - URLSession note
//
// TODO: Switch to a background URLSession (URLSessionConfiguration.background(
//       withIdentifier: "bmail.uploader")) for large hosted/secret uploads.
//       Background sessions require a delegate-based approach — URLSession
//       doesn't return Data inline from background tasks — which adds meaningful
//       complexity. Using the shared foreground session here for the initial cut;
//       background resilience is a follow-up.
//
// TODO: Add per-part retry with exponential back-off (3 attempts, 0.5s / 1s / 2s).
//
// TODO: Add resume tokens: persist (r2Key, uploadId, uploadedParts) to disk so a
//       crash mid-upload can resume from the last completed part instead of
//       restarting from scratch.
