import Foundation
import RaftPersistence
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP

/// A pure read must not consume a revision, a denied/throwing command must
/// still commit its nonce/expiry edit, and a rollback must never advance the
/// canonical committed-byte comparison base. Real PostgreSQL proves the rows;
/// the encode counter wraps the actual production bindings, not a test seam.
///
/// Run this filter alone in a fresh process: the shared transaction domain is a
/// one-way production policy for the lifetime of that process.
private let snapshotEncodingEnabled =
    ProcessInfo.processInfo.environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE"] == "1"
private let snapshotRestartChildEnabled =
    ProcessInfo.processInfo.environment["RAFT_SNAPSHOT_ENCODING_RESTART_CHILD"] == "1"

private let snapshotUser = "snapshot-encoding-user"
private let snapshotExpiry = Date(timeIntervalSinceReferenceDate: 800_000_000.125)
private let wiredToken = "wired-expiry-nonce"
private let committedToken = "committed-expiry-nonce"
private let throwingToken = "denied-expiry-nonce"
private let rollbackToken = "rollback-expiry-nonce"
private let effectToken = "effect-expiry-nonce"
private let rollbackEffectToken = "rollback-effect-expiry-nonce"
private let failedCommitToken = "failed-commit-expiry-nonce"
private let committedEffectID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEE01")!
private let onlyEffectID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEE02")!
private let rolledBackEffectID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEE03")!

@Suite(.serialized) struct BusinessPersistenceSnapshotEncodingPostgresTests {
    @Test(.enabled(if: snapshotEncodingEnabled))
    func pureReadsUseCanonicalCommittedBytesAndPreserveWriteSemantics() async throws {
        let databaseURL = try #require(
            ProcessInfo.processInfo.environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL"]
        )
        let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        let accounts = EmailLoginDirectory()
        let production = try accounts.makeDurableBindings()
        let keys = production.map(\.key)
        let authKey = try DurableKey(domain: .authProfiles, aggregateID: "root")
        let oauthKey = try DurableKey(domain: .oauthLedger, aggregateID: "root")

        // Count real codec invocations at the binding boundary. The owners and
        // the runtime stay the production graph; only the closures are wrapped.
        let encodes = Mutex(0)
        let bindings = production.map { binding in
            DurableSnapshotBinding(
                key: binding.key,
                encode: {
                    encodes.withLock { $0 += 1 }
                    return try binding.encode()
                },
                restore: binding.restore
            )
        }

        let observer = try await PostgresPersistence.start(configuration: configuration)
        var runtime: BusinessPersistenceRuntime?
        do {
            let initial = try await observer.readSnapshot(keys)
            #expect(initial.isEmpty, "the gate supplies a fresh database")

            let writer = try await BusinessPersistenceRuntime.start(
                configuration: configuration, bindings: bindings
            )
            runtime = writer
            let afterStart = try await observer.readSnapshot(keys)

            // Start restored the owners; production wiring now changes live
            // state that is not in PostgreSQL. The canonical base must be the
            // wired state, not the bootstrap rows.
            accounts.oauthFlows.configureSigningSecret("snapshot-encoding-post-wiring-secret")
            accounts.authProfileStore.setResetToken(
                hash: wiredToken, userId: snapshotUser, expiresAt: snapshotExpiry
            )

            encodes.withLock { $0 = 0 }
            try await writer.activate()
            #expect(encodes.withLock { $0 } == keys.count,
                    "activation must seed each binding once from the wired committed view")

