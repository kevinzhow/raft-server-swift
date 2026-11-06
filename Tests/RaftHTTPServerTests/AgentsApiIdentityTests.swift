import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AgentIdentityFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let memberId: String
    let serverId: String
    let ownerToken: String
    let memberToken: String
}

private func makeAgentIdentityFixture(_ suffix: String) -> AgentIdentityFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001048\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001049\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001048\(suffix)"
    accounts.addAccount(id: ownerId, email: "agent-id-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "agent-id-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-id-\(suffix)", name: "Agent Identity \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    return AgentIdentityFixture(
        accounts: accounts,
        ownerId: ownerId,
        memberId: memberId,
        serverId: serverId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId)
    )
}

private func agentHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func createAgentResponse(
    _ client: any Client,
    _ fixture: AgentIdentityFixture,
    name: String,
    token: String? = nil
) async throws -> ClientResponse {
    try await client.send(.post, headers: agentHeaders(token ?? fixture.ownerToken, fixture.serverId), to: "/api/agents") { request in
        request.body = .init(string: "{\"name\":\"\(name)\",\"runtime\":\"codex\"}")
    }
}

private func jsonObject(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func agentChannelsListOnlyViewerVisibleMembershipsWithAgentMuteState() async throws {
    let f = makeAgentIdentityFixture("001")
    let accounts = f.accounts
    let agentA = accounts.oauth.createAgent(serverId: f.serverId, name: "channels-agent-a-001", runtime: "codex")
    let agentB = accounts.oauth.createAgent(serverId: f.serverId, name: "channels-agent-b-001", runtime: "codex")
    let publicChannel = accounts.oauth.createChannel(serverId: f.serverId, name: "alpha-public-001", creatorUserId: f.ownerId, description: "visible public channel")
    let privateChannel = accounts.oauth.createChannel(serverId: f.serverId, name: "beta-private-001", creatorUserId: f.ownerId, type: "private", description: "private membership")
    let jointChannel = accounts.oauth.createChannel(serverId: f.serverId, name: "gamma-joint-001", creatorUserId: f.ownerId, type: "joint")
    let hiddenPrivate = accounts.oauth.createChannel(serverId: f.serverId, name: "delta-hidden-private-001", creatorUserId: f.ownerId, type: "private")
    let hiddenJoint = accounts.oauth.createChannel(serverId: f.serverId, name: "epsilon-hidden-joint-001", creatorUserId: f.ownerId, type: "joint")
    for channel in [publicChannel, privateChannel, jointChannel, hiddenPrivate, hiddenJoint] {
        accounts.oauth.addChannelAgent(channelId: channel, agentId: agentA)
    }
    accounts.oauth.addChannelHuman(channelId: privateChannel, userId: f.ownerId)
    accounts.oauth.addChannelHuman(channelId: jointChannel, userId: f.ownerId)
    for _ in 0..<6 {
        _ = accounts.oauth.createMessageRecord(channelId: privateChannel, content: "mute seed", senderId: f.memberId)
    }
    _ = accounts.oauth.setActivityMuted(channelId: privateChannel, userId: agentA, muted: true)
    _ = accounts.oauth.setActivityMuted(channelId: publicChannel, userId: f.ownerId, muted: true)
    let dm = accounts.oauth.createDirectChannel(serverId: f.serverId, firstUserId: agentA, secondUserId: agentB)
    accounts.addPostableChannel(serverId: f.serverId, channelId: dm, memberId: agentA, kind: "dm", name: "dm")
    accounts.addPostableChannel(serverId: f.serverId, channelId: dm, memberId: agentB, kind: "dm", name: "dm")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let response = try await client.get(
                URI(string: "/api/agents/\(agentA)/channels"),
                headers: agentHeaders(f.ownerToken, f.serverId)
            )
            #expect(response.status == .ok)
            let rows = (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            let byName = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: Any])? in
                guard let name = row["name"] as? String else { return nil }
                return (name, row)
            })
            #expect(byName["all"] == nil, "virtual #all is not an explicit membership")
            #expect(byName["alpha-public-001"]?["id"] as? String == publicChannel)
            #expect(byName["alpha-public-001"]?["type"] as? String == "channel")
            #expect(byName["alpha-public-001"]?["description"] as? String == "visible public channel")
            #expect(byName["alpha-public-001"]?["activityMuted"] as? Bool == false, "viewer mute must not leak")
            #expect(byName["alpha-public-001"]?["muteFromSeq"] is NSNull)
            #expect(byName["beta-private-001"]?["id"] as? String == privateChannel)
            #expect(byName["beta-private-001"]?["type"] as? String == "private")
            #expect(byName["beta-private-001"]?["activityMuted"] as? Bool == true)
            #expect(byName["beta-private-001"]?["muteFromSeq"] as? Int == 7)
            #expect(byName["gamma-joint-001"]?["id"] as? String == jointChannel)
            #expect(byName["gamma-joint-001"]?["type"] as? String == "joint")
            #expect(byName["delta-hidden-private-001"] == nil, "private channels require viewer membership")
            #expect(byName["epsilon-hidden-joint-001"] == nil, "joint channels require viewer membership")
            #expect(rows.allSatisfy { $0["archivedAt"] is NSNull })
            #expect(!rows.contains { $0["id"] as? String == dm }, "agent DMs are not channels")
        }
    }
}

