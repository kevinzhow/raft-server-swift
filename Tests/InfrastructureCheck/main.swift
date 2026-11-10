import Foundation
import RaftPersistence
import RaftRedis
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Real infrastructure acceptance only. This does not persist or restore any
// production owner, and it does not establish subscription delivery.
@main
private enum InfrastructureCheck {
    static func main() async {
        do {
            let input = try Input(environment: ProcessInfo.processInfo.environment)
            switch input.mode {
            case .check: try await runChecks(input)
            case .fencing: await FencedWriterCheck.run(databaseURL: input.databaseURL)
            case .seed: try await seedCheckpoint(input)
            case .verify: try await verifyCheckpoint(input)
            }
            print("PASS infrastructure-only-complete")
        } catch let failure as CheckFailure {
            print("FAIL \(failure.label.rawValue) [\(failure.reason.rawValue)]")
            exit(1)
        } catch {
            // Never interpolate an error, URL, command, key, document or token.
            print("FAIL configuration [configuration]")
            exit(1)
        }
    }
}

private enum Mode: Sendable {
    case check, fencing, seed, verify
}

private struct Input: Sendable {
    let databaseURL: String
    let redisURL: String
    let namespace: String
    let mode: Mode

    init(environment: [String: String]) throws {
        guard let databaseURL = environment["DATABASE_URL"], !databaseURL.isEmpty,
              let redisURL = environment["REDIS_URL"], !redisURL.isEmpty,
              let database = URLComponents(string: databaseURL),
              database.password?.isEmpty == false,
              let redis = URLComponents(string: redisURL),
              redis.password?.isEmpty == false else { throw Reason.configuration }
        switch Array(CommandLine.arguments.dropFirst()) {
        case [], ["--check"]: mode = .check
        case ["--check-fencing"]: mode = .fencing
        case ["--seed-checkpoint"]: mode = .seed
        case ["--verify-checkpoint"]: mode = .verify
        default: throw Reason.configuration
        }
        let runID: UUID
        if case .fencing = mode {
            runID = UUID()
        } else if case .check = mode {
            runID = UUID()
        } else {
            guard let value = environment["CHECK_RUN_ID"], let id = UUID(uuidString: value)
            else { throw Reason.configuration }
            runID = id
        }
        self.databaseURL = databaseURL
        self.redisURL = redisURL
        namespace = "raft-infrastructure-check:" + runID.uuidString.lowercased()
    }

    func key(_ domain: DurableDomain, _ suffix: String) throws -> DurableKey {
        try DurableKey(domain: domain, aggregateID: namespace + ":" + suffix)
    }

    func redisKey(_ suffix: String) -> String { namespace + ":" + suffix }
}

private enum Label: String, Sendable {
    case pgMigration = "postgres-migrate"
    case pgStart = "postgres-start-ping"
    case pgTyped = "postgres-typed-jsonb-roundtrip"
    case pgWrongCodec = "postgres-wrong-codec-rejected"
    case pgAtomic = "postgres-cross-domain-rollback"
    case pgReadSet = "postgres-read-set-conflict"
    case pgRace = "postgres-same-revision-one-winner"
    case pgTombstone = "postgres-tombstone-prevents-aba"
    case pgClose = "postgres-closed-rejected"
    case pgReopen = "postgres-reopen-durable-read"
    case pgCleanup = "postgres-own-namespace-cleanup"
    case pgBadEndpoint = "postgres-bad-endpoint-rejected"
    case pgBadCredentials = "postgres-bad-credentials-rejected"
    case redisPing = "redis-auth-ping"
    case redisSelect = "redis-select-isolation"
    case redisRace = "redis-nx-one-winner"
    case redisBinary = "redis-binary-get-delete"
    case redisIncrement = "redis-atomic-increment-with-ttl"
    case redisExpiry = "redis-real-expiry"
    case redisLease = "redis-owner-checked-release"
    case redisCleanup = "redis-own-namespace-cleanup"
    case redisBadEndpoint = "redis-bad-endpoint-rejected"
    case redisBadCredentials = "redis-bad-credentials-rejected"
    case redisShape = "redis-empty-null-binary-nested-replies"
    case redisBoundedMutation = "redis-bounded-mutation-not-replayed"
    case redisDeadline = "redis-command-deadline"
    case redisCancellation = "redis-inflight-cancellation"
    case checkpointAbsent = "checkpoint-requires-absent-pair"
    case checkpointPGSeed = "checkpoint-postgres-seeded"
    case checkpointRedisSeed = "checkpoint-redis-seeded"
    case checkpointPGVerify = "checkpoint-postgres-restored"
    case checkpointRedisVerify = "checkpoint-redis-restored"
}

