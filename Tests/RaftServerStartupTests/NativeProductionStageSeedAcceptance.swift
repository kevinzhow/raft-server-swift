import Foundation
import RaftPersistence
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

// PRIVATE acceptance candidate. Run this filter alone in a fresh process.
// Verified/profile rows are synthetic fixtures, not mailbox or delivery evidence.
// BPR bootstrap persists defaults before seeding. Failure never resets the DB.
// Lead migrates the dedicated stage DB first and owns full-table outbox counts:
// SELECT count(*) FROM raft_persistence.durable_outbox;
// Require zero before this helper and again after it closes, before Main starts.
// pendingOutbox checks below cover only due, unclaimed, non-exhausted entries.
private let nativeStageSeedEnabled =
    ProcessInfo.processInfo.environment["RAFT_NATIVE_STAGE_SEED"] == "1"

@Test(.enabled(if: nativeStageSeedEnabled), .serialized)
func nativeProductionStageSeedAccountsAndServerOnly() async throws {
    do {
        let input = try NativeSeedInput()
        let root = EmailLoginDirectory()
        root.oauthFlows.configureSigningSecret(input.jwtSecret)
        let bindings = try root.makeDurableBindings()
        let keys = try NativeSeedAudit.expectedKeys()
        guard bindings.count == 14, Set(bindings.map(\.key)) == keys else {
            throw NativeSeedFailure.bindings
        }
        let baseline = try NativeSeedSnapshot.capture(bindings)
        try NativeSeedAudit.pristine(baseline, jwtSecret: input.jwtSecret)
        // The fixture helper uses this real cached PHC without repeating CPU work
        // while the business transaction's permit is held. Never print the PHC.
        let passwordHash = AuthFixturePassword.encoded(input.password)
        let facts = NativeSeedFacts(runID: input.runID)
        let configuration = try PostgresPersistenceConfiguration(databaseURL: input.databaseURL)
        // This client never acquires a writer lease, migrates, dispatches or writes.
        let reader = try await PostgresPersistence.start(configuration: configuration, migrate: false)
        var writer: BusinessPersistenceRuntime?
        do {
            let existing = try await reader.readSnapshot(Array(keys))
            let dueBefore = try await reader.pendingOutbox(limit: 1)
            guard existing.isEmpty, dueBefore.isEmpty else { throw NativeSeedFailure.nonemptyDatabase }
            let runtime = try await BusinessPersistenceRuntime.start(configuration: configuration, bindings: bindings)
            writer = runtime
            try await runtime.activate()
            let committed = try await runtime.execute {
                do {
                    let began = Date()
                    for person in facts.people {
                        root.addAccount(id: person.id, email: person.email, password: input.password)
                        root.markEmailVerified(userId: person.id)
                    }
                    // addOwnedServer also creates an all channel. This acceptance-
                    // local borrow writes only the two approved ledger tables.
                    root.oauth.state.withLock { state in
                        state.servers[facts.serverID] = OAuthLedger.Server(
                            id: facts.serverID, slug: facts.slug, name: facts.serverName, ownerId: facts.ownerID)
                        state.members["\(facts.serverID)\n\(facts.ownerID)"] = "owner"
                        state.members["\(facts.serverID)\n\(facts.memberID)"] = "member"
                    }
                    let ended = Date()
                    let snapshot = try NativeSeedSnapshot.capture(bindings)
                    try NativeSeedAudit.seeded(snapshot, baseline: baseline, facts: facts,
                        passwordHash: passwordHash, began: began, ended: ended)
                    return snapshot
                } catch {
                    // BPR intentionally commits ordinary domain refusals. An audit
                    // refusal must discard all pending fixture mutations instead.
                    DeferredEffects.markRollbackOnly()
                    throw NativeSeedFailure.allowlist
                }
            }
            let documents = try await reader.readSnapshot(Array(keys))
            guard documents.count == 14, Set(documents.map(\.key)) == keys,
                  Set(documents.map(\.revision)).count == 1,
                  let revision = documents.first?.revision, revision > 1 else {
                throw NativeSeedFailure.durableAudit
            }
            let recovered = try NativeSeedSnapshot.documents(documents)
            guard recovered.values == committed.values else { throw NativeSeedFailure.durableAudit }
            let dueAfter = try await reader.pendingOutbox(limit: 1)
            guard dueAfter.isEmpty else { throw NativeSeedFailure.effects }
            await runtime.close()
            writer = nil
            await reader.close()
            // Explicit safe-field receipt only. No snapshots, errors, URLs,
            // credentials, password hashes, JWTs or bearer tokens reach output.
            let receipt = NativeSeedReceipt(
                kind: "synthetic-fixture-seed-only", runID: input.runID, serverID: facts.serverID,
                slug: facts.slug, ownerID: facts.ownerID, memberID: facts.memberID,
                emails: facts.people.map(\.email), ownerPayloads: 14, revision: revision,
                dueUnclaimedOutboxEmpty: true, totalOutboxZeroRequiresLeadPSQL: true)
            let bytes = try JSONEncoder().encode(receipt)
            guard let text = String(data: bytes, encoding: .utf8) else { throw NativeSeedFailure.receipt }
            print(text)
        } catch {
            await writer?.close()
            await reader.close()
            if (error as? TransactionError) == .rollbackOnly { throw NativeSeedFailure.allowlist }
            if let safe = error as? NativeSeedFailure { throw safe }
            throw NativeSeedFailure.persistence
        }
    } catch {
        if let safe = error as? NativeSeedFailure { throw safe }
        throw NativeSeedFailure.configuration
    }
}

