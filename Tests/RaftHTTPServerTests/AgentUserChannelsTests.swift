import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func agentUserChannelsGatesCapabilitiesVisibilityAndPaging() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111635"
    let subjectId = "11111111-1111-4111-8111-111111111636"
    let serverId = "33333333-3333-4333-8333-333333333678"
    accounts.addAccount(id: ownerId, email: "user-channels-owner@test.invalid", password: "password123")
    accounts.addAccount(id: subjectId, email: "user-channels-subject@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: subjectId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "user-channels", name: "User Channels", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: subjectId, role: "member")
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "UserChannelsBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "user-channels-room", creatorUserId: ownerId, type: "channel")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: subjectId)
    let fullScopes = ["channels", "read", "channel:read", "server:read"]
    let key = accounts.mintAgentCredential(agentId: agentId, scopes: fullScopes, name: "user-channels")
    let channelsOnly = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels"], name: "channels-only")
    let noChannelRead = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels", "read", "server:read"], name: "no-channel-read")
    let noServerRead = accounts.mintAgentCredential(agentId: agentId, scopes: ["channels", "read", "channel:read"], name: "no-server-read")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func call(_ key: String, _ name: String, query: String = "") async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
                let response = try await client.get(URI(string: "/internal/agent-api/users/\(encoded)/channels\(query)"), headers: headers)
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let channelsCap = try await call(channelsOnly, "user-channels-subject")
            #expect(channelsCap.0.status == .forbidden)
            #expect(channelsCap.1["requiredCapability"] as? String == "read")
            let channelRead = try await call(noChannelRead, "user-channels-subject")
            #expect(channelRead.0.status == .forbidden)
            #expect(channelRead.1["requiredScope"] as? String == "channel:read")
            let serverRead = try await call(noServerRead, "user-channels-subject")
            #expect(serverRead.0.status == .forbidden)
            #expect(serverRead.1["requiredScope"] as? String == "server:read")

            let unknown = try await call(key, "nobody")
            #expect(unknown.0.status == .notFound)
            #expect(unknown.1["code"] as? String == "user_not_found")
            let caseSensitive = try await call(key, "User-Channels-Subject")
            #expect(caseSensitive.0.status == .notFound)

            // Pinned `routes/internalAgentApi.ts:418-426` runs
            // `agentApiUserChannelsQuerySchema` and publishes its zod 4.3.6
            // issues under `agent_api_contract_invalid`.
            let limitIssue = #"{"error":"Invalid agent-api userChannels query","code":"agent_api_contract_invalid","issues":[{"path":"limit","message":"must be an integer from 1 to 200"}]}"#
            let offsetIssue = #"{"error":"Invalid agent-api userChannels query","code":"agent_api_contract_invalid","issues":[{"path":"offset","message":"must be a non-negative integer"}]}"#
            for (query, expected) in [
                ("?limit=201", limitIssue),
                ("?limit=0", limitIssue),
                ("?limit=-1", limitIssue),
                ("?offset=-1", offsetIssue),
                ("?offset=1.5", offsetIssue),
                ("?limit=abc", limitIssue),
                (
                    "?offset=-1&limit=0",
                    #"{"error":"Invalid agent-api userChannels query","code":"agent_api_contract_invalid","issues":[{"path":"offset","message":"must be a non-negative integer"},{"path":"limit","message":"must be an integer from 1 to 200"}]}"#
                ),
            ] {
                let invalid = try await call(key, "user-channels-subject", query: query)
                #expect(invalid.0.status == .badRequest, "\(query)")
                #expect(invalid.0.body.string == expected, "\(query)")
            }
            let page = try await call(key, "@user-channels-subject", query: "?limit=200")
            #expect(page.0.status == .ok)
            let pageInfo = page.1["page"] as? [String: Any]
            #expect(pageInfo?["limit"] as? Int == 200)
            #expect(pageInfo?["offset"] as? Int == 0)
            let memberships = page.1["memberships"] as? [[String: Any]] ?? []
            #expect(memberships.contains { $0["id"] as? String == channelId })
            accounts.setChannelHumanRoleForTesting(channelId: channelId, userId: subjectId, role: "admin")
            let promoted = try await call(key, "user-channels-subject")
            let promotedRows = promoted.1["memberships"] as? [[String: Any]] ?? []
            #expect(promotedRows.first { $0["id"] as? String == channelId }?["channelRole"] as? String == "admin")

            accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)
            let hidden = try await call(key, "user-channels-subject")
            #expect(hidden.0.status == .notFound)
            accounts.oauth.setAgentRole(serverId: serverId, agentId: agentId, role: "admin")
            let admin = try await call(key, "user-channels-subject")
            #expect(admin.0.status == .ok)

            var infoHeaders = HTTPFields()
            infoHeaders[.authorization] = "Bearer \(key)"
            let encodedInfo = "user-channels-subject".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "user-channels-subject"
            let info = try await client.get(URI(string: "/internal/agent-api/users/info?name=\(encodedInfo)"), headers: infoHeaders)
            #expect(info.status == .ok)
            let infoText = info.body.string ?? ""
            #expect(infoText.contains("#user-channels-room"))
            #expect(!infoText.lowercased().contains("admin"))
        }
    }
}

