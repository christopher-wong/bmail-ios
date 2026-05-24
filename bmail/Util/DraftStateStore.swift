import Foundation
import os.log

// MARK: - Persisted types

/// Per-file entry inside HostedDraftState. Mirrors the fields of the generated
/// HostedFile OpenAPI schema that are required to reconstruct pendingHostedFiles
/// after a crash / app kill — plus the plaintext filename (never sent to the
/// server in the hosted flow).
struct HostedDraftFile: Codable, Equatable, Hashable, Sendable {
    let r2Key: String
    /// Plaintext filename, sender-side only. Never sent to the server for
    /// hosted attachments — the server only stores ciphertext at that layer.
    let filename: String
    let mime: String
    /// Ciphertext size on R2 (post-encryption).
    let size: Int64
    /// Original plaintext size.
    let plaintextSize: Int64
    let chunkSize: Int
    let chunkCount: Int
}

/// Top-level per-draft hosted state: one CEK covers all hosted files in a draft.
struct HostedDraftState: Codable, Equatable, Sendable {
    /// base64url-encoded 32-byte CEK (matches the web IDB schema's `cek_b64`).
    let cekB64: String
    var files: [HostedDraftFile]
}

// MARK: - DraftStateStore

/// Persists per-draft hosted CEK + file manifest to disk so a compose session
/// can be safely resumed after a crash, app kill, or backgrounding mid-upload.
///
/// Mirrors the web's `draft_hosted` IndexedDB object store in idb.ts.
/// One JSON file per draft: `<rootURL>/<draftID>.hosted.json`.
///
/// **App Group**: no App Group entitlement is present in bmail.entitlements
/// today, so we use the Documents directory. TODO: migrate the root URL to
/// `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`
/// when a share extension is added and the entitlement is provisioned.
struct DraftStateStore: Sendable {

    // MARK: - Shared default

    static let `default` = DraftStateStore(
        rootURL: FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("drafts", isDirectory: true)
    )

    // MARK: - Configuration

    let rootURL: URL

    private static let log = Logger(subsystem: "com.bmail", category: "DraftStateStore")

    // MARK: - Public API

    /// Load the hosted state for `draftID`, or nil if none exists / on error.
    func loadHosted(draftID: String) -> HostedDraftState? {
        let url = stateURL(for: draftID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(HostedDraftState.self, from: data)
        } catch {
            Self.log.warning("DraftStateStore: corrupt state for \(draftID, privacy: .public) — deleting. \(error, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Persist hosted state for `draftID`. Errors are logged and swallowed —
    /// compose must not crash due to a disk-full or permission error.
    func saveHosted(draftID: String, state: HostedDraftState) {
        do {
            try ensureRootDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys   // deterministic, diff-friendly
            let data = try encoder.encode(state)
            try data.write(to: stateURL(for: draftID), options: [.atomic])
        } catch {
            Self.log.error("DraftStateStore: save failed for \(draftID, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Remove the state file for `draftID`. Call after a successful send or
    /// explicit draft discard. Errors are silently ignored.
    func clearHosted(draftID: String) {
        try? FileManager.default.removeItem(at: stateURL(for: draftID))
    }

    /// Best-effort GC: delete state files whose last-modified date is older
    /// than 30 days. Call from a background task at app launch.
    func gcStale() {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for case let url as URL in enumerator {
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasSuffix(".hosted.json") else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = values.contentModificationDate else { continue }
            if modDate < cutoff {
                Self.log.info("DraftStateStore: GC removing stale file \(url.lastPathComponent, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Private helpers

    func stateURL(for draftID: String) -> URL {
        rootURL.appendingPathComponent("\(draftID).hosted.json")
    }

    private func ensureRootDirectoryExists() throws {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
}
