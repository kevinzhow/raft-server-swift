import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// `GET /api/tasks/:taskId/history` is the canonical append-only task timeline
/// read by the pinned Web task dialog (`taskStore.loadTaskHistory`).
///
/// Upstream `routes/tasks.ts` resolves the task through the same server/channel
/// access checks as the task mutations, then answers `{events}` from
/// `taskService.listTaskHistory`: `id`, `seq`, `eventType`, `actorType`,
/// `actorName`, `payload`, `createdAt`, ordered by the global `seq`. A legacy
/// task without a canonical row answers 409 with the service's message.

private struct TaskHistoryFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111681"
    let memberId = "11111111-1111-4111-8111-111111111682"
    let serverId = "33333333-3333-4333-8333-333333333681"
    let channelId: String

    init() {
        for (id, email) in [(ownerId, "history-owner"), (memberId, "history-member")] {
            accounts.addAccount(id: id, email: "\(email)@task-history.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "task-history", name: "Task History", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "task-history-room", creatorUserId: ownerId)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "task-history-room")
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId, name: "task-history-room")
    }

    func headers(_ userId: String? = nil) -> HTTPFields {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: userId ?? ownerId))"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return headers
    }
}

private func taskHistoryObject(_ response: ClientResponse) throws -> [String: Any] {
    let body = try #require(response.body.string)
    return try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
}

private func createHistoryTask(_ client: any Client, _ fixture: TaskHistoryFixture, title: String = "history task") async throws -> String {
    let response = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/tasks/channel/\(fixture.channelId)")) { request in
        request.body = .init(string: "{\"tasks\":[{\"title\":\"\(title)\"}]}")
    }
    #expect(response.status == .ok, Comment(rawValue: response.body.string ?? ""))
    let body = try taskHistoryObject(response)
    let tasks = try #require(body["tasks"] as? [[String: Any]])
    return try #require(tasks.first?["id"] as? String)
}

