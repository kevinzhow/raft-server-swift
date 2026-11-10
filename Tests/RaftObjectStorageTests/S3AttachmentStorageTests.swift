import Crypto
import Foundation
import NIOCore
import SotoTestUtils
import Synchronization
import Testing
@testable import RaftObjectStorage

private struct ObjectFixtureState: Sendable {
    var ciphertext: Data?
    var tamper = false
    var requests: [AWSTestServer.Request] = []
}

@Test func sotoAttachmentRoundTripStoresCiphertextAndDetectsTampering() async throws {
    let server = AWSTestServer(serviceProtocol: .xml)
    let state = Mutex(ObjectFixtureState())
    let config = try S3AttachmentStorageConfiguration.loopbackFixture(
        endpoint: server.addressURL, bucket: "fixture", accessKeyID: "synthetic-access",
        secretAccessKey: "synthetic-secret", encryptionKey: Data(repeating: 7, count: 32)
    )
    let store = S3AttachmentStorage(configuration: config)
    let serving = Task.detached {
        try server.processRaw { request in
            state.withLock { value in
                value.requests.append(request)
                switch request.method.rawValue {
                case "PUT":
                    value.ciphertext = Data(request.body.readableBytesView)
                    return .result(.init(httpStatus: .ok, headers: ["ETag": "\"fixture-object\""]), continueProcessing: true)
                case "GET":
                    guard var bytes = value.ciphertext else {
                        let xml = "<Error><Code>NoSuchKey</Code><Message>Missing</Message></Error>"
                        return .result(.init(httpStatus: .notFound, headers: ["Content-Type": "application/xml"], body: ByteBuffer(string: xml)))
                    }
                    if value.tamper { bytes[bytes.index(before: bytes.endIndex)] ^= 1 }
                    return .result(.init(httpStatus: .ok, headers: ["Content-Type": "application/octet-stream"], body: ByteBuffer(bytes: bytes)), continueProcessing: true)
                case "DELETE":
                    value.ciphertext = nil
                    return .result(.init(httpStatus: .noContent), continueProcessing: true)
                default:
                    return .result(.init(httpStatus: .methodNotAllowed))
                }
            }
        }
    }
    do {
        let bytes = Data([0, 255, 254, 128, 65, 66, 67, 13, 10])
        let id = UUID().uuidString.lowercased()
        let reference = try await store.put(attachmentID: id, bytes: bytes)
        #expect(reference.objectKey == "attachments/\(id)")
        #expect(reference.byteCount == bytes.count)
        #expect(reference.encryptionVersion == 1)
        #expect(reference.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let captured = state.withLock { $0.requests.first }
        let put = try #require(captured)
        let headers = Dictionary(put.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let ciphertext = Data(put.body.readableBytesView)
        #expect(put.uri == "/fixture/attachments/\(id)?x-id=PutObject")
        #expect(ciphertext != bytes)
        #expect(ciphertext.count == bytes.count + 28)
        #expect(headers["content-length"] == String(ciphertext.count))
        #expect(headers["authorization"]?.contains("Credential=synthetic-access/") == true)
        #expect(headers["authorization"]?.contains("/auto/s3/aws4_request") == true)
        #expect(headers["x-amz-content-sha256"] == SHA256.hash(data: ciphertext).map { String(format: "%02x", $0) }.joined())
        #expect(try await store.get(reference) == bytes)
        let count = state.withLock { $0.requests.count }
        let foreign = AttachmentObjectReference(objectKey: "other/\(id)", sha256: reference.sha256, byteCount: bytes.count, encryptionVersion: 1)
        let invalid = await #expect(throws: AttachmentStorageError.self) { try await store.get(foreign) }
        #expect(invalid == .invalidReference)
        #expect(state.withLock { $0.requests.count } == count)
        state.withLock { $0.tamper = true }
        let tampered = await #expect(throws: AttachmentStorageError.self) { try await store.get(reference) }
        #expect(tampered == .integrityFailure)
        try await store.delete(reference)
        let missing = await #expect(throws: AttachmentStorageError.self) { try await store.get(reference) }
        #expect(missing == .notFound)
        // The final missing-object response ends processRaw. Join its task only
        // after the client has consumed that response, but before either owner
        // closes the socket/event loop: client completion alone does not join
        // the test server's final response-write continuation.
        try await serving.value
        try await store.shutdown()
        try server.stop()
    } catch {
        try? await store.shutdown()
        try? server.stop()
        _ = try? await serving.value
        throw error
    }
}

@Test func attachmentConfigurationDerivesEndpointAndRefusesUnsafeOrMissingInputs() throws {
    let secret = "synthetic-s3-secret"
    let account = String(repeating: "a", count: 32)
    let environment = [
        "ATTACHMENT_STORAGE_PROVIDER": "s3", "S3_BUCKET": "fixture",
        "S3_ACCESS_KEY_ID": "synthetic-access", "S3_SECRET_ACCESS_KEY": secret,
        "CLOUDFLARE_ACCOUNT_ID": account,
        "ATTACHMENT_ENCRYPTION_KEY": Data(repeating: 7, count: 32).base64EncodedString(),
    ]
    let configuration = try S3AttachmentStorageConfiguration.fromEnvironment(environment)
    #expect(configuration.endpoint.absoluteString == "https://\(account).r2.cloudflarestorage.com")
    #expect(configuration.region == "auto")
    #expect(configuration.keyPrefix == "attachments/")
    #expect(!String(describing: configuration).contains(secret))
    #expect(!String(reflecting: configuration).contains(account))
    for invalid in ["http://example.com", "https://user:secret@example.com", "https://example.com?redirect=1"] {
        var changed = environment
        changed["S3_ENDPOINT"] = invalid
        #expect(throws: AttachmentStorageError.self) { try S3AttachmentStorageConfiguration.fromEnvironment(changed) }
    }
    var missing = environment
    missing["S3_ACCESS_KEY_ID"] = ""
    #expect(throws: AttachmentStorageError.self) { try S3AttachmentStorageConfiguration.fromEnvironment(missing) }
}
