import Foundation

public enum AttachmentStorageError: Error, Sendable, Equatable {
    case notConfigured
    case invalidConfiguration
    case invalidReference
    case transportFailure
    case notFound
    case providerRejected(status: Int)
    case invalidResponse
    case integrityFailure
    case tooLarge
}

/// The database retains the locator and plaintext integrity facts. It contains
/// neither storage credentials nor the encryption key or plaintext file bytes.
public struct AttachmentObjectReference: Codable, Sendable, Equatable {
    public let objectKey: String
    public let sha256: String
    public let byteCount: Int
    public let encryptionVersion: Int

    public init(objectKey: String, sha256: String, byteCount: Int, encryptionVersion: Int) {
        self.objectKey = objectKey
        self.sha256 = sha256
        self.byteCount = byteCount
        self.encryptionVersion = encryptionVersion
    }
}

public protocol AttachmentObjectStoring: Sendable {
    func put(attachmentID: String, bytes: Data) async throws -> AttachmentObjectReference
    func get(_ reference: AttachmentObjectReference) async throws -> Data
    func delete(_ reference: AttachmentObjectReference) async throws
}
