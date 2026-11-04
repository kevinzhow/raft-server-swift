import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let dayMs: TimeInterval = 24 * 60 * 60

@Test func agentAppEventsListNewestFirstWithPagingExpiryAndPrivateVisibility() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001082001"
    let ownerId = "11111111-1111-4111-8111-000001082001"
    let creatorId = "11111111-1111-4111-8111-000001082002"
    let memberId = "11111111-1111-4111-8111-000001082003"
    for (id, email) in [(ownerId, "owner"), (creatorId, "creator"), (memberId, "member")] {
        accounts.addAccount(id: id, email: "\(email)@app-events.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "app-events", name: "App Events", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: creatorId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "EventBot", creatorUserId: creatorId, runtime: "claude")
    let otherAgent = accounts.oauth.createAgent(serverId: serverId, name: "OtherBot", creatorUserId: ownerId, runtime: "claude")
    let app = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Event App", clientId: "event-app",
        allowedScopes: ["agent:notification:write"]
    )
    let now = Date()
    let ids = (0..<3).map { _ in UUID().uuidString.lowercased() }
    for i in 0..<3 {
        accounts.oauth.seedAgentAppEventForTesting(
            id: ids[i], agentId: agent, clientRecordId: app.id, summary: "reminder \(i)",
            status: i == 2 ? "delivered" : "queued",
            expiresAt: i == 0 ? now.addingTimeInterval(-1000) : now.addingTimeInterval(dayMs),
            createdAt: now.addingTimeInterval(-Double(3 - i) * 60), payloadJSON: "{\"text\":\"payload \(i)\"}"
        )
    }
    let otherEvent = UUID().uuidString.lowercased()
    accounts.oauth.seedAgentAppEventForTesting(
        id: otherEvent, agentId: otherAgent, clientRecordId: app.id, summary: "owner agent only",
        status: "queued", expiresAt: now.addingTimeInterval(dayMs), createdAt: now
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
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
                var value = HTTPFields()
                value[.authorization] = "Bearer \(token)"
                value[HTTPField.Name("X-Server-Id")!] = serverId
                return value
            }
            let creatorHeaders = headers(try await login("creator@app-events.test"))
            let page1 = try await client.get(URI(string: "/api/integrations/agents/\(agent)/events?limit=2"), headers: creatorHeaders)
            #expect(page1.status == .ok)
            let body1 = try JSONSerialization.jsonObject(with: Data((page1.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let events1 = body1["events"] as? [[String: Any]] ?? []
            #expect(events1.map { $0["summary"] as? String } == ["reminder 2", "reminder 1"])
            #expect(events1.map { $0["status"] as? String } == ["delivered", "queued"])
            #expect((events1.first?["app"] as? [String: Any])?["clientKey"] as? String == "event-app")
            let cursor = try #require(body1["nextCursor"] as? String)
            let page2 = try await client.get(URI(string: "/api/integrations/agents/\(agent)/events?limit=2&before=\(cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor)"), headers: creatorHeaders)
            let body2 = try JSONSerialization.jsonObject(with: Data((page2.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let events2 = body2["events"] as? [[String: Any]] ?? []
            #expect(events2.map { [$0["summary"] as? String, $0["status"] as? String] } == [["reminder 0", "expired"]])
            #expect(body2["nextCursor"] == nil || body2["nextCursor"] is NSNull)

            let detail = try await client.get(URI(string: "/api/integrations/agents/\(agent)/events/\(ids[1])"), headers: creatorHeaders)
            #expect(detail.status == .ok)
            let detailBody = try JSONSerialization.jsonObject(with: Data((detail.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect((detailBody["payload"] as? [String: Any])?["text"] as? String == "payload 1")
            #expect((try await client.get(URI(string: "/api/integrations/agents/\(agent)/events/\(otherEvent)"), headers: creatorHeaders)).status == .notFound)
            #expect((try await client.get(URI(string: "/api/integrations/agents/\(agent)/events/\(UUID().uuidString)"), headers: creatorHeaders)).status == .notFound)
            #expect((try await client.get(URI(string: "/api/integrations/agents/\(agent)/events?limit=0"), headers: creatorHeaders)).status == .badRequest)
            #expect((try await client.get(URI(string: "/api/integrations/agents/\(agent)/events?before=nope"), headers: creatorHeaders)).status == .badRequest)

            let memberHeaders = headers(try await login("member@app-events.test"))
            #expect((try await client.get(URI(string: "/api/integrations/agents/\(agent)/events"), headers: memberHeaders)).status == .forbidden)
            let ownerHeaders = headers(try await login("owner@app-events.test"))
            #expect((try await client.get(URI(string: "/api/integrations/agents/\(agent)/events"), headers: ownerHeaders)).status == .ok)
        }
    }
}

@Test func pruneDeletesOnlyEventsPastTheRetentionWindow() throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001082011"
    let ownerId = "11111111-1111-4111-8111-000001082011"
    accounts.oauth.addOwnedServer(id: serverId, slug: "prune", name: "Prune", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "PruneBot", creatorUserId: ownerId, runtime: "claude")
    let app = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Prune App", clientId: "prune-app"
    )
    let now = Date(timeIntervalSince1970: 1_791_158_400) // 2026-10-05T00:00:00Z
    let retention = Double(OAuthLedger.agentAppEventRetentionAfterExpiryMs) / 1000
    let old = UUID().uuidString.lowercased()
    let recent = UUID().uuidString.lowercased()
    accounts.oauth.seedAgentAppEventForTesting(
        id: old, agentId: agent, clientRecordId: app.id, summary: "old", status: "queued",
        expiresAt: now.addingTimeInterval(-retention - 1), createdAt: now
    )
    accounts.oauth.seedAgentAppEventForTesting(
        id: recent, agentId: agent, clientRecordId: app.id, summary: "recent", status: "queued",
        expiresAt: now.addingTimeInterval(-retention + dayMs), createdAt: now
    )
    let deleted = accounts.oauth.pruneExpiredAgentAppEvents(now: now, batchSize: 1)
    #expect(deleted >= 1)
    let remaining = accounts.oauth.agentAppEventDetail(userId: ownerId, agentId: agent, eventId: old)
    if case .notFound = remaining {} else { Issue.record("old event survived prune") }
    if case .event = accounts.oauth.agentAppEventDetail(userId: ownerId, agentId: agent, eventId: recent) {} else {
        Issue.record("recent event was pruned")
    }
}