@Test func userChannelsJoinActiveJointProjectionsOnly() async throws {
    let accounts = EmailLoginDirectory()
    let ownerA = "11111111-1111-4111-8111-111111111637"
    let scout = "11111111-1111-4111-8111-111111111638"
    let mem = "11111111-1111-4111-8111-111111111639"
    let alice = "11111111-1111-4111-8111-111111111640"
    let serverA = "33333333-3333-4333-8333-333333333679"
    let serverB = "33333333-3333-4333-8333-333333333680"
    for (id, email) in [(ownerA, "uc-owner@test.invalid"), (scout, "scout@test.invalid"), (mem, "mem@test.invalid"), (alice, "alice@test.invalid")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverA, slug: "uc-a", name: "UC A", ownerId: ownerA)
    accounts.oauth.addOwnedServer(id: serverB, slug: "uc-b", name: "UC B", ownerId: alice)
    accounts.oauth.addMember(serverId: serverA, userId: scout, role: "member")
    accounts.oauth.addMember(serverId: serverA, userId: mem, role: "member")
    let local = accounts.oauth.createChannel(serverId: serverA, name: "joint-local", creatorUserId: ownerA, type: "joint")
    let peer = accounts.oauth.createChannel(serverId: serverB, name: "joint-local", creatorUserId: alice, type: "joint")
    let canonical = accounts.oauth.createChannel(serverId: serverA, name: "joint-storage", creatorUserId: ownerA)
    for user in [scout, mem] { accounts.oauth.addChannelHuman(channelId: local, userId: user) }
    accounts.oauth.addChannelHuman(channelId: peer, userId: alice)
    accounts.addJointChannelProjection(localChannelId: local, canonicalChannelId: canonical, serverId: serverA)
    accounts.addJointChannelProjection(localChannelId: peer, canonicalChannelId: canonical, serverId: serverB)
    let adminAgent = accounts.oauth.createAgent(serverId: serverA, name: "UCAdmin", creatorUserId: ownerA, runtime: "claude")
    let memberAgent = accounts.oauth.createAgent(serverId: serverA, name: "UCMember", creatorUserId: ownerA, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: local, agentId: adminAgent)
    _ = memberAgent
    let adminKey = accounts.mintAgentCredential(agentId: adminAgent, scopes: ["channels", "read", "channel:read", "server:read"], name: "uc-admin")
    let memberKey = accounts.mintAgentCredential(agentId: memberAgent, scopes: ["channels", "read", "channel:read", "server:read"], name: "uc-member")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func call(_ key: String, _ name: String) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key)"
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
                let response = try await client.get(URI(string: "/internal/agent-api/users/\(encoded)/channels?limit=200"), headers: headers)
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let scoutRows = try await call(adminKey, "scout")
            let memberships = scoutRows["memberships"] as? [[String: Any]] ?? []
            #expect(memberships.contains { $0["id"] as? String == local && ($0["type"] as? String) == "joint" })
            #expect(!memberships.contains { $0["id"] as? String == peer })
            #expect((scoutRows["uncheckedCount"] as? Int ?? 0) == 0)

            let memRead = try await call(memberKey, "scout")
            let memRows = memRead["memberships"] as? [[String: Any]] ?? []
            #expect(!memRows.contains { $0["id"] as? String == local })
            #expect((memRead["uncheckedCount"] as? Int ?? 0) >= 1)

            accounts.setJointProjectionStatusForTesting(localChannelId: local, serverId: serverA, status: "disconnected")
            let disconnected = try await call(adminKey, "mem")
            let disconnectedRows = disconnected["memberships"] as? [[String: Any]] ?? []
            #expect(!disconnectedRows.contains { $0["id"] as? String == local })
            #expect((disconnected["uncheckedCount"] as? Int ?? 0) >= 1)

            accounts.oauth.addChannelHuman(channelId: local, userId: mem)
            accounts.setJointProjectionStatusForTesting(localChannelId: local, serverId: serverA, status: "active")
            accounts.setChannelHumanRoleForTesting(channelId: local, userId: mem, role: "admin")
            let memRowsActive = try await call(adminKey, "mem")
            let memMemberships = memRowsActive["memberships"] as? [[String: Any]] ?? []
            #expect(memMemberships.contains { $0["id"] as? String == local })
        }
    }
}
