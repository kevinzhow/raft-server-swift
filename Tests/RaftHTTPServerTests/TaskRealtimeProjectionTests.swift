import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class TaskRealtimeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []
    func append(_ room: String, _ event: String, _ payload: String?) {
        lock.lock(); storage.append((room, event, payload)); lock.unlock()
    }
    var values: [(room: String, event: String, payload: String?)] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

@Test func taskClaimEmitsOnlyTheTaskBoardEvent() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001035001"
    let ownerId = "11111111-1111-4111-8111-000001035001"
    let ownerEmail = "task-realtime-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-realtime", name: "Task Realtime", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "task-realtime-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "task-realtime-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let ids = accounts.addTasks(channelId: channel, titles: ["canonical task"])
    let events = TaskRealtimeEvents()
    accounts.realtimeEmitter = { room, event, payload in events.append(room, event, payload) }

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
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let messageOnly = accounts.addChannelMessageForTesting(channelId: channel, content: "not a task", senderId: ownerId)
            let refused = try await client.send(.patch, headers: headers, to: URI(string: "/api/tasks/\(messageOnly)/claim"))
            #expect(refused.status == .notFound)
            #expect(events.values.isEmpty)

            let claimed = try await client.send(.patch, headers: headers, to: URI(string: "/api/tasks/\(ids[0])/claim"))
            #expect(claimed.status == .ok)
            let updates = events.values.filter { $0.event == "task:updated" }
            #expect(updates.count == 1)
            #expect(updates.first?.room == "channel:\(channel)")
            let payload = (try? JSONSerialization.jsonObject(with: Data((updates.first?.payload ?? "").utf8))) as? [String: Any] ?? [:]
            let task = try #require(payload["task"] as? [String: Any])
            #expect(task["id"] as? String == ids[0])
            #expect(task["status"] as? String == "in_progress")
            #expect(task["claimedById"] as? String == ownerId)
            #expect(events.values.contains { $0.event == "message:updated" } == false)
        }
    }
}
