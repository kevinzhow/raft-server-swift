import Crypto
import Foundation
import RaftObjectStorage

/// The stored image object a successful upload produced. The URL is the
/// published capability path (`/api/avatars/...` or `/api/integration-logos/...`).
public struct AvatarStoredFile: Sendable, Equatable {
    public let url: String
    public let objectKey: String
    public let format: AvatarImageFormat
    public let byteCount: Int

    public init(url: String, objectKey: String, format: AvatarImageFormat, byteCount: Int) {
        self.url = url
        self.objectKey = objectKey
        self.format = format
        self.byteCount = byteCount
    }
}

/// The bytes and real media type of a served profile asset.
public struct AvatarBinaryContent: Sendable, Equatable {
    public let bytes: Data
    public let contentType: String

    public init(bytes: Data, contentType: String) {
        self.bytes = bytes
        self.contentType = contentType
    }
}

/// Upload-side refusals. Domain services map each case to their own published
/// error shape because the same storage failure has different messages on the
/// profile, agent and integration-logo routes.
public enum AvatarStoreError: Error, Sendable, Equatable {
    case tooLarge(maxBytes: Int)
    case badFormat
    case notAnImage
    case storageNotConfigured
    case storageFailure
}

/// The public object routes' published failures.
public enum AvatarServeError: DomainError, Equatable {
    case invalidFilename
    case avatarNotFound
    case logoNotFound
    case storageNotConfigured
    case serveFailed(avatar: Bool)

    public var status: UInt {
        switch self {
        case .invalidFilename: 400
        case .avatarNotFound, .logoNotFound: 404
        case .storageNotConfigured, .serveFailed: 500
        }
    }

    public var errorMessage: String {
        switch self {
        case .invalidFilename: "Invalid filename"
        case .avatarNotFound: "Avatar not found"
        case .logoNotFound: "Logo not found"
        case .storageNotConfigured: "Storage not configured"
        case .serveFailed(let avatar): avatar ? "Failed to serve avatar" : "Failed to serve logo"
        }
    }
}

/// Avatar and integration-logo bytes, shared by the four upload routes and the
/// two public object routes.
///
/// Upstream `avatarService`/`oauthService` resize the image to 256×256 WebP with
/// sharp. This port's release closure has no image codec, so the validated
/// original bytes are stored under the same capability-key layout and served
/// with their real content type; see `docs/DEVIATIONS.md` D23. The SHA-256
/// prefix filename is computed from the retained bytes.
public struct AvatarService: Sendable {
    public static let maximumBytes = 5 * 1024 * 1024
    public static let profileAvatarMaximumBytes = maximumBytes

    private let storage: AvatarStorageRegistry
    private let oauth: OAuthLedger

    init(storage: AvatarStorageRegistry, oauth: OAuthLedger) {
        self.storage = storage
        self.oauth = oauth
    }

    // MARK: - Uploads

    /// `storeUserAvatar`: namespace `users`.
    public func storeUserAvatar(
        existingAvatarUrl: String?,
        file: AvatarUploadFile
    ) async throws -> AvatarStoredFile {
        try await storeProfileAvatar(namespace: "users", existingAvatarUrl: existingAvatarUrl, file: file)
    }

    /// `storeAgentAvatar`: the upstream namespace is the Server id, not
    /// `server-<id>` and not `users`.
    public func storeAgentAvatar(
        serverId: String,
        existingAvatarUrl: String?,
        file: AvatarUploadFile
    ) async throws -> AvatarStoredFile {
        try await storeProfileAvatar(namespace: serverId, existingAvatarUrl: existingAvatarUrl, file: file)
    }

    /// `storeServerAvatar`: namespace `server-<serverId>`.
    public func storeServerAvatar(
        serverId: String,
        existingAvatarUrl: String?,
        file: AvatarUploadFile
    ) async throws -> AvatarStoredFile {
        try await storeProfileAvatar(namespace: "server-\(serverId)", existingAvatarUrl: existingAvatarUrl, file: file)
    }

