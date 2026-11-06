import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentResolveHidesPrivateChannelsFromOutsiders() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111521"
    let serverId = "33333333-3333-4333-8333-333333333605"
    accounts.addAccount(id: ownerId, email: "resolve-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "resolve-private", name: "Resolve Private", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "secret-room", creatorUserId: ownerId, type: "private")
    accounts.oauth.setChannelType(id: channel, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, kind: "private", name: "secret-room")
    let invited = accounts.oauth.createAgent(serverId: serverId, name: "resolve-invited")
    let outsider = accounts.oauth.createAgent(serverId: serverId, name: "resolve-outsider")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: invited)
    let invitedKey = accounts.mintAgentCredential(agentId: invited, scopes: ["channels", "send"], name: "invited")
    let outsiderKey = accounts.mintAgentCredential(agentId: outsider, scopes: ["channels", "send"], name: "outsider")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func resolve(_ key: String) async throws -> ([String: Any], Int) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/internal/agent-api/resolve-channel") { request in
                    request.body = .init(string: "{\"target\":\"#secret-room\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:], response.status.code)
            }
            let invitedResult = try await resolve(invitedKey)
            #expect(invitedResult.1 == 200)
            #expect(invitedResult.0["channelId"] as? String == channel)
            #expect(invitedResult.0["type"] as? String == "private")
            let outsiderResult = try await resolve(outsiderKey)
            #expect(outsiderResult.1 == 404, Comment(rawValue: "\(outsiderResult.1) \(outsiderResult.0)"))
        }
    }
}
