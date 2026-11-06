import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct IdemFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001098001"
    let ownerId = "11111111-1111-4111-8111-000001098001"
    var agentId = ""
    var channelId = ""
    var channelName = ""
    var apiKey = ""

    mutating func seed() throws {
        accounts.addAccount(id: ownerId, email: "idem-owner@idem.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "idem", name: "Idem", ownerId: ownerId)
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "IdemBot", creatorUserId: ownerId, runtime: "claude")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "idem-room", creatorUserId: ownerId, type: "channel")
        channelName = "idem-room"
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: channelName, humanIds: [ownerId], agentIds: [agentId])
        apiKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["send", "read", "tasks", "channels"], name: "idem")
    }

    func headers() -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(apiKey)"
        headers[.contentType] = "application/json"
        return headers
    }
}

private func post(_ client: any Client, _ fixture: IdemFixture, _ path: String, _ body: String) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    let response = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/internal/agent-api/\(path)")) { request in
        request.body = .init(string: body)
    }
    let raw = response.body.string ?? ""
    return (response.status, (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:], raw)
}

private func taskBody(_ fixture: IdemFixture, _ title: String, extra: String = "") -> String {
    "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"\(title)\"}],\"idempotencyKey\":\"KEY\"\(extra)}"
}

@Test func taskCreateIdempotencyKeyReplaysAndRefusesMismatches() async throws {
    var fixture = IdemFixture()
    try fixture.seed()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let firstBody = "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"write the spec\"},{\"title\":\"ship it\",\"creates_resource\":true}],\"idempotencyKey\":\"create-1\"}"
            let first = try await post(client, fixture, "tasks", firstBody)
            #expect(first.status == .ok, Comment(rawValue: first.raw))
            #expect(accounts.taskCountForTesting(channelId: fixture.channelId) == 2)
            let replayBody = "{\"idempotencyKey\":\"create-1\",\"tasks\":[{\"title\":\"write the spec\",\"creates_resource\":false},{\"creates_resource\":true,\"title\":\"ship it\"}],\"channel\":\"#\(fixture.channelName)\"}"
            let replay = try await post(client, fixture, "tasks", replayBody)
            #expect(replay.status == .ok)
            #expect(replay.body as NSDictionary == first.body as NSDictionary, Comment(rawValue: "first=\(first.raw) replay=\(replay.raw)"))
            #expect(accounts.taskCountForTesting(channelId: fixture.channelId) == 2)
            #expect(accounts.agentApiIdempotencyKeysForTesting(agentId: fixture.agentId, route: "taskCreate") == ["create-1"])

            for mismatch in [
                "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"other\"}],\"idempotencyKey\":\"create-1\"}",
                "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"write the spec\",\"creates_resource\":true},{\"title\":\"ship it\",\"creates_resource\":true}],\"idempotencyKey\":\"create-1\"}",
                "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"write the spec\"},{\"title\":\"ship it\",\"creates_resource\":true}],\"assignee\":\"@IdemBot\",\"idempotencyKey\":\"create-1\"}",
            ] {
                let refused = try await post(client, fixture, "tasks", mismatch)
                #expect(refused.status == .conflict)
                #expect(refused.body["code"] as? String == "idempotency_key_reused")
                #expect(refused.body["mismatch"] as? String == "request")
                #expect(refused.body["suggestedNextAction"] != nil)
            }
            #expect(accounts.taskCountForTesting(channelId: fixture.channelId) == 2)

            let noKeyA = try await post(client, fixture, "tasks", "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"same title\"}]}")
            let noKeyB = try await post(client, fixture, "tasks", "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"same title\"}],\"idempotencyKey\":\"   \"}")
            #expect(noKeyA.status == .ok)
            #expect(noKeyB.status == .ok)
            #expect(noKeyA.body as NSDictionary != noKeyB.body as NSDictionary)
            #expect(accounts.taskCountForTesting(channelId: fixture.channelId) == 4)
            #expect(accounts.agentApiIdempotencyKeysForTesting(agentId: fixture.agentId, route: "taskCreate") == ["create-1"])

            let assignedBody = "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"self-start\"}],\"assignee\":\"@IdemBot\",\"idempotencyKey\":\"assigned-1\"}"
            let assigned = try await post(client, fixture, "tasks", assignedBody)
            #expect(assigned.status == .ok)
            #expect(assigned.body["assignmentReceipt"] != nil)
            let assignedReplay = try await post(client, fixture, "tasks", assignedBody)
            #expect(assignedReplay.body as NSDictionary == assigned.body as NSDictionary)
            #expect(accounts.taskCountForTesting(channelId: fixture.channelId) == 5)
        }
    }
}