private func patchTask(_ client: any Client, _ fixture: TaskHistoryFixture, _ taskId: String,
                       _ suffix: String, _ body: String?, userId: String? = nil) async throws -> ClientResponse {
    try await client.send(.patch, headers: fixture.headers(userId), to: URI(string: "/api/tasks/\(taskId)/\(suffix)")) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func historyEvents(_ client: any Client, _ fixture: TaskHistoryFixture,
                           taskId: String, userId: String? = nil) async throws -> [[String: Any]] {
    let response = try await client.send(.get, headers: fixture.headers(userId), to: URI(string: "/api/tasks/\(taskId)/history"))
    #expect(response.status == .ok, Comment(rawValue: response.body.string ?? ""))
    let body = try taskHistoryObject(response)
    return try #require(body["events"] as? [[String: Any]])
}

@Suite(.serialized)
struct TaskHistoryHTTPTests {
    @Test func taskCreationRecordsTheCanonicalCreatedEvent() async throws {
        let fixture = TaskHistoryFixture()
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let taskId = try await createHistoryTask(client, fixture)
                let response = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/tasks/\(taskId)/history"))
                #expect(response.status == .ok)
                let raw = try #require(response.body.string)
                // Published member order is the listTaskHistory projection.
                #expect(raw.hasPrefix("{\"events\":[{\"id\":\""))
                let events = try #require(try taskHistoryObject(response)["events"] as? [[String: Any]])
                let event = try #require(events.first)
                #expect(Set(event.keys) == ["id", "seq", "eventType", "actorType", "actorName", "payload", "createdAt"])
                #expect((event["id"] as? String)?.isEmpty == false)
                #expect(event["seq"] as? Int == 1)
                #expect(event["eventType"] as? String == "created")
                #expect(event["actorType"] as? String == "user")
                #expect(event["actorName"] as? String == "history-owner")
                let payload = try #require(event["payload"] as? [String: Any])
                #expect(Set(payload.keys) == ["taskNumber", "status", "requiresResourceReceipt"])
                #expect(payload["taskNumber"] as? Int == 1)
                #expect(payload["status"] as? String == "todo")
                #expect(payload["requiresResourceReceipt"] as? Bool == false)
                #expect((event["createdAt"] as? String)?.hasSuffix("Z") == true)
            }
        }
    }

    @Test func taskHistoryAppendsClaimAssignmentUnclaimStatusAndReopenInSeqOrder() async throws {
        let fixture = TaskHistoryFixture()
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let taskId = try await createHistoryTask(client, fixture)

                #expect(try await patchTask(client, fixture, taskId, "claim", nil, userId: fixture.memberId).status == .ok)
                #expect(try await patchTask(client, fixture, taskId, "assignee",
                    "{\"assignee\":{\"type\":\"user\",\"id\":\"\(fixture.ownerId)\"}}").status == .ok)
                #expect(try await patchTask(client, fixture, taskId, "unclaim", nil).status == .ok)
                #expect(try await patchTask(client, fixture, taskId, "status", "{\"status\":\"done\"}").status == .ok)
                #expect(try await patchTask(client, fixture, taskId, "status", "{\"status\":\"closed\"}").status == .ok)
                #expect(try await patchTask(client, fixture, taskId, "status", "{\"status\":\"in_progress\"}").status == .ok)

                let events = try await historyEvents(client, fixture, taskId: taskId)
                #expect(events.map { $0["seq"] as? Int } == Array(1...8))
                #expect(events.map { $0["eventType"] as? String } == [
                    "created", "assignee_changed", "status_changed", "assignee_changed",
                    "assignee_changed", "status_changed", "closed", "reopened",
                ])

                let claimAssignee = try #require(events[1]["payload"] as? [String: Any])
                #expect(claimAssignee["assigneeType"] as? String == "user")
                #expect(claimAssignee["assigneeId"] as? String == fixture.memberId)
                #expect(events[1]["actorType"] as? String == "user")
                #expect(events[1]["actorName"] as? String == "history-member")

                let claimStatus = try #require(events[2]["payload"] as? [String: Any])
                #expect(claimStatus["from"] as? String == "todo")
                #expect(claimStatus["to"] as? String == "in_progress")
                #expect(claimStatus["forced"] as? Bool == false)

                let assigned = try #require(events[3]["payload"] as? [String: Any])
                #expect(assigned["assigneeType"] as? String == "user")
                #expect(assigned["assigneeId"] as? String == fixture.ownerId)
                #expect(assigned["previousAssigneeType"] as? String == "user")
                #expect(assigned["previousAssigneeId"] as? String == fixture.memberId)
                #expect(events[3]["actorName"] as? String == "history-owner")

                let unclaimed = try #require(events[4]["payload"] as? [String: Any])
                #expect(unclaimed["assigneeType"] is NSNull)
                #expect(unclaimed["assigneeId"] is NSNull)
                #expect(unclaimed["previousAssigneeId"] as? String == fixture.ownerId)

                let done = try #require(events[5]["payload"] as? [String: Any])
                #expect(done["from"] as? String == "in_progress")
                #expect(done["to"] as? String == "done")
                #expect(done["forced"] as? Bool == false)

                let closed = try #require(events[6]["payload"] as? [String: Any])
                #expect(closed["from"] as? String == "done")
                #expect(closed["to"] as? String == "closed")
                #expect(events[6]["actorType"] as? String == "user")

                let reopened = try #require(events[7]["payload"] as? [String: Any])
                #expect(reopened["from"] as? String == "closed")
                #expect(reopened["to"] as? String == "in_progress")
            }
        }
    }

    @Test func convertedMessageRecordsTheCreatedConvertedEvent() async throws {
        let fixture = TaskHistoryFixture()
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let sent = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/messages")) { request in
                    request.body = .init(string: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"convert this\"}")
                }
                #expect(sent.status == .ok)
                let message = try taskHistoryObject(sent)
                let messageId = try #require(message["id"] as? String)
                let converted = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/tasks/convert-message")) { request in
                    request.body = .init(string: "{\"messageId\":\"\(messageId)\"}")
                }
                #expect(converted.status == .ok)
                let task = try #require(try taskHistoryObject(converted)["task"] as? [String: Any])
                let taskId = try #require(task["id"] as? String)
                let events = try await historyEvents(client, fixture, taskId: taskId)
                #expect(events.count == 1)
                let payload = try #require(events.first?["payload"] as? [String: Any])
                #expect(payload["taskNumber"] as? Int == 1)
                #expect(payload["status"] as? String == "todo")
                #expect(payload["convertedFromMessage"] as? Bool == true)
                #expect(events.first?["eventType"] as? String == "created")
            }
        }
    }

    @Test func channelDeletionRecordsTheSystemClosedEventAndHistoryStaysReadable() async throws {
        let fixture = TaskHistoryFixture()
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let taskId = try await createHistoryTask(client, fixture)
                let deleted = try await client.send(.delete, headers: fixture.headers(), to: URI(string: "/api/channels/\(fixture.channelId)"))
                #expect(deleted.status == .ok, Comment(rawValue: deleted.body.string ?? ""))
                let events = try await historyEvents(client, fixture, taskId: taskId)
                #expect(events.map { $0["eventType"] as? String } == ["created", "closed"])
                let closed = try #require(events.last)
                #expect(closed["actorType"] as? String == "system")
                #expect(closed["actorName"] is NSNull)
                let payload = try #require(closed["payload"] as? [String: Any])
                #expect(payload["status"] as? String == "closed")
                #expect(payload["reason"] as? String == "channel_deleted")
                #expect(payload["channelId"] as? String == fixture.channelId)
            }
        }
    }

    @Test func taskHistoryRefusesUnauthenticatedUnknownAndLegacyTasks() async throws {
        let fixture = TaskHistoryFixture()
        let legacyId = fixture.accounts.addOrphanTaskForTesting(
            channelId: fixture.channelId, title: "legacy no host", taskNumber: 40)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                // `guardUuidPathParams` answers the uniform 404 for a non-UUID id.
                let nonUuid = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/tasks/not-a-uuid/history"))
                #expect(nonUuid.status == .notFound)
                #expect(nonUuid.body.string == #"{"error":"Task not found"}"#)

                let unknown = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/tasks/\(UUID().uuidString.lowercased())/history"))
                #expect(unknown.status == .notFound)
                #expect(unknown.body.string == #"{"error":"Task not found"}"#)

                var missingAuth = fixture.headers()
                missingAuth[.authorization] = nil
                let unauthenticated = try await client.send(.get, headers: missingAuth,
                    to: URI(string: "/api/tasks/\(legacyId)/history"))
                #expect(unauthenticated.status == .unauthorized)
                #expect(unauthenticated.body.string == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)

                var badToken = fixture.headers()
                badToken[.authorization] = "Bearer not-a-session"
                let invalid = try await client.send(.get, headers: badToken,
                    to: URI(string: "/api/tasks/\(legacyId)/history"))
                #expect(invalid.status == .unauthorized)
                #expect(invalid.body.string == #"{"error":"Invalid or expired token","code":"auth_required"}"#)

                var missingServer = fixture.headers()
                missingServer[HTTPField.Name("X-Server-Id")!] = nil
                let noServer = try await client.send(.get, headers: missingServer,
                    to: URI(string: "/api/tasks/\(legacyId)/history"))
                #expect(noServer.status == .badRequest)
                #expect(noServer.body.string == #"{"error":"Missing X-Server-Id header"}"#)

                let legacy = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/tasks/\(legacyId)/history"))
                #expect(legacy.status == .conflict)
                #expect(legacy.body.string == #"{"error":"legacy task cards do not have canonical history"}"#)
            }
        }
    }

    @Test func taskHistoryRequiresServerMembership() async throws {
        let fixture = TaskHistoryFixture()
        let outsiderId = "11111111-1111-4111-8111-111111111683"
        fixture.accounts.addAccount(id: outsiderId, email: "history-outsider@task-history.test", password: "password123")
        fixture.accounts.markEmailVerified(userId: outsiderId)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let taskId = try await createHistoryTask(client, fixture)
                let response = try await client.send(.get, headers: fixture.headers(outsiderId),
                    to: URI(string: "/api/tasks/\(taskId)/history"))
                #expect(response.status == .forbidden)
                #expect(response.body.string == #"{"error":"Not a member of this server"}"#)
            }
        }
    }
}
