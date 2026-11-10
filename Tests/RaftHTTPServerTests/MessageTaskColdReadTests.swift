import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Every retained-message read spreads the stored task columns. Upstream's
/// `messageService` projections always contain the six task keys; ordinary
/// messages publish them as JSON `null`. The create ack and `message:new`
/// frame already do this, so cold reads must agree.

private struct ColdReadFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111691"
    let serverId = "33333333-3333-4333-8333-333333333691"
    let channelId: String

    init() {
        accounts.addAccount(id: ownerId, email: "cold-read-owner@task-cold-read.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "task-cold-read", name: "Task Cold Read", ownerId: ownerId)
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "cold-read-room", creatorUserId: ownerId)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "cold-read-room")
    }

    func headers() -> HTTPFields {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return headers
    }
}

private let coldReadTaskKeys = [
    "taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId", "taskClaimedAt", "taskCompletedAt",
]

private func coldReadObject(_ response: ClientResponse) throws -> [String: Any] {
    let body = try #require(response.body.string)
    return try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
}

private func coldReadJSON(_ response: ClientResponse) throws -> Any {
    let body = try #require(response.body.string)
    return try JSONSerialization.jsonObject(with: Data(body.utf8))
}

@Suite(.serialized)
struct MessageTaskColdReadTests {
    @Test func channelHistorySyncContextAndThreadRowsAlwaysCarryTheSixTaskKeys() async throws {
        let fixture = ColdReadFixture()
        let ordinaryId = UUID().uuidString.lowercased()
        fixture.accounts.insertHumanMessage(id: ordinaryId, channelId: fixture.channelId, senderId: fixture.ownerId, content: "ordinary cold row")
        let parentId = UUID().uuidString.lowercased()
        fixture.accounts.insertHumanMessage(id: parentId, channelId: fixture.channelId, senderId: fixture.ownerId, content: "thread parent")
        let threadId = UUID().uuidString.lowercased()
        fixture.accounts.addThreadChannel(
            serverId: fixture.serverId, threadChannelId: threadId,
            parentChannelId: fixture.channelId, parentMessageId: parentId, memberId: fixture.ownerId)
        let replyId = UUID().uuidString.lowercased()
        fixture.accounts.insertHumanMessage(id: replyId, channelId: threadId, senderId: fixture.ownerId, content: "thread reply")

        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: fixture.accounts))
            try await app.testing { client in
                let taskSend = try await client.send(.post, headers: fixture.headers(), to: URI(string: "/api/messages")) { request in
                    request.body = .init(string: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"task cold row\",\"asTask\":true}")
                }
                #expect(taskSend.status == .ok)
                let taskMessage = try coldReadObject(taskSend)
                let taskMessageId = try #require(taskMessage["id"] as? String)

                let history = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/messages/channel/\(fixture.channelId)?limit=50"))
                #expect(history.status == .ok)
                let historyRows = try #require(try coldReadObject(history)["messages"] as? [[String: Any]])
                let ordinary = try #require(historyRows.first { $0["id"] as? String == ordinaryId })
                for key in coldReadTaskKeys {
                    #expect(ordinary[key] is NSNull, "channel history ordinary row publishes \(key) as null")
                }
                let taskRow = try #require(historyRows.first { $0["id"] as? String == taskMessageId })
                #expect(taskRow["taskStatus"] as? String == "todo")
                #expect(taskRow["taskNumber"] as? Int == 1)
                for key in coldReadTaskKeys.dropFirst(2) {
                    #expect(taskRow[key] is NSNull, "task cold row publishes \(key) as null before assignment")
                }

                let sync = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/messages/sync?channel_id=\(fixture.channelId)&since_seq=0&limit=50"))
                #expect(sync.status == .ok)
                let syncRows = try #require(try coldReadJSON(sync) as? [[String: Any]])
                let syncOrdinary = try #require(syncRows.first { $0["id"] as? String == ordinaryId })
                for key in coldReadTaskKeys {
                    #expect(syncOrdinary[key] is NSNull, "sync ordinary row publishes \(key) as null")
                }
                let syncTask = try #require(syncRows.first { $0["id"] as? String == taskMessageId })
                #expect(syncTask["taskStatus"] as? String == "todo")
                #expect(syncTask["taskNumber"] as? Int == 1)

                let context = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/messages/context/\(ordinaryId)?channelId=\(fixture.channelId)&before=0&after=0"))
                #expect(context.status == .ok, Comment(rawValue: context.body.string ?? ""))
                let contextBody = try coldReadObject(context)
                let contextRows = try #require(contextBody["messages"] as? [[String: Any]])
                let contextRow = try #require(contextRows.first { $0["id"] as? String == ordinaryId })
                for key in coldReadTaskKeys {
                    #expect(contextRow[key] is NSNull, "context ordinary row publishes \(key) as null")
                }

                let threadHistory = try await client.send(.get, headers: fixture.headers(),
                    to: URI(string: "/api/messages/channel/\(threadId)?limit=50"))
                #expect(threadHistory.status == .ok, Comment(rawValue: threadHistory.body.string ?? ""))
                let threadRows = try #require(try coldReadObject(threadHistory)["messages"] as? [[String: Any]])
                let threadReply = try #require(threadRows.first { $0["id"] as? String == replyId })
                for key in coldReadTaskKeys {
                    #expect(threadReply[key] is NSNull, "thread reply publishes \(key) as null")
                }
            }
        }
    }
}
