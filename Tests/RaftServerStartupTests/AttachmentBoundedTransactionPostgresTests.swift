import Crypto
import Foundation
import HTTPTypes
#if canImport(Glibc)
import Glibc
#endif
import Logging
import PostgresNIO
@testable import RaftHTTP
@testable import RaftHTTPServer
import RaftObjectStorage
import RaftPersistence
import Synchronization
import TestSupport
import Testing
import Vapor
import VaporTesting

/// Real-PostgreSQL acceptance for the bounded attachment body plane.
///
/// Each test starts the real `BusinessPersistenceRuntime` (writer lease, FIFO,
/// fenced CAS, publication) and serves the configured app with a gated object
/// store. It proves that object/multipart I/O happens outside the global writer,
/// that post-I/O authorization still denies plaintext, and that the cleanup
/// matrix never deletes after an unknown commit.
///
/// The shared transaction domain is a one-way production policy, so one test
/// method must run in one process. `scripts/test-pg.sh` launches each gated
/// startup test in its own runner process with a fresh database; do not run this
/// suite's methods together with `swift test --filter`.
///
/// Required environment (also supplied by `make test-pg`):
///   RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE=1
///   RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL=<fresh PostgreSQL 17>
private let attachmentBoundedPGEnabled =
    ProcessInfo.processInfo.environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE"] == "1"

private let boundedHTML = Data("<!doctype html><html><body>synthetic bounded private report</body></html>".utf8)

