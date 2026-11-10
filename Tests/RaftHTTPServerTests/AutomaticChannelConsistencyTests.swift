import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private func automaticChannelHeaders(_ token: String, serverId: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return headers
}

private func automaticChannelJSON(_ response: ClientResponse) throws -> Any {
    try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))
}

private func automaticChannelObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(try automaticChannelJSON(response) as? [String: Any])
}

private func automaticChannelLogin(_ client: any TestClient, email: String) async throws -> String {
    let response = try await client.send(.post, headers: automaticChannelHeaders(""), to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    #expect(response.status == .ok)
    return try #require(try automaticChannelObject(response)["accessToken"] as? String)
}

@Test func ordinaryServerAndAgentCreationPublishImmediatelyUsableChannels() async throws {
    let accounts = EmailLoginDirectory()
    for (id, email) in [
        ("11111111-1111-4111-8111-111111112171", "automatic-channel-owner@slock.test"),
        ("11111111-1111-4111-8111-111111112172", "automatic-channel-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    // No pre-created server, OAuth channel, postable row, runtime provider or
    // machine fixture: both positive channel identities come from public HTTP.
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let owner = try await automaticChannelLogin(client, email: "automatic-channel-owner@slock.test")
            let outsider = try await automaticChannelLogin(client, email: "automatic-channel-outsider@slock.test")
            func createServer(_ token: String, slug: String) async throws -> String {
                let response = try await client.send(.post, headers: automaticChannelHeaders(token), to: "/api/servers") { request in
                    request.body = .init(string: "{\"name\":\"Automatic channels\",\"slug\":\"\(slug)\"}")
                }
                #expect(response.status == .ok)
                return try #require(try automaticChannelObject(response)["id"] as? String)
            }
            let serverId = try await createServer(owner, slug: "automatic-channels-primary")
            let otherServerId = try await createServer(outsider, slug: "automatic-channels-other")
            accounts.oauth.addMember(serverId: otherServerId, userId: "11111111-1111-4111-8111-111111112171", role: "member")
            let ownerHeaders = automaticChannelHeaders(owner, serverId: serverId)
            let listed = try await client.get("/api/channels", headers: ownerHeaders)
            #expect(listed.status == .ok)
            let channels = try #require(try automaticChannelJSON(listed) as? [[String: Any]])
            let allId = try #require(channels.first { $0["name"] as? String == "all" }?["id"] as? String)
            func page(_ channelId: String, headers: HTTPFields) async throws -> ClientResponse {
                try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            }
            func postAndRead(_ channelId: String, content: String) async throws {
                let posted = try await client.send(.post, headers: ownerHeaders, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}")
                }
                #expect(posted.status == .ok)
                let response = try await page(channelId, headers: ownerHeaders)
                #expect(response.status == .ok)
                let rows = try #require(try automaticChannelObject(response)["messages"] as? [[String: Any]])
                #expect(rows.contains { $0["content"] as? String == content })
            }
            let emptyAll = try await page(allId, headers: ownerHeaders)
            #expect(emptyAll.status == .ok)
            #expect(try automaticChannelObject(emptyAll)["messages"] as? [[String: String]] == [])
            try await postAndRead(allId, content: "ordinary all channel write")

            let created = try await client.send(.post, headers: ownerHeaders, to: "/api/agents") { request in
                request.body = .init(string: #"{"name":"automatic-channel-agent","runtimeConfig":{"version":1,"runtime":"codex","model":{"kind":"custom","name":"protocol-only-model"}}}"#)
            }
            #expect(created.status == .ok)
            let agentId = try #require(try automaticChannelObject(created)["id"] as? String)
            let directList = try await client.get("/api/channels/dm", headers: ownerHeaders)
            #expect(directList.status == .ok)
            let directRows = try #require(try automaticChannelJSON(directList) as? [[String: Any]])
            let dmId = try #require(directRows.first { $0["peerId"] as? String == agentId }?["id"] as? String)
            let emptyDM = try await page(dmId, headers: ownerHeaders)
            #expect(emptyDM.status == .ok)
            #expect(try automaticChannelObject(emptyDM)["messages"] as? [[String: String]] == [])
            try await postAndRead(dmId, content: "ordinary creator DM write")
            let reopened = try await client.send(.post, headers: ownerHeaders, to: "/api/channels/dm") { request in
                request.body = .init(string: "{\"agentId\":\"\(agentId)\"}")
            }
            #expect(reopened.status == .ok)
            #expect(try automaticChannelObject(reopened)["id"] as? String == dmId)
            let afterReopen = try await page(dmId, headers: ownerHeaders)
            #expect(afterReopen.status == .ok)
            let retained = try #require(try automaticChannelObject(afterReopen)["messages"] as? [[String: Any]])
            #expect(retained.contains { $0["content"] as? String == "ordinary creator DM write" })
            // No membership in the primary server; no access to its private DM.
            #expect(try await page(dmId, headers: automaticChannelHeaders(outsider, serverId: serverId)).status == .forbidden)
            #expect(try await page(dmId, headers: automaticChannelHeaders(owner, serverId: otherServerId)).status == .notFound)
            let deniedWrite = try await client.send(.post, headers: automaticChannelHeaders(outsider, serverId: serverId), to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(allId)\",\"content\":\"not a member\"}")
            }
            #expect(deniedWrite.status == .forbidden)
            let ownerPage = try await page(allId, headers: ownerHeaders)
            let ownerRows = try #require(try automaticChannelObject(ownerPage)["messages"] as? [[String: Any]])
            let messageId = try #require(ownerRows.first?["id"] as? String)
            for path in [
                "/api/messages/channel/\(allId)", "/api/messages/sync?channel_id=\(allId)",
                "/api/messages/sync", "/api/messages/\(messageId)/mention-deliveries", "/api/channels/inbox/done",
            ] {
                let denied = try await client.get(URI(string: path), headers: automaticChannelHeaders(outsider, serverId: serverId))
                #expect(denied.status == .forbidden)
                #expect(try automaticChannelObject(denied) as NSDictionary == ["error": "Not a member of this server"] as NSDictionary)
            }
            let missingScope = try await page(allId, headers: automaticChannelHeaders(owner))
            #expect(missingScope.status == .badRequest)
            #expect(try automaticChannelObject(missingScope) as NSDictionary == ["error": "Missing X-Server-Id header"] as NSDictionary)
            // Server membership alone must not grant another user's private DM.
            accounts.oauth.addMember(serverId: serverId, userId: "11111111-1111-4111-8111-111111112172", role: "member")
            let unrelatedMember = automaticChannelHeaders(outsider, serverId: serverId)
            #expect(try await page(allId, headers: unrelatedMember).status == .ok)
            #expect(try await page(dmId, headers: unrelatedMember).status == .notFound)
            let privateWrite = try await client.send(.post, headers: unrelatedMember, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(dmId)\",\"content\":\"not a DM participant\"}")
            }
            #expect(privateWrite.status == .forbidden)
            // Node permits this guest read when its actual guest gate and
            // all-channel visibility are enabled; the shared server gate must
            // accept guest membership, not impose owner/admin/member roles.
            accounts.enableGuestRoleTransitions(serverId: serverId)
            accounts.createFeatureFlagForTesting(key: "server_guest_v0", enabled: true, killSwitch: false)
            accounts.addFeatureFlagRuleForTesting(key: "server_guest_v0", stage: "server", decision: "allow", values: [serverId])
            accounts.setChannelGuestVisibleForTesting(channelId: allId, visible: true)
            accounts.oauth.addMember(serverId: serverId, userId: "11111111-1111-4111-8111-111111112172", role: "guest")
            accounts.oauth.addChannelHuman(channelId: allId, userId: "11111111-1111-4111-8111-111111112172")
            #expect(try await page(allId, headers: unrelatedMember).status == .ok)
            accounts.oauth.removeMember(serverId: serverId, userId: "11111111-1111-4111-8111-111111112172")
            let retired = try await page(allId, headers: unrelatedMember)
            #expect(retired.status == .forbidden)
            #expect(try automaticChannelObject(retired)["error"] as? String == "Not a member of this server")
            accounts.oauth.deleteServer(id: serverId)
            #expect(try await page(allId, headers: ownerHeaders).status == .forbidden)
        }
    }
}

