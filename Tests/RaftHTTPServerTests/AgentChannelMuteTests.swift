import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MuteFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerToken: String
    let channelId: String
    let channelName: String
    let joinOnlyChannelId: String
    let agentId: String
    let agentName: String
    let agentKey: String
}

private func makeMuteFixture(_ suffix: String) -> MuteFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001310\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001310\(suffix)"
    accounts.addAccount(id: ownerId, email: "mute-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "agent-mute-\(suffix)", name: "Agent Mute \(suffix)", ownerId: ownerId)
    let channelName = "agent-mute-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let joinOnlyChannelId = accounts.oauth.createChannel(serverId: serverId, name: "agent-mute-join-only-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: joinOnlyChannelId, memberId: ownerId, kind: "channel", name: "agent-mute-join-only-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: joinOnlyChannelId, userId: ownerId)
    let agentName = "MuteBot\(suffix)"
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: agentName, creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.setSendFreshnessModeForTesting("force")
    return MuteFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        channelId: channelId,
        channelName: channelName,
        joinOnlyChannelId: joinOnlyChannelId,
        agentId: agentId,
        agentName: agentName,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "channels"], name: "mute-\(suffix)")
    )
}

private func muteHumanHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func muteAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func muteJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@discardableResult
private func mutePostHuman(
    _ client: any Client,
    _ f: MuteFixture,
    content: String,
    mentionAgent: Bool = false
) async throws -> (id: String, seq: Int) {
    let response = try await client.send(.post, headers: muteHumanHeaders(f.ownerToken, f.serverId), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(f.channelId)\",\"content\":\"\(content)\"}")
    }
    let id = try #require(try muteJSON(response)["id"] as? String)
    let seq = try #require(f.accounts.humanMessageSequence(id: id))
    if mentionAgent {
        f.accounts.addMessageMention(messageId: id, targetType: "agent", targetId: f.agentId)
    }
    return (id, seq)
}

private func mutePost(
    _ client: any Client,
    f: MuteFixture,
    channelId: String,
    muted: Bool
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.send(
        .post,
        headers: muteAgentHeaders(f.agentKey),
        to: "/internal/agent-api/channels/\(channelId)/\(muted ? "mute" : "unmute")"
    )
    return (response.status, try muteJSON(response))
}

private func muteEvents(_ client: any Client, f: MuteFixture) async throws -> [[String: Any]] {
    let response = try await client.get(URI(string: "/internal/agent-api/events"), headers: muteAgentHeaders(f.agentKey))
    #expect(response.status == .ok)
    return (try muteJSON(response)["events"] as? [[String: Any]]) ?? []
}

private func muteHints(_ client: any Client, f: MuteFixture) async throws -> (body: [String: Any], raw: String) {
    let response = try await client.get(URI(string: "/internal/agent-api/wake-hints?since=latest"), headers: muteAgentHeaders(f.agentKey))
    return (try muteJSON(response), response.body.string ?? "")
}

private func muteSend(
    _ client: any Client,
    f: MuteFixture,
    content: String,
    seenUpToSeq: Int
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    let response = try await client.send(.post, headers: muteAgentHeaders(f.agentKey), to: "/internal/agent-api/send") { request in
        request.body = .init(string: "{\"target\":\"#\(f.channelName)\",\"content\":\"\(content)\",\"seenUpToSeq\":\(seenUpToSeq)}")
    }
    return (response.status, try muteJSON(response))
}

@Test func agentChannelMuteIsReceiverKeyedAndVisibleInServerInfo() async throws {
    let f = makeMuteFixture("901")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let seeded = try await mutePostHuman(client, f, content: "pre-mute ordinary chatter")

            func serverChannel() async throws -> [String: Any]? {
                let response = try await client.get(URI(string: "/internal/agent-api/server"), headers: muteAgentHeaders(f.agentKey))
                #expect(response.status == .ok)
                let channels = (try muteJSON(response)["channels"] as? [[String: Any]]) ?? []
                return channels.first { $0["id"] as? String == f.channelId }
            }

            let before = try #require(try await serverChannel())
            #expect(before["activityMuted"] as? Bool == false)
            #expect(before["muteFromSeq"] == nil || before["muteFromSeq"] is NSNull)

            let nonMember = try await mutePost(client, f: f, channelId: f.joinOnlyChannelId, muted: true)
            #expect(nonMember.status == .forbidden)

            let muted = try await mutePost(client, f: f, channelId: f.channelId, muted: true)
            #expect(muted.status == .ok)
            #expect(muted.body["activityMuted"] as? Bool == true)
            #expect(muted.body["muteFromSeq"] as? Int == seeded.seq + 1)
            let attention = try #require(muted.body["attention"] as? [String: Any])
            #expect(attention["state"] as? String == "muted")
            #expect((attention["unmuteCommand"] as? String)?.contains("raft channel unmute #\(f.channelName)") == true)
            #expect((attention["unmuteApi"] as? String)?.contains("/internal/agent-api/channels/\(f.channelId)/unmute") == true)
            #expect((attention["stillArrives"] as? [String])?.contains { $0.contains("@mentions") } == true)
            #expect(attention["threadBoundary"] as? String == "Channel mute suppresses ordinary Activity from this channel only. Threads you follow keep delivering independently until you unfollow them.")
            #expect((attention["catchUp"] as? String)?.contains("history") == true)
            #expect(f.accounts.agentMuteStateForTesting(channelId: f.channelId, agentId: f.agentId)?.muteFromSeq == seeded.seq + 1)

            let afterMute = try #require(try await serverChannel())
            #expect(afterMute["activityMuted"] as? Bool == true)
            #expect(afterMute["muteFromSeq"] as? Int == seeded.seq + 1)

            let unmuted = try await mutePost(client, f: f, channelId: f.channelId, muted: false)
            #expect(unmuted.status == .ok)
            #expect(unmuted.body["activityMuted"] as? Bool == false)
            #expect(unmuted.body["muteFromSeq"] == nil || unmuted.body["muteFromSeq"] is NSNull)
            let unmuteAttention = try #require(unmuted.body["attention"] as? [String: Any])
            #expect(unmuteAttention["state"] as? String == "unmuted")
            #expect((unmuteAttention["muteCommand"] as? String)?.contains("raft channel mute #\(f.channelName)") == true)

            let afterUnmute = try #require(try await serverChannel())
            #expect(afterUnmute["activityMuted"] as? Bool == false)
            #expect(f.accounts.agentMuteStateForTesting(channelId: f.channelId, agentId: f.agentId) == nil)
        }
    }
}

