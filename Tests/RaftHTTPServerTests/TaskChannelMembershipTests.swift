import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func taskMembershipLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func taskHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

@Test func publicChannelTasksAreReadableButImmutableForNonMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111771001"
    let readerId = "11111111-1111-4111-8111-111111771002"
    let serverId = "33333333-3333-4333-8333-333333771001"
    accounts.addAccount(id: ownerId, email: "task-owner-771@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: readerId, email: "task-reader-771@slock.test", password: "password123")
    accounts.markEmailVerified(userId: readerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-readonly", name: "Task Readonly", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: readerId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "readonly-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "readonly-public")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerToken = try await taskMembershipLogin(client, email: "task-owner-771@slock.test")
            let readerToken = try await taskMembershipLogin(client, email: "task-reader-771@slock.test")
            let ownerHeaders = taskHeaders(ownerToken, serverId)
            let readerHeaders = taskHeaders(readerToken, serverId)

            let created = try await client.send(.post, headers: ownerHeaders, to: "/api/tasks/channel/\(channel)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"readonly task\"}]}")
            }
            let createdBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            let taskId = (createdBody?["taskIds"] as? [String])?.first ?? ""
            let message = try await client.send(.post, headers: ownerHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"convert me\"}")
            }
            let messageId = (try JSONSerialization.jsonObject(with: Data((message.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            let list = try await client.get(URI(string: "/api/tasks/channel/\(channel)"), headers: readerHeaders)
            #expect(list.status == .ok)
            let listBody = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [String: Any]
            let tasks = listBody?["tasks"] as? [[String: Any]] ?? []
            #expect(tasks.contains { $0["id"] as? String == taskId })

            #expect(try await client.send(.patch, headers: readerHeaders, to: "/api/tasks/\(taskId)/claim").status == .forbidden)
            let status = try await client.send(.patch, headers: readerHeaders, to: "/api/tasks/\(taskId)/status") { request in
                request.body = .init(string: "{\"status\":\"in_progress\"}")
            }
            #expect(status.status == .forbidden)
            let create = try await client.send(.post, headers: readerHeaders, to: "/api/tasks/channel/\(channel)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"should not create\"}]}")
            }
            #expect(create.status == .forbidden)
            let convert = try await client.send(.post, headers: readerHeaders, to: "/api/tasks/convert-message") { request in
                request.body = .init(string: "{\"messageId\":\"\(messageId)\"}")
            }
            #expect(convert.status == .forbidden)
        }
    }
}

@Test func privateChannelTasksStayHiddenFromServerHumansOutsideTheChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111771003"
    let memberId = "11111111-1111-4111-8111-111111771004"
    let readerId = "11111111-1111-4111-8111-111111771005"
    let serverId = "33333333-3333-4333-8333-333333771002"
    for (id, email, role) in [
        (ownerId, "private-task-owner-771@slock.test", "owner"),
        (memberId, "private-task-member-771@slock.test", "member"),
        (readerId, "private-task-reader-771@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "private-task", name: "Private Task", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "private-tasks", creatorUserId: ownerId, type: "private")
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, kind: "private", name: "private-tasks")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let memberToken = try await taskMembershipLogin(client, email: "private-task-member-771@slock.test")
            let readerToken = try await taskMembershipLogin(client, email: "private-task-reader-771@slock.test")
            let memberHeaders = taskHeaders(memberToken, serverId)
            let readerHeaders = taskHeaders(readerToken, serverId)

            let created = try await client.send(.post, headers: memberHeaders, to: "/api/tasks/channel/\(channel)") { request in
                request.body = .init(string: "{\"tasks\":[{\"title\":\"private task\"}]}")
            }
            let taskId = ((try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["taskIds"] as? [String])?.first ?? ""
            let message = try await client.send(.post, headers: memberHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"private convert target\"}")
            }
            let messageId = (try JSONSerialization.jsonObject(with: Data((message.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            let memberList = try await client.get(URI(string: "/api/tasks/channel/\(channel)"), headers: memberHeaders)
            #expect(memberList.status == .ok)
            let memberListBody = try JSONSerialization.jsonObject(with: Data((memberList.body.string ?? "").utf8)) as? [String: Any]
            #expect((memberListBody?["tasks"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == taskId })
            let number = try await client.get(URI(string: "/api/tasks/channel/\(channel)/number/1"), headers: memberHeaders)
            #expect(number.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((number.body.string ?? "").utf8)) as? [String: Any])?["task"] != nil)

            #expect(try await client.get(URI(string: "/api/tasks/channel/\(channel)"), headers: readerHeaders).status == .notFound)
            #expect(try await client.get(URI(string: "/api/tasks/channel/\(channel)/number/1"), headers: readerHeaders).status == .notFound)
            #expect(try await client.send(.patch, headers: readerHeaders, to: "/api/tasks/\(taskId)/claim").status == .notFound)
            let convert = try await client.send(.post, headers: readerHeaders, to: "/api/tasks/convert-message") { request in
                request.body = .init(string: "{\"messageId\":\"\(messageId)\"}")
            }
            #expect(convert.status == .notFound)
        }
    }
}

@Test func channelAndServerTaskListsValidateTheStatusFilter() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111771006"
    let serverId = "33333333-3333-4333-8333-333333771003"
    accounts.addAccount(id: ownerId, email: "task-status-owner-771@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "task-status", name: "Task Status", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "status-filter-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "status-filter-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await taskMembershipLogin(client, email: "task-status-owner-771@slock.test")
            let headers = taskHeaders(token, serverId)
            for base in ["/api/tasks/channel/\(channel)", "/api/tasks/server"] {
                #expect(try await client.get(URI(string: "\(base)?status=in_progress"), headers: headers).status == .ok)
                let bad = try await client.get(URI(string: "\(base)?status=bogus"), headers: headers)
                #expect(bad.status == .badRequest)
                let repeated = try await client.get(URI(string: "\(base)?status=todo&status=bogus"), headers: headers)
                #expect(repeated.status == .badRequest)
            }
        }
    }
}
