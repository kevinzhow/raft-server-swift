import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct DiscoveryFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerToken: String
    let memberId: String
    let memberToken: String
}

private func makeDiscoveryFixture(_ suffix: String) -> DiscoveryFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001330\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001331\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001330\(suffix)"
    accounts.addAccount(id: ownerId, email: "discovery-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "discovery-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "discovery-\(suffix)", name: "Discovery \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    return DiscoveryFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberId: memberId,
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId)
    )
}

private func discoveryHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func discoveryJSON(_ response: ClientResponse) throws -> Any {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as Any
}

@Test func agentIdentityRejectsNonUUIDReservedAndDuplicateHandles() async throws {
    let f = makeDiscoveryFixture("901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let nonUUID = try await client.get(URI(string: "/api/agents/not-a-uuid"), headers: discoveryHeaders(f.ownerToken, f.serverId))
            #expect(nonUUID.status == .notFound)
            let nonUUIDBody = (try discoveryJSON(nonUUID)) as? [String: Any] ?? [:]
            #expect(nonUUIDBody["error"] as? String == "Agent not found")
            #expect(nonUUIDBody["code"] == nil)

            for name in ["all", "Human", "HUMANS", "agent", "Agents", "here", "Idle", "BUSY", "system", "reminders", "Reminders"] {
                let response = try await client.send(.post, headers: discoveryHeaders(f.ownerToken, f.serverId), to: "/api/agents") { request in
                    request.body = .init(string: "{\"name\":\"\(name)\",\"runtime\":\"codex\"}")
                }
                #expect(response.status == .badRequest, "\(name) must be reserved")
                let body = (try discoveryJSON(response)) as? [String: Any] ?? [:]
                #expect((body["error"] as? String)?.lowercased().contains("is reserved. choose another name.") == true)
            }

            let valid = try await client.send(.post, headers: discoveryHeaders(f.ownerToken, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"agent-helper\",\"runtime\":\"codex\"}")
            }
            #expect(valid.status == .ok)
            #expect(((try discoveryJSON(valid)) as? [String: Any])?["name"] as? String == "agent-helper")

            let duplicate = try await client.send(.post, headers: discoveryHeaders(f.ownerToken, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"agent-helper\",\"runtime\":\"codex\"}")
            }
            #expect(duplicate.status == .conflict)
            let duplicateBody = (try discoveryJSON(duplicate)) as? [String: Any] ?? [:]
            #expect((duplicateBody["error"] as? String)?.lowercased().contains("already taken") == true)
        }
    }
}

@Test func agentCreatorIsBoundAtCreationAndCannotBePatched() async throws {
    let f = makeDiscoveryFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await client.send(.post, headers: discoveryHeaders(f.ownerToken, f.serverId), to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"creator-agent-902\",\"runtime\":\"codex\"}")
            }
            #expect(created.status == .ok)
            let body = (try discoveryJSON(created)) as? [String: Any] ?? [:]
            let agentId = try #require(body["id"] as? String)
            let creator = try #require(body["creator"] as? [String: Any])
            #expect(creator["type"] as? String == "human")
            #expect(creator["id"] as? String == f.ownerId)

            let forbidden = try await client.send(.patch, headers: discoveryHeaders(f.memberToken, f.serverId), to: "/api/agents/\(agentId)/creator") { request in
                request.body = .init(string: "{\"creatorType\":\"user\",\"creatorId\":\"\(f.memberId)\"}")
            }
            #expect(forbidden.status == .notFound)

            let fetched = try await client.get(URI(string: "/api/agents/\(agentId)"), headers: discoveryHeaders(f.ownerToken, f.serverId))
            let fetchedBody = (try discoveryJSON(fetched)) as? [String: Any] ?? [:]
            #expect((fetchedBody["creator"] as? [String: Any])?["id"] as? String == f.ownerId)
        }
    }
}

@Test func memberViewAgentsAuthorityReachesRuntimeOptions() async throws {
    let f = makeDiscoveryFixture("903")
    let agentId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "runtime-options-agent-903", creatorUserId: f.ownerId, runtime: "codex")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let options = try await client.get(URI(string: "/api/agents/\(agentId)/runtime-options"), headers: discoveryHeaders(f.memberToken, f.serverId))
            #expect(options.status == .ok)
        }
    }
}

@Test func agentDirectMessagesListOnlyAgentToAgentConversations() async throws {
    let f = makeDiscoveryFixture("904")
    let agentA = f.accounts.oauth.createAgent(serverId: f.serverId, name: "agent-dm-a-904", creatorUserId: f.ownerId, runtime: "codex")
    let agentB = f.accounts.oauth.createAgent(serverId: f.serverId, name: "agent-dm-b-904", creatorUserId: f.ownerId, runtime: "codex")
    let a2aDm = f.accounts.createAgentDirectChannelForTesting(serverId: f.serverId, firstAgentId: agentA, secondAgentId: agentB)
    f.accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: a2aDm, senderId: agentA, content: "agent to agent preview", senderType: "agent")
    let humanDm = f.accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: f.memberId, secondUserId: agentA)
    f.accounts.oauth.addChannelHuman(channelId: humanDm, userId: f.memberId)
    f.accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: humanDm, senderId: f.memberId, content: "human private message")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/agents/\(agentA)/agent-dms"), headers: discoveryHeaders(f.ownerToken, f.serverId))
            #expect(response.status == .ok)
            let rows = (try discoveryJSON(response)) as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            #expect(rows[0]["id"] as? String == a2aDm)
            #expect(rows[0]["peerId"] as? String == agentB)
            #expect(rows[0]["peerName"] as? String == "agent-dm-b-904")
            #expect(rows[0]["lastMessagePreview"] as? String == "agent to agent preview")
        }
    }
}

