import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func deletingATaskRemovesItFromTheBoardAndNumberLookup() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111325"
    let serverId = "33333333-3333-4333-8333-333333333493"
    accounts.addAccount(id: ownerId, email: "delete-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "delete", name: "Delete", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "delete-room", creatorUserId: ownerId)
    let first = accounts.addTask(channelId: channelId, title: "first", description: nil)
    let second = accounts.addTask(channelId: channelId, title: "second", description: nil)

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
                request.body = .init(string: "{\"email\":\"delete-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let deleted = try await client.send(.delete, headers: headers, to: "/api/tasks/\(first)")
            #expect(deleted.status == .ok)

            let list = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channelId)")
            #expect(list.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [String: Any]
            let numbers = (rows?["tasks"] as? [[String: Any]] ?? []).compactMap { $0["taskNumber"] as? Int }
            #expect(numbers == [2])

            let number = try await client.send(.get, headers: headers, to: "/api/tasks/channel/\(channelId)/number/1")
            #expect(number.status == .notFound)
            #expect(accounts.addTasks(channelId: channelId, titles: []).isEmpty)
            #expect(second.isEmpty == false)

            let unknown = try await client.send(.delete, headers: headers, to: "/api/tasks/not-a-task")
            #expect(unknown.status == .notFound)
        }
    }
}