    /// `storeIntegrationLogo`: namespace `integration-logos/<clientRecordId>`.
    public func storeIntegrationLogo(
        clientRecordId: String,
        file: AvatarUploadFile
    ) async throws -> AvatarStoredFile {
        let validated = try validate(file)
        let filename = "\(validated.hash).webp"
        let objectKey = "integration-logos/\(clientRecordId)/\(filename)"
        try storage.ensureAvailable()
        do { try await storage.put(objectKey, bytes: validated.bytes) }
        catch AttachmentStorageError.notConfigured { throw AvatarStoreError.storageNotConfigured }
        catch { throw AvatarStoreError.storageFailure }
        return AvatarStoredFile(
            url: "/api/\(objectKey)", objectKey: objectKey, format: validated.format, byteCount: validated.bytes.count
        )
    }

    /// `GET /api/avatars/:namespace/:filename`. A missing object answers 404 on
    /// this deployment; see `docs/DEVIATIONS.md` D24.
    public func avatarContent(namespace: String, filename: String) async throws -> AvatarBinaryContent {
        guard Self.isValidNamespace(namespace), filename.wholeMatch(of: /^[0-9a-f]+\.webp$/) != nil else {
            throw AvatarServeError.invalidFilename
        }
        return try await content(key: "avatars/\(namespace)/\(filename)", notFound: .avatarNotFound, avatar: true)
    }

    /// `GET /api/integration-logos/:clientId/:filename`. The ledger owns the
    /// storage key; a key that is absent or does not end in the requested hash
    /// publishes the upstream `Logo not found` 404.
    public func integrationLogoContent(clientRecordId: String, filename: String) async throws -> AvatarBinaryContent {
        guard filename.wholeMatch(of: /^([0-9a-f]{32})\.webp$/) != nil else {
            throw AvatarServeError.invalidFilename
        }
        let contentHash = String(filename.dropLast(".webp".count))
        guard let key = oauth.clientLogoStorageKey(clientRecordId: clientRecordId, contentHash: contentHash) else {
            throw AvatarServeError.logoNotFound
        }
        return try await content(key: key, notFound: .logoNotFound, avatar: false)
    }

    /// Remove a replaced or cleared logo after its row transaction committed.
    /// The caller owns the best-effort policy; a missing object is not an error.
    public func deleteStoredObject(_ key: String) async {
        try? await storage.delete(key)
    }

    // MARK: - Validation and storage

    private func storeProfileAvatar(
        namespace: String,
        existingAvatarUrl: String?,
        file: AvatarUploadFile
    ) async throws -> AvatarStoredFile {
        let validated = try validate(file)
        let filename = "\(validated.hash).webp"
        let objectKey = "avatars/\(namespace)/\(filename)"
        let url = "/api/\(objectKey)"
        try storage.ensureAvailable()
        // The key is content-addressed, so a repeated upload writes the same
        // object. Always writing also repairs a development in-memory fallback
        // that lost its bytes on restart.
        do { try await storage.put(objectKey, bytes: validated.bytes) }
        catch AttachmentStorageError.notConfigured { throw AvatarStoreError.storageNotConfigured }
        catch { throw AvatarStoreError.storageFailure }
        return AvatarStoredFile(
            url: url, objectKey: objectKey, format: validated.format, byteCount: validated.bytes.count
        )
    }

    private func content(
        key: String,
        notFound: AvatarServeError,
        avatar: Bool
    ) async throws -> AvatarBinaryContent {
        let bytes: Data
        do { bytes = try await storage.get(key) }
        catch AttachmentStorageError.notFound { throw notFound }
        catch AttachmentStorageError.notConfigured { throw AvatarServeError.storageNotConfigured }
        catch { throw AvatarServeError.serveFailed(avatar: avatar) }
        let format = AvatarImageFormat.sniff(bytes) ?? .webp
        return AvatarBinaryContent(bytes: bytes, contentType: format.rawValue)
    }

    private func validate(_ file: AvatarUploadFile) throws -> (bytes: Data, hash: String, format: AvatarImageFormat) {
        guard AvatarImageFormat.declared(file.contentType) != nil else { throw AvatarStoreError.badFormat }
        guard file.bytes.count <= Self.maximumBytes else {
            throw AvatarStoreError.tooLarge(maxBytes: Self.maximumBytes)
        }
        guard let format = AvatarImageFormat.sniff(file.bytes) else { throw AvatarStoreError.notAnImage }
        let digest = SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined()
        return (file.bytes, String(digest.prefix(32)), format)
    }

    private static func isValidNamespace(_ namespace: String) -> Bool {
        !namespace.isEmpty && namespace.utf8.count <= 128
            && namespace != "." && namespace != ".."
            && namespace.utf8.allSatisfy {
                (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
    }
}
