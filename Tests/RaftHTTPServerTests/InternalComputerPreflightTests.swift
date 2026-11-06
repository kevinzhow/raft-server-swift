import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct PreflightFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerToken: String
    let computerKey: String
    let agentKey: String
}

private func makePreflightFixture() -> PreflightFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111626"
    let serverId = "33333333-3333-4333-8333-333333333668"
    let serverSlug = "preflight-co"
    accounts.addAccount(id: ownerId, email: "preflight-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: serverSlug, name: "Preflight Co", ownerId: ownerId)
    let computer = try? accounts.computersFleet.attachComputer(
        authorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))",
        request: ComputerAttachRequest(serverSlug: serverSlug, name: "preflight-computer")
    )
    let computerKey = computer?.apiKey ?? ""
    let agentKey = accounts.mintAgentCredential(
        agentId: "11111111-1111-4111-8111-111111111627",
        scopes: ["read"],
        name: "preflight-agent"
    )
    return PreflightFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: serverSlug,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        computerKey: computerKey,
        agentKey: agentKey
    )
}

private func preflightPost(
    _ client: any Client,
    key: String?,
    path: String = "/internal/computer/preflight"
) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let key { headers[.authorization] = "Bearer \(key)" }
    let response = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: "{}")
    }
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, json, raw)
}

@Test func preflightSurfaceIsRegistryDerivedAndSideEffectFree() async throws {
    let f = makePreflightFixture()
    let credentialsBefore = f.accounts.agentCredentialInventoryCountForTesting()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await preflightPost(client, key: f.computerKey)
            #expect(first.status == .ok)
            #expect(first.body["ok"] as? Bool == true)
            let version = first.body["surfaceVersion"] as? String ?? ""
            #expect(!version.isEmpty)

            let principal = first.body["principal"] as? [String: Any]
            #expect(principal?["kind"] as? String == "computer")

            let claimed = (first.body["claimedPrefixes"] as? [String]) ?? []
            #expect(claimed.contains("/internal/computer/"))

            let principals = (first.body["registeredPrincipals"] as? [String]) ?? []
            #expect(principals == principals.sorted(), "principals are a sorted unique set")
            #expect(Set(principals).count == principals.count)
            #expect(principals.contains("sk_computer"))
            #expect(principals.contains("sk_agent"))

            let surface = (first.body["computerSurface"] as? [[String: Any]]) ?? []
            #expect(!surface.isEmpty)
            for entry in surface {
                #expect((entry["path"] as? String)?.hasPrefix("/internal/computer/") == true)
                #expect(entry["principal"] as? String == "sk_computer")
                #expect(!((entry["method"] as? String) ?? "").isEmpty)
                #expect(!((entry["path"] as? String) ?? "").contains("*"), "the unregistered-path catch-all is not a claimed surface")
            }
            let keys = surface.compactMap { entry -> String? in
                guard let method = entry["method"] as? String, let path = entry["path"] as? String else { return nil }
                return "\(method) \(path)"
            }
            #expect(Set(keys).count == keys.count, "no duplicate surface rows")
            #expect(keys.contains("POST /internal/computer/preflight"), "the preflight route describes itself")
            #expect(keys.contains("GET /internal/computer/runners"))
            #expect(keys.contains("POST /internal/computer/runners/:agentId/credentials"))

            // Read-only: the projection mints no credential and writes nothing.
            let second = try await preflightPost(client, key: f.computerKey)
            #expect(second.status == .ok)
            #expect(second.raw == first.raw, "the projection is stable between calls")
            #expect(f.accounts.agentCredentialInventoryCountForTesting() == credentialsBefore)
        }
    }
}

@Test func preflightWrongPrincipalFailsClosed() async throws {
    let f = makePreflightFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let agent = try await preflightPost(client, key: f.agentKey)
            #expect(agent.status == .unauthorized)
            #expect(agent.body["code"] as? String == "invalid_principal")

            let missing = try await preflightPost(client, key: nil)
            #expect(missing.status == .unauthorized)
            #expect(missing.body["code"] as? String == "auth_required")
        }
    }
}

@Test func preflightUnregisteredSiblingFailsClosed() async throws {
    let f = makePreflightFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sibling = try await preflightPost(client, key: f.computerKey, path: "/internal/computer/preflight-not-registered")
            #expect(sibling.status == .unauthorized)
            #expect(sibling.body["code"] as? String == "auth_policy_unregistered_path")

            // A live surface still answers normally, and the catch-all does not
            // shadow it.
            let live = try await preflightPost(client, key: f.computerKey)
            #expect(live.status == .ok)
        }
    }
}
