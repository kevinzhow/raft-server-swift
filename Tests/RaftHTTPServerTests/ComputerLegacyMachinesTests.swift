import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct LegacyMachineFixture {
    let accounts = EmailLoginDirectory()
    let serverId: String
    let ownerId: String
    let slug: String

    init(serverId: String, ownerId: String, slug: String) {
        self.serverId = serverId
        self.ownerId = ownerId
        self.slug = slug
        accounts.addAccount(id: ownerId, email: "\(slug)-owner@legacy.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Legacy \(slug)", ownerId: ownerId)
    }

    func headers() -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
        return headers
    }

    func get(_ client: any Client, slug: String? = nil, includeAll: Bool = false) async throws -> ClientResponse {
        var path = "/api/computer/legacy-machines"
        var query: [String] = []
        if let slug { query.append("serverSlug=\(slug)") }
        if includeAll { query.append("includeAll=1") }
        if !query.isEmpty { path += "?" + query.joined(separator: "&") }
        return try await client.get(URI(string: path), headers: headers())
    }
}

@Test func legacyMachinesGateAuthAndCloakSymmetry() async throws {
    let fixture = LegacyMachineFixture(serverId: "33333333-3333-4333-8333-000001093001", ownerId: "11111111-1111-4111-8111-000001093001", slug: "legacy-cloak")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
        try await app.testing { client in
            fixture.accounts.setComputerAttachEnabledForTesting(false)
            let gated = try await fixture.get(client, slug: "anything")
            #expect(gated.status == .notFound)
            fixture.accounts.setComputerAttachEnabledForTesting(nil)

            let unauthenticated = try await client.get(URI(string: "/api/computer/legacy-machines?serverSlug=anything"))
            #expect(unauthenticated.status == .unauthorized)
            #expect((try JSONSerialization.jsonObject(with: Data((unauthenticated.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "auth_required")

            let missing = try await client.get(URI(string: "/api/computer/legacy-machines"), headers: fixture.headers())
            #expect(missing.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((missing.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "server_slug_required")

            let unknown = try await fixture.get(client, slug: "nonexistent-slug", includeAll: true)
            #expect(unknown.status == .forbidden)
            let unknownBody = unknown.body.string

            let other = LegacyMachineFixture(serverId: "33333333-3333-4333-8333-000001093002", ownerId: "11111111-1111-4111-8111-000001093002", slug: "legacy-other")
            fixture.accounts.oauth.addOwnedServer(id: other.serverId, slug: other.slug, name: "Other", ownerId: other.ownerId)
            let nonMember = try await fixture.get(client, slug: other.slug, includeAll: true)
            #expect(nonMember.status == .forbidden)

            let doomed = LegacyMachineFixture(serverId: "33333333-3333-4333-8333-000001093003", ownerId: "11111111-1111-4111-8111-000001093003", slug: "legacy-deleted")
            fixture.accounts.oauth.addOwnedServer(id: doomed.serverId, slug: doomed.slug, name: "Doomed", ownerId: doomed.ownerId)
            fixture.accounts.oauth.deleteServer(id: doomed.serverId)
            let deleted = try await fixture.get(client, slug: doomed.slug, includeAll: true)
            #expect(deleted.status == .forbidden)
            #expect(deleted.body.string == unknownBody)
            #expect(nonMember.body.string == unknownBody)
            #expect((try JSONSerialization.jsonObject(with: Data((unknownBody ?? "").utf8)) as? [String: Any])?["code"] as? String == "not_authorized")
        }
    }
}

