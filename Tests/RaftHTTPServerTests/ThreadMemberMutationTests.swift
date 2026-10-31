import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func threadChannelsRefuseMemberMutations() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111542"
    let serverId = "33333333-3333-4333-8333-333333333618"
    accounts.addAccount(id: ownerId, email: "thread-mutate-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "thread-mutate", name: "Thread Mutate", ownerId: ownerId)
    let parent = accounts.oauth.createChannel(serverId: serverId, name: "thread-mutate-parent", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parent, memberId: ownerId, name: "thread-mutate-parent")
    let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: UUID().uuidString.lowercased())
    accounts.addPostableChannel(serverId: serverId, channelId: thread, memberId: ownerId, kind: "thread", parentChannelId: parent, name: "thread")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "thread-mutate-agent")

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
                request.body = .init(string: "{\"email\":\"thread-mutate-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let probes: [(String, HTTPRequest.Method, String, String?)] = [
                ("add", .post, "/api/channels/\(thread)/members", "{\"userId\":\"\(ownerId)\"}"),
                ("remove human", .delete, "/api/channels/\(thread)/members/user/\(ownerId)", nil),
                ("remove agent", .delete, "/api/channels/\(thread)/members/agent/\(agent)", nil),
                ("join", .post, "/api/channels/\(thread)/join", nil),
                ("leave", .post, "/api/channels/\(thread)/leave", nil),
                ("role", .patch, "/api/channels/\(thread)/members/user/\(ownerId)/role", "{\"role\":\"admin\"}"),
            ]
            for (label, method, path, body) in probes {
                let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                #expect(response.status == .badRequest, "\(label) should be 400")
                let error = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String ?? ""
                #expect(error.localizedCaseInsensitiveContains("follow/unfollow"))
            }
            #expect(!accounts.oauth.channelHumanIds(channelId: thread).contains(ownerId))
            #expect(!accounts.oauth.channelAgentIds(channelId: thread).contains(agent))
        }
    }
}