private enum Reason: String, Error, Sendable {
    case assertion, configuration, persistence, redis, unexpected
}

private struct CheckFailure: Error {
    let label: Label
    let reason: Reason
}

private func require(_ condition: Bool) throws {
    guard condition else { throw Reason.assertion }
}

@discardableResult
private func check<Value: Sendable>(
    _ label: Label, _ operation: @Sendable () async throws -> Value
) async throws -> Value {
    do {
        let value = try await operation()
        print("PASS \(label.rawValue)")
        return value
    } catch {
        let reason: Reason
        if let specific = error as? Reason { reason = specific }
        else if error is PersistenceError { reason = .persistence }
        else if error is RedisError { reason = .redis }
        else { reason = .unexpected }
        throw CheckFailure(label: label, reason: reason)
    }
}

private struct TypedProof: Codable, Sendable {
    let maximum: Int64
    let minimum: Int
    let bytes: Data
    let instant: Date
    let absent: String?
    let text: String
    let witness: String

    init(witness: String) {
        maximum = Int64.max
        minimum = Int.min
        bytes = Data((0...255).map { UInt8($0) })
        instant = Date(timeIntervalSinceReferenceDate: Double(bitPattern: 0x41c23456789abcde))
        absent = nil
        text = "日本語 中文 e\u{301} 🛶 \"quoted\" \\slash\r\nsecond line"
        self.witness = witness
    }

    private enum CodingKeys: String, CodingKey {
        case maximum, minimum, bytes, instant, absent, text, witness
    }

    // Encode and require an explicit JSON null, rather than omit the optional key.
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maximum, forKey: .maximum)
        try values.encode(minimum, forKey: .minimum)
        try values.encode(bytes, forKey: .bytes)
        try values.encode(instant, forKey: .instant)
        try values.encode(absent, forKey: .absent)
        try values.encode(text, forKey: .text)
        try values.encode(witness, forKey: .witness)
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maximum = try values.decode(Int64.self, forKey: .maximum)
        minimum = try values.decode(Int.self, forKey: .minimum)
        bytes = try values.decode(Data.self, forKey: .bytes)
        instant = try values.decode(Date.self, forKey: .instant)
        absent = try values.decode(String?.self, forKey: .absent)
        text = try values.decode(String.self, forKey: .text)
        witness = try values.decode(String.self, forKey: .witness)
    }

    func matches(_ other: Self) -> Bool {
        maximum == other.maximum && minimum == other.minimum && bytes == other.bytes
            && instant.timeIntervalSinceReferenceDate.bitPattern
                == other.instant.timeIntervalSinceReferenceDate.bitPattern
            && absent == other.absent && text == other.text && witness == other.witness
    }
}

private struct Record: Codable, Equatable, Sendable {
    let value: Int
    let text: String
}

private func document(_ database: PostgresPersistence, _ key: DurableKey) async throws -> DurableDocument {
    guard let result = try await database.read(key) else { throw Reason.assertion }
    return result
}

private func oneRevision(_ revisions: [DurableRevision]) throws -> DurableRevision {
    guard revisions.count == 1, let result = revisions.first else { throw Reason.assertion }
    return result
}

private func expectConflict(_ operation: @Sendable () async throws -> Void) async throws {
    do { try await operation() }
    catch let error as PersistenceError {
        if case .conflict = error { return }
        throw error
    }
    throw Reason.assertion
}

private func pgTyped(_ database: PostgresPersistence, _ input: Input) async throws {
    let key = try input.key(.feedback, "typed")
    let expected = TypedProof(witness: input.namespace)
    let created = try oneRevision(try await database.compareAndSwap([
        .put(expected, key: key, codecVersion: 7, expectedRevision: nil),
    ]))
    try require(created.key == key && created.revision == 1 && !created.deleted)
    let row = try await document(database, key)
    try require(row.revision == created.revision)
    try require(try row.decode(TypedProof.self, codecVersion: 7).matches(expected))
}

