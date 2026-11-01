import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func eventsSenderTypeEchoMirrorsTheAgentFacingSenderType() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111112101"
    let serverId = "33333333-3333-4333-8333-333333335101"
    let ownerEmail = "events-sendertype-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "events-sendertype", name: "Events SenderType Test", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "EventsSenderTypeExt", runtime: "external")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "events-sendertype-room", creatorUserId: ownerId)
    for member in [ownerId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: member, name: "events-sendertype-room")
    }
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let created = try accounts.oauth.createClient(
        serverId: serverId,
        createdByUserId: ownerId,
        name: "External Build App",
        clientId: "external-build-app",
        allowedScopes: ["openid", "agent:event:write"]
    )
    let thirdPartyId = UUID().uuidString.lowercased()
    accounts.oauth.addThirdPartyAgentEventForTesting(
        id: thirdPartyId,
        serverId: serverId,
        agentId: agent,
        clientRecordId: created.id,
        kind: "event",
        summary: "from a third-party app @owner",
        payloadJSON: "{\"status\":\"ready\"}",
        expiresAt: Date().addingTimeInterval(60_000),
        status: "delivering"
    )
    let systemId = accounts.addSystemMessageForTesting(channelId: channel, content: "from the system")
    let externalId = accounts.addExternalProjectionMessageForTesting(
        channelId: channel,
        senderName: "Alice External",
        content: "hello <result> @owner",
        externalMessageId: "1722387723.000100"
    )
    let apiKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send", "read"], name: "events-sendertype-test")

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
            let ownerToken = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var messageHeaders = HTTPFields()
            messageHeaders[.authorization] = "Bearer \(ownerToken)"
            messageHeaders[.contentType] = "application/json"
            messageHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let posted = try await client.send(.post, headers: messageHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"from a human\"}")
            }
            #expect(posted.status == .ok)
            let humanId = (try JSONSerialization.jsonObject(with: Data((posted.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""

            var eventHeaders = HTTPFields()
            eventHeaders[.authorization] = "Bearer \(apiKey)"
            let response = try await client.get("/internal/agent-api/events", headers: eventHeaders)
            #expect(response.status == .ok)
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
            let events = body?["events"] as? [[String: Any]] ?? []
            let byId = Dictionary(uniqueKeysWithValues: events.compactMap { row -> (String, [String: Any])? in
                guard let id = row["message_id"] as? String else { return nil }
                return (id, row)
            })

            #expect(byId[humanId]?["sender_type"] as? String == "human")
            #expect(byId[humanId]?["senderType"] as? String == "human")
            #expect(byId[humanId]?["sender_name"] as? String == "events-sendertype-owner")
            #expect(byId[systemId]?["sender_type"] as? String == "system")
            #expect(byId[systemId]?["senderType"] as? String == "system")

            #expect(byId[thirdPartyId]?["sender_type"] as? String == "third_party_app")
            #expect(byId[thirdPartyId]?["senderType"] as? String == "third_party_app")
            #expect(((byId[thirdPartyId]?["third_party_event"] as? [String: Any])?["source"] as? [String: Any])?["client_id"] as? String == "external-build-app")
            #expect(byId[thirdPartyId]?["content"] as? String == "from a third-party app user:owner")

            #expect(byId[externalId]?["sender_type"] as? String == "third_party_app")
            #expect(byId[externalId]?["senderType"] as? String == "third_party_app")
            #expect(byId[externalId]?["mentioned"] as? Bool == false)
            #expect((byId[externalId]?["external_message"] as? [String: Any])?["message_id"] as? String == "1722387723.000100")
            #expect(byId[externalId]?["content"] as? String == "hello <result> @owner")

            let replay = try await client.get("/internal/agent-api/events", headers: eventHeaders)
            #expect(((try? JSONSerialization.jsonObject(with: Data((replay.body.string ?? "").utf8))) as? [String: Any])?["events"] as? [[String: Any]] != nil)
            let replayEvents = ((try? JSONSerialization.jsonObject(with: Data((replay.body.string ?? "").utf8))) as? [String: Any])?["events"] as? [[String: Any]] ?? []
            #expect(replayEvents.isEmpty)
        }
    }
}