/// A gated object store. `blockNext(.get/.put)` suspends exactly the next
/// matching operation until `release()`, which is used to observe the writer
/// boundary while storage I/O is still in flight.
private actor AttachmentStorageGate: AttachmentObjectStoring {
    enum Block: Sendable { case get, put }

    private var objects: [String: Data] = [:]
    private var block: Block?
    private var enteredCount = 0
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockNext(_ block: Block) {
        self.block = block
        enteredCount = 0
    }

    func waitUntilEntered() async {
        while enteredCount < 1 {
            await withCheckedContinuation { enteredWaiters.append($0) }
        }
    }

    func waitUntilEntered(count: Int) async {
        while enteredCount < count {
            await withCheckedContinuation { enteredWaiters.append($0) }
        }
    }

    func enteredOperations() -> Int { enteredCount }

    func release() {
        block = nil
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func objectCount() -> Int { objects.count }

    func fullObjectKeys() -> [String] { Array(objects.keys) }

    func put(attachmentID: String, bytes: Data) async throws -> AttachmentObjectReference {
        if block == .put { await suspend() }
        let key = "attachments/\(attachmentID)"
        objects[key] = bytes
        return AttachmentObjectReference(
            objectKey: key, sha256: "acceptance-synthetic", byteCount: bytes.count, encryptionVersion: 1
        )
    }

    func get(_ reference: AttachmentObjectReference) async throws -> Data {
        if block == .get { await suspend() }
        guard let bytes = objects[reference.objectKey] else { throw AttachmentStorageError.notFound }
        return bytes
    }

    func delete(_ reference: AttachmentObjectReference) async throws {
        objects.removeValue(forKey: reference.objectKey)
    }

    private func suspend() async {
        enteredCount += 1
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if block != nil {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }
}

private struct AttachmentPGFixture {
    let accounts: EmailLoginDirectory
    let runtime: BusinessPersistenceRuntime
    let storage: AttachmentStorageGate
    let bindings: [DurableSnapshotBinding]
    let control: PostgresConnection
    let user: String
    let server: String
    let channel: String
    let authorization: String
    let agentKey: String?
    let attachmentId: String?

    var userHeaders: HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = authorization
        headers[HTTPField.Name("X-Server-Id")!] = server
        return headers
    }
}

private func postgresConfiguration(from databaseURL: String) throws -> PostgresConnection.Configuration {
    guard let url = URLComponents(string: databaseURL), let host = url.host,
          let encodedUser = url.percentEncodedUser,
          let username = encodedUser.removingPercentEncoding,
          let encodedPath = url.percentEncodedPath.removingPercentEncoding,
          encodedPath.hasPrefix("/"), encodedPath.count > 1 else {
        throw AttachmentPGBoundedError.invalidDatabaseURL
    }
    let password = url.percentEncodedPassword?.removingPercentEncoding
    return PostgresConnection.Configuration(
        host: host, port: url.port ?? 5432, username: username, password: password,
        database: String(encodedPath.dropFirst()), tls: .disable
    )
}

private func makeAttachmentPGFixture(
    seedAttachment: Data? = nil,
    seedAgent: Bool = false,
    logger: Logger
) async throws -> AttachmentPGFixture {
    let environment = ProcessInfo.processInfo.environment
    let databaseURL = try #require(environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL"])
    let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)

    let storage = AttachmentStorageGate()
    let accounts = EmailLoginDirectory()
    let user = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: user, email: "bounded-\(user)@example.com", password: "password123")
    accounts.markEmailVerified(userId: user)
    accounts.oauth.addOwnedServer(id: server, slug: "bounded-\(server)", name: "Bounded", ownerId: user)
    let channel = accounts.oauth.createChannel(serverId: server, name: "bounded", creatorUserId: user)
    accounts.addPostableChannel(serverId: server, channelId: channel, memberId: user, name: "bounded")
    accounts.configureAttachmentStorage(storage)
    let authorization = "Bearer \(accounts.mintAccessTokenForTesting(userId: user))"

    var agentKey: String?
    if seedAgent {
        let agent = accounts.oauth.createAgent(
            serverId: server, name: "bounded-agent", creatorUserId: user, runtime: "claude"
        )
        agentKey = accounts.mintAgentCredential(
            agentId: agent, scopes: ["send", "read"], name: "bounded-key"
        )
    }

    var attachmentId: String?
    if let seedAttachment {
        let uploaded = try await accounts.agentsLifecycle.uploadAttachmentContents(
            authorization: authorization, serverId: server, channelId: channel,
            files: [.init(filename: "private.html", mimeType: "text/html", bytes: seedAttachment)]
        )
        attachmentId = try #require(uploaded.attachments.first?.id)
    }

    let bindings = try accounts.makeDurableBindings()
    let runtime = try await BusinessPersistenceRuntime.start(
        configuration: configuration, bindings: bindings
    )
    do {
        let control = try await PostgresConnection.connect(
            configuration: try postgresConfiguration(from: databaseURL), id: 0, logger: logger
        )
        return AttachmentPGFixture(
            accounts: accounts, runtime: runtime, storage: storage, bindings: bindings,
            control: control, user: user, server: server, channel: channel,
            authorization: authorization, agentKey: agentKey, attachmentId: attachmentId
        )
    } catch {
        await runtime.close()
        throw error
    }
}

private func withAttachmentPGFixture(
    seedAttachment: Data? = nil,
    seedAgent: Bool = false,
    logger: Logger,
    _ body: (AttachmentPGFixture) async throws -> Void
) async throws {
    let fixture = try await makeAttachmentPGFixture(
        seedAttachment: seedAttachment, seedAgent: seedAgent, logger: logger
    )
    do {
        try await body(fixture)
    } catch {
        await fixture.runtime.close()
        try? await fixture.control.close()
        throw error
    }
    await fixture.runtime.close()
    try? await fixture.control.close()
}

private func configureAttachmentApp(
    _ app: Application, fixture: AttachmentPGFixture
) async throws {
    configure(app, services: FallbackServices(
        nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
        emailAccounts: fixture.accounts, persistence: fixture.runtime
    ))
    // Route/feature registration allocates its stores before the one-way
    // production policy is enabled, exactly like the process entrypoint.
    try await fixture.runtime.activate()
}