private enum NativeSeedFailure: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case configuration, bindings, nonemptyDatabase, allowlist, durableAudit, effects, persistence, receipt
    case pristine(NativeSeedPristineCheck)
    var description: String { "Native stage seed rejected (\(label)); details redacted" }
    var debugDescription: String { description }
    private var label: String {
        switch self {
        case .pristine(let check): "pristine." + check.rawValue
        case .configuration: "configuration"
        case .bindings: "bindings"
        case .nonemptyDatabase: "database-not-empty"
        case .allowlist: "seed-allowlist"
        case .durableAudit: "durable-readback"
        case .effects: "eligible-outbox-not-empty"
        case .persistence: "persistence"
        case .receipt: "receipt"
        }
    }
}

private struct NativeSeedInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let databaseURL: String
    let password: String
    let jwtSecret: String
    let runID: String
    var description: String { "NativeSeedInput(redacted)" }
    var debugDescription: String { description }
    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RAFT_NATIVE_STAGE_SEED"] == "1",
              let rawID = environment["RAFT_NATIVE_STAGE_RUN_ID"], let uuid = UUID(uuidString: rawID),
              let databaseURL = environment["RAFT_NATIVE_STAGE_SEED_DATABASE_URL"],
              let url = URLComponents(string: databaseURL),
              ["postgres", "postgresql"].contains(url.scheme ?? ""), url.host == "127.0.0.1",
              let port = url.port, (1...65535).contains(port),
              url.user?.isEmpty == false, url.password?.isEmpty == false, url.fragment == nil,
              let password = environment["RAFT_NATIVE_STAGE_SEED_PASSWORD"], password.utf8.count >= 16,
              let jwtSecret = environment["RAFT_NATIVE_STAGE_SEED_JWT_SECRET"], jwtSecret.utf8.count >= 32 else {
            throw NativeSeedFailure.configuration
        }
        let runID = uuid.uuidString.lowercased()
        let database = "raft_native_stage_" + runID.replacingOccurrences(of: "-", with: "")
        guard url.path == "/" + database else { throw NativeSeedFailure.configuration }
        self.databaseURL = databaseURL
        self.password = password
        self.jwtSecret = jwtSecret
        self.runID = runID
    }
}

private struct NativeSeedPerson: Sendable {
    let id: String
    let email: String
    var handle: String { String(email.split(separator: "@")[0]) }
}

private struct NativeSeedFacts: Sendable {
    let ownerID = UUID().uuidString.lowercased()
    let memberID = UUID().uuidString.lowercased()
    let serverID = UUID().uuidString.lowercased()
    let slug: String
    let serverName: String
    let people: [NativeSeedPerson]
    init(runID: String) {
        let suffix = String(runID.prefix(8))
        slug = "native-stage-" + runID
        serverName = "Native stage " + suffix
        people = [NativeSeedPerson(id: ownerID, email: "stage-owner-\(suffix)@slock.test"),
                  NativeSeedPerson(id: memberID, email: "stage-member-\(suffix)@slock.test")]
    }
}

