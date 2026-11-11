import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MembershipFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let agentId: String
    let agentName: String
    let machineKey: String
    let readKey: String
    let joinedChannel: String
    let joinOnlyChannel: String
    let privateChannel: String
    let jointChannel: String
    let archivedChannel: String
    let agentOnlyPrivateChannel: String
    let allChannelId: String
}

private func makeMembershipFixture(_ suffix: String) -> MembershipFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001200\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001200\(suffix)"
    accounts.addAccount(id: ownerId, email: "membership-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "membership-\(suffix)", name: "Membership \(suffix)", ownerId: ownerId)
    func channel(_ name: String, type: String = "channel") -> String {
        let id = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId, type: type)
        accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: ownerId, kind: type, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: ownerId)
        return id
    }
    let joinedChannel = channel("focus-room")
    let joinOnlyChannel = channel("join-public")
    let privateChannel = channel("agent-private-invite-only", type: "private")
    let jointChannel = channel("agent-joint-invite-only", type: "joint")
    let archivedChannel = channel("archived-join-room")
    let agentOnlyPrivateChannel = channel("agent-only-private", type: "private")
    let agentName = "MembershipBot\(suffix)"
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: joinedChannel, agentId: agentId)
    accounts.oauth.addChannelAgent(channelId: agentOnlyPrivateChannel, agentId: agentId)
    accounts.oauth.setChannelArchived(id: archivedChannel, archivedAt: Date())
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "membership-machine-\(suffix)")
    accounts.assignAgentMachineForTesting(agentId: agentId, machineId: machine)
    let allChannel = accounts.oauth.allChannelId(serverId: serverId) ?? ""
    return MembershipFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        agentId: agentId,
        agentName: agentName,
        machineKey: accounts.machineAPIKey(machineId: machine) ?? "",
        readKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "channels"], name: "membership-\(suffix)"),
        joinedChannel: joinedChannel,
        joinOnlyChannel: joinOnlyChannel,
        privateChannel: privateChannel,
        jointChannel: jointChannel,
        archivedChannel: archivedChannel,
        agentOnlyPrivateChannel: agentOnlyPrivateChannel,
        allChannelId: allChannel
    )
}

private func membershipRequest(
    _ client: any Client,
    f: MembershipFixture,
    path: String,
    method: HTTPRequest.Method = .post,
    body: String? = nil,
    machine: Bool = true
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(machine ? f.machineKey : f.readKey)"
    if body != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private func membershipChannels(
    _ client: any Client,
    f: MembershipFixture
) async throws -> [String: Bool] {
    let response = try await client.get(
        URI(string: "/internal/agent-api/server"),
        headers: {
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.readKey)"
            return headers
        }()
    )
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let rows = (body["channels"] as? [[String: Any]]) ?? []
    var byName: [String: Bool] = [:]
    for row in rows {
        if let name = row["name"] as? String {
            byName[name] = row["joined"] as? Bool
        }
    }
    return byName
}

@Test func legacyAgentLeavesItsOwnRegularChannelWithoutAdminRights() async throws {
    let f = makeMembershipFixture("801")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let before = try await membershipChannels(client, f: f)
            #expect(before["focus-room"] == true)
            let leave = try await membershipRequest(client, f: f, path: "/internal/agent/\(f.agentId)/channels/\(f.joinedChannel)/leave")
            #expect(leave.status == .ok)
            let after = try await membershipChannels(client, f: f)
            #expect(after["focus-room"] == false)
            #expect(after["join-public"] == false)
        }
    }
}

@Test func legacyAgentCannotLeaveTheVirtualAllChannel() async throws {
    let f = makeMembershipFixture("802")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let leave = try await membershipRequest(client, f: f, path: "/internal/agent/\(f.agentId)/channels/\(f.allChannelId)/leave")
            #expect(leave.status == .forbidden)
            #expect((leave.body["error"] as? String)?.contains("#all channel") == true)
        }
    }
}

