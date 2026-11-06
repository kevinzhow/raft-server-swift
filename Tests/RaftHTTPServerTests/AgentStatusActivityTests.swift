import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func activityISO(_ offset: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(offset))
}

@Test func agentStatusActivityDrivesTheDotAndRejectsInvalidFields() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001025001"
    let ownerId = "11111111-1111-4111-8111-000001025001"
    accounts.addAccount(id: ownerId, email: "agent-status-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-status", name: "Agent Status", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "StatusExt", runtime: "external")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "status")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            headers[.contentType] = "application/json"
            func post(_ events: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/internal/agent-api/activity") { request in
                    request.body = .init(string: "{\"schema\":\"raft-agent-status.v1\",\"events\":[\(events)]}")
                }
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            let statusOnly = try await post("{\"eventId\":\"st-1\",\"status\":\"working\",\"detail\":\"Running the test suite\",\"occurredAt\":\"\(activityISO(-60))\"}")
            #expect(statusOnly.status == .ok)
            #expect(body(statusOnly) as NSDictionary == ["ok": true, "acceptedCount": 1, "rejectedCount": 0, "droppedCount": 0] as NSDictionary)
            #expect(accounts.agentActivityForTesting(agentId: agent)?.activity == "working")
            #expect(accounts.agentActivityForTesting(agentId: agent)?.detail == "Running the test suite")
            #expect(accounts.agentStatusAdoptedForTesting(agentId: agent))

            let hookStatus = try await post("{\"eventId\":\"st-2\",\"hookEventName\":\"PreToolUse\",\"toolName\":\"Bash\",\"status\":\"thinking\",\"occurredAt\":\"\(activityISO(-59))\"}")
            #expect(body(hookStatus)["acceptedCount"] as? Int == 1)
            #expect(accounts.agentActivityForTesting(agentId: agent)?.activity == "thinking")
            #expect(accounts.agentActivityForTesting(agentId: agent)?.detail == "")

            let invalid = try await post("{\"eventId\":\"bad-1\",\"status\":\"busy\",\"occurredAt\":\"\(activityISO(0))\"}")
            #expect(invalid.status == .badRequest)
            #expect(body(invalid)["code"] as? String == "status_invalid")
            let long = try await post("{\"eventId\":\"bad-2\",\"status\":\"working\",\"detail\":\"\(String(repeating: "x", count: 201))\",\"occurredAt\":\"\(activityISO(0))\"}")
            #expect(long.status == .badRequest)
            #expect(body(long)["code"] as? String == "detail_too_long")
            let nonString = try await post("{\"eventId\":\"bad-3\",\"status\":\"working\",\"detail\":7,\"occurredAt\":\"\(activityISO(0))\"}")
            #expect(nonString.status == .badRequest)
            #expect(body(nonString)["code"] as? String == "detail_invalid")
            let exact = try await post("{\"eventId\":\"ok-200\",\"status\":\"error\",\"detail\":\"\(String(repeating: "y", count: 200))\",\"occurredAt\":\"\(activityISO(0))\"}")
            #expect(body(exact)["acceptedCount"] as? Int == 1)

            let unorderable = try await post("{\"status\":\"working\",\"occurredAt\":\"\(activityISO(0))\"},{\"eventId\":\"no-time\",\"status\":\"working\"}")
            #expect(unorderable.status == .ok)
            #expect(body(unorderable) as NSDictionary == ["ok": true, "acceptedCount": 0, "rejectedCount": 2, "droppedCount": 0] as NSDictionary)
        }
    }
}

