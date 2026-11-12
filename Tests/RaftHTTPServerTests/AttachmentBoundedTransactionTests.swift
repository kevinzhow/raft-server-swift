import Foundation
import HTTPTypes
@testable import RaftHTTP
@testable import RaftHTTPServer
import RaftObjectStorage
import Synchronization
import Testing
import Vapor

/// One scripted outcome for a single short commit phase.
private enum AttachmentPortStep: Sendable {
    case run
    case unknown
    case refused(any DomainError)
    case failed(any Error)
    case unavailable
    case cancelled
}

/// A deterministic port. `.run` executes the phase body and projects its
/// attempt; every other step simulates a runtime outcome without running it.
private final class ScriptedAttachmentPort: AttachmentTransactionPort, Sendable {
    private let steps: Mutex<[AttachmentPortStep]>
    private let commits = Mutex(0)

    init(_ steps: [AttachmentPortStep]) { self.steps = Mutex(steps) }
    var commitCount: Int { commits.withLock { $0 } }

    func read<Value: Sendable>(_ body: @Sendable () throws -> Value) async throws -> Value {
        try body()
    }

    func commit<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> AttachmentCommitAttempt<Value>
    ) async -> AttachmentCommitOutcome<Value> {
        commits.withLock { $0 += 1 }
        let step = steps.withLock { steps in
            steps.isEmpty ? .unknown : steps.removeFirst()
        }
        switch step {
        case .run:
            do {
                switch try await body() {
                case .ready(let value): return .committed(value)
                case .refused(let error): return .notCommitted(.refused(error))
                case .failed(let error): return .notCommitted(.failed(error))
                }
            } catch {
                return .notCommitted(.failed(error))
            }
        case .unknown:
            return .outcomeUnknown
        case .refused(let error):
            return .notCommitted(.refused(error))
        case .failed(let error):
            return .notCommitted(.failed(error))
        case .unavailable:
            return .notCommitted(.unavailable)
        case .cancelled:
            return .notCommitted(.cancelledBeforeStart)
        }
    }
}

private final class MemoryAttachmentStorage: AttachmentObjectStoring, Sendable {
    private let objects = Mutex<[String: Data]>([:])

    var count: Int { objects.withLock { $0.count } }

    func put(attachmentID: String, bytes: Data) async throws -> AttachmentObjectReference {
        let key = "attachments/\(attachmentID)"
        objects.withLock { $0[key] = bytes }
        return AttachmentObjectReference(
            objectKey: key, sha256: "synthetic", byteCount: bytes.count, encryptionVersion: 1
        )
    }

    func get(_ reference: AttachmentObjectReference) async throws -> Data {
        guard let bytes = objects.withLock({ $0[reference.objectKey] }) else {
            throw AttachmentStorageError.notFound
        }
        return bytes
    }

    func delete(_ reference: AttachmentObjectReference) async throws {
        objects.withLock { $0.removeValue(forKey: reference.objectKey) }
    }
}

private struct SyntheticUploadFailure: Error {}

private struct BoundedUploadObservation {
    let outcome: Result<AttachmentUploadListResponse, any Error>
    let objectCount: Int
    let rowCount: Int
    let commitCount: Int
}

private func observeBoundedUpload(
    _ steps: [AttachmentPortStep]
) async throws -> BoundedUploadObservation {
    let storage = MemoryAttachmentStorage()
    let setup = AttachmentPreviewAccounts(storage: storage)
    let port = ScriptedAttachmentPort(steps)
    let outcome: Result<AttachmentUploadListResponse, any Error>
    do {
        let response = try await setup.accounts.agentsLifecycle.uploadAttachmentContents(
            authorization: setup.authorization, serverId: setup.serverId, channelId: setup.channelId,
            files: [.init(filename: "bounded.txt", mimeType: "text/plain",
                          bytes: Data("synthetic bounded notes".utf8))],
            transaction: .bounded(port)
        )
        outcome = .success(response)
    } catch {
        outcome = .failure(error)
    }
    return BoundedUploadObservation(
        outcome: outcome, objectCount: storage.count,
        rowCount: setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments.count },
        commitCount: port.commitCount
    )
}

private struct FixedAttachmentResponder: Responder {
    let respondBody: @Sendable (Request) async throws -> Response

    func respond(to request: Request) async throws -> Response {
        try await respondBody(request)
    }
}

