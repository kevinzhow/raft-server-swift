import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverAdminCannotInspectOrMutateAnInvisiblePrivateChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111517"
    let inviteeId = "11111111-1111-4111-8111-111111111518"
    let adminId = "11111111-1111-4111-8111-111111111519"
    let candidateId = "11111111-1111-4111-8111-111111111520"
    let serverId = "33333333-3333-4333-8333-333333333604"
    for (id, email) in [
        (ownerId, "boundary-owner@slock.test"),
        (inviteeId, "boundary-invitee@slock.test"),
        (adminId, "boundary-admin@slock.test"),
        (candidateId, "boundary-candidate@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "boundary", name: "Boundary", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: inviteeId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: candidateId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "boundary-room", creatorUserId: ownerId, type: "private")
    accounts.oauth.setChannelType(id: channel, type: "private")
    for id in [ownerId, inviteeId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: id, kind: "private", name: "boundary-room")
        accounts.oauth.addChannelHuman(channelId: channel, userId: id)
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "boundary-agent")

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
                request.body = .init(string: "{\"email\":\"boundary-admin@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            #expect(try await client.send(.get, headers: headers, to: "/api/channels/\(channel)/agents").status == .notFound)
            #expect(try await client.send(.delete, headers: headers, to: "/api/channels/\(channel)/members/user/\(inviteeId)").status == .notFound)
            #expect(try await client.send(.delete, headers: headers, to: "/api/channels/\(channel)/members/agent/\(agent)").status == .notFound)
            #expect(try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/archive").status == .notFound)
            #expect(try await client.send(.patch, headers: headers, to: "/api/channels/\(channel)") { request in
                request.body = .init(string: "{\"description\":\"must stay hidden\"}")
            }.status == .notFound)

            let addHuman = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"userId\":\"\(candidateId)\"}")
            }
            #expect(addHuman.status == .ok)
            #expect(accounts.oauth.channelHumanIds(channelId: channel).contains(candidateId))
            let addAgent = try await client.send(.post, headers: headers, to: "/api/channels/\(channel)/members") { request in
                request.body = .init(string: "{\"agentId\":\"\(agent)\"}")
            }
            #expect(addAgent.status == .ok)
            #expect(accounts.oauth.channelAgentIds(channelId: channel).contains(agent))
        }
    }
}