private struct NativeSeedSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let values: [DurableKey: JSONValue]
    var description: String { "NativeSeedSnapshot(redacted)" }
    var debugDescription: String { description }
    static func capture(_ bindings: [DurableSnapshotBinding]) throws -> Self {
        var values: [DurableKey: JSONValue] = [:]
        for binding in bindings {
            guard values[binding.key] == nil else { throw NativeSeedFailure.bindings }
            values[binding.key] = try JSONDecoder().decode(JSONValue.self, from: binding.encode())
        }
        return Self(values: values)
    }
    static func documents(_ documents: [DurableDocument]) throws -> Self {
        var values: [DurableKey: JSONValue] = [:]
        for document in documents {
            guard values[document.key] == nil else { throw NativeSeedFailure.durableAudit }
            let opaque = try document.decode(Data.self, codecVersion: 1)
            values[document.key] = try JSONDecoder().decode(JSONValue.self, from: opaque)
        }
        return Self(values: values)
    }
}

// Closed identifiers contain schema paths only; no snapshot-derived keys or values.
private enum NativeSeedPristineCheck: String, Sendable {
    case bindingKeys = "bindings.keys"
    case authEnvelope = "auth_profiles.envelope.object"
    case authKeys = "auth_profiles.envelope.keys"
    case authDomain = "auth_profiles.domain"
    case authVersion = "auth_profiles.version"
    case authDates = "auth_profiles.dateEncoding"
    case authPayload = "auth_profiles.payload.object"
    case authRows = "auth_profiles.payload.empty_tables"
    case oauthEnvelope = "oauth_ledger.envelope.object"
    case oauthKeys = "oauth_ledger.envelope.keys"
    case oauthFormat = "oauth_ledger.format"
    case oauthVersion = "oauth_ledger.version"
    case oauthDates = "oauth_ledger.dateEncoding"
    case oauthDerivation = "oauth_ledger.signingKeyDerivation"
    case oauthKey = "oauth_ledger.jwtSecret.configured_key"
    case oauthBusiness = "oauth_ledger.businessState.object"
    case oauthRows = "oauth_ledger.businessState.empty_tables"
    case agentsEnvelope = "agents_runtime.envelope.object"
    case agentsPayload = "agents_runtime.payload.object"
    case executionObject = "agents_runtime.payload.execution.object"
    case executionRows = "agents_runtime.payload.execution.empty_tables"
    case defaultFlags = "agents_runtime.payload.featureFlagRecords.default"
    case agentRows = "agents_runtime.payload.remaining_empty_tables"
    case machinesEnvelope = "machines_and_computers.envelope.object"
    case machinesPayload = "machines_and_computers.payload.object"
    case machineRelease = "machines_and_computers.payload.latestComputerRelease"
    case machineRows = "machines_and_computers.payload.remaining_empty_tables"
    case messagesEnvelope = "messages_and_threads.envelope.object"
    case messagesPayload = "messages_and_threads.payload.object"
    case messageRows = "messages_and_threads.payload.humanMessageRows"
    case tasksEnvelope = "tasks_and_reminders.envelope.object"
    case tasksBusiness = "tasks_and_reminders.business.object"
    case taskRows = "tasks_and_reminders.business.taskRecords"
}