private func pgWrongCodec(_ database: PostgresPersistence, _ input: Input) async throws {
    let row = try await document(database, input.key(.feedback, "typed"))
    do { _ = try row.decode(TypedProof.self, codecVersion: 8) }
    catch let error as PersistenceError {
        if case .codecVersionMismatch(expected: 8, actual: 7) = error { return }
        throw error
    }
    throw Reason.assertion
}

private func pgAtomic(_ database: PostgresPersistence, _ input: Input) async throws {
    let first = try input.key(.authProfiles, "atomic-a")
    let second = try input.key(.notifications, "atomic-b")
    let initial = Record(value: 1, text: "committed")
    let inserted = try await database.compareAndSwap([
        .put(initial, key: first, codecVersion: 1, expectedRevision: nil),
        .put(initial, key: second, codecVersion: 1, expectedRevision: nil),
    ])
    try require(inserted.count == 2 && inserted.allSatisfy { $0.revision == 1 && !$0.deleted })
    let before = try await database.readSnapshot([second, first])
    try require(before.count == 2 && Set(before.map(\.key)) == Set([first, second]))
    // JSON permits an escaped NUL; PostgreSQL JSONB rejects it. The first
    // aggregate update must roll back when this real second-domain write fails.
    do {
        _ = try await database.compareAndSwap([
            .put(Record(value: 2, text: "uncommitted"), key: first, codecVersion: 1, expectedRevision: 1),
            .put(Record(value: 2, text: "\u{0}"), key: second, codecVersion: 1, expectedRevision: 1),
        ])
        throw Reason.assertion
    } catch let error as PersistenceError {
        guard case .database = error else { throw error }
    }
    let after = try await database.readSnapshot([first, second])
    try require(after.count == 2)
    for row in after {
        try require(row.revision == 1 && row.decode(Record.self, codecVersion: 1) == initial)
    }
}

private func pgReadSet(_ database: PostgresPersistence, _ input: Input) async throws {
    let written = try input.key(.authProfiles, "atomic-a")
    let readOnly = try input.key(.notifications, "atomic-b")
    let before = try await document(database, written)
    let dependency = try await document(database, readOnly)
    _ = try await database.compareAndSwap([
        .put(Record(value: 3, text: "changed-dependency"), key: readOnly,
             codecVersion: 1, expectedRevision: dependency.revision),
    ])
    let candidate = try DurableWrite.put(
        Record(value: 4, text: "must-not-commit"), key: written,
        codecVersion: 1, expectedRevision: before.revision
    )
    let condition = try DurableCondition(key: readOnly, expectedRevision: dependency.revision)
    try await expectConflict { _ = try await database.compareAndSwap([candidate], checking: [condition]) }
    let after = try await document(database, written)
    try require(after.revision == before.revision)
    try require(try after.decode(Record.self, codecVersion: 1) == before.decode(Record.self, codecVersion: 1))

    let absence = try input.key(.agentsRuntime, "read-absence")
    let absentCondition = try DurableCondition(key: absence, expectedRevision: nil)
    try require(try await database.read(absence) == nil)
    _ = try await database.compareAndSwap([
        .put(Record(value: 1, text: "new-dependency"), key: absence, codecVersion: 1, expectedRevision: nil),
    ])
    try await expectConflict { _ = try await database.compareAndSwap([candidate], checking: [absentCondition]) }
    try require(try await document(database, written).revision == before.revision)
}

private func pgRace(_ database: PostgresPersistence, _ input: Input) async throws {
    let key = try input.key(.messagesAndThreads, "cas-race")
    let initial = try oneRevision(try await database.compareAndSwap([
        .put(Record(value: -1, text: "initial"), key: key, codecVersion: 1, expectedRevision: nil),
    ]))
    let winners = try await withThrowingTaskGroup(of: Int?.self) { group in
        for contender in 0..<16 {
            group.addTask {
                let write = try DurableWrite.put(
                    Record(value: contender, text: "winner"), key: key,
                    codecVersion: 1, expectedRevision: initial.revision
                )
                do {
                    let result = try oneRevision(try await database.compareAndSwap([write]))
                    try require(result.revision == initial.revision + 1)
                    return contender
                } catch let error as PersistenceError {
                    switch error {
                    case .conflict: return nil
                    case .database(_, let state, _) where state == "40001" || state == "40P01": return nil
                    default: throw error
                    }
                }
            }
        }
        var result: [Int] = []
        for try await contender in group { if let contender { result.append(contender) } }
        return result
    }
    try require(winners.count == 1)
    let stored = try await document(database, key)
    try require(stored.revision == initial.revision + 1)
    try require(try stored.decode(Record.self, codecVersion: 1) == Record(value: winners[0], text: "winner"))
}

