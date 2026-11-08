import Foundation

/// R2 derives its endpoint from the existing Cloudflare account ID. An explicit
/// HTTPS endpoint supports other S3-compatible deployments. Never log this value
/// by reflection: use the deliberately redacted descriptions below.
public struct S3AttachmentStorageConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let endpoint: URL
    let bucket: String
    let region: String
    let keyPrefix: String
    let accessKeyID: String
    let secretAccessKey: String
    let encryptionKey: Data
    let maximumPlaintextBytes: Int

    public static func fromEnvironment(_ environment: [String: String]) throws -> Self {
        guard environment["ATTACHMENT_STORAGE_PROVIDER"] == "s3",
              let bucket = environment["S3_BUCKET"], !bucket.isEmpty,
              let access = environment["S3_ACCESS_KEY_ID"], !access.isEmpty,
              let secret = environment["S3_SECRET_ACCESS_KEY"], !secret.isEmpty,
              let encoded = environment["ATTACHMENT_ENCRYPTION_KEY"],
              let encryptionKey = Data(base64Encoded: encoded), encryptionKey.count == 32,
              encryptionKey.base64EncodedString() == encoded else {
            throw AttachmentStorageError.notConfigured
        }
        let rawEndpoint: String
        if let explicit = environment["S3_ENDPOINT"], !explicit.isEmpty {
            rawEndpoint = explicit
        } else {
            guard let account = environment["CLOUDFLARE_ACCOUNT_ID"], account.utf8.count == 32,
                  account.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw AttachmentStorageError.invalidConfiguration
            }
            rawEndpoint = "https://\(account).r2.cloudflarestorage.com"
        }
        guard let endpoint = URL(string: rawEndpoint) else { throw AttachmentStorageError.invalidConfiguration }
        return try Self(
            endpoint: endpoint, bucket: bucket, accessKeyID: access, secretAccessKey: secret,
            encryptionKey: encryptionKey, region: environment["S3_REGION"] ?? "auto",
            keyPrefix: environment["S3_KEY_PREFIX"] ?? "attachments/", maximumPlaintextBytes: 200 * 1024 * 1024,
            allowLoopbackHTTP: false
        )
    }

    /// Only this explicit factory permits plaintext HTTP for real local network
    /// acceptance. The environment parser never permits it.
    public static func loopbackFixture(
        endpoint: URL, bucket: String, accessKeyID: String, secretAccessKey: String,
        encryptionKey: Data, region: String = "auto", keyPrefix: String = "attachments/",
        maximumPlaintextBytes: Int = 200 * 1024 * 1024
    ) throws -> Self {
        guard let host = endpoint.host,
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else {
            throw AttachmentStorageError.invalidConfiguration
        }
        return try Self(
            endpoint: endpoint, bucket: bucket, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
            encryptionKey: encryptionKey, region: region, keyPrefix: keyPrefix,
            maximumPlaintextBytes: maximumPlaintextBytes, allowLoopbackHTTP: true
        )
    }

    private init(
        endpoint: URL, bucket: String, accessKeyID: String, secretAccessKey: String,
        encryptionKey: Data, region: String, keyPrefix: String, maximumPlaintextBytes: Int,
        allowLoopbackHTTP: Bool
    ) throws {
        let asciiToken: (String) -> Bool = { value in
            !value.isEmpty && value.utf8.allSatisfy { (33...126).contains($0) }
        }
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              parts.scheme == "https" || (allowLoopbackHTTP && parts.scheme == "http"
                && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())),
              (3...63).contains(bucket.utf8.count),
              bucket.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              !bucket.hasPrefix("."), !bucket.hasSuffix("."), !bucket.contains(".."),
              asciiToken(accessKeyID), asciiToken(secretAccessKey),
              !region.isEmpty, region.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              encryptionKey.count == 32, (1...(200 * 1024 * 1024)).contains(maximumPlaintextBytes),
              !keyPrefix.isEmpty, !keyPrefix.hasPrefix("/"), keyPrefix.utf8.count <= 512,
              keyPrefix.utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || [45, 46, 47, 95].contains($0) }),
              !keyPrefix.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            throw AttachmentStorageError.invalidConfiguration
        }
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.keyPrefix = keyPrefix.hasSuffix("/") ? keyPrefix : keyPrefix + "/"
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.encryptionKey = encryptionKey
        self.maximumPlaintextBytes = maximumPlaintextBytes
    }

    func objectKey(attachmentID: String) throws -> String {
        guard let id = UUID(uuidString: attachmentID) else { throw AttachmentStorageError.invalidReference }
        return keyPrefix + id.uuidString.lowercased()
    }

    func validate(_ reference: AttachmentObjectReference) throws {
        guard reference.encryptionVersion == 1, reference.byteCount >= 0,
              reference.byteCount <= maximumPlaintextBytes,
              reference.sha256.utf8.count == 64,
              reference.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              reference.objectKey.hasPrefix(keyPrefix),
              let id = UUID(uuidString: String(reference.objectKey.dropFirst(keyPrefix.count))),
              reference.objectKey == keyPrefix + id.uuidString.lowercased() else {
            throw AttachmentStorageError.invalidReference
        }
    }

    public var description: String { "S3AttachmentStorageConfiguration(credentials and locations redacted)" }
    public var debugDescription: String { description }
}