private enum NativeSeedAudit {
    static func expectedKeys() throws -> Set<DurableKey> {
        var keys = try Set(DurableDomain.allCases.map { try DurableKey(domain: $0, aggregateID: "root") })
        keys.insert(try DurableKey(domain: .notifications, aggregateID: "native"))
        guard keys.count == 14 else { throw NativeSeedFailure.bindings }
        return keys
    }
    static func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let result) = value else { throw NativeSeedFailure.allowlist }
        return result
    }
    static func root(_ snapshot: NativeSeedSnapshot, _ domain: DurableDomain) throws -> [String: JSONValue] {
        try object(snapshot.values[DurableKey(domain: domain, aggregateID: "root")])
    }
    static func empty(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let rows): rows.isEmpty
        case .array(let rows): rows.isEmpty
        case .integer(let count): count == 0
        default: false
        }
    }
    private static func pristineObject(_ value: JSONValue?, _ check: NativeSeedPristineCheck) throws -> [String: JSONValue] {
        guard case .object(let result) = value else { throw NativeSeedFailure.pristine(check) }
        return result
    }
    private static func pristineRoot(_ snapshot: NativeSeedSnapshot, _ domain: DurableDomain,
                                     _ check: NativeSeedPristineCheck) throws -> [String: JSONValue] {
        try pristineObject(snapshot.values[DurableKey(domain: domain, aggregateID: "root")], check)
    }
    static func pristine(_ snapshot: NativeSeedSnapshot, jwtSecret: String) throws {
        guard Set(snapshot.values.keys) == (try expectedKeys()) else { throw NativeSeedFailure.pristine(.bindingKeys) }
        let auth = try pristineRoot(snapshot, .authProfiles, .authEnvelope)
        guard Set(auth.keys) == ["domain", "version", "dateEncoding", "payload"] else { throw NativeSeedFailure.pristine(.authKeys) }
        guard auth["domain"] == .string("raft.auth-profile") else { throw NativeSeedFailure.pristine(.authDomain) }
        guard auth["version"] == .integer(1) else { throw NativeSeedFailure.pristine(.authVersion) }
        guard auth["dateEncoding"] == .string("reference-seconds-ieee754-hex") else { throw NativeSeedFailure.pristine(.authDates) }
        let authPayload = try pristineObject(auth["payload"], .authPayload)
        guard authPayload.values.allSatisfy(empty) else { throw NativeSeedFailure.pristine(.authRows) }
        let oauth = try pristineRoot(snapshot, .oauthLedger, .oauthEnvelope)
        guard Set(oauth.keys) == ["format", "version", "dateEncoding", "signingKeyDerivation", "jwtSecret", "businessState"] else {
            throw NativeSeedFailure.pristine(.oauthKeys)
        }
        guard oauth["format"] == .string("raft.oauth-ledger") else { throw NativeSeedFailure.pristine(.oauthFormat) }
        guard oauth["version"] == .integer(1) else { throw NativeSeedFailure.pristine(.oauthVersion) }
        guard oauth["dateEncoding"] == .string("foundation-reference-date-ieee754-binary64-hex") else {
            throw NativeSeedFailure.pristine(.oauthDates)
        }
        guard oauth["signingKeyDerivation"] == .string("raft-oidc-v1/hkdf-sha256/id-token-es256-private/p256-v1") else {
            throw NativeSeedFailure.pristine(.oauthDerivation)
        }
        guard oauth["jwtSecret"] == .string(jwtSecret) else { throw NativeSeedFailure.pristine(.oauthKey) }
        let oauthBusiness = try pristineObject(oauth["businessState"], .oauthBusiness)
        guard oauthBusiness.values.allSatisfy(empty) else { throw NativeSeedFailure.pristine(.oauthRows) }
        let agents = try pristineObject(pristineRoot(snapshot, .agentsRuntime, .agentsEnvelope)["payload"], .agentsPayload)
        let execution = try pristineObject(agents["execution"], .executionObject)
        guard execution.values.allSatisfy(empty) else { throw NativeSeedFailure.pristine(.executionRows) }
        // AgentsRuntimeStore.State's sole default flag, encoded by FlagRow. This
        // is production policy metadata; every execution/business table stays empty.
        let defaultFlags: JSONValue = .object(["attachment_comments_v0": .object([
            "key": .string("attachment_comments_v0"), "enabled": .bool(true),
            "killSwitch": .bool(false), "defaultEnabled": .bool(true),
        ])])
        guard agents["featureFlagRecords"] == defaultFlags else { throw NativeSeedFailure.pristine(.defaultFlags) }
        guard agents.filter({ $0.key != "execution" && $0.key != "featureFlagRecords" }).values.allSatisfy(empty) else {
            throw NativeSeedFailure.pristine(.agentRows)
        }
        let machines = try pristineObject(pristineRoot(snapshot, .machinesAndComputers, .machinesEnvelope)["payload"], .machinesPayload)
        guard machines["latestComputerRelease"] == .null else { throw NativeSeedFailure.pristine(.machineRelease) }
        guard machines.filter({ $0.key != "latestComputerRelease" }).values.allSatisfy(empty) else {
            throw NativeSeedFailure.pristine(.machineRows)
        }
        let messages = try pristineObject(pristineRoot(snapshot, .messagesAndThreads, .messagesEnvelope)["payload"], .messagesPayload)
        let tasks = try pristineObject(pristineRoot(snapshot, .tasksAndReminders, .tasksEnvelope)["business"], .tasksBusiness)
        guard messages["humanMessageRows"] == .array([]) else { throw NativeSeedFailure.pristine(.messageRows) }
        guard tasks["taskRecords"] == .array([]) else { throw NativeSeedFailure.pristine(.taskRows) }
    }
    static func seeded(_ after: NativeSeedSnapshot, baseline: NativeSeedSnapshot, facts: NativeSeedFacts,
                       passwordHash: String, began: Date, ended: Date) throws {
        guard Set(after.values.keys) == (try expectedKeys()) else { throw NativeSeedFailure.bindings }
        for (key, original) in baseline.values where key.domain != .authProfiles && key.domain != .oauthLedger {
            // Full codec equality retains all twelve untouched payloads, including
            // native notifications, machines, execution and empty message/task owners.
            guard after.values[key] == original else { throw NativeSeedFailure.allowlist }
        }
        var auth = try root(after, .authProfiles)
        var payload = try object(auth["payload"])
        let accounts = try object(payload["accounts"])
        let analytics = try object(payload["analyticsIds"])
        guard Set(accounts.keys) == Set(facts.people.map(\.email)),
              Set(analytics.keys) == Set(facts.people.map(\.id)) else { throw NativeSeedFailure.allowlist }
        for person in facts.people {
            let row = try object(accounts[person.email])
            let passwordAt = try timestamp(row["passwordCredentialEstablishedAt"], began: began, ended: ended)
            let profileAt = try timestamp(row["profileSetupCompletedAt"], began: began, ended: ended)
            var expected: [String: JSONValue] = [
                "id": .string(person.id), "email": .string(person.email), "passwordHash": .string(passwordHash),
                "passwordCredentialEstablishedAt": passwordAt, "profileSetupCompletedAt": profileAt,
                "name": .string(person.handle), "emailVerified": .bool(true),
                "preferredTranslationMode": .string("off"), "autoTranslationEnabled": .bool(false),
                "preferredTranslationDisplay": .string("translated"),
            ]
            for key in ["displayLanguage", "displayName", "profileSetupSuggestedHandle", "profileSetupProvider", "avatarUrl",
                        "description", "shareUsageData", "stagingSelfAccountCapabilityHash", "retiredAt", "preferredLanguage",
                        "preferredTimezone", "preferredTimeFormat", "preferredMessageBodyFontSize", "referralSource",
                        "referralSourceOther", "referralSourceSkippedAt", "signupRole", "signupSurveyCompletedAt",
                        "firstOnboardingCompletedAt", "firstOnboardingCompletedSessionFamilyId"] { expected[key] = .null }
            guard row == expected, case .string(let analyticsID) = analytics[person.id],
                  UUID(uuidString: analyticsID) != nil else { throw NativeSeedFailure.allowlist }
        }
        payload["accounts"] = .object([:]); payload["analyticsIds"] = .object([:])
        auth["payload"] = .object(payload)
        guard JSONValue.object(auth) == (try rootValue(baseline, .authProfiles)) else { throw NativeSeedFailure.allowlist }
        var oauth = try root(after, .oauthLedger)
        var business = try object(oauth["businessState"])
        let server: JSONValue = .object([
            "id": .string(facts.serverID), "slug": .string(facts.slug), "name": .string(facts.serverName),
            "ownerId": .string(facts.ownerID), "avatarUrl": .null, "plan": .string("free"), "deleted": .bool(false),
            "productAnalyticsEnabled": .bool(true), "translationEnabled": .bool(false),
            "publiclyVisible": .bool(false), "publicGuestJoinEnabled": .bool(false),
        ])
        guard business["servers"] == .object([facts.serverID: server]),
              business["members"] == .object(["\(facts.serverID)\n\(facts.ownerID)": .string("owner"),
                                               "\(facts.serverID)\n\(facts.memberID)": .string("member")]) else {
            throw NativeSeedFailure.allowlist
        }
        business["servers"] = .object([:]); business["members"] = .object([:])
        oauth["businessState"] = .object(business)
        guard JSONValue.object(oauth) == (try rootValue(baseline, .oauthLedger)) else { throw NativeSeedFailure.allowlist }
    }
    private static func rootValue(_ snapshot: NativeSeedSnapshot, _ domain: DurableDomain) throws -> JSONValue {
        .object(try root(snapshot, domain))
    }
    private static func timestamp(_ value: JSONValue?, began: Date, ended: Date) throws -> JSONValue {
        guard case .string(let hex) = value, !hex.isEmpty, hex.utf8.count <= 16,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let bits = UInt64(hex, radix: 16) else { throw NativeSeedFailure.allowlist }
        let seconds = Double(bitPattern: bits)
        guard seconds.isFinite, seconds >= began.timeIntervalSinceReferenceDate,
              seconds <= ended.timeIntervalSinceReferenceDate else { throw NativeSeedFailure.allowlist }
        return .string(hex)
    }
}

private struct NativeSeedReceipt: Encodable {
    let kind: String
    let runID: String
    let serverID: String
    let slug: String
    let ownerID: String
    let memberID: String
    let emails: [String]
    let ownerPayloads: Int
    let revision: Int64
    let dueUnclaimedOutboxEmpty: Bool
    let totalOutboxZeroRequiresLeadPSQL: Bool
}