@Test func agentChannelMuteSuppressesOrdinaryDeliveryButNotMentions() async throws {
    let f = makeMuteFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            _ = try await mutePostHuman(client, f, content: "ordinary before mute")
            let drained = try await muteEvents(client, f: f)
            #expect(drained.compactMap { $0["content"] as? String } == ["ordinary before mute"])

            let muted = try await mutePost(client, f: f, channelId: f.channelId, muted: true)
            #expect(muted.status == .ok)

            _ = try await mutePostHuman(client, f, content: "ordinary after agent mute")
            let hints = try await muteHints(client, f: f)
            #expect(!hints.raw.contains("ordinary after agent mute"), "a muted ordinary body never leaks through hints")
            let eventsWhileMuted = try await muteEvents(client, f: f)
            #expect(eventsWhileMuted.isEmpty, "muted ordinary channel messages stay out of delivery")

            _ = try await mutePostHuman(client, f, content: "@\(f.agentName) personal mention after mute", mentionAgent: true)
            let mentionHints = try await muteHints(client, f: f)
            let hintRows = (mentionHints.body["wake_hints"] as? [[String: Any]]) ?? []
            #expect(hintRows.count == 1)
            let mentionEvents = try await muteEvents(client, f: f)
            #expect(mentionEvents.compactMap { $0["content"] as? String } == ["@\(f.agentName) personal mention after mute"])
            #expect(mentionEvents.first?["mentioned"] as? Bool == true)

            let unmute = try await mutePost(client, f: f, channelId: f.channelId, muted: false)
            #expect(unmute.status == .ok)
            let backlog = try await muteEvents(client, f: f)
            #expect(backlog.isEmpty, "unmute resumes future delivery; catch-up is the history surface")
        }
    }
}

@Test func agentApiFreshnessIgnoresMutedOrdinaryButHoldsOnPierce() async throws {
    let f = makeMuteFixture("903")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let baseline = try await mutePostHuman(client, f, content: "baseline before mute")
            let muted = try await mutePost(client, f: f, channelId: f.channelId, muted: true)
            #expect(muted.status == .ok)

            let mutedOrdinary = try await mutePostHuman(client, f, content: "muted ordinary before agent-api send")
            let sentThroughMutedTail = try await muteSend(
                client,
                f: f,
                content: "agent-api send after muted ordinary",
                seenUpToSeq: baseline.seq
            )
            #expect(sentThroughMutedTail.status == .ok)
            #expect(sentThroughMutedTail.body["state"] as? String == "sent", "muted ordinary rows do not force a hold")

            let pierce = try await mutePostHuman(
                client,
                f,
                content: "@\(f.agentName) pierce after muted ordinary",
                mentionAgent: true
            )
            let held = try await muteSend(
                client,
                f: f,
                content: "agent-api send after pierce",
                seenUpToSeq: baseline.seq
            )
            #expect(held.status == .ok)
            #expect(held.body["state"] as? String == "held")
            #expect(held.body["newMessageCount"] as? Int == 1)
            let heldMessages = try #require(held.body["heldMessages"] as? [[String: Any]])
            #expect(heldMessages.map { $0["id"] as? String } == [pierce.id])
            #expect(heldMessages.map { $0["content"] as? String } == ["@\(f.agentName) pierce after muted ordinary"])
            #expect(!heldMessages.contains { ($0["id"] as? String) == mutedOrdinary.id }, "the muted ordinary row is not forced into held context")
            #expect(held.body["seenUpToSeq"] as? Int == pierce.seq)
        }
    }
}
