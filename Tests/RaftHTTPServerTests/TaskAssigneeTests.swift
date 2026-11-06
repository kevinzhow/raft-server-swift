import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func assignmentIsOCCGuardedAndDoesNotStartWork() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111304"
    let memberId = "11111111-1111-4111-8111-111111111305"
    let outsiderId = "11111111-1111-4111-8111-111111111306"
    let serverId = "33333333-3333-4333-8333-333333333481"
    for (id, email) in [
        (ownerId, "assign-owner@slock.test"),
        (memberId, "assign-member@slock.test"),
        (outsiderId, "assign-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "assign", name: "Assign", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: outsiderId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "assign-channel", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: memberId)
    let taskId = accounts.taskCatalog.addTasks(channelId: channelId, titles: ["assign task"]).first ?? ""

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
            let ownerToken = try await login("assign-owner@slock.test")
            let memberToken = try await login("assign-member@slock.test")
            let outsiderToken = try await login("assign-outsider@slock.test")

            func assign(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/tasks/\(taskId)/assignee") { request in
                    request.body = .init(string: body)
                }
            }
            func readTask() async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers(ownerToken), to: "/api/tasks/channel/\(channelId)")
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["tasks"] as? [[String: Any]] ?? []).first { $0["id"] as? String == taskId } ?? [:]
            }
            func status(_ token: String, _ value: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: "/api/tasks/\(taskId)/status") { request in
                    request.body = .init(string: "{\"status\":\"\(value)\"}")
                }
            }

            let first = try await assign(memberToken, "{\"assignee\":{\"type\":\"user\",\"id\":\"\(ownerId)\"}}")
            #expect(first.status == .ok)
            var task = try await readTask()
            #expect(task["claimedById"] as? String == ownerId)
            #expect(task["claimedByType"] as? String == "user")
            #expect(task["status"] as? String == "todo")
            #expect(task["claimedAt"] == nil || task["claimedAt"] is NSNull)
            let revisionAfterFirst = task["revision"] as? Int ?? -1
            #expect(revisionAfterFirst == 1)

            let noop = try await assign(memberToken, "{\"assignee\":{\"type\":\"user\",\"id\":\"\(ownerId)\"}}")
            #expect(noop.status == .ok)
            #expect((try await readTask())["revision"] as? Int == revisionAfterFirst)

            let outsider = try await assign(outsiderToken, "{\"assignee\":{\"type\":\"user\",\"id\":\"\(outsiderId)\"}}")
            #expect(outsider.status == .conflict)

            let stale = try await assign(memberToken, "{\"assignee\":{\"type\":\"user\",\"id\":\"\(memberId)\"},\"expectedRevision\":0}")
            #expect(stale.status == .conflict)
            let staleBody = try JSONSerialization.jsonObject(with: Data((stale.body.string ?? "").utf8)) as? [String: Any]
            #expect(staleBody?["currentRevision"] as? Int == revisionAfterFirst)
            #expect((try await readTask())["claimedById"] as? String == ownerId)

            #expect(try await status(memberToken, "in_progress").status == .ok)
            task = try await readTask()
            #expect(task["status"] as? String == "in_progress")
            #expect(task["claimedAt"] is String)

            let withdraw = try await assign(memberToken, "{\"assignee\":null}")
            #expect(withdraw.status == .ok)
            task = try await readTask()
            #expect(task["claimedById"] == nil || task["claimedById"] is NSNull)
            #expect(task["status"] as? String == "in_progress")

            #expect(try await status(memberToken, "done").status == .ok)
            let doneAssign = try await assign(memberToken, "{\"assignee\":{\"type\":\"user\",\"id\":\"\(ownerId)\"}}")
            #expect(doneAssign.status == .conflict)

            let malformed = try await assign(memberToken, "{\"assignee\":\"nope\"}")
            #expect(malformed.status == .badRequest)
        }
    }
}