            let afterActivate = try await observer.readSnapshot(keys)
            #expect(documentStates(afterStart) == documentStates(afterActivate),
                    "activation must not rewrite rows")
            let oauthDocument = try #require(afterActivate.first { $0.key == oauthKey })
            #expect(String(decoding: oauthDocument.json, as: UTF8.self)
                .contains("snapshot-encoding-post-wiring-secret") == false,
                "pure wiring must not be persisted by activation")

            // Encoding the same committed value twice must be byte-identical;
            // the cache comparison relies on this exactly like the old
            // base-versus-pending comparison did.
            for binding in production {
                let first = try binding.encode()
                let second = try binding.encode()
                #expect(first == second)
            }

            // A pure read must not move a revision or a row. It also proves the
            // cached base is the post-wiring state: a raw bootstrap cache would
            // see the signing-secret and reset-token edits as changes.
            encodes.withLock { $0 = 0 }
            try await writer.execute {
                _ = accounts.authProfileStore.resetToken(hash: wiredToken)
            }
            #expect(encodes.withLock { $0 } == keys.count,
                    "a pure read must encode the pending snapshots once, not the base again")
            let afterPureRead = try await observer.readSnapshot(keys)
            #expect(documentStates(afterActivate) == documentStates(afterPureRead),
                    "a pure read consumed a revision or rewrote a row")

            // A real business edit commits and advances only its owner.
            let beforeCommitted = afterPureRead
            try await writer.execute {
                accounts.authProfileStore.setResetToken(
                    hash: committedToken, userId: snapshotUser, expiresAt: snapshotExpiry
                )
            }
            let afterCommitted = try await observer.readSnapshot(keys)
            #expect(changedKeys(beforeCommitted, afterCommitted) == Set([authKey]),
                    "an auth-profile edit must write only the auth-profile row")
            encodes.withLock { $0 = 0 }
            try await writer.execute { _ = accounts.authProfileStore.resetToken(hash: committedToken) }
            #expect(encodes.withLock { $0 } == keys.count)
            let afterCommittedRead = try await observer.readSnapshot(keys)
            #expect(documentStates(afterCommitted) == documentStates(afterCommittedRead),
                    "the cache must advance with a confirmed commit; the next read re-wrote the row")

            // A command that is denied after mutating expiry/nonce facts still
            // commits those facts before its original error is returned.
            let beforeThrowing = afterCommittedRead
            await #expect(throws: SnapshotEncodingDenied.self) {
                try await writer.execute {
                    accounts.authProfileStore.setResetToken(
                        hash: throwingToken, userId: snapshotUser, expiresAt: snapshotExpiry
                    )
                    throw SnapshotEncodingDenied()
                }
            }
            #expect(accounts.authProfileStore.resetToken(hash: throwingToken) != nil)
            let afterThrowing = try await observer.readSnapshot(keys)
            #expect(changedKeys(beforeThrowing, afterThrowing) == Set([authKey]),
                    "a denied command did not commit its nonce/expiry edit")

            // Rollback-only discards pending edits, writes nothing, and must not
            // advance the comparison base.
            await #expect(throws: TransactionError.rollbackOnly) {
                try await writer.execute {
                    accounts.authProfileStore.setResetToken(
                        hash: rollbackToken, userId: snapshotUser, expiresAt: snapshotExpiry
                    )
                    DeferredEffects.markRollbackOnly()
                }
            }
            #expect(accounts.authProfileStore.resetToken(hash: rollbackToken) == nil)
            let afterRollback = try await observer.readSnapshot(keys)
            #expect(documentStates(afterThrowing) == documentStates(afterRollback),
                    "rollback-only advanced a revision or the committed-byte base")
            encodes.withLock { $0 = 0 }
            try await writer.execute { _ = accounts.authProfileStore.resetToken(hash: committedToken) }
            #expect(encodes.withLock { $0 } == keys.count)
            let afterRollbackRead = try await observer.readSnapshot(keys)
            #expect(documentStates(afterRollback) == documentStates(afterRollbackRead))

            // Business data and its durable effect commit in one transaction.
            let beforeEffect = afterRollbackRead
            try await writer.execute {
                accounts.authProfileStore.setResetToken(
                    hash: effectToken, userId: snapshotUser, expiresAt: snapshotExpiry
                )
                try DeferredEffects.persist(
                    kind: "snapshot.encoding.probe", payload: Data("committed-effect".utf8),
                    effectID: committedEffectID
                )
            }
            let afterEffect = try await observer.readSnapshot(keys)
            #expect(changedKeys(beforeEffect, afterEffect) == Set([authKey]))
            let effect = try #require(try await observer.outboxEffect(effectID: committedEffectID))
            #expect(effect.effect.payload == Data("committed-effect".utf8))
            #expect(accounts.authProfileStore.resetToken(hash: effectToken) != nil)

            // An effects-only commit still uses every binding as the SQL
            // payload, but reuses the snapshots this transaction already
            // encoded instead of encoding the same frozen owners again.
            let beforeOnlyEffect = try await observer.readSnapshot(keys)
            encodes.withLock { $0 = 0 }
            try await writer.execute {
                try DeferredEffects.persist(
                    kind: "snapshot.encoding.probe", payload: Data("only-effect".utf8),
                    effectID: onlyEffectID
                )
            }
            #expect(encodes.withLock { $0 } == keys.count,
                    "effects-only encoding re-encoded the pending snapshots")
            let onlyEffectEntry = try #require(try await observer.outboxEffect(effectID: onlyEffectID))
            #expect(onlyEffectEntry.effect.payload == Data("only-effect".utf8))
            let afterOnlyEffect = try await observer.readSnapshot(keys)
            #expect(changedKeys(beforeOnlyEffect, afterOnlyEffect) == Set(keys),
                    "effects-only commits must keep writing every binding")
            encodes.withLock { $0 = 0 }
            try await writer.execute { _ = accounts.authProfileStore.resetToken(hash: committedToken) }
            #expect(encodes.withLock { $0 } == keys.count)
            let afterOnlyEffectRead = try await observer.readSnapshot(keys)
            #expect(documentStates(afterOnlyEffect) == documentStates(afterOnlyEffectRead),
                    "the effects-only commit did not advance the cache")

            // A rolled back effect and its business edit disappear together.
            let beforeRolledBackEffect = try await observer.readSnapshot(keys)
            await #expect(throws: TransactionError.rollbackOnly) {
                try await writer.execute {
                    accounts.authProfileStore.setResetToken(
                        hash: rollbackEffectToken, userId: snapshotUser, expiresAt: snapshotExpiry
                    )
                    try DeferredEffects.persist(
                        kind: "snapshot.encoding.probe", payload: Data("rolled-back-effect".utf8),
                        effectID: rolledBackEffectID
                    )
                    DeferredEffects.markRollbackOnly()
                }
            }
            #expect(try await observer.outboxEffect(effectID: rolledBackEffectID) == nil)
            #expect(accounts.authProfileStore.resetToken(hash: rollbackEffectToken) == nil)
            let afterRolledBackEffect = try await observer.readSnapshot(keys)
            #expect(documentStates(beforeRolledBackEffect) == documentStates(afterRolledBackEffect),
                    "a rolled back effect or business edit reached PostgreSQL")

            // A commit that loses its revision check must fail closed without
            // publishing the mutation or advancing the canonical base. The real
            // same-lease CAS below moves every revision with identical bytes,
            // the same conflict shape an admitted stale commit already tests.
            let persistence = await writer.persistence
            let epoch = await writer.lease.epoch
            let beforeFailedCommit = try await observer.readSnapshot(keys)
            do {
                try await writer.execute {
                    accounts.authProfileStore.setResetToken(
                        hash: failedCommitToken, userId: snapshotUser, expiresAt: snapshotExpiry
                    )
                    let documents = try await observer.readSnapshot(keys)
                    let writes = try documents.map {
                        try DurableWrite.put(
                            $0.decode(Data.self, codecVersion: 1), key: $0.key,
                            codecVersion: 1, expectedRevision: $0.revision
                        )
                    }
                    _ = try await persistence.compareAndSwap(writes, expectedWriterEpoch: epoch)
                }
                Issue.record("a stale revision committed")
            } catch PersistenceError.conflict {}
            #expect(!writer.readinessSnapshot.isReady,
                    "a failed commit must permanently close admission")
            let cacheAfterFailure = await writer.committedSnapshots
            #expect(cacheAfterFailure.isEmpty,
                    "a failed commit retained or advanced the byte comparison base")
            #expect(accounts.authProfileStore.resetToken(hash: failedCommitToken) == nil)
            let afterFailedCommit = try await observer.readSnapshot(keys)
            #expect(bytePayloads(beforeFailedCommit) == bytePayloads(afterFailedCommit),
                    "the failed commit changed a stored payload")
            #expect(changedKeys(beforeFailedCommit, afterFailedCommit) == Set(keys),
                    "the same-lease CAS should have moved every revision")

            // A fresh process restores the same committed data, seeds the cache
            // from the post-restore owners, and still does not churn revisions.
            await writer.close()
            runtime = nil
            let afterClose = try await observer.readSnapshot(keys)
            #expect(documentStates(afterFailedCommit) == documentStates(afterClose),
                    "closing the runtime rewrote a row")
            try await runRestartChild()
        } catch {
            await runtime?.close()
            try? await observer.close()
            throw error
        }
        try await observer.close()
    }
}

