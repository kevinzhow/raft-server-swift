import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct LegacyRosterFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerId: String
    let ownerToken: String
    let strangerToken: String
}

private func makeLegacyRosterFixture(_ suffix: String) -> LegacyRosterFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001380\(suffix)"
    let strangerId = "11111111-1111-4111-8111-000001381\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001380\(suffix)"
    let serverSlug = "roster-\(suffix)"
    accounts.addAccount(id: ownerId, email: "roster-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: strangerId, email: "roster-stranger-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: strangerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: serverSlug, name: "Roster Co \(suffix)", ownerId: ownerId)
    return LegacyRosterFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: serverSlug,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        strangerToken: accounts.mintAccessTokenForTesting(userId: strangerId)
    )
}

private func legacyRosterGet(
    _ client: any Client,
    token: String?,
    query: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    var headers = HTTPFields()
    if let token { headers[.authorization] = "Bearer \(token)" }
    let response = try await client.get(URI(string: "/api/computer/legacy-machines\(query)"), headers: headers)
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, json, raw)
}

@Test func legacyMachinesGateAuthAndCloak() async throws {
    let f = makeLegacyRosterFixture("901")
    f.accounts.setComputerAttachEnabledForTesting(false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let disabled = try await legacyRosterGet(client, token: f.ownerToken, query: "?serverSlug=\(f.serverSlug)")
            #expect(disabled.status == .notFound)
        }
    }
    f.accounts.setComputerAttachEnabledForTesting(nil)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unauthenticated = try await legacyRosterGet(client, token: nil, query: "?serverSlug=\(f.serverSlug)")
            #expect(unauthenticated.status == .unauthorized)
            #expect(unauthenticated.body["code"] as? String == "auth_required")

            let missingSlug = try await legacyRosterGet(client, token: f.ownerToken, query: "")
            #expect(missingSlug.status == .badRequest)
            #expect(missingSlug.body["code"] as? String == "server_slug_required")

            let unknown = try await legacyRosterGet(client, token: f.ownerToken, query: "?serverSlug=\(UUID().uuidString)")
            let nonMember = try await legacyRosterGet(client, token: f.strangerToken, query: "?serverSlug=\(f.serverSlug)")
            #expect(unknown.status == .forbidden)
            #expect(nonMember.status == unknown.status)
            #expect(unknown.raw == nonMember.raw, "unknown and non-member servers answer identically")
            #expect(unknown.body["code"] as? String == "not_authorized")
        }
    }
}

@Test func legacyMachinesRosterScopesToTheCallerAndHidesSecrets() async throws {
    let f = makeLegacyRosterFixture("902")
    let alpha = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "alpha")
    let beta = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "beta")
    _ = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: "11111111-1111-4111-8111-000001381902", name: "stranger-machine")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let result = try await legacyRosterGet(client, token: f.ownerToken, query: "?serverSlug=\(f.serverSlug)")
            #expect(result.status == .ok)
            let entries = (result.body["entries"] as? [[String: Any]]) ?? []
            #expect(entries.compactMap { $0["machineName"] as? String } == ["alpha", "beta"], "caller-scoped machines only")
            let byName = Dictionary(uniqueKeysWithValues: entries.compactMap { row -> (String, [String: Any])? in
                guard let name = row["machineName"] as? String else { return nil }
                return (name, row)
            })
            #expect(byName["alpha"]?["daemonId"] as? String == alpha.id)
            #expect(byName["alpha"]?["apiKeyFingerprint"] as? String == alpha.fingerprint)
            #expect(byName["alpha"]?["hasFingerprint"] as? Bool == true)
            #expect(byName["alpha"]?["hostname"] == nil || byName["alpha"]?["hostname"] is NSNull)
            #expect(byName["alpha"]?["lastSeenAt"] == nil || byName["alpha"]?["lastSeenAt"] is NSNull)
            #expect(byName["alpha"]?["legacyKeyMigratedAt"] == nil || byName["alpha"]?["legacyKeyMigratedAt"] is NSNull)
            #expect(byName["beta"]?["apiKeyFingerprint"] as? String == beta.fingerprint)

            #expect(!result.raw.contains("apiKeyHash"))
            #expect(!result.raw.contains("apiKeyPrefix"))
            #expect(!result.raw.contains(alpha.apiKey))
            #expect(!result.raw.contains(beta.apiKey))
        }
    }
}