@Test func ordinaryOpenDMRepairsAnExistingOAuthOnlyCreatorChannelWithoutChangingItsIdentity() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111112173"
    let serverId = "33333333-3333-4333-8333-333333334173"
    accounts.addAccount(id: userId, email: "automatic-channel-legacy@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "automatic-channel-legacy", name: "Legacy OAuth facts", ownerId: userId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "legacy-channel-agent", creatorUserId: userId, runtime: "codex")
    let channelId = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: userId, secondUserId: agentId)
    accounts.oauth.removeChannelHuman(channelId: channelId, userId: agentId)
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    // Exactly the previous committed OAuth-only shape, with no postable seed.
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let token = try await automaticChannelLogin(client, email: "automatic-channel-legacy@slock.test")
            let headers = automaticChannelHeaders(token, serverId: serverId)
            let path = URI(string: "/api/messages/channel/\(channelId)")
            #expect(try await client.get(path, headers: headers).status == .notFound)
            for _ in 0..<2 {
                let opened = try await client.send(.post, headers: headers, to: "/api/channels/dm") { request in
                    request.body = .init(string: "{\"agentId\":\"\(agentId)\"}")
                }
                #expect(opened.status == .ok)
                #expect(try automaticChannelObject(opened)["id"] as? String == channelId)
            }
            let readable = try await client.get(path, headers: headers)
            #expect(readable.status == .ok)
            #expect(try automaticChannelObject(readable)["messages"] as? [[String: String]] == [])
            let posted = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(channelId)\",\"content\":\"canonical open DM repaired posting\"}")
            }
            #expect(posted.status == .ok)
            let result = try await client.get(path, headers: headers)
            #expect(result.status == .ok)
            let messages = try #require(try automaticChannelObject(result)["messages"] as? [[String: Any]])
            #expect(messages.contains { $0["content"] as? String == "canonical open DM repaired posting" })
        }
    }
}