/// Waits for gated storage entries with a deadline. A regression that keeps
/// only one transfer inside the old writer FIFO must fail promptly instead of
/// parking the suite on an actor continuation; releasing the gate first lets
/// the caller's HTTP tasks unwind.
private func awaitStorageEntry(
    _ storage: AttachmentStorageGate, count: Int = 1, seconds: Double = 10
) async throws {
    do {
        try await withTestDeadline("attachment storage entry", seconds: seconds) {
            await storage.waitUntilEntered(count: count)
        }
    } catch {
        await storage.release()
        throw error
    }
}

private func completesBeforeDeadline(
    seconds: Double, _ operation: @escaping @Sendable () async throws -> Void
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            do { try await operation(); return true } catch { return false }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        return finished
    }
}

private func appendBoundedEvent(_ accounts: EmailLoginDirectory, type: String) {
    accounts.productEventStore.append(RecordedProductEvent(
        subjectType: "user", subjectId: "attachment-bounded-pg",
        eventType: type, actorType: "user", actorId: "attachment-bounded-pg",
        source: "acceptance", idempotencyKey: nil, metadataJSON: "{}"
    ))
}

private func multipartUpload(
    channelId: String, filename: String = "bounded.txt",
    mimeType: String = "text/plain", bytes: Data
) -> (body: Data, boundary: String) {
    let boundary = "attachment-bounded-\(UUID().uuidString)"
    var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"channelId\"\r\n\r\n\(channelId)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8)
    body.append(bytes)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return (body, boundary)
}

