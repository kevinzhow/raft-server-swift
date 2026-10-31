import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func internalAgentSendResolvesTheChannelAndHonorsArchive() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111427"
    let serverId = "33333333-3333-4333-8333-333333333550"
    accounts.addAccount(id: ownerId, email: "agent-send@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-send", name: "Agent Send", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "SendAgent")
    let outsiderAgent = accounts.oauth.createAgent(serverId: serverId, name: "OutsiderAgent")
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "agent-send-machine")
    let apiKey = accounts.machineAPIKey(machineId: machineId) ?? ""

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
                request.body = .init(string: "{\"email\":\"agent-send@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var userHeaders = HTTPFields()
            userHeaders[.authorization] = "Bearer \(token)"
            userHeaders[.contentType] = "application/json"
            userHeaders[HTTPField.Name("X-Server-Id")!] = serverId

            let channel = try await client.send(.post, headers: userHeaders, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"agent-send-room\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            accounts.oauth.addChannelAgent(channelId: channelId, agentId: agent)

            func send(_ agentId: String, _ target: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(apiKey)"
                headers[.contentType] = "application/json"
                return try await client.send(.post, headers: headers, to: "/internal/agent/\(agentId)/send") { request in
                    request.body = .init(string: "{\"target\":\"\(target)\",\"content\":\"agent message\"}")
                }
            }
            func json(_ response: ClientResponse) throws -> [String: Any] {
                try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let sent = try await send(agent, "#agent-send-room")
            #expect(sent.status == .ok)
            #expect((try json(sent)["channelId"] as? String) == channelId)

            #expect(try await send(outsiderAgent, "#agent-send-room").status == .forbidden)
            #expect(try await send(agent, "#missing-room").status == .notFound)

            #expect(try await client.send(.post, headers: userHeaders, to: "/api/channels/\(channelId)/archive").status == .ok)
            let frozen = try await send(agent, "#agent-send-room")
            #expect(frozen.status == .conflict)
            #expect(try json(frozen)["code"] as? String == "channel_archived")
            #expect(try await client.send(.post, headers: userHeaders, to: "/api/channels/\(channelId)/unarchive").status == .ok)
            #expect(try await send(agent, "#agent-send-room").status == .ok)
        }
    }
}