@Test func agentStatusOrdersClampsDedupesAndSuppressesPostAdoptionHooks() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001025002"
    let ownerId = "11111111-1111-4111-8111-000001025002"
    accounts.addAccount(id: ownerId, email: "agent-status-order@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-status-order", name: "Agent Status Order", ownerId: ownerId)
    let reporter = accounts.oauth.createAgent(serverId: serverId, name: "ReporterExt", runtime: "external")
    let hooksOnly = accounts.oauth.createAgent(serverId: serverId, name: "HooksOnlyExt", runtime: "external")
    let reporterKey = accounts.mintAgentCredential(agentId: reporter, scopes: ["read"], name: "reporter")
    let hooksKey = accounts.mintAgentCredential(agentId: hooksOnly, scopes: ["read"], name: "hooks")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func post(_ key: String, _ events: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/internal/agent-api/activity") { request in
                    request.body = .init(string: "{\"schema\":\"raft-agent-status.v1\",\"events\":[\(events)]}")
                }
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let t0 = Date().timeIntervalSince1970 - 60
            let iso = { (delta: TimeInterval) in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.string(from: Date(timeIntervalSince1970: t0 + delta))
            }

            _ = try await post(hooksKey, "{\"eventId\":\"o-1\",\"hookEventName\":\"PreToolUse\",\"toolName\":\"Bash\",\"occurredAt\":\"\(iso(0))\"}")
            #expect(accounts.agentActivityForTesting(agentId: hooksOnly)?.activity == "working")
            _ = try await post(hooksKey, "{\"eventId\":\"o-2\",\"hookEventName\":\"Stop\",\"occurredAt\":\"\(iso(1))\"}")
            #expect(accounts.agentActivityForTesting(agentId: hooksOnly)?.activity == "online")
            #expect(accounts.agentStatusAdoptedForTesting(agentId: hooksOnly) == false)

            _ = try await post(reporterKey, "{\"eventId\":\"newer\",\"status\":\"working\",\"detail\":\"Editing files\",\"occurredAt\":\"\(iso(5))\"}")
            _ = try await post(reporterKey, "{\"eventId\":\"older\",\"hookEventName\":\"PostToolUse\",\"status\":\"online\",\"occurredAt\":\"\(iso(0))\"}")
            #expect(accounts.agentActivityForTesting(agentId: reporter)?.activity == "working")
            #expect(accounts.agentActivityForTesting(agentId: reporter)?.detail == "Editing files")

            let replay = try await post(reporterKey, "{\"eventId\":\"newer\",\"status\":\"offline\",\"occurredAt\":\"\(iso(9))\"},{\"eventId\":\"dup-in-batch\",\"status\":\"working\",\"detail\":\"first\",\"occurredAt\":\"\(iso(6))\"},{\"eventId\":\"dup-in-batch\",\"status\":\"error\",\"detail\":\"second\",\"occurredAt\":\"\(iso(7))\"}")
            #expect(body(replay) as NSDictionary == ["ok": true, "acceptedCount": 1, "rejectedCount": 2, "droppedCount": 0] as NSDictionary)
            #expect(accounts.agentActivityForTesting(agentId: reporter)?.detail == "first")

            _ = try await post(reporterKey, "{\"eventId\":\"future\",\"status\":\"error\",\"detail\":\"Clock skew\",\"occurredAt\":\"\(activityISO(3600))\"}")
            #expect(accounts.agentActivityForTesting(agentId: reporter)?.activity == "error")
            try await Task.sleep(nanoseconds: 10_000_000)
            _ = try await post(reporterKey, "{\"eventId\":\"after-future\",\"status\":\"online\",\"occurredAt\":\"\(activityISO(0))\"}")
            #expect(accounts.agentActivityForTesting(agentId: reporter)?.activity == "online")
            #expect(accounts.agentActivityForTesting(agentId: reporter)?.detail == "")

            _ = try await post(reporterKey, "{\"eventId\":\"h-2\",\"hookEventName\":\"PreToolUse\",\"toolName\":\"Bash\",\"occurredAt\":\"\(iso(10))\"}")
            #expect(accounts.agentActivityForTesting(agentId: reporter)?.activity == "online")
            _ = try await post(hooksKey, "{\"eventId\":\"o-3\",\"hookEventName\":\"PreToolUse\",\"occurredAt\":\"\(iso(11))\"}")
            #expect(accounts.agentActivityForTesting(agentId: hooksOnly)?.activity == "working")
        }
    }
}