@Test func legacyMachinesIncludeAllKeepsFingerprintsOutOfTheBody() async throws {
    let f = makeLegacyRosterFixture("903")
    let withFingerprint = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "has-fp")
    let withoutFingerprint = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "null-fp")
    f.accounts.nullMachineFingerprintForTesting(machineId: withoutFingerprint.id)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let defaultRoster = try await legacyRosterGet(client, token: f.ownerToken, query: "?serverSlug=\(f.serverSlug)")
            let defaultEntries = (defaultRoster.body["entries"] as? [[String: Any]]) ?? []
            #expect(defaultEntries.compactMap { $0["machineName"] as? String } == ["has-fp"], "pre-handshake rows stay out by default")

            let explicitDefault = try await legacyRosterGet(client, token: f.ownerToken, query: "?serverSlug=\(f.serverSlug)&includeAll=0")
            #expect(((explicitDefault.body["entries"] as? [[String: Any]]) ?? []).compactMap { $0["machineName"] as? String } == ["has-fp"], "includeAll=0 means the default fingerprint-only roster")

            let all = try await legacyRosterGet(client, token: f.ownerToken, query: "?serverSlug=\(f.serverSlug)&includeAll=1")
            #expect(all.status == .ok)
            #expect(!all.raw.contains("apiKeyFingerprint"), "includeAll omits the fingerprint key entirely")
            #expect(!all.raw.contains(withFingerprint.fingerprint))
            let entries = (all.body["entries"] as? [[String: Any]]) ?? []
            #expect(entries.compactMap { $0["machineName"] as? String } == ["has-fp", "null-fp"])
            let byName = Dictionary(uniqueKeysWithValues: entries.compactMap { row -> (String, [String: Any])? in
                guard let name = row["machineName"] as? String else { return nil }
                return (name, row)
            })
            #expect(byName["has-fp"]?["hasFingerprint"] as? Bool == true)
            #expect(byName["null-fp"]?["hasFingerprint"] as? Bool == false)
            #expect(byName["has-fp"]?["apiKeyFingerprint"] == nil)
        }
    }
}

@Test func legacyMachinesIncludeAlreadyAdoptedRows() async throws {
    let f = makeLegacyRosterFixture("904")
    let live = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "live")
    let migrated = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "already-adopted")
    let migratedAt = Date(timeIntervalSince1970: 1_790_000_000)
    f.accounts.markMachineLegacyMigratedForTesting(machineId: migrated.id, at: migratedAt)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let result = try await legacyRosterGet(client, token: f.ownerToken, query: "?serverSlug=\(f.serverSlug)")
            let entries = (result.body["entries"] as? [[String: Any]]) ?? []
            #expect(entries.compactMap { $0["machineName"] as? String } == ["already-adopted", "live"])
            let byName = Dictionary(uniqueKeysWithValues: entries.compactMap { row -> (String, [String: Any])? in
                guard let name = row["machineName"] as? String else { return nil }
                return (name, row)
            })
            #expect(byName["live"]?["legacyKeyMigratedAt"] == nil || byName["live"]?["legacyKeyMigratedAt"] is NSNull)
            #expect(byName["already-adopted"]?["legacyKeyMigratedAt"] as? String == formatter.string(from: migratedAt))
            #expect((byName["live"]?["daemonId"] as? String) == live.id)
            #expect((byName["already-adopted"]?["daemonId"] as? String) == migrated.id)
        }
    }
}