@Test func taskCreateIdempotencyKeyExpiresAfter24Hours() async throws {
    var fixture = IdemFixture()
    try fixture.seed()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let body = taskBody(fixture, "daily")
            let first = try await post(client, fixture, "tasks", body)
            #expect(first.status == .ok)
            accounts.ageAgentApiIdempotencyKeysForTesting(agentId: fixture.agentId, seconds: 24 * 60 * 60 - 60)
            let live = try await post(client, fixture, "tasks", body)
            #expect(live.body as NSDictionary == first.body as NSDictionary)
            let refused = try await post(client, fixture, "tasks", taskBody(fixture, "other"))
            #expect(refused.status == .conflict, Comment(rawValue: refused.raw))
            #expect(accounts.taskCountForTesting(channelId: fixture.channelId) == 1)

            accounts.ageAgentApiIdempotencyKeysForTesting(agentId: fixture.agentId, seconds: 2 * 60)
            let again = try await post(client, fixture, "tasks", body)
            #expect(again.status == .ok)
            #expect(again.body as NSDictionary != first.body as NSDictionary)
            #expect(accounts.taskCountForTesting(channelId: fixture.channelId) == 2)
            let replaced = try await post(client, fixture, "tasks", body)
            #expect(replaced.body as NSDictionary == again.body as NSDictionary)
        }
    }
}

@Test func actionPrepareIdempotencyIsScopedByRoute() async throws {
    var fixture = IdemFixture()
    try fixture.seed()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let cardBody = "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"idem-room-2\"},\"idempotencyKey\":\"card-1\"}"
            let first = try await post(client, fixture, "prepare-action", cardBody)
            #expect(first.status == .created, Comment(rawValue: first.raw))
            let replay = try await post(client, fixture, "prepare-action", cardBody)
            #expect(replay.status == .created)
            #expect(replay.body as NSDictionary == first.body as NSDictionary)
            #expect(accounts.actionCardCountForTesting(agentId: fixture.agentId) == 1)

            let mismatch = try await post(client, fixture, "prepare-action", "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"other-room\"},\"idempotencyKey\":\"card-1\"}")
            #expect(mismatch.status == .conflict)
            #expect(mismatch.body["code"] as? String == "idempotency_key_reused")
            #expect(accounts.actionCardCountForTesting(agentId: fixture.agentId) == 1)

            let sameKeyOtherRoute = try await post(client, fixture, "tasks", "{\"channel\":\"#\(fixture.channelName)\",\"tasks\":[{\"title\":\"x\"}],\"idempotencyKey\":\"card-1\"}")
            #expect(sameKeyOtherRoute.status == .ok)

            let noKeyA = try await post(client, fixture, "prepare-action", "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"room-c\"}}")
            let noKeyB = try await post(client, fixture, "prepare-action", "{\"target\":\"#\(fixture.channelName)\",\"action\":{\"type\":\"channel:create\",\"name\":\"room-c\"}}")
            #expect(noKeyA.status == .created)
            #expect(noKeyB.status == .created)
            #expect((noKeyA.body["messageId"] as? String) != (noKeyB.body["messageId"] as? String))
            #expect(accounts.actionCardCountForTesting(agentId: fixture.agentId) == 3)

            accounts.ageAgentApiIdempotencyKeysForTesting(agentId: fixture.agentId, seconds: 24 * 60 * 60 + 1)
            let expired = try await post(client, fixture, "prepare-action", cardBody)
            #expect(expired.status == .created)
            #expect((expired.body["messageId"] as? String) != (first.body["messageId"] as? String))
            #expect(accounts.actionCardCountForTesting(agentId: fixture.agentId) == 4)
        }
    }
}

@Test func idempotencyLedgerPrunesOnlyExpiredRowsInBoundedBatches() async throws {
    var fixture = IdemFixture()
    try fixture.seed()
    let accounts = fixture.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            for index in 0..<7 {
                let response = try await post(client, fixture, "tasks", taskBody(fixture, "expired-\(index)").replacingOccurrences(of: "KEY", with: "expired-\(index)"))
                #expect(response.status == .ok)
            }
            accounts.ageAgentApiIdempotencyKeysForTesting(agentId: fixture.agentId, seconds: 24 * 60 * 60 + 3600)
            for index in 0..<2 {
                let response = try await post(client, fixture, "tasks", taskBody(fixture, "live-\(index)").replacingOccurrences(of: "KEY", with: "live-\(index)"))
                #expect(response.status == .ok)
            }
            let keysBefore = accounts.agentApiIdempotencyKeysForTesting(agentId: fixture.agentId, route: "taskCreate")
            #expect(keysBefore.count == 9)
            #expect(accounts.pruneAgentApiIdempotencyKeysForTesting(batchSize: 3, maxBatches: 2) == 6)
            #expect(accounts.agentApiIdempotencyKeysForTesting(agentId: fixture.agentId, route: "taskCreate").count == 3)
            #expect(accounts.pruneAgentApiIdempotencyKeysForTesting(batchSize: 3, maxBatches: 2) == 1)
            let remaining = accounts.agentApiIdempotencyKeysForTesting(agentId: fixture.agentId, route: "taskCreate").sorted()
            #expect(remaining == ["live-0", "live-1"])
            #expect(accounts.pruneAgentApiIdempotencyKeysForTesting(batchSize: 3, maxBatches: 2) == 0)
        }
    }
}