/// Runs only when the parent launched a fresh runner process for the restart
/// leg. A marker file proves the nested filter actually executed.
@Suite(.serialized) struct SnapshotRestartChildTests {
    @Test(.enabled(if: snapshotRestartChildEnabled))
    func restartsWithTheSameWiredCommittedData() async throws {
        let environment = ProcessInfo.processInfo.environment
        let databaseURL = try #require(
            environment["RAFT_BUSINESS_PERSISTENCE_PG_ACCEPTANCE_DATABASE_URL"]
        )
        let marker = try #require(environment["RAFT_SNAPSHOT_ENCODING_RESTART_MARKER"])
        let configuration = try PostgresPersistenceConfiguration(databaseURL: databaseURL)
        let accounts = EmailLoginDirectory()
        let bindings = try accounts.makeDurableBindings()
        let keys = bindings.map(\.key)

        let observer = try await PostgresPersistence.start(configuration: configuration)
        var runtime: BusinessPersistenceRuntime?
        do {
            let beforeStart = try await observer.readSnapshot(keys)

            let writer = try await BusinessPersistenceRuntime.start(
                configuration: configuration, bindings: bindings
            )
            runtime = writer

            // Every committed nonce/expiry fact survived the restart.
            for token in [wiredToken, committedToken, throwingToken, effectToken] {
                let restored = try #require(accounts.authProfileStore.resetToken(hash: token))
                try #require(restored.userId == snapshotUser)
                try #require(restored.expiresAt == snapshotExpiry)
            }
            for token in [rollbackToken, rollbackEffectToken, failedCommitToken] {
                try #require(accounts.authProfileStore.resetToken(hash: token) == nil)
            }
            try #require(try await observer.outboxEffect(effectID: committedEffectID) != nil)
            try #require(try await observer.outboxEffect(effectID: onlyEffectID) != nil)
            try #require(try await observer.outboxEffect(effectID: rolledBackEffectID) == nil)

            // Restore followed by new wiring must again seed the live committed
            // state; the first pure read may not write the new secret.
            accounts.oauthFlows.configureSigningSecret("snapshot-encoding-restart-wiring")
            try await writer.activate()
            let afterActivate = try await observer.readSnapshot(keys)
            try #require(documentStates(beforeStart) == documentStates(afterActivate))
            try await writer.execute { _ = accounts.authProfileStore.resetToken(hash: committedToken) }
            let afterRead = try await observer.readSnapshot(keys)
            try #require(documentStates(afterActivate) == documentStates(afterRead))

            await writer.close()
            runtime = nil
            try Data("ok".utf8).write(to: URL(fileURLWithPath: marker))
        } catch {
            await runtime?.close()
            try? await observer.close()
            throw error
        }
        try await observer.close()
    }
}