@Test func agentDirectMessagePreviewSkipsTrailingSystemMessages() async throws {
    let f = makeDiscoveryFixture("905")
    let agentA = f.accounts.oauth.createAgent(serverId: f.serverId, name: "agent-dm-a-905", creatorUserId: f.ownerId, runtime: "codex")
    let agentB = f.accounts.oauth.createAgent(serverId: f.serverId, name: "agent-dm-b-905", creatorUserId: f.ownerId, runtime: "codex")
    let a2aDm = f.accounts.createAgentDirectChannelForTesting(serverId: f.serverId, firstAgentId: agentA, secondAgentId: agentB)
    f.accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: a2aDm, senderId: agentA, content: "real chat preview", senderType: "agent")
    f.accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: a2aDm, senderId: agentA, content: "ACTIVITY ONLY", messageType: "system", senderType: "agent")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/agents/\(agentA)/agent-dms"), headers: discoveryHeaders(f.ownerToken, f.serverId))
            let rows = (try discoveryJSON(response)) as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            #expect(rows[0]["lastMessagePreview"] as? String == "real chat preview")
        }
    }
}

@Test func agentChannelsProjectViewerVisibilityAndAgentMuteState() async throws {
    let f = makeDiscoveryFixture("906")
    let agentA = f.accounts.oauth.createAgent(serverId: f.serverId, name: "channels-agent-a-906", creatorUserId: f.ownerId, runtime: "codex")
    _ = f.accounts.oauth.createAgent(serverId: f.serverId, name: "channels-agent-b-906", creatorUserId: f.ownerId, runtime: "codex")
    func channel(_ name: String, type: String, description: String?, agentMember: Bool, viewerMember: Bool) -> String {
        let id = f.accounts.oauth.createChannel(serverId: f.serverId, name: name, creatorUserId: f.ownerId, type: type)
        if viewerMember {
            f.accounts.addPostableChannel(serverId: f.serverId, channelId: id, memberId: f.ownerId, kind: type, name: name)
            f.accounts.oauth.addChannelHuman(channelId: id, userId: f.ownerId)
        }
        if agentMember {
            f.accounts.oauth.addChannelAgent(channelId: id, agentId: agentA)
            f.accounts.addPostableChannel(serverId: f.serverId, channelId: id, memberId: agentA, kind: type, name: name)
        }
        if let description {
            f.accounts.oauth.updateChannel(id: id, name: nil, description: description, systemMessage: nil)
        }
        return id
    }
    let publicChannel = channel("alpha-public-906", type: "channel", description: "visible public channel", agentMember: true, viewerMember: false)
    let privateChannel = channel("beta-private-906", type: "private", description: "private membership", agentMember: true, viewerMember: true)
    let jointChannel = channel("gamma-joint-906", type: "joint", description: nil, agentMember: true, viewerMember: true)
    _ = channel("delta-hidden-private-906", type: "private", description: nil, agentMember: true, viewerMember: false)
    _ = channel("epsilon-hidden-joint-906", type: "joint", description: nil, agentMember: true, viewerMember: false)
    let a2aDm = f.accounts.createAgentDirectChannelForTesting(serverId: f.serverId, firstAgentId: agentA, secondAgentId: agentA)
    f.accounts.setAgentMuteForTesting(channelId: privateChannel, agentId: agentA, serverId: f.serverId, muteFromSeq: 7)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/agents/\(agentA)/channels"), headers: discoveryHeaders(f.ownerToken, f.serverId))
            #expect(response.status == .ok)
            let rows = (try discoveryJSON(response)) as? [[String: Any]] ?? []
            let byName = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
                guard let name = row["name"] as? String else { return nil }
                return (name, row)
            })
            #expect(byName["all"] == nil, "the virtual #all channel is not an explicit agent membership")
            #expect(byName["alpha-public-906"]?["id"] as? String == publicChannel)
            #expect(byName["alpha-public-906"]?["type"] as? String == "channel")
            #expect(byName["alpha-public-906"]?["description"] as? String == "visible public channel")
            #expect(byName["alpha-public-906"]?["activityMuted"] as? Bool == false)
            #expect(byName["beta-private-906"]?["type"] as? String == "private")
            #expect(byName["beta-private-906"]?["description"] as? String == "private membership")
            #expect(byName["beta-private-906"]?["activityMuted"] as? Bool == true, "the agent's own mute state projects here")
            #expect(byName["beta-private-906"]?["muteFromSeq"] as? Int == 7)
            #expect(byName["gamma-joint-906"]?["type"] as? String == "joint")
            #expect(byName["gamma-joint-906"]?["description"] == nil || byName["gamma-joint-906"]?["description"] is NSNull)
            #expect(byName["delta-hidden-private-906"] == nil, "private channels need viewer membership")
            #expect(byName["epsilon-hidden-joint-906"] == nil, "joint channels need viewer membership")
            #expect(rows.allSatisfy { ($0["createdAt"] as? String)?.isEmpty == false })
            #expect(rows.allSatisfy { $0["archivedAt"] == nil || $0["archivedAt"] is NSNull })
            #expect(!rows.contains { ($0["id"] as? String) == a2aDm }, "agent DMs are not channels")
        }
    }
}