@Suite(.serialized) struct AttachmentBoundedTransactionPostgresTests {
    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func blockedObjectGetDoesNotHoldTheBusinessWriterAndRevalidatesRevocation() async throws {
        let logger = Logger(label: "raft.attachment-bounded-get")
        try await withAttachmentPGFixture(seedAttachment: boundedHTML, logger: logger) { fixture in
            let attachmentId = try #require(fixture.attachmentId)
            try await withApp { app in
                try await configureAttachmentApp(app, fixture: fixture)
                try await app.testing { client in
                    await fixture.storage.blockNext(.get)
                    let reading = Task {
                        try await client.send(
                            .get, headers: fixture.userHeaders,
                            to: URI(string: "/api/attachments/\(attachmentId)")
                        )
                    }
                    try await awaitStorageEntry(fixture.storage)

                    let committed = await completesBeforeDeadline(seconds: 5) {
                        try await fixture.runtime.execute {
                            appendBoundedEvent(fixture.accounts, type: "while-get-blocked")
                        }
                    }
                    #expect(committed, "runtime.execute blocked behind the attachment GET")

                    let revoked = await completesBeforeDeadline(seconds: 5) {
                        try await fixture.runtime.execute {
                            fixture.accounts.oauth.removeMember(
                                serverId: fixture.server, userId: fixture.user
                            )
                        }
                    }
                    #expect(revoked, "permission revocation did not commit while the GET was blocked")

                    await fixture.storage.release()
                    let refused = try await reading.value
                    #expect(refused.status == .notFound)
                    #expect(refused.body.string == #"{"error":"Attachment not found"}"#)
                    #expect(refused.body.data?.range(of: boundedHTML) == nil)
                }
            }
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func blockedObjectGetRejectsAChangedObjectBindingWithoutLeakingPlaintext() async throws {
        let logger = Logger(label: "raft.attachment-bounded-binding")
        try await withAttachmentPGFixture(seedAttachment: boundedHTML, logger: logger) { fixture in
            let attachmentId = try #require(fixture.attachmentId)
            try await withApp { app in
                try await configureAttachmentApp(app, fixture: fixture)
                try await app.testing { client in
                    await fixture.storage.blockNext(.get)
                    let reading = Task {
                        try await client.send(
                            .get, headers: fixture.userHeaders,
                            to: URI(string: "/api/attachments/\(attachmentId)")
                        )
                    }
                    try await awaitStorageEntry(fixture.storage)

                    let changed = await completesBeforeDeadline(seconds: 5) {
                        try await fixture.runtime.execute {
                            fixture.accounts.messagesAndThreadsStore.withState { state in
                                guard let old = state.attachmentObjectReferences[attachmentId] else { return }
                                let key = "attachments/\(UUID().uuidString.lowercased())"
                                state.attachmentObjectReferences[attachmentId] = .init(
                                    objectKey: key, sha256: old.sha256,
                                    byteCount: old.byteCount, encryptionVersion: old.encryptionVersion
                                )
                                state.channelAttachments[attachmentId]?.storageKey = key
                            }
                        }
                    }
                    #expect(changed, "the binding change did not commit while the GET was blocked")

                    await fixture.storage.release()
                    let refused = try await reading.value
                    #expect(refused.status == .notFound)
                    #expect(refused.body.string == #"{"error":"Attachment not found"}"#)
                    #expect(refused.body.data?.range(of: boundedHTML) == nil)
                }
            }
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func blockedObjectPutDoesNotHoldTheBusinessWriterAndPublishesRowsAfterRelease() async throws {
        let logger = Logger(label: "raft.attachment-bounded-put")
        try await withAttachmentPGFixture(logger: logger) { fixture in
            let (body, boundary) = multipartUpload(channelId: fixture.channel, bytes: boundedHTML)
            try await withApp { app in
                try await configureAttachmentApp(app, fixture: fixture)
                try await app.testing { client in
                    await fixture.storage.blockNext(.put)
                    var headers = fixture.userHeaders
                    headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                    let uploading = Task {
                        try await client.send(.post, headers: headers, to: "/api/attachments/upload") {
                            $0.body = .init(data: body)
                        }
                    }
                    try await awaitStorageEntry(fixture.storage)

                    let committed = await completesBeforeDeadline(seconds: 5) {
                        try await fixture.runtime.execute {
                            appendBoundedEvent(fixture.accounts, type: "while-put-blocked")
                        }
                    }
                    #expect(committed, "runtime.execute blocked behind the attachment upload PUT")

                    await fixture.storage.release()
                    let response = try await uploading.value
                    #expect(response.status == .ok)
                    let object = try JSONSerialization.jsonObject(with: response.body.data ?? Data())
                        as? [String: Any]
                    let rows = try #require(object?["attachments"] as? [[String: Any]])
                    let row = try #require(rows.first)
                    let id = try #require(row["id"] as? String)
                    // The production bounded path publishes the same upstream
                    // attachments.ts:656-676 envelope as the legacy HTTP fixture.
                    #expect(Set(row.keys) == ["id", "filename", "mimeType", "sizeBytes", "width", "height", "thumbnailUrl", "rasterPreviewUrl"])
                    #expect(row["filename"] as? String == "bounded.txt")
                    #expect(row["mimeType"] as? String == "text/plain")
                    #expect(row["sizeBytes"] as? Int == boundedHTML.count)
                    for key in ["width", "height", "thumbnailUrl", "rasterPreviewUrl"] { #expect(row[key] is NSNull) }

                    let published = try fixture.runtime.withCommittedReadView {
                        fixture.accounts.messagesAndThreadsStore.withState { state in
                            state.channelAttachments[id] != nil
                                && state.attachmentObjectReferences[id] != nil
                        }
                    }
                    #expect(published)
                    #expect(await fixture.storage.objectCount() == 1)
                }
            }
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func fullTransferBudgetQueuesWithoutHoldingTheBusinessWriter() async throws {
        let logger = Logger(label: "raft.attachment-bounded-budget")
        try await withAttachmentPGFixture(seedAttachment: boundedHTML, logger: logger) { fixture in
            let attachmentId = try #require(fixture.attachmentId)
            try await withApp { app in
                try await configureAttachmentApp(app, fixture: fixture)
                try await app.testing { client in
                    await fixture.storage.blockNext(.get)
                    let path = try #require(URI(string: "/api/attachments/\(attachmentId)"))
                    let reads = (0..<5).map { _ in
                        Task { try await client.send(.get, headers: fixture.userHeaders, to: path) }
                    }
                    try await awaitStorageEntry(fixture.storage, count: 4)
                    let enteredBeforeRelease = await fixture.storage.enteredOperations()
                    #expect(enteredBeforeRelease == 4)
                    // The fifth request must queue on the shared cap-4 budget,
                    // not enter storage. A short settle keeps this observation
                    // from racing the fifth request's own setup.
                    try await Task.sleep(for: .milliseconds(300))
                    let enteredWhileFull = await fixture.storage.enteredOperations()
                    #expect(enteredWhileFull == 4,
                            "the fifth classified GET entered storage past the cap-4 budget")

                    let committed = await completesBeforeDeadline(seconds: 5) {
                        try await fixture.runtime.execute {
                            appendBoundedEvent(fixture.accounts, type: "while-transfer-budget-full")
                        }
                    }
                    #expect(committed, "runtime.execute blocked behind the full transfer budget")

                    await fixture.storage.release()
                    for read in reads {
                        let response = try await read.value
                        #expect(response.status == .ok)
                        #expect(response.body.data == boundedHTML)
                    }
                }
            }
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func refusedPostPutAdmissionDeletesTheObjectAndLeavesNoRow() async throws {
        let logger = Logger(label: "raft.attachment-bounded-refused")
        try await withAttachmentPGFixture(logger: logger) { fixture in
            let (body, boundary) = multipartUpload(channelId: fixture.channel, bytes: boundedHTML)
            try await withApp { app in
                try await configureAttachmentApp(app, fixture: fixture)
                try await app.testing { client in
                    await fixture.storage.blockNext(.put)
                    var headers = fixture.userHeaders
                    headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                    let uploading = Task {
                        try await client.send(.post, headers: headers, to: "/api/attachments/upload") {
                            $0.body = .init(data: body)
                        }
                    }
                    try await awaitStorageEntry(fixture.storage)

                    let revoked = await completesBeforeDeadline(seconds: 5) {
                        try await fixture.runtime.execute {
                            fixture.accounts.oauth.removeMember(
                                serverId: fixture.server, userId: fixture.user
                            )
                        }
                    }
                    #expect(revoked)
                    await fixture.storage.release()

                    let refused = try await uploading.value
                    #expect(refused.status == .forbidden)
                    #expect(refused.body.string == #"{"error":"Not a member of this server"}"#)
                    #expect(await fixture.storage.objectCount() == 0)
                    let rows = try fixture.runtime.withCommittedReadView {
                        fixture.accounts.messagesAndThreadsStore.withState { $0.channelAttachments.count }
                    }
                    #expect(rows == 0)
                }
            }
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func cancelledFencedCommitStillPublishesAndRetainsTheObject() async throws {
        let logger = Logger(label: "raft.attachment-bounded-cancelled")
        try await withAttachmentPGFixture(logger: logger) { fixture in
            try await fixture.runtime.activate()
            let port = RuntimeAttachmentTransactionPort(runtime: fixture.runtime)
            await fixture.storage.blockNext(.put)
            let uploading = Task {
                try await fixture.accounts.agentsLifecycle.uploadAttachmentContents(
                    authorization: fixture.authorization, serverId: fixture.server,
                    channelId: fixture.channel,
                    files: [.init(filename: "cancelled.bin", mimeType: "application/octet-stream",
                                  bytes: Data("synthetic cancelled commit".utf8))],
                    transaction: .bounded(port)
                )
            }
            try await awaitStorageEntry(fixture.storage)

            let lockID = try firstFencedLockID(fixture.bindings)
            try await execute(
                fixture.control, "SELECT pg_advisory_lock(1380001364, \(lockID))", logger: logger
            )
            await fixture.storage.release()
            let waiting = try await waitForBlockedWriter(fixture.control, logger: logger)
            #expect(waiting, "the post-PUT fenced CAS never reached the advisory lock")

            uploading.cancel()
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.runtime.readinessSnapshot.isReady,
                    "request cancellation must not fail business admission closed")

            _ = try await scalar(
                fixture.control, "SELECT pg_advisory_unlock(1380001364, \(lockID))", logger: logger
            )
            switch await uploading.result {
            case .success(let response):
                let id = try #require(response.attachments.first?.id)
                let retained = try fixture.runtime.withCommittedReadView {
                    fixture.accounts.messagesAndThreadsStore.withState { $0.channelAttachments[id] != nil }
                }
                #expect(retained)
                #expect(await fixture.storage.objectCount() == 1)
            case .failure(let error):
                Issue.record("cancelled request lost its shielded commit: \(String(describing: error))")
            }
            #expect(fixture.runtime.readinessSnapshot.isReady)
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func lostWriterDuringFencedCommitRetainsTheObjectAndFailsClosed() async throws {
        let logger = Logger(label: "raft.attachment-bounded-unknown")
        try await withAttachmentPGFixture(logger: logger) { fixture in
            try await fixture.runtime.activate()
            let port = RuntimeAttachmentTransactionPort(runtime: fixture.runtime)
            await fixture.storage.blockNext(.put)
            let uploading = Task {
                try await fixture.accounts.agentsLifecycle.uploadAttachmentContents(
                    authorization: fixture.authorization, serverId: fixture.server,
                    channelId: fixture.channel,
                    files: [.init(filename: "unknown.bin", mimeType: "application/octet-stream",
                                  bytes: Data("synthetic unknown commit".utf8))],
                    transaction: .bounded(port)
                )
            }
            try await awaitStorageEntry(fixture.storage)

            let lockID = try firstFencedLockID(fixture.bindings)
            try await execute(
                fixture.control, "SELECT pg_advisory_lock(1380001364, \(lockID))", logger: logger
            )
            await fixture.storage.release()
            let waiting = try await waitForBlockedWriter(fixture.control, logger: logger)
            #expect(waiting, "the post-PUT fenced CAS never reached the advisory lock")

            let writer = try await scalarInt(
                fixture.control, "SELECT backend_pid::bigint FROM raft_persistence.writer_control",
                logger: logger
            )
            _ = try await scalar(
                fixture.control, "SELECT pg_terminate_backend(\(writer))", logger: logger
            )
            // A post-callback writer connection failure maps to .outcomeUnknown.
            // This proves conservative retention for a lost/ambiguous fenced
            // commit; it does not prove a successful COMMIT whose acknowledgement
            // was lost.
            switch await uploading.result {
            case .success:
                Issue.record("an unknown SQL commit claimed success")
            case .failure(let error):
                #expect(error is AttachmentPersistenceUnavailable)
            }
            // Never delete after an unknown commit.
            #expect(await fixture.storage.objectCount() == 1)
            #expect(!fixture.runtime.readinessSnapshot.isReady)
            _ = try? await scalar(
                fixture.control, "SELECT pg_advisory_unlock(1380001364, \(lockID))", logger: logger
            )
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func excludedInternalAgentUploadStillCommitsInsideTheOuterTransaction() async throws {
        let logger = Logger(label: "raft.attachment-bounded-agent")
        try await withAttachmentPGFixture(seedAgent: true, logger: logger) { fixture in
            let agentKey = try #require(fixture.agentKey)
            let (body, boundary) = multipartUpload(
                channelId: fixture.channel, filename: "agent-note.txt", bytes: Data("agent upload".utf8)
            )
            try await withApp { app in
                try await configureAttachmentApp(app, fixture: fixture)
                try await app.testing { client in
                    var headers = HTTPFields()
                    headers[.authorization] = "Bearer \(agentKey)"
                    headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
                    let response = try await client.send(
                        .post, headers: headers, to: "/internal/agent-api/upload"
                    ) {
                        $0.body = .init(data: body)
                    }
                    #expect(response.status == .ok)
                    let object = try JSONSerialization.jsonObject(with: response.body.data ?? Data())
                        as? [String: Any]
                    let id = try #require(object?["id"] as? String)

                    let committed = try fixture.runtime.withCommittedReadView {
                        let row = fixture.accounts.messagesAndThreadsStore
                            .withState { $0.channelAttachments[id] != nil }
                        let used = fixture.accounts.agentsRuntimeStore
                            .withState { $0.agentCredentials[agentKey]?.lastUsedAt != nil }
                        return row && used
                    }
                    #expect(committed, "the excluded internal agent upload did not commit row + credential use")
                    #expect(await fixture.storage.objectCount() == 1)
                }
            }
        }
    }

    @Test(.enabled(if: attachmentBoundedPGEnabled), .timeLimit(.minutes(2)))
    func nonUUIDAttachmentPathKeepsItsTypedRefusalInsteadOf503() async throws {
        let logger = Logger(label: "raft.attachment-bounded-nonuuid")
        try await withAttachmentPGFixture(logger: logger) { fixture in
            try await withApp { app in
                try await configureAttachmentApp(app, fixture: fixture)
                try await app.testing { client in
                    let response = try await client.send(
                        .get, headers: fixture.userHeaders,
                        to: URI(string: "/api/attachments/not-a-uuid")
                    )
                    #expect(response.status == .badRequest)
                    #expect(response.body.string
                        == #"{"code":"invalid_attachment_id","error":"Invalid attachment id"}"#)
                }
            }
        }
    }
}

// MARK: - Direct PostgreSQL control session

/// Mirrors `PostgresPersistence.lockID`: SHA-256 over `domain + NUL + aggregate`,
/// first four bytes big-endian as a signed 32-bit advisory-lock identity.
private func firstFencedLockID(_ bindings: [DurableSnapshotBinding]) throws -> Int32 {
    let locks = try bindings.map { binding -> Int32 in
        let ordering = binding.key.domain.rawValue + "\u{0}" + binding.key.aggregateID
        let hash = SHA256.hash(data: Data(ordering.utf8))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int32(bitPattern: value)
    }
    guard let lock = locks.min() else { throw AttachmentPGBoundedError.invalidResponse }
    return lock
}

private func scalar(
    _ connection: PostgresConnection, _ sql: String, logger: Logger
) async throws -> Bool {
    var result = false
    for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {
        result = try row.decode(Bool.self)
    }
    return result
}

private func scalarInt(
    _ connection: PostgresConnection, _ sql: String, logger: Logger
) async throws -> Int64 {
    var result: Int64?
    for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {
        result = try row.decode(Int64.self)
    }
    guard let result else { throw AttachmentPGBoundedError.invalidResponse }
    return result
}

private func execute(
    _ connection: PostgresConnection, _ sql: String, logger: Logger
) async throws {
    for try await _ in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger) {}
}

/// Waits until a backend other than this control session is blocked on the
/// fenced advisory lock, i.e. the runtime is inside its real SQL transaction.
private func waitForBlockedWriter(
    _ connection: PostgresConnection, logger: Logger
) async throws -> Bool {
    for _ in 0..<100 {
        if try await scalar(connection, """
            SELECT EXISTS (
                SELECT 1 FROM pg_stat_activity
                WHERE datname = current_database() AND pid <> pg_backend_pid()
                  AND wait_event_type = 'Lock'
                  AND query LIKE '%pg_advisory_xact_lock%'
            )
            """, logger: logger) {
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private enum AttachmentPGBoundedError: Error {
    case invalidDatabaseURL
    case invalidResponse
}