private func pgTombstone(_ database: PostgresPersistence, _ input: Input) async throws {
    let key = try input.key(.serversAndChannels, "tombstone")
    let original = try oneRevision(try await database.compareAndSwap([
        .put(Record(value: 1, text: "original"), key: key, codecVersion: 1, expectedRevision: nil),
    ]))
    let deleted = try oneRevision(try await database.compareAndSwap([
        .delete(key: key, expectedRevision: original.revision),
    ]))
    try require(deleted.deleted && deleted.revision > original.revision)
    try require(try await database.read(key) == nil)
    let replacement = Record(value: 2, text: "replacement")
    let recreated = try oneRevision(try await database.compareAndSwap([
        .put(replacement, key: key, codecVersion: 1, expectedRevision: nil),
    ]))
    try require(!recreated.deleted && recreated.revision > deleted.revision)
    let stale = try DurableWrite.put(Record(value: 9, text: "stale"), key: key,
                                    codecVersion: 1, expectedRevision: original.revision)
    try await expectConflict { _ = try await database.compareAndSwap([stale]) }
    let staleDelete = try DurableWrite.delete(key: key, expectedRevision: original.revision)
    try await expectConflict { _ = try await database.compareAndSwap([staleDelete]) }
    let current = try await document(database, key)
    try require(current.revision == recreated.revision)
    try require(try current.decode(Record.self, codecVersion: 1) == replacement)
}

private func cleanPostgres(_ database: PostgresPersistence, _ input: Input) async throws {
    let keys = try [input.key(.feedback, "typed"), input.key(.authProfiles, "atomic-a"),
                    input.key(.notifications, "atomic-b"), input.key(.agentsRuntime, "read-absence"),
                    input.key(.messagesAndThreads, "cas-race"), input.key(.serversAndChannels, "tombstone")]
    var writes: [DurableWrite] = []
    for key in keys {
        if let row = try await database.read(key) {
            writes.append(try .delete(key: key, expectedRevision: row.revision))
        }
    }
    if !writes.isEmpty { _ = try await database.compareAndSwap(writes) }
    for key in keys { try require(try await database.read(key) == nil) }
}

private func runChecks(_ input: Input) async throws {
    let configuration = try PostgresPersistenceConfiguration(databaseURL: input.databaseURL, maximumConnections: 8)
    try await check(.pgMigration) { try await PostgresPersistence.migrate(configuration: configuration) }
    let database = try await check(.pgStart) {
        let database = try await PostgresPersistence.start(configuration: configuration, migrate: false)
        do { try await database.ping(); return database }
        catch { await database.close(); throw error }
    }
    do {
        try await check(.pgTyped) { try await pgTyped(database, input) }
        try await check(.pgWrongCodec) { try await pgWrongCodec(database, input) }
        try await check(.pgAtomic) { try await pgAtomic(database, input) }
        try await check(.pgReadSet) { try await pgReadSet(database, input) }
        try await check(.pgRace) { try await pgRace(database, input) }
        try await check(.pgTombstone) { try await pgTombstone(database, input) }
    } catch {
        try? await cleanPostgres(database, input)
        await database.close()
        throw error
    }
    await database.close()
    try await check(.pgClose) {
        do { try await database.ping() }
        catch let error as PersistenceError { if case .closed = error { return }; throw error }
        throw Reason.assertion
    }
    let reopened = try await check(.pgReopen) {
        let reopened = try await PostgresPersistence.start(configuration: configuration, migrate: false)
        do {
            try await reopened.ping()
            let row = try await document(reopened, input.key(.feedback, "typed"))
            try require(try row.decode(TypedProof.self, codecVersion: 7).matches(TypedProof(witness: input.namespace)))
            return reopened
        } catch { await reopened.close(); throw error }
    }
    do { try await check(.pgCleanup) { try await cleanPostgres(reopened, input) } }
    catch { await reopened.close(); throw error }
    await reopened.close()
    try await postgresRejections(input)
    try await redisChecks(input)
}

private func changedURL(_ source: String, _ mutate: (inout URLComponents) -> Void) throws -> String {
    guard var parts = URLComponents(string: source) else { throw Reason.configuration }
    mutate(&parts)
    guard let result = parts.string else { throw Reason.configuration }
    return result
}