private final class AttachmentAuthProbe: Sendable {
    private let seen = Mutex(false)
    var didSeeAdmission: Bool { seen.withLock { $0 } }

    func responder() -> FixedAttachmentResponder {
        FixedAttachmentResponder { request in
            self.seen.withLock { $0 = request.auth.get(AttachmentFlexContext.self) != nil }
            return Response(status: .ok)
        }
    }
}

private func attachmentHeaders(_ setup: AttachmentPreviewAccounts) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = setup.authorization
    headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
    return headers
}

@Test func attachmentBodyPlanePolicySelectsOnlyTheExactHumanShapes() {
    let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    for method in [HTTPRequest.Method.get, .head] {
        #expect(AttachmentBodyPlanePolicy.matches(method: method, path: "/api/attachments/\(id)"))
        #expect(AttachmentBodyPlanePolicy.matches(method: method, path: "/api/attachments/\(id)/preview"))
        #expect(AttachmentBodyPlanePolicy.matches(method: method, path: "/api/attachments/\(id)/html-preview"))
    }
    #expect(AttachmentBodyPlanePolicy.matches(method: .post, path: "/api/attachments/upload"))

    // Non-body-plane methods keep the legacy FIFO.
    #expect(!AttachmentBodyPlanePolicy.matches(method: .get, path: "/api/attachments/upload"))
    #expect(!AttachmentBodyPlanePolicy.matches(method: .delete, path: "/api/attachments/\(id)"))
    #expect(!AttachmentBodyPlanePolicy.matches(method: .post, path: "/api/attachments/\(id)"))

    // Aliases, metadata/capability shapes and comments stay legacy.
    for path in [
        "/api/attachments/\(id)/url", "/api/attachments/\(id)/urls",
        "/api/attachments/\(id)/html-preview-url", "/api/attachments/\(id)/comments",
        "/api/attachments/upload-sessions", "/api/attachments/upload-sessions/\(id)",
        "/api/attachments/upload-sessions/\(id)/complete", "/api/attachments/upload-capabilities",
        "/api/attachments/not-a-uuid", "/api/attachments/\(id)/", "/api/attachments//\(id)",
        "/api/attachments/\(id)/Preview", "/api/attachments/\(id)/html-preview/extra",
        "/api/attachments/\(id.uppercased())x", "/internal/agent-api/attachments/\(id)",
        "/internal/agent-api/upload", "/api/public/servers/example/attachments/\(id)",
    ] {
        #expect(!AttachmentBodyPlanePolicy.matches(method: .get, path: path))
    }
    #expect(!AttachmentBodyPlanePolicy.matches(method: .post, path: "/api/attachments/uploads"))
    #expect(!AttachmentBodyPlanePolicy.matches(method: .post, path: "/internal/agent-api/upload"))
    // UUIDs are matched by the shared UUID rule, including uppercase hex.
    #expect(AttachmentBodyPlanePolicy.matches(method: .get, path: "/api/attachments/\(id.uppercased())"))
}

