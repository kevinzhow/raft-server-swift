import AsyncHTTPClient
import Crypto
import Foundation
import SotoS3

/// Soto owns S3 signing and HTTP protocol handling. The application owns the
/// encryption boundary: public object access cannot disclose attachment bytes.
public actor S3AttachmentStorage: AttachmentObjectStoring, PublicAssetObjectStoring {
    private let configuration: S3AttachmentStorageConfiguration
    private let httpClient: HTTPClient
    private let awsClient: AWSClient
    private let s3: S3
    private var isShutdown = false

    public init(configuration: S3AttachmentStorageConfiguration) {
        self.configuration = configuration
        let http = HTTPClient(configuration: .init(redirectConfiguration: .disallow))
        let aws = AWSClient(
            credentialProvider: .static(accessKeyId: configuration.accessKeyID, secretAccessKey: configuration.secretAccessKey),
            retryPolicy: .noRetry, httpClient: http
        )
        self.httpClient = http
        self.awsClient = aws
        self.s3 = S3(
            client: aws, region: Region(rawValue: configuration.region), endpoint: configuration.endpoint.absoluteString,
            timeout: .seconds(90), options: [.s3DisableChunkedUploads, .s3Disable100Continue]
        )
    }

    deinit {
        // Owners call shutdown explicitly. Retain clients until asynchronous
        // cleanup finishes if construction fails before the owner is installed.
        if !isShutdown {
            let aws = awsClient
            let http = httpClient
            Task {
                try? await aws.shutdown()
                try? await http.shutdown()
            }
        }
    }

    public func shutdown() async throws {
        guard !isShutdown else { return }
        isShutdown = true
        try await awsClient.shutdown()
        try await httpClient.shutdown()
    }

    public func put(attachmentID: String, bytes: Data) async throws -> AttachmentObjectReference {
        guard !isShutdown else { throw AttachmentStorageError.notConfigured }
        guard bytes.count <= configuration.maximumPlaintextBytes else { throw AttachmentStorageError.tooLarge }
        let key = try configuration.objectKey(attachmentID: attachmentID)
        let reference = AttachmentObjectReference(
            objectKey: key, sha256: Self.sha256(bytes), byteCount: bytes.count, encryptionVersion: 1
        )
        let encrypted: Data
        do {
            let sealed = try AES.GCM.seal(
                bytes, using: SymmetricKey(data: configuration.encryptionKey), authenticating: Self.associatedData(key)
            )
            guard let combined = sealed.combined else { throw AttachmentStorageError.integrityFailure }
            encrypted = combined
        } catch { throw AttachmentStorageError.integrityFailure }
        do {
            _ = try await s3.putObject(.init(
                body: .init(bytes: encrypted), bucket: configuration.bucket, contentLength: Int64(encrypted.count),
                contentType: "application/octet-stream", key: key
            ))
        } catch { throw Self.storageError(error) }
        return reference
    }

    public func get(_ reference: AttachmentObjectReference) async throws -> Data {
        guard !isShutdown else { throw AttachmentStorageError.notConfigured }
        try configuration.validate(reference)
        let encrypted: Data
        do {
            let result = try await s3.getObject(.init(bucket: configuration.bucket, key: reference.objectKey))
            let buffer = try await result.body.collect(upTo: reference.byteCount + 28)
            encrypted = Data(buffer.readableBytesView)
        } catch { throw Self.storageError(error) }
        guard encrypted.count == reference.byteCount + 28 else { throw AttachmentStorageError.integrityFailure }
        let bytes: Data
        do {
            bytes = try AES.GCM.open(
                AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: configuration.encryptionKey),
                authenticating: Self.associatedData(reference.objectKey)
            )
        } catch { throw AttachmentStorageError.integrityFailure }
        guard bytes.count == reference.byteCount, Self.sha256(bytes) == reference.sha256 else {
            throw AttachmentStorageError.integrityFailure
        }
        return bytes
    }

    public func delete(_ reference: AttachmentObjectReference) async throws {
        guard !isShutdown else { throw AttachmentStorageError.notConfigured }
        try configuration.validate(reference)
        do { _ = try await s3.deleteObject(.init(bucket: configuration.bucket, key: reference.objectKey)) }
        catch {
            let mapped = Self.storageError(error)
            if mapped != .notFound { throw mapped }
        }
    }

    // MARK: - Public profile assets

    /// The upstream public-asset namespace. Uploaded avatars use
    /// `avatars/<namespace>/<sha256-prefix>.webp`; integration logos use
    /// `integration-logos/<clientRecordId>/<sha256-prefix>.webp`. The key is
    /// the capability path, so serving needs no database lookup for avatars.
    public func putPublicAsset(_ key: String, bytes: Data) async throws {
        guard !isShutdown else { throw AttachmentStorageError.notConfigured }
        let hash = try Self.publicAssetHash(key)
        guard bytes.count <= Self.maximumPublicAssetBytes else { throw AttachmentStorageError.tooLarge }
        let referenceHash = Self.sha256(bytes)
        guard referenceHash.hasPrefix(hash) else { throw AttachmentStorageError.integrityFailure }
        let encrypted = try sealPublicAsset(bytes, key: key)
        do {
            _ = try await s3.putObject(.init(
                body: .init(bytes: encrypted), bucket: configuration.bucket, contentLength: Int64(encrypted.count),
                contentType: "application/octet-stream", key: key
            ))
        } catch { throw Self.storageError(error) }
    }

    public func getPublicAsset(_ key: String) async throws -> Data {
        guard !isShutdown else { throw AttachmentStorageError.notConfigured }
        let hash = try Self.publicAssetHash(key)
        let encrypted: Data
        do {
            let result = try await s3.getObject(.init(bucket: configuration.bucket, key: key))
            let buffer = try await result.body.collect(upTo: Self.maximumPublicAssetBytes + 28)
            encrypted = Data(buffer.readableBytesView)
        } catch { throw Self.storageError(error) }
        guard encrypted.count <= Self.maximumPublicAssetBytes + 28 else {
            throw AttachmentStorageError.integrityFailure
        }
        let bytes: Data
        do {
            bytes = try AES.GCM.open(
                AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: configuration.encryptionKey),
                authenticating: Self.publicAssetAssociatedData(key)
            )
        } catch { throw AttachmentStorageError.integrityFailure }
        guard bytes.count <= Self.maximumPublicAssetBytes, Self.sha256(bytes).hasPrefix(hash) else {
            throw AttachmentStorageError.integrityFailure
        }
        return bytes
    }

    public func deletePublicAsset(_ key: String) async throws {
        guard !isShutdown else { throw AttachmentStorageError.notConfigured }
        _ = try Self.publicAssetHash(key)
        do { _ = try await s3.deleteObject(.init(bucket: configuration.bucket, key: key)) }
        catch {
            let mapped = Self.storageError(error)
            if mapped != .notFound { throw mapped }
        }
    }

    private static let maximumPublicAssetBytes = 5 * 1024 * 1024

    private static func publicAssetHash(_ key: String) throws -> String {
        let segments = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3,
              segments[0] == "avatars" || segments[0] == "integration-logos",
              !segments[1].isEmpty, segments[1].utf8.count <= 128,
              segments[1].utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              segments[1] != ".", segments[1] != "..",
              let filename = segments.last,
              let match = filename.wholeMatch(of: /^([0-9a-f]{32})\.webp$/)
        else { throw AttachmentStorageError.invalidReference }
        return String(match.1)
    }

    private func sealPublicAsset(_ bytes: Data, key: String) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(
                bytes, using: SymmetricKey(data: configuration.encryptionKey),
                authenticating: Self.publicAssetAssociatedData(key)
            )
            guard let combined = sealed.combined else { throw AttachmentStorageError.integrityFailure }
            return combined
        } catch { throw AttachmentStorageError.integrityFailure }
    }

    private static func publicAssetAssociatedData(_ key: String) -> Data { Data(("raft-public-asset:v1:" + key).utf8) }

    private static func associatedData(_ key: String) -> Data { Data(("raft-attachment:v1:" + key).utf8) }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func storageError(_ error: any Error) -> AttachmentStorageError {
        // SDK descriptions and response bodies can repeat private object names,
        // endpoints and credentials. Retain only a typed category/status.
        if let error = error as? AttachmentStorageError { return error }
        if let error = error as? any AWSErrorType {
            if error.errorCode == "NoSuchKey" || error.context?.responseCode.code == 404 { return .notFound }
            if let status = error.context?.responseCode.code { return .providerRejected(status: Int(status)) }
            return .invalidResponse
        }
        if let error = error as? AWSRawError { return .providerRejected(status: Int(error.context.responseCode.code)) }
        return .transportFailure
    }
}