private func boundedPostgresURL(_ source: String, badEndpoint: Bool) throws -> String {
    try changedURL(source) { parts in
        if badEndpoint { parts.host = "127.0.0.1"; parts.port = 1 }
        else { parts.password = "invalid-" + UUID().uuidString }
        let bounded = Set(["connect_timeout", "statement_timeout", "lock_timeout"])
        parts.queryItems = (parts.queryItems ?? []).filter { !bounded.contains($0.name) } + [
            URLQueryItem(name: "connect_timeout", value: "1"),
            URLQueryItem(name: "statement_timeout", value: "1000"),
            URLQueryItem(name: "lock_timeout", value: "1000"),
        ]
    }
}

private func postgresRejections(_ input: Input) async throws {
    for badEndpoint in [true, false] {
        try await check(badEndpoint ? .pgBadEndpoint : .pgBadCredentials) {
            let url = try boundedPostgresURL(input.databaseURL, badEndpoint: badEndpoint)
            let configuration = try PostgresPersistenceConfiguration(databaseURL: url)
            do {
                let unexpected = try await PostgresPersistence.start(configuration: configuration, migrate: false)
                await unexpected.close()
            } catch let error as PersistenceError {
                switch error {
                case .database(_, let state, _) where badEndpoint || state == "28P01" || state == "28000": return
                case .timedOut where badEndpoint: return
                default: throw error
                }
            }
            throw Reason.assertion
        }
    }
}

