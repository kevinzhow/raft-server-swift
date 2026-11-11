import Foundation
import RaftObjectStorage
import Synchronization

/// The transient object-storage port for profile assets.
///
/// Production installs the same encrypted `S3AttachmentStorage` used for
/// attachments; the actor encrypts these objects with the existing key and
/// keeps the upstream capability-key layout. A development process without S3
/// configuration keeps the bytes in memory, mirroring the in-memory
/// `developmentAttachmentBytes` fallback. The port is never persisted.
public final class AvatarStorageRegistry: Sendable {
    private struct State: Sendable {
        var storage: (any PublicAssetObjectStoring)?
        var development: [String: Data] = [:]
        var requiresDurable = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Install the durable store. Durable mode also disables the in-memory
    /// fallback, so a production process never silently serves ephemeral
    /// profile assets.
    public func configure(_ storage: any PublicAssetObjectStoring) {
        state.withLock { current in
            current.storage = storage
            current.development.removeAll()
            current.requiresDurable = true
        }
    }

    /// Called on a production configuration before requests are admitted.
    public func requireDurable() {
        state.withLock { $0.requiresDurable = true }
    }

    /// A durable deployment without an installed store answers the published
    /// "Storage not configured" refusal instead of writing to memory.
    func ensureAvailable() throws {
        let snapshot = state.withLock { ($0.storage != nil, $0.requiresDurable) }
        if !snapshot.0, snapshot.1 { throw AttachmentStorageError.notConfigured }
    }

    func put(_ key: String, bytes: Data) async throws {
        let snapshot = state.withLock { ($0.storage, $0.requiresDurable) }
        if let storage = snapshot.0 {
            try await storage.putPublicAsset(key, bytes: bytes)
            return
        }
        guard !snapshot.1 else { throw AttachmentStorageError.notConfigured }
        state.withLock { $0.development[key] = bytes }
    }

    func get(_ key: String) async throws -> Data {
        let snapshot = state.withLock { ($0.storage, $0.development[key], $0.requiresDurable) }
        if let storage = snapshot.0 {
            return try await storage.getPublicAsset(key)
        }
        if let bytes = snapshot.1 { return bytes }
        if snapshot.2 { throw AttachmentStorageError.notConfigured }
        throw AttachmentStorageError.notFound
    }

    func delete(_ key: String) async throws {
        let snapshot = state.withLock { ($0.storage, $0.requiresDurable) }
        if let storage = snapshot.0 {
            try await storage.deletePublicAsset(key)
            return
        }
        guard !snapshot.1 else { throw AttachmentStorageError.notConfigured }
        state.withLock { _ = $0.development.removeValue(forKey: key) }
    }
}
