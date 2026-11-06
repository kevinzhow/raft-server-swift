import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// The legacy handlers read `bodyText` and parsed JSON themselves, so a body
/// sent without a JSON `Content-Type` was accepted. The typed routes keep that
/// behavior through `jsonRequestBody`'s raw-bytes fallback.
@Test func agentSendAcceptsABodyWithoutAJSONContentType() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111990101"
    let serverId = "33333333-3333-4333-8333-333333990101"
    accounts.oauth.addOwnedServer(id: serverId, slug: "no-content-type", name: "No Content Type", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "HeaderlessBot")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "general", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "general")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "headerless-machine")
    let key = accounts.machineAPIKey(machineId: machine) ?? ""

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            let response = try await client.send(
                .post,
                headers: headers,
                to: "/internal/agent/\(agent)/send"
            ) { request in
                request.body = .init(string: "{\"target\":\"#general\",\"content\":\"headerless\"}")
            }
            #expect(response.status == .ok)
            let raw = response.body.string ?? ""
            // The route must publish the DTO's legacy byte order, not the
            // nondeterministic JSONEncoder key order.
            let idIndex = try #require(raw.range(of: "\"id\""))
            let channelIndex = try #require(raw.range(of: "\"channelId\""))
            #expect(idIndex.lowerBound < channelIndex.lowerBound)
            #expect(raw.hasSuffix("}"))
            let body = (try JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            #expect(body["channelId"] as? String == channel)
            #expect(body["id"] as? String != nil)
        }
    }
}

@Test func activityIngestAcceptsABodyWithoutAJSONContentType() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111990102"
    let serverId = "33333333-3333-4333-8333-333333990102"
    accounts.oauth.addOwnedServer(id: serverId, slug: "activity-headerless", name: "Activity Headerless", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "HeaderlessActivityBot")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "headerless")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(key)"
            let response = try await client.send(
                .post,
                headers: headers,
                to: "/internal/agent-api/activity"
            ) { request in
                request.body = .init(string: "{\"events\":[]}")
            }
            #expect(response.status == .ok)
            let body = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(body["acceptedCount"] as? Int == 0)
            #expect(body["rejectedCount"] as? Int == 0)
        }
    }
}