private struct SnapshotEncodingDenied: Error {}

private struct DocumentState: Equatable {
    let revision: Int64
    let codecVersion: Int
    let updatedAt: Date
    let json: Data
}

private func documentStates(_ documents: [DurableDocument]) -> [DurableKey: DocumentState] {
    Dictionary(uniqueKeysWithValues: documents.map { document in
        (document.key, DocumentState(
            revision: document.revision, codecVersion: document.codecVersion,
            updatedAt: document.updatedAt, json: document.json
        ))
    })
}

private func changedKeys(_ before: [DurableDocument], _ after: [DurableDocument]) -> Set<DurableKey> {
    let old = documentStates(before)
    let new = documentStates(after)
    return Set(new.keys.filter { old[$0] != new[$0] })
}

private func bytePayloads(_ documents: [DurableDocument]) -> [DurableKey: Data] {
    Dictionary(uniqueKeysWithValues: documents.map { ($0.key, $0.json) })
}

/// Re-execute this test binary for the restart leg. The child uses a fresh
/// shared transaction domain (one per process), which is the only way to prove
/// a real restart restores the same owners without declaring a production seam.
private func runRestartChild() async throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))
    let directory = FileManager.default.temporaryDirectory
    let stamp = UUID().uuidString
    let marker = directory.appendingPathComponent("snapshot-restart-\(stamp).ok")
    let log = directory.appendingPathComponent("snapshot-restart-\(stamp).log")
    try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
    let handle = try FileHandle(forWritingTo: log)
    do {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--testing-library", "swift-testing",
            "--no-parallel",
            "--filter",
            "^RaftServerStartupTests\\.SnapshotRestartChildTests/restartsWithTheSameWiredCommittedData\\(\\)(/|$)",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["RAFT_SNAPSHOT_ENCODING_RESTART_CHILD"] = "1"
        environment["RAFT_SNAPSHOT_ENCODING_RESTART_MARKER"] = marker.path
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            try? handle.close()
            Issue.record("the restart child did not finish within 120 seconds")
            return
        }
        try? handle.close()
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0,
              (try? String(contentsOf: marker, encoding: .utf8)) == "ok" else {
            Issue.record("""
                the restart child failed (status \(process.terminationStatus)); \
                marker exists: \(FileManager.default.fileExists(atPath: marker.path))
                \(output.suffix(4000))
                """)
            return
        }
    } catch {
        try? handle.close()
        throw error
    }
}