@Test func agentCreateRejectsDuplicateActiveHandles() async throws {
    let f = makeAgentIdentityFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            #expect(try await createAgentResponse(client, f, name: "principal-api-agent-002").status == .ok)
            let duplicate = try await createAgentResponse(client, f, name: "principal-api-agent-002")
            #expect(duplicate.status == .conflict)
            #expect((try jsonObject(duplicate)["error"] as? String ?? "").lowercased().contains("already taken"))
        }
    }
}

@Test func agentCreateRejectsReservedHandles() async throws {
    let f = makeAgentIdentityFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for name in ["all", "Human", "HUMANS", "agent", "Agents", "here", "Idle", "BUSY", "system", "reminders", "Reminders"] {
                let response = try await createAgentResponse(client, f, name: name)
                #expect(response.status == .badRequest, "\(name)")
                #expect((try jsonObject(response)["error"] as? String ?? "").contains("is reserved. Choose another name."))
            }
            let valid = try await createAgentResponse(client, f, name: "agent-helper-003")
            #expect(valid.status == .ok)
            #expect(try jsonObject(valid)["name"] as? String == "agent-helper-003")
        }
    }
}

@Test func agentCreatorIsSetAtCreationAndVisibleOnTheMemberProfile() async throws {
    let f = makeAgentIdentityFixture("004")
    let accounts = f.accounts
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let created = try await createAgentResponse(client, f, name: "creator-agent-004")
            #expect(created.status == .ok)
            let createdBody = try jsonObject(created)
            let agentId = try #require(createdBody["id"] as? String)
            #expect((createdBody["creator"] as? [String: Any])?["type"] as? String == "human")
            #expect((createdBody["creator"] as? [String: Any])?["id"] as? String == f.ownerId)

            let profile = try await client.get(
                URI(string: "/api/servers/\(f.serverId)/members/\(f.ownerId)/profile"),
                headers: agentHeaders(f.ownerToken, f.serverId)
            )
            #expect(profile.status == .ok)
            let createdAgents = (try jsonObject(profile)["createdAgents"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            #expect(createdAgents == [agentId])

            let forbidden = try await client.send(
                .patch,
                headers: agentHeaders(f.memberToken, f.serverId),
                to: URI(string: "/api/agents/\(agentId)/creator")
            ) { request in
                request.body = .init(string: "{\"creatorType\":\"user\",\"creatorId\":\"\(f.memberId)\"}")
            }
            #expect(forbidden.status == .notFound)

            let after = try await client.get(URI(string: "/api/agents/\(agentId)"), headers: agentHeaders(f.ownerToken, f.serverId))
            #expect(((try jsonObject(after)["creator"] as? [String: Any])?["id"] as? String) == f.ownerId)
        }
    }
}

@Test func memberViewAgentsReachesRuntimeOptions() async throws {
    let f = makeAgentIdentityFixture("005")
    let agent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "runtime-options-agent-005", creatorUserId: f.ownerId, runtime: "codex")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let response = try await client.get(
                URI(string: "/api/agents/\(agent)/runtime-options"),
                headers: agentHeaders(f.memberToken, f.serverId)
            )
            #expect(response.status == .ok)
        }
    }
}