@Test func legacyMachinesHappyPathNullFingerprintAndMigratedRows() async throws {
    let fixture = LegacyMachineFixture(serverId: "33333333-3333-4333-8333-000001093011", ownerId: "11111111-1111-4111-8111-000001093011", slug: "legacy-roster")
    let accounts = fixture.accounts
    let alpha = accounts.registerMachineWithKeyForTesting(serverId: fixture.serverId, userId: fixture.ownerId, name: "alpha")
    let beta = accounts.registerMachineWithKeyForTesting(serverId: fixture.serverId, userId: fixture.ownerId, name: "beta")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let response = try await fixture.get(client, slug: fixture.slug)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let entries = body["entries"] as? [[String: Any]] ?? []
            #expect(entries.count == 2)
            let byName = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, [String: Any])? in
                guard let name = entry["machineName"] as? String else { return nil }
                return (name, entry)
            })
            #expect(byName["alpha"]?["daemonId"] as? String == alpha.id)
            #expect(byName["alpha"]?["apiKeyFingerprint"] as? String == alpha.fingerprint)
            #expect(byName["alpha"]?["hasFingerprint"] as? Bool == true)
            #expect((byName["alpha"]?["apiKeyFingerprint"] as? String)?.count == 16)
            #expect(byName["beta"]?["daemonId"] as? String == beta.id)
            #expect(byName["beta"]?["apiKeyFingerprint"] as? String == beta.fingerprint)

            accounts.nullMachineFingerprintForTesting(machineId: beta.id)
            let filtered = try await fixture.get(client, slug: fixture.slug)
            let filteredEntries = (try JSONSerialization.jsonObject(with: Data((filtered.body.string ?? "").utf8)) as? [String: Any])?["entries"] as? [[String: Any]] ?? []
            #expect(filteredEntries.count == 1)

            let all = try await fixture.get(client, slug: fixture.slug, includeAll: true)
            let allText = all.body.string ?? ""
            #expect(allText.contains("apiKeyFingerprint") == false)
            #expect(allText.contains(alpha.fingerprint) == false)
            let allEntries = (try JSONSerialization.jsonObject(with: Data(allText.utf8)) as? [String: Any])?["entries"] as? [[String: Any]] ?? []
            #expect(allEntries.count == 2)
            let allNames = Dictionary(uniqueKeysWithValues: allEntries.compactMap { entry -> (String, [String: Any])? in
                guard let name = entry["machineName"] as? String else { return nil }
                return (name, entry)
            })
            #expect(allNames["alpha"]?["hasFingerprint"] as? Bool == true)
            #expect(allNames["beta"]?["hasFingerprint"] as? Bool == false)
            #expect(allNames["alpha"]?["apiKeyFingerprint"] == nil)
            #expect(allNames["beta"]?["apiKeyFingerprint"] == nil)

            let migratedAt = Date(timeIntervalSince1970: 1_700_000_000)
            accounts.markMachineLegacyMigratedForTesting(machineId: alpha.id, at: migratedAt)
            let migrated = try await fixture.get(client, slug: fixture.slug)
            let migratedEntries = (try JSONSerialization.jsonObject(with: Data((migrated.body.string ?? "").utf8)) as? [String: Any])?["entries"] as? [[String: Any]] ?? []
            let sortedNames = migratedEntries.compactMap { $0["machineName"] as? String }
            #expect(sortedNames == ["alpha"])
            #expect(migratedEntries[0]["legacyKeyMigratedAt"] as? String != nil)
        }
    }
}

@Test func legacyMachinesNeverLeakCredentialsAndAreCrossUserIsolated() async throws {
    let fixture = LegacyMachineFixture(serverId: "33333333-3333-4333-8333-000001093021", ownerId: "11111111-1111-4111-8111-000001093021", slug: "legacy-secret")
    let accounts = fixture.accounts
    let reg = accounts.registerMachineWithKeyForTesting(serverId: fixture.serverId, userId: fixture.ownerId, name: "alpha")
    let memberId = "11111111-1111-4111-8111-000001093022"
    accounts.addAccount(id: memberId, email: "legacy-member@legacy.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addMember(serverId: fixture.serverId, userId: memberId, role: "member")
    let memberMachine = accounts.registerMachineWithKeyForTesting(serverId: fixture.serverId, userId: memberId, name: "member-daemon")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let ownerResponse = try await fixture.get(client, slug: fixture.slug)
            let ownerText = ownerResponse.body.string ?? ""
            #expect(ownerText.contains("apiKeyHash") == false)
            #expect(ownerText.contains("apiKeyPrefix") == false)
            #expect(ownerText.contains("api_key_hash") == false)
            #expect(ownerText.contains(reg.apiKey) == false)
            #expect(ownerText.contains(String(reg.apiKey.prefix(20))) == false)

            var memberHeaders = HTTPFields()
            memberHeaders[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: memberId))"
            let memberResponse = try await client.get(URI(string: "/api/computer/legacy-machines?serverSlug=\(fixture.slug)"), headers: memberHeaders)
            #expect(memberResponse.status == .ok)
            let memberEntries = (try JSONSerialization.jsonObject(with: Data((memberResponse.body.string ?? "").utf8)) as? [String: Any])?["entries"] as? [[String: Any]] ?? []
            #expect(memberEntries.count == 1)
            #expect(memberEntries[0]["machineName"] as? String == "member-daemon")
            #expect(memberEntries[0]["daemonId"] as? String == memberMachine.id)
        }
    }
}