@Test func boundedUploadCleanupFollowsTheCommitOutcome() async throws {
    // Committed: rows + one object retained, one commit per phase.
    let committed = try await observeBoundedUpload([.run, .run])
    guard case .success(let response) = committed.outcome else {
        Issue.record("a committed bounded upload did not succeed")
        return
    }
    #expect(response.attachments.count == 1)
    #expect(committed.objectCount == 1)
    #expect(committed.rowCount == 1)
    #expect(committed.commitCount == 2)

    // Unknown commit: never delete the just-written object and publish no row.
    let unknown = try await observeBoundedUpload([.run, .unknown])
    guard case .failure(let unknownError) = unknown.outcome else {
        Issue.record("an unknown bounded commit claimed success")
        return
    }
    #expect(unknownError is AttachmentPersistenceUnavailable)
    #expect(unknown.objectCount == 1)
    #expect(unknown.rowCount == 0)

    // Typed refusal: the closure refused before writing metadata, so cleanup is safe.
    let refused = try await observeBoundedUpload([
        .run, .refused(AttachmentContentError.cannotWriteChannel)
    ])
    guard case .failure(let refusedError) = refused.outcome else {
        Issue.record("a refused bounded commit claimed success")
        return
    }
    #expect(refusedError as? AttachmentContentError == .cannotWriteChannel)
    #expect(refused.objectCount == 0)
    #expect(refused.rowCount == 0)

    // Unexpected operation failure before metadata: delete and let the caller map 500.
    let failed = try await observeBoundedUpload([.run, .failed(SyntheticUploadFailure())])
    guard case .failure(let failedError) = failed.outcome else {
        Issue.record("a failed bounded commit claimed success")
        return
    }
    #expect(failedError is SyntheticUploadFailure)
    #expect(failed.objectCount == 0)
    #expect(failed.rowCount == 0)

    // Admission loss and pre-callback cancellation are known-not-committed.
    for steps in [[.run, .unavailable], [.run, .cancelled]] as [[AttachmentPortStep]] {
        let stopped = try await observeBoundedUpload(steps)
        guard case .failure(let stoppedError) = stopped.outcome else {
            Issue.record("a stopped bounded commit claimed success")
            return
        }
        #expect(stoppedError is AttachmentPersistenceUnavailable)
        #expect(stopped.objectCount == 0)
        #expect(stopped.rowCount == 0)
    }

    // A pre-commit admission loss never writes an object.
    let early = try await observeBoundedUpload([.unavailable])
    if case .success = early.outcome { Issue.record("a pre-commit admission loss claimed success") }
    #expect(early.objectCount == 0)
    #expect(early.rowCount == 0)
}

@Test func boundedFlexAdmissionCommitsBeforePopulatingRequestAuth() async throws {
    let setup = AttachmentPreviewAccounts(storage: MemoryAttachmentStorage())
    let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let request = Request(
        method: .get, url: try #require(URI(string: "/api/attachments/\(id)")),
        headers: attachmentHeaders(setup)
    )
    let probe = AttachmentAuthProbe()
    let port = ScriptedAttachmentPort([.run])
    let middleware = AttachmentFlexAdmissionMiddleware(lifecycle: setup.accounts.agentsLifecycle)

    let response = try await AttachmentTransactionScope.$bounded.withValue(true) {
        try await AttachmentTransactionScope.$port.withValue(port) {
            try await middleware.respond(to: request, chainingTo: probe.responder())
        }
    }

    #expect(response.status == .ok)
    #expect(probe.didSeeAdmission)
    #expect(port.commitCount == 1)
}

@Test func boundedFlexAdmissionKeepsRefusalAndUnavailableBytes() async throws {
    let setup = AttachmentPreviewAccounts(storage: MemoryAttachmentStorage())
    let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let middleware = AttachmentFlexAdmissionMiddleware(lifecycle: setup.accounts.agentsLifecycle)

    // A typed refusal is committed and returned with its unchanged HEAD bytes.
    let refusalProbe = AttachmentAuthProbe()
    let refusalPort = ScriptedAttachmentPort([.run])
    let headRequest = Request(
        method: .head, url: try #require(URI(string: "/api/attachments/\(id)")), headers: .init()
    )
    let refusal = try await AttachmentTransactionScope.$bounded.withValue(true) {
        try await AttachmentTransactionScope.$port.withValue(refusalPort) {
            try await middleware.respond(to: headRequest, chainingTo: refusalProbe.responder())
        }
    }
    #expect(refusal.status == .unauthorized)
    #expect((refusal.body.string ?? "").isEmpty)
    #expect(refusal.headers[.contentLength] == "35")
    #expect(!refusalProbe.didSeeAdmission)
    #expect(refusalPort.commitCount == 1)

    // Admission loss returns the exact existing 503 body/headers.
    let unavailablePort = ScriptedAttachmentPort([.unavailable])
    let unavailableRequest = Request(
        method: .get, url: try #require(URI(string: "/api/attachments/\(id)")),
        headers: attachmentHeaders(setup)
    )
    let unavailable = try await AttachmentTransactionScope.$bounded.withValue(true) {
        try await AttachmentTransactionScope.$port.withValue(unavailablePort) {
            try await middleware.respond(
                to: unavailableRequest, chainingTo: AttachmentAuthProbe().responder()
            )
        }
    }
    #expect(unavailable.status == .serviceUnavailable)
    #expect(unavailable.body.string == #"{"error":"Business persistence unavailable"}"#)
    #expect(unavailable.headers[.contentType] == "application/json")
    #expect(unavailable.headers[.cacheControl] == "no-store")
}