@Test func legacyAgentJoinsAVisiblePublicChannelWithABornReadSystemNotice() async throws {
    let f = makeMembershipFixture("803")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let join = try await membershipRequest(client, f: f, path: "/internal/agent/\(f.agentId)/channels/\(f.joinOnlyChannel)/join")
            #expect(join.status == .ok)
            let channels = try await membershipChannels(client, f: f)
            #expect(channels["join-public"] == true)

            var historyHeaders = HTTPFields()
            historyHeaders[.authorization] = "Bearer \(f.readKey)"
            let history = try await client.get(
                URI(string: "/internal/agent-api/history?channel=%23join-public&limit=10&consume=false"),
                headers: historyHeaders
            )
            let historyBody = (try? JSONSerialization.jsonObject(with: Data((history.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let systemRows = (historyBody["messages"] as? [[String: Any]] ?? []).filter {
                $0["senderId"] as? String == "system" || $0["senderType"] as? String == "system"
            }
            let notice = try #require(systemRows.last)
            #expect(notice["content"] as? String == "@\(f.agentName) joined this channel.")

            // The join is born-read for the joining agent: its event pull stays empty.
            let events = try await client.get(
                URI(string: "/internal/agent-api/events"),
                headers: historyHeaders
            )
            let eventsBody = (try? JSONSerialization.jsonObject(with: Data((events.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let eventRows = (eventsBody["events"] as? [[String: Any]]) ?? []
            #expect(!eventRows.contains { $0["content"] as? String == "@\(f.agentName) joined this channel." })
        }
    }
}

@Test func agentSelfJoinRefusesPrivateJointAndArchivedChannels() async throws {
    let f = makeMembershipFixture("804")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let privateJoin = try await membershipRequest(client, f: f, path: "/internal/agent/\(f.agentId)/channels/\(f.privateChannel)/join")
            #expect(privateJoin.status == .forbidden)
            #expect((privateJoin.body["error"] as? String)?.contains("Private channels require an invitation") == true)

            let jointJoin = try await membershipRequest(client, f: f, path: "/internal/agent/\(f.agentId)/channels/\(f.jointChannel)/join")
            #expect(jointJoin.status == .forbidden)
            #expect((jointJoin.body["error"] as? String)?.contains("Joint channels require an invitation") == true)

            let archivedJoin = try await membershipRequest(client, f: f, path: "/internal/agent/\(f.agentId)/channels/\(f.archivedChannel)/join")
            #expect(archivedJoin.status == .conflict)
            #expect(archivedJoin.body["code"] as? String == "channel_archived")

            let channels = try await membershipChannels(client, f: f)
            #expect(channels["agent-private-invite-only"] == nil, "non-member private channels stay hidden")
            #expect(channels["agent-joint-invite-only"] == nil, "non-member joint channels stay hidden")
        }
    }
}

@Test func leavingAnAgentOnlyPrivateChannelSoftDeletesIt() async throws {
    let f = makeMembershipFixture("805")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // The channel is agent-only: drop the human member first.
            f.accounts.oauth.removeChannelHuman(channelId: f.agentOnlyPrivateChannel, userId: f.ownerId)
            f.accounts.removeChannelMemberForTesting(channelId: f.agentOnlyPrivateChannel, userId: f.ownerId)
            let before = try await membershipChannels(client, f: f)
            #expect(before["agent-only-private"] == true)

            let leave = try await membershipRequest(client, f: f, path: "/internal/agent/\(f.agentId)/channels/\(f.agentOnlyPrivateChannel)/leave")
            #expect(leave.status == .ok)
            let after = try await membershipChannels(client, f: f)
            #expect(after["agent-only-private"] == nil, "an empty private channel is soft-deleted")
        }
    }
}

@Test func legacyAgentUnfollowsAThreadTargetWithoutLeavingTheParentChannel() async throws {
    let f = makeMembershipFixture("806")
    let parent = f.accounts.oauth.createMessageRecord(channelId: f.joinedChannel, content: "thread parent", senderId: f.ownerId)
    let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: f.joinedChannel, parentMessageId: parent.id)
    f.accounts.addPostableChannel(
        serverId: f.serverId,
        channelId: threadId,
        memberId: f.ownerId,
        kind: "thread",
        parentChannelId: f.joinedChannel,
        parentMessageId: parent.id,
        name: "thread"
    )
    f.accounts.oauth.addChannelAgent(channelId: threadId, agentId: f.agentId)
    f.accounts.followThreadForAgentTesting(
        serverId: f.serverId,
        agentId: f.agentId,
        threadChannelId: threadId,
        parentMessageId: parent.id
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            func followedThreadIds() async throws -> [String] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(f.readKey)"
                let response = try await client.get(URI(string: "/internal/agent-api/threads"), headers: headers)
                let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
                return (body["threads"] as? [[String: Any]] ?? []).compactMap { $0["threadChannelId"] as? String }
            }
            #expect(try await followedThreadIds() == [threadId])

            let unfollow = try await membershipRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/threads/unfollow",
                body: "{\"thread\":\"#focus-room:\(parent.id.prefix(8))\"}"
            )
            #expect(unfollow.status == .ok)
            #expect(try await followedThreadIds().isEmpty)
            let channels = try await membershipChannels(client, f: f)
            #expect(channels["focus-room"] == true, "unfollowing a thread does not leave the parent channel")
        }
    }
}

@Test func legacyAgentUnfollowRejectsATopLevelChannelTarget() async throws {
    let f = makeMembershipFixture("807")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unfollow = try await membershipRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/threads/unfollow",
                body: "{\"thread\":\"#focus-room\"}"
            )
            #expect(unfollow.status == .badRequest)
            #expect((unfollow.body["error"] as? String)?.contains("Target must be a thread") == true)
        }
    }
}

@Test func legacyAgentUnfollowsAFollowedThreadWithoutParentMembership() async throws {
    let f = makeMembershipFixture("808")
    // A public parent stays readable, so a listed thread there can be unfollowed
    // without joining the parent channel; private parents stay cloaked.
    let outsiderThread = f.accounts.oauth.createThreadChannel(parentChannelId: f.joinOnlyChannel, parentMessageId: "abcdef1234567890")
    f.accounts.addPostableChannel(
        serverId: f.serverId,
        channelId: outsiderThread,
        memberId: f.ownerId,
        kind: "thread",
        parentChannelId: f.joinOnlyChannel,
        parentMessageId: "abcdef1234567890",
        name: "thread"
    )
    f.accounts.followThreadForAgentTesting(
        serverId: f.serverId,
        agentId: f.agentId,
        threadChannelId: outsiderThread,
        parentMessageId: "abcdef1234567890"
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unfollow = try await membershipRequest(
                client,
                f: f,
                path: "/internal/agent/\(f.agentId)/threads/unfollow",
                body: "{\"thread\":\"\(outsiderThread)\"}"
            )
            #expect(unfollow.status == .ok)
            let channels = try await membershipChannels(client, f: f)
            #expect(channels["join-public"] == false, "unfollow never joins the parent")
        }
    }
}
