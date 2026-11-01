import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AppConfigFixture {
    let accounts: EmailLoginDirectory
    let agentA: String
    let agentB: String
    let writeA: String
    let readA: String
    let writeB: String
}

private func makeAppConfigFixture(suffix: String) -> AppConfigFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 110_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 120_000 + number)
    accounts.addAccount(id: ownerId, email: "app-config-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "app-config-\(suffix)", name: "App Config API", ownerId: ownerId)
    let agentA = accounts.oauth.createAgent(serverId: serverId, name: "ConfigA-\(suffix)")
    let agentB = accounts.oauth.createAgent(serverId: serverId, name: "ConfigB-\(suffix)")
    let writeA = accounts.mintAgentCredential(agentId: agentA, scopes: ["read", "tasks"], name: "app-config-write-a-\(suffix)")
    let readA = accounts.mintAgentCredential(agentId: agentA, scopes: ["read"], name: "app-config-read-a-\(suffix)")
    let writeB = accounts.mintAgentCredential(agentId: agentB, scopes: ["read", "tasks"], name: "app-config-write-b-\(suffix)")
    return AppConfigFixture(accounts: accounts, agentA: agentA, agentB: agentB, writeA: writeA, readA: readA, writeB: writeB)
}

private func appConfigRead(_ client: any Client, key: String, appId: String = "system.cleaner") async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[HTTPField.Name("X-Raft-Client")!] = "cli"
    let response = try await client.get(URI(string: "/internal/agent-api/apps/\(appId)/config"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func appConfigPatch(
    _ client: any Client,
    key: String,
    body: String,
    appId: String = "system.cleaner"
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Raft-Client")!] = "cli"
    let response = try await client.send(.patch, headers: headers, to: "/internal/agent-api/apps/\(appId)/config") { request in
        request.body = .init(string: body)
    }
    let parsed = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, parsed)
}

@Test func agentAppConfigIsCredentialBoundAndCASafe() async throws {
    let fixture = makeAppConfigFixture(suffix: "781")
    let initialExpected: NSDictionary = [
        "appId": "system.cleaner",
        "revision": 0,
        "schema": [
            "enabled": ["type": "boolean"],
            "threshold_bytes": ["type": "integer", "minimum": 4096, "maximum": 1_073_741_824],
            "interval_seconds": ["type": "integer", "minimum": 900, "maximum": 604_800],
        ],
        "defaults": ["enabled": true, "threshold_bytes": 65536, "interval_seconds": 3600],
        "overrides": [:],
        "effective": ["enabled": true, "threshold_bytes": 65536, "interval_seconds": 3600],
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let initial = try await appConfigRead(client, key: fixture.writeA)
            #expect(initial.status == .ok)
            #expect(initial.body as NSDictionary == initialExpected)

            let denied = try await appConfigPatch(
                client,
                key: fixture.readA,
                body: "{\"expectedRevision\":0,\"set\":{\"enabled\":false},\"unset\":[]}"
            )
            #expect(denied.status == .forbidden)

            let updated = try await appConfigPatch(
                client,
                key: fixture.writeA,
                body: "{\"expectedRevision\":0,\"set\":{\"enabled\":false,\"threshold_bytes\":131072},\"unset\":[]}"
            )
            #expect(updated.status == .ok)
            #expect(updated.body["revision"] as? Int == 1)
            #expect(updated.body["overrides"] as? NSDictionary == ["enabled": false, "threshold_bytes": 131_072] as NSDictionary)
            #expect(updated.body["apply"] == nil)
            #expect(updated.body["effective"] as? NSDictionary == ["enabled": false, "threshold_bytes": 131_072, "interval_seconds": 3600] as NSDictionary)

            let stale = try await appConfigPatch(
                client,
                key: fixture.writeA,
                body: "{\"expectedRevision\":0,\"set\":{\"enabled\":true},\"unset\":[]}"
            )
            #expect(stale.status == .conflict)
            #expect(stale.body as NSDictionary == [
                "error": "Config revision is stale; current revision is 1",
                "errorCode": "RAP_APP_CONFIG_REVISION_STALE",
                "currentRevision": 1,
            ] as NSDictionary)

            let otherOwner = try await appConfigRead(client, key: fixture.writeB)
            #expect(otherOwner.status == .ok)
            #expect(otherOwner.body["revision"] as? Int == 0)
            #expect(otherOwner.body["overrides"] as? NSDictionary == [:])
            #expect((otherOwner.body["effective"] as? [String: Any])?["enabled"] as? Bool == true)

            let unknown = try await appConfigRead(client, key: fixture.writeA, appId: "system.unknown")
            #expect(unknown.status == .notFound)
            #expect(unknown.body["errorCode"] as? String == "RAP_APP_CONFIG_APP_UNKNOWN")
        }
    }
}
