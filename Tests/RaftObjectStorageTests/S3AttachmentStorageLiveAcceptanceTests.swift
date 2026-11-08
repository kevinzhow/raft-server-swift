import Foundation
import Testing
@testable import RaftObjectStorage

/// Explicit operator gate only. Ordinary unit runs never contact a real bucket.
/// The caller supplies only the storage environment and enables this test.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RAFT_LIVE_S3_ACCEPTANCE"] == "1"))
func s3AttachmentLiveProductionEnvironmentRoundTrip() async throws {
    var environment = ProcessInfo.processInfo.environment
    environment["S3_KEY_PREFIX"] = "deployment-acceptance/" + UUID().uuidString.lowercased() + "/"
    let configuration = try S3AttachmentStorageConfiguration.fromEnvironment(environment)
    let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
    let writer = try S3AttachmentStorage(configuration: configuration)
    let reference: AttachmentObjectReference
    var written: AttachmentObjectReference?
    do {
        reference = try await writer.put(attachmentID: UUID().uuidString.lowercased(), bytes: bytes)
        written = reference
        #expect(reference.byteCount == bytes.count)
        #expect(reference.encryptionVersion == 1)
        #expect(try await writer.get(reference) == bytes)
        try await writer.shutdown()
    } catch {
        if let written { try? await writer.delete(written) }
        try? await writer.shutdown()
        throw error
    }
    // Independent SDK/HTTP clients recover the existing encrypted object solely
    // from the durable reference and the configured key, then remove this object.
    let reader = try S3AttachmentStorage(configuration: configuration)
    do {
        #expect(try await reader.get(reference) == bytes)
        try await reader.delete(reference)
        do {
            _ = try await reader.get(reference)
            Issue.record("The deleted acceptance object remained readable")
        } catch {
            #expect(error as? AttachmentStorageError == .notFound)
        }
        try await reader.shutdown()
    } catch {
        try? await reader.delete(reference)
        try? await reader.shutdown()
        throw error
    }
}
