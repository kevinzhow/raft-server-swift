import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func externalDiagnosticsRefusesMembersAndManagedAgents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111617"
    let memberId = "11111111-1111-4111-8111-111111111618"
    let serverId = "33333333-3333-4333-8333-333333333663"
    accounts.addAccount(id: ownerId, email: "diagnostics-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "diagnostics-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "diagnostics", name: "Diagnostics", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let external = accounts.oauth.createAgent(serverId: serverId, name: "diag-external", creatorUserId: ownerId, runtime: "external")
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "diag-managed", creatorUserId: ownerId)
    let missing = UUID().uuidString.lowercased()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("diagnostics-owner@slock.test")
            let memberToken = try await login("diagnostics-member@slock.test")
            #expect(try await client.send(.get, headers: headers(memberToken), to: "/api/agents/\(external)/external-diagnostics").status == .forbidden)
            let managedResponse = try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(managed)/external-diagnostics")
            #expect(managedResponse.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((managedResponse.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "agent_not_external")
            #expect(try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(missing)/external-diagnostics").status == .notFound)
            #expect(try await client.send(.get, headers: headers(ownerToken), to: "/api/agents/\(external)/external-diagnostics").status == .ok)
        }
    }
}

@Test func externalDiagnosticsProjectsPresencePushAndCursorFactsWithoutSecrets() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111619"
    let serverId = "33333333-3333-4333-8333-333333333664"
    accounts.addAccount(id: ownerId, email: "diagnostics-facts@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "diagnostics-facts", name: "Diagnostics Facts", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "diag-facts", creatorUserId: ownerId, runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "diag-facts")
    let adoptedAt = ISO8601DateFormatter().date(from: "2026-09-01T10:00:00Z")!
    let pulledAt = ISO8601DateFormatter().date(from: "2026-09-02T11:00:00Z")!
    accounts.setAgentStatusProtocolAdoptedForTesting(agentId: agent, at: adoptedAt)
    accounts.setAgentCursorPullStateForTesting(agentId: agent, lastPulledAt: pulledAt, pendingAcks: 3)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"diagnostics-facts@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(key)"
            #expect(try await client.get("/internal/agent-api", headers: agentHeaders).status == .ok)

            var webhookHeaders = agentHeaders
            webhookHeaders[.contentType] = "application/json"
            let webhook = try await client.send(.put, headers: webhookHeaders, to: "/internal/agent-api/push-webhook") { request in
                request.body = .init(string: "{\"url\":\"https://receiver.example.com/raft/inbox?token=path-secret-123\",\"secret\":\"Q2hvb3NlLWEtcmFuZG9tLXNlY3JldC1vZi0zMi1ieXRlcw_x\"}")
            }
            #expect(webhook.status == .ok)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.get("/api/agents/\(agent)/external-diagnostics", headers: headers)
            #expect(response.status == .ok)
            let raw = response.body.string ?? ""
            let body = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            #expect(body?["agentId"] as? String == agent)
            #expect(body?["runtime"] as? String == "external")
            #expect(body?["provider"] is NSNull)
            let presence = body?["presence"] as? [String: Any]
            #expect(presence?["lastSeenAt"] is String)
            #expect(presence?["online"] as? Bool == true)
            #expect(presence?["onlineWindowMs"] as? Int == 120000)
            let status = body?["status"] as? [String: Any]
            #expect(status?["activity"] as? String == "idle")
            #expect(status?["statusProtocolAdoptedAt"] is String)
            let push = body?["push"] as? [String: Any]
            #expect(push?["registered"] as? Bool == true)
            #expect(push?["enabled"] as? Bool == true)
            #expect(push?["endpointHost"] as? String == "receiver.example.com")
            #expect(push?["consecutiveFailures"] as? Int == 0)
            #expect(push?["lastDeliveryAt"] is NSNull)
            let events = body?["events"] as? [String: Any]
            #expect(events?["lastCursorPullAt"] is String)
            #expect(events?["pendingCursorAckCount"] as? Int == 3)
            let connections = body?["connections"] as? [[String: Any]] ?? []
            #expect(connections.first?["provider"] as? String == "github")
            #expect(connections.first?["state"] as? String == "not_applicable")
            #expect(!raw.contains("/raft/inbox"))
            #expect(!raw.contains("path-secret-123"))
            #expect(!raw.contains("Q2hvb3NlLWEtcmFuZG9t"))
            #expect(!raw.contains("sk_agent_"))
        }
    }
}

@Test func externalDiagnosticsReportsProviderProvisioningAndUnavailableConnections() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111620"
    let serverId = "33333333-3333-4333-8333-333333333665"
    accounts.addAccount(id: ownerId, email: "diagnostics-provider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "diagnostics-provider", name: "Diagnostics Provider", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "diag-provider", creatorUserId: ownerId, runtime: "external")
    accounts.setHostedRuntimeStateForTesting(agentId: agent, state: "active")
    let activatedAt = ISO8601DateFormatter().date(from: "2026-09-03T00:00:00Z")!
    accounts.setAgentProviderPositionForTesting(
        agentId: agent,
        state: "active",
        providerAgentId: "ap_agent_1",
        activatedAt: activatedAt
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"diagnostics-provider@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.get("/api/agents/\(agent)/external-diagnostics", headers: headers)
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
            let provider = body?["provider"] as? [String: Any]
            #expect(provider?["kind"] as? String == "antiproton")
            #expect(provider?["state"] as? String == "active")
            #expect(provider?["providerAgentId"] as? String == "ap_agent_1")
            #expect(provider?["syncPending"] as? Bool == false)
            #expect(provider?["lastErrorCode"] is NSNull)
            #expect(provider?["lastErrorAt"] is NSNull)
            #expect(provider?["activatedAt"] is String)

            let presence = body?["presence"] as? [String: Any]
            #expect(presence?["lastSeenAt"] is NSNull)
            #expect(presence?["online"] as? Bool == false)

            let push = body?["push"] as? [String: Any]
            #expect(push?["registered"] as? Bool == false)
            #expect(push?["enabled"] as? Bool == false)
            #expect(push?["endpointHost"] is NSNull)
            #expect(push?["disabledReason"] is NSNull)
            #expect(push?["disabledAt"] is NSNull)
            #expect(push?["lastAttemptAt"] is NSNull)
            #expect(push?["lastError"] is NSNull)
            #expect(push?["nextAttemptAt"] is NSNull)

            let events = body?["events"] as? [String: Any]
            #expect(events?["lastCursorPullAt"] is NSNull)
            #expect(events?["pendingCursorAckCount"] as? Int == 0)

            let connections = body?["connections"] as? [[String: Any]] ?? []
            #expect(connections.count == 1)
            #expect(connections.first?["provider"] as? String == "github")
            #expect(connections.first?["state"] as? String == "unavailable")
            #expect(connections.first?["reason"] is String)
        }
    }
}