private func redisChecks(_ input: Input) async throws {
    let configuration = try RedisConfiguration(url: input.redisURL)
    let client = RedisClient(configuration: configuration)
    try await check(.redisPing) { try await client.ping() }
    try await check(.redisSelect) {
        let otherURL = try changedURL(input.redisURL) { $0.path = configuration.database == 0 ? "/1" : "/0" }
        let other = RedisClient(configuration: try RedisConfiguration(url: otherURL))
        let key = input.redisKey("select")
        do {
            try require(try await client.set(key, value: "selected", expirySeconds: 30, onlyIfAbsent: true))
            try require(try await other.get(key) == nil)
            try require(try await other.set(key, value: "alternate", expirySeconds: 30, onlyIfAbsent: true))
            try require(try await client.get(key) == "selected")
            try require(try await other.get(key) == "alternate")
        } catch {
            _ = try? await client.delete([key]); _ = try? await other.delete([key])
            throw error
        }
        try require(try await client.delete([key]) == 1)
        try require(try await other.delete([key]) == 1)
    }
    let keys = ["nx", "binary", "counter", "expiry", "lease", "empty", "bounded-mutation", "deadline", "cancel"].map { input.redisKey($0) }
    do {
        try await check(.redisRace) {
            let key = input.redisKey("nx")
            let winners = try await withThrowingTaskGroup(of: String?.self) { group in
                for _ in 0..<16 {
                    let value = UUID().uuidString
                    group.addTask { try await client.setIfAbsent(key, value: value, ttlSeconds: 30) ? value : nil }
                }
                var winners: [String] = []
                for try await result in group { if let result { winners.append(result) } }
                return winners
            }
            try require(winners.count == 1)
            try require(try await client.get(key) == winners[0])
        }
        try await check(.redisBinary) {
            let key = input.redisKey("binary")
            let bytes = (0...255).map { UInt8($0) } + [0, 13, 10, 255, 0]
            try require(try await client.setBytes(key, value: bytes, expirySeconds: 30))
            try require(try await client.getBytes(key) == bytes)
            try require(try await client.delete([key]) == 1)
            try require(try await client.getBytes(key) == nil)
        }
        try await check(.redisShape) {
            let key = input.redisKey("empty")
            try require(try await client.setBytes(key, value: [], expirySeconds: 30))
            try require(try await client.getBytes(key) == [])
            try require(try await client.delete([key]) == 1)
            try require(try await client.getBytes(key) == nil)
            let bytes: [UInt8] = [0, 255, 13, 10, 128, 0]
            let script = "return {ARGV[1], false, {'', 1}, redis.error_reply('BUSINESSCHECK rejected')}"
            let reply = try await client.execute(bytes: [
                Array("EVAL".utf8), Array(script.utf8), Array("0".utf8), bytes,
            ])
            try require(reply == .array([
                .bulkString(bytes), .bulkString(nil),
                .array([.bulkString([]), .integer(1)]), .error("BUSINESSCHECK rejected"),
            ]))
        }
        try await check(.redisBoundedMutation) {
            let key = input.redisKey("bounded-mutation")
            let bounded = RedisClient(configuration: try RedisConfiguration(
                url: input.redisURL, maximumResponseBytes: 64
            ))
            do {
                _ = try await bounded.eval(
                    script: "redis.call('INCR', KEYS[1]); return string.rep('x', 256)", keys: [key]
                )
                throw Reason.assertion
            } catch let error as RedisError {
                try require(error == .responseTooLarge)
            }
            try require(try await client.get(key) == "1")
        }
        try await check(.redisDeadline) {
            let bounded = RedisClient(configuration: try RedisConfiguration(
                url: input.redisURL, connectTimeout: .seconds(1), commandTimeout: .milliseconds(75)
            ))
            let clock = ContinuousClock()
            let started = clock.now
            do {
                _ = try await bounded.execute(["BLPOP", input.redisKey("deadline"), "5"])
                throw Reason.assertion
            } catch let error as RedisError {
                try require(error == .commandTimedOut)
            }
            try require(started.duration(to: clock.now) < .seconds(2))
            try await client.ping()
        }
        try await check(.redisCancellation) {
            func blockedClients() async throws -> Int {
                guard case .bulkString(let bytes?) = try await client.execute(["INFO", "clients"])
                else { throw Reason.assertion }
                let text = String(decoding: bytes, as: UTF8.self)
                guard let row = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("blocked_clients:") }),
                      let count = Int(row.dropFirst("blocked_clients:".count))
                else { throw Reason.assertion }
                return count
            }
            let baseline = try await blockedClients()
            let operation = Task {
                try await client.execute(["BLPOP", input.redisKey("cancel"), "5"])
            }
            do {
                let clock = ContinuousClock()
                let arrivalDeadline = clock.now.advanced(by: .seconds(2))
                while try await blockedClients() <= baseline {
                    try require(clock.now < arrivalDeadline)
                    try await Task.sleep(for: .milliseconds(10))
                }
                let cancelledAt = clock.now
                operation.cancel()
                do {
                    _ = try await operation.value
                    throw Reason.assertion
                } catch is CancellationError {}
                try require(cancelledAt.duration(to: clock.now) < .seconds(1))
                let closeDeadline = clock.now.advanced(by: .seconds(2))
                while try await blockedClients() > baseline {
                    try require(clock.now < closeDeadline)
                    try await Task.sleep(for: .milliseconds(10))
                }
                try await client.ping()
            } catch {
                operation.cancel()
                _ = try? await operation.value
                throw error
            }
        }
        try await check(.redisIncrement) {
            let key = input.redisKey("counter")
            let values = try await withThrowingTaskGroup(of: Int64.self) { group in
                for _ in 0..<16 { group.addTask { try await client.incrementWithTTL(key, ttlSeconds: 30) } }
                var values: [Int64] = []
                for try await value in group { values.append(value) }
                return values
            }
            try require(values.sorted() == (1...16).map { Int64($0) })
            try require(try await client.get(key) == "16")
            guard case .integer(let ttl) = try await client.execute(["PTTL", key]) else { throw Reason.assertion }
            try require(ttl > 0 && ttl <= 30_000)
        }
        try await check(.redisExpiry) {
            let key = input.redisKey("expiry")
            try require(try await client.setIfAbsent(key, value: "expiring", ttlMilliseconds: 1000))
            try require(try await client.get(key) == "expiring")
            try await Task.sleep(for: .milliseconds(1200))
            try require(try await client.get(key) == nil)
            try require(try await client.setIfAbsent(key, value: "after-expiry", ttlMilliseconds: 30_000))
        }
        try await check(.redisLease) {
            let key = input.redisKey("lease")
            let oldOwner = UUID().uuidString
            let newOwner = UUID().uuidString
            try require(try await client.setIfAbsent(key, value: oldOwner, ttlMilliseconds: 1000))
            try require(try await client.deleteIfValueMatches(key, value: newOwner) == false)
            try require(try await client.get(key) == oldOwner)
            try await Task.sleep(for: .milliseconds(1200))
            try require(try await client.get(key) == nil)
            try require(try await client.setIfAbsent(key, value: newOwner, ttlSeconds: 30))
            try require(try await client.deleteIfValueMatches(key, value: oldOwner) == false)
            try require(try await client.get(key) == newOwner)
            try require(try await client.deleteIfValueMatches(key, value: newOwner))
            try require(try await client.get(key) == nil)
        }
        try await check(.redisCleanup) {
            _ = try await client.delete(keys)
            for key in keys { try require(try await client.getBytes(key) == nil) }
        }
    } catch {
        _ = try? await client.delete(keys)
        throw error
    }
    for badEndpoint in [true, false] {
        try await check(badEndpoint ? .redisBadEndpoint : .redisBadCredentials) {
            let url = try changedURL(input.redisURL) { parts in
                if badEndpoint { parts.host = "127.0.0.1"; parts.port = 1 }
                else { parts.password = "invalid-" + UUID().uuidString }
            }
            let invalid = RedisClient(configuration: try RedisConfiguration(
                url: url, connectTimeout: .seconds(1), commandTimeout: .seconds(1)
            ))
            do { try await invalid.ping() }
            catch let error as RedisError {
                if badEndpoint {
                    switch error {
                    case .connectionFailed, .connectionTimedOut, .commandTimedOut, .connectionClosed: return
                    default: throw error
                    }
                }
                if case .serverError(let code) = error, code == "WRONGPASS" || code == "NOAUTH" { return }
                throw error
            }
            throw Reason.assertion
        }
    }
}

