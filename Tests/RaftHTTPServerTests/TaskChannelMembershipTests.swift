import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func taskWritesAndPrivateReadsFollowChannelMembership() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111301"
    let readerId = "11111111-1111-4111-8111-111111111302"
    let memberId = "11111111-1111-4111-8111-111111111303"
    let serverId = "33333333-3333-4333-8333-333333333480"
    for (id, email) in [
        (ownerId, "task-owner@slock.test"),
        (readerId, "task-reader@slock.test"),
        (memberId, "task-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-contract", name: "Task Contract", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: readerId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let publicChannel = accounts.oauth.createChannel(serverId: serverId, name: "readonly-public", creatorUserId: ownerId)
    let publicMessage = accounts.oauth.createMessageRecord(channelId: publicChannel, content: "convert me", senderId: ownerId).id
    let publicTask = accounts.addTasks(channelId: publicChannel, titles: ["readonly task"]).first ?? ""
    let privateChannel = accounts.oauth.createChannel(serverId: serverId, name: "private-tasks", creatorUserId: ownerId, type: "private")
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: memberId)
    let privateMessage = accounts.oauth.createMessageRecord(channelId: privateChannel, content: "private convert target", senderId: memberId).id
    let privateTask = accounts.addTasks(channelId: privateChannel, titles: ["private task"]).first ?? ""

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
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("task-owner@slock.test")
            let readerToken = try await login("task-reader@slock.test")
            let memberToken = try await login("task-member@slock.test")

            func call(_ method: HTTPRequest.Method, _ token: String, _ path: String, body: String? = nil) async throws -> ClientResponse {
                try await client.send(method, headers: headers(token), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }

            let readerList = try await call(.get, readerToken, "/api/tasks/channel/\(publicChannel)")
            #expect(readerList.status == .ok)
            let listBody = try JSONSerialization.jsonObject(with: Data((readerList.body.string ?? "").utf8)) as? [String: Any]
            #expect((listBody?["tasks"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == publicTask })
            #expect(try await call(.patch, readerToken, "/api/tasks/\(publicTask)/claim").status == .forbidden)
            #expect(try await call(.patch, readerToken, "/api/tasks/\(publicTask)/status", body: "{\"status\":\"in_progress\"}").status == .forbidden)
            #expect(try await call(.post, readerToken, "/api/tasks/channel/\(publicChannel)", body: "{\"tasks\":[{\"title\":\"should not create\"}]}").status == .forbidden)
            #expect(try await call(.post, readerToken, "/api/tasks/convert-message", body: "{\"messageId\":\"\(publicMessage)\"}").status == .forbidden)

            let memberList = try await call(.get, memberToken, "/api/tasks/channel/\(privateChannel)")
            #expect(memberList.status == .ok)
            let memberListBody = (try JSONSerialization.jsonObject(with: Data((memberList.body.string ?? "").utf8))) as? [String: Any]
            #expect((memberListBody?["tasks"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == privateTask })
            let memberNumber = try await call(.get, memberToken, "/api/tasks/channel/\(privateChannel)/number/1")
            #expect(memberNumber.status == .ok)
            let memberNumberBody = (try JSONSerialization.jsonObject(with: Data((memberNumber.body.string ?? "").utf8))) as? [String: Any]
            #expect((memberNumberBody?["task"] as? [String: Any])?["id"] as? String == privateTask)

            #expect(try await call(.get, readerToken, "/api/tasks/channel/\(privateChannel)").status == .notFound)
            #expect(try await call(.get, readerToken, "/api/tasks/channel/\(privateChannel)/number/1").status == .notFound)
            #expect(try await call(.patch, readerToken, "/api/tasks/\(privateTask)/claim").status == .notFound)
            #expect(try await call(.post, readerToken, "/api/tasks/convert-message", body: "{\"messageId\":\"\(privateMessage)\"}").status == .notFound)

            #expect(try await call(.get, ownerToken, "/api/tasks/channel/\(publicChannel)?status=in_progress").status == .ok)
            #expect(try await call(.get, ownerToken, "/api/tasks/channel/\(publicChannel)?status=bogus").status == .badRequest)
            #expect(try await call(.get, ownerToken, "/api/tasks/channel/\(publicChannel)?status=todo&status=bogus").status == .badRequest)
            #expect(try await call(.get, ownerToken, "/api/tasks/server?status=in_progress").status == .ok)
            #expect(try await call(.get, ownerToken, "/api/tasks/server?status=bogus").status == .badRequest)
            #expect(try await call(.get, ownerToken, "/api/tasks/server?status=todo&status=bogus").status == .badRequest)
        }
    }
}