private func checkpointBytes(_ input: Input) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(TypedProof(witness: input.namespace))
}

private func seedCheckpoint(_ input: Input) async throws {
    let configuration = try PostgresPersistenceConfiguration(databaseURL: input.databaseURL)
    let redis = RedisClient(configuration: try RedisConfiguration(url: input.redisURL))
    let database = try await check(.pgStart) {
        let database = try await PostgresPersistence.start(configuration: configuration)
        do { try await database.ping(); return database }
        catch { await database.close(); throw error }
    }
    do {
        try await check(.redisPing) { try await redis.ping() }
        let key = try input.key(.feedback, "checkpoint")
        let redisKey = input.redisKey("checkpoint")
        try await check(.checkpointAbsent) {
            try require(try await database.read(key) == nil)
            try require(try await redis.getBytes(redisKey) == nil)
        }
        try await check(.checkpointPGSeed) {
            let created = try oneRevision(try await database.compareAndSwap([
                .put(TypedProof(witness: input.namespace), key: key, codecVersion: 7, expectedRevision: nil),
            ]))
            try require(created.revision == 1 && !created.deleted)
            let stored = try await document(database, key)
            try require(try stored.decode(TypedProof.self, codecVersion: 7).matches(TypedProof(witness: input.namespace)))
        }
        try await check(.checkpointRedisSeed) {
            let bytes = Array(try checkpointBytes(input))
            // No expiry: verify must observe the persisted key after process and container restart.
            try require(try await redis.setBytes(redisKey, value: bytes, onlyIfAbsent: true))
            try require(try await redis.getBytes(redisKey) == bytes)
        }
    } catch { await database.close(); throw error }
    await database.close()
}

private func verifyCheckpoint(_ input: Input) async throws {
    let configuration = try PostgresPersistenceConfiguration(databaseURL: input.databaseURL)
    let redis = RedisClient(configuration: try RedisConfiguration(url: input.redisURL))
    // Deliberately no migration, create, put, SET or cleanup in verification mode.
    let database = try await check(.pgStart) {
        let database = try await PostgresPersistence.start(configuration: configuration, migrate: false)
        do { try await database.ping(); return database }
        catch { await database.close(); throw error }
    }
    do {
        try await check(.redisPing) { try await redis.ping() }
        try await check(.checkpointPGVerify) {
            let row = try await document(database, input.key(.feedback, "checkpoint"))
            try require(row.revision == 1)
            try require(try row.decode(TypedProof.self, codecVersion: 7).matches(TypedProof(witness: input.namespace)))
        }
        try await check(.checkpointRedisVerify) {
            guard let bytes = try await redis.getBytes(input.redisKey("checkpoint")) else { throw Reason.assertion }
            try require(bytes == Array(try checkpointBytes(input)))
            let proof = try JSONDecoder().decode(TypedProof.self, from: Data(bytes))
            try require(proof.matches(TypedProof(witness: input.namespace)))
        }
    } catch { await database.close(); throw error }
    await database.close()
}
