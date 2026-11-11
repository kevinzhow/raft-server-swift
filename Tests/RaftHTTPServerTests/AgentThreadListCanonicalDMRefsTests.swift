import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// `GET /internal/agent-api/threads` publishes the pinned
/// `listAgentFollowedThreads` projection over the public route:
///
/// - every parent is named through `resolveAgentFacingChannelRef`, so a DM
///   parent reads as its canonical `dm:@peer[~kind]` ref (human, agent and
///   cross-kind twin) instead of the internal `#dm` channel row;
/// - a channel parent keeps the `#name` form;
/// - the eight-hex parent-message suffix is canonical lowercase;
/// - the twin label is stable before the second DM of the pair exists.

private struct CanonicalThreadWorld {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerName: String
    let workerId: String
    let peerAgentName: String
    let twinAgentId: String
    let twinName: String
    let channelName: String
    let readKey: String
    let channelThreadId: String
    let humanThreadId: String
    let agentThreadId: String
    let twinHumanThreadId: String
}

private func addThread(
    _ accounts: EmailLoginDirectory,
    serverId: String,
    agentId: String,
    parentChannelId: String,
    parentMessageId: String,
    senderId: String,
    senderType: String,
    followedAt: Date
) -> String {
    accounts.insertHumanMessage(
        id: parentMessageId,
        channelId: parentChannelId,
        senderId: senderId,
        content: "thread parent \(parentMessageId.prefix(8))",
        senderType: senderType
    )
    let threadId = accounts.oauth.createThreadChannel(
        parentChannelId: parentChannelId,
        parentMessageId: parentMessageId
    )
    accounts.addPostableChannel(
        serverId: serverId,
        channelId: threadId,
        memberId: agentId,
        kind: "thread",
        parentChannelId: parentChannelId,
        parentMessageId: parentMessageId,
        name: "thread"
    )
    accounts.followThreadForAgentTesting(
        serverId: serverId,
        agentId: agentId,
        threadChannelId: threadId,
        parentMessageId: parentMessageId,
        reason: "manual",
        followedAt: followedAt
    )
    return threadId
}

private func addDM(
    _ accounts: EmailLoginDirectory,
    serverId: String,
    agentId: String,
    peerId: String,
    peerKind: OAuthLedger.DirectChannelParticipantKind
) -> String {
    let channelId = accounts.oauth.createDirectChannel(
        serverId: serverId,
        firstUserId: agentId,
        secondUserId: peerId,
        firstKind: .agent,
        secondKind: peerKind
    )
    for member in [agentId, peerId] {
        accounts.addPostableChannel(
            serverId: serverId,
            channelId: channelId,
            memberId: member,
            kind: "dm",
            name: "dm"
        )
    }
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    if peerKind == .human {
        accounts.oauth.addChannelHuman(channelId: channelId, userId: peerId)
    } else {
        accounts.oauth.addChannelAgent(channelId: channelId, agentId: peerId)
    }
    return channelId
}

private func makeCanonicalThreadWorld(_ suffix: String) -> CanonicalThreadWorld {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001610\(suffix)"
    let ownerId = "11111111-1111-4111-8111-000001610\(suffix)"
    let twinHumanId = "11111111-1111-4111-8111-000001611\(suffix)"
    let ownerName = "HumanPeer\(suffix)"
    let twinName = "Twin\(suffix)"
    accounts.addAccount(id: ownerId, email: "thread-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: twinHumanId, email: "thread-twin-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: twinHumanId)
    accounts.setAccountProfileForTesting(id: ownerId, name: ownerName)
    accounts.setAccountProfileForTesting(id: twinHumanId, name: twinName)
    accounts.oauth.addOwnedServer(
        id: serverId, slug: "thread-list-\(suffix)", name: "Thread List \(suffix)", ownerId: ownerId
    )
    accounts.oauth.addMember(serverId: serverId, userId: twinHumanId, role: "member")

    let workerId = accounts.oauth.createAgent(serverId: serverId, name: "ThreadBot\(suffix)", runtime: "codex")
    let peerAgentId = accounts.oauth.createAgent(serverId: serverId, name: "AgentPeer\(suffix)", runtime: "codex")
    let twinAgentId = accounts.oauth.createAgent(serverId: serverId, name: twinName, runtime: "claude")
    let peerAgentName = "AgentPeer\(suffix)"

    let channelName = "thread-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(
        serverId: serverId, name: channelName, creatorUserId: ownerId
    )
    accounts.addPostableChannel(
        serverId: serverId, channelId: channelId, memberId: ownerId, name: channelName
    )
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.addPostableChannel(
        serverId: serverId, channelId: channelId, memberId: workerId, name: channelName
    )
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: workerId)

    let humanDM = addDM(accounts, serverId: serverId, agentId: workerId, peerId: ownerId, peerKind: .human)
    let agentDM = addDM(accounts, serverId: serverId, agentId: workerId, peerId: peerAgentId, peerKind: .agent)
    let twinHumanDM = addDM(accounts, serverId: serverId, agentId: workerId, peerId: twinHumanId, peerKind: .human)

    // The first eight characters are deliberately mixed case: the published
    // short id is canonical lowercase.
    let channelThreadId = addThread(
        accounts, serverId: serverId, agentId: workerId, parentChannelId: channelId,
        parentMessageId: "ABCDEF12-1111-4111-8111-111111111111",
        senderId: ownerId, senderType: "user",
        followedAt: Date(timeIntervalSince1970: 1_789_500_000)
    )
    let humanThreadId = addThread(
        accounts, serverId: serverId, agentId: workerId, parentChannelId: humanDM,
        parentMessageId: "AAAA1111-1111-4111-8111-111111111111",
        senderId: ownerId, senderType: "user",
        followedAt: Date(timeIntervalSince1970: 1_789_500_100)
    )
    let agentThreadId = addThread(
        accounts, serverId: serverId, agentId: workerId, parentChannelId: agentDM,
        parentMessageId: "BBBB2222-2222-4222-8222-222222222222",
        senderId: peerAgentId, senderType: "agent",
        followedAt: Date(timeIntervalSince1970: 1_789_500_200)
    )
    let twinHumanThreadId = addThread(
        accounts, serverId: serverId, agentId: workerId, parentChannelId: twinHumanDM,
        parentMessageId: "CCCC3333-3333-4333-8333-333333333333",
        senderId: twinHumanId, senderType: "user",
        followedAt: Date(timeIntervalSince1970: 1_789_500_300)
    )

    return CanonicalThreadWorld(
        accounts: accounts, serverId: serverId, ownerName: ownerName,
        workerId: workerId, peerAgentName: peerAgentName,
        twinAgentId: twinAgentId, twinName: twinName,
        channelName: channelName,
        readKey: accounts.mintAgentCredential(
            agentId: workerId, scopes: ["read"], name: "thread-list-\(suffix)"
        ),
        channelThreadId: channelThreadId, humanThreadId: humanThreadId,
        agentThreadId: agentThreadId, twinHumanThreadId: twinHumanThreadId
    )
}

private func threadRows(
    _ client: any Client, key: String
) async throws -> (status: HTTPResponse.Status, raw: String, rows: [[String: Any]]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    let response = try await client.get(URI(string: "/internal/agent-api/threads"), headers: headers)
    let raw = response.body.string ?? ""
    let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, raw, object["threads"] as? [[String: Any]] ?? [])
}

private func row(
    _ rows: [[String: Any]], thread: String, comment: Comment
) throws -> [String: Any] {
    try #require(rows.first { $0["threadChannelId"] as? String == thread }, comment)
}

@Test func agentThreadListPublishesCanonicalDMRefsForEveryParentKind() async throws {
    let world = makeCanonicalThreadWorld("911")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: world.accounts
        ))
        try await app.testing { client in
            // Before the twin agent's DM exists, the human twin's thread still
            // carries the kind suffix: the label comes from the directory, not
            // from which DM rows happen to exist.
            let first = try await threadRows(client, key: world.readKey)
            #expect(first.status == .ok, Comment(rawValue: first.raw))
            #expect(first.rows.count == 4)
            for (threadId, expectedTarget, expectedParent) in [
                (world.channelThreadId, "#\(world.channelName):abcdef12", "#\(world.channelName)"),
                (world.humanThreadId, "dm:@\(world.ownerName):aaaa1111", "dm:@\(world.ownerName)"),
                (world.agentThreadId, "dm:@\(world.peerAgentName):bbbb2222", "dm:@\(world.peerAgentName)"),
                (world.twinHumanThreadId, "dm:@\(world.twinName)~human:cccc3333", "dm:@\(world.twinName)~human"),
            ] {
                let entry = try row(first.rows, thread: threadId, comment: Comment(rawValue: threadId))
                #expect(entry["target"] as? String == expectedTarget, Comment(rawValue: threadId))
                #expect(entry["parentChannelRef"] as? String == expectedParent, Comment(rawValue: threadId))
                #expect(
                    entry["parentMessageShortId"] as? String
                        == String(expectedTarget.split(separator: ":").last ?? ""),
                    Comment(rawValue: threadId)
                )
            }
            #expect(!first.rows.contains { ($0["target"] as? String)?.hasPrefix("#dm") == true })
            #expect(!first.rows.contains { ($0["parentChannelRef"] as? String)?.hasPrefix("#dm") == true })

            // The second DM of the twin pair now exists; both threads keep
            // their kind-qualified canonical labels.
            let twinAgentDM = addDM(
                world.accounts, serverId: world.serverId, agentId: world.workerId,
                peerId: world.twinAgentId, peerKind: .agent
            )
            let twinAgentThreadId = addThread(
                world.accounts, serverId: world.serverId, agentId: world.workerId,
                parentChannelId: twinAgentDM,
                parentMessageId: "DDDD4444-4444-4444-8444-444444444444",
                senderId: world.twinAgentId, senderType: "agent",
                followedAt: Date(timeIntervalSince1970: 1_789_500_400)
            )

            let second = try await threadRows(client, key: world.readKey)
            #expect(second.status == .ok, Comment(rawValue: second.raw))
            #expect(second.rows.count == 5)
            let twinHuman = try row(
                second.rows, thread: world.twinHumanThreadId,
                comment: Comment(rawValue: world.twinHumanThreadId)
            )
            #expect(twinHuman["target"] as? String == "dm:@\(world.twinName)~human:cccc3333")
            #expect(twinHuman["parentChannelRef"] as? String == "dm:@\(world.twinName)~human")
            let twinAgent = try row(
                second.rows, thread: twinAgentThreadId,
                comment: Comment(rawValue: twinAgentThreadId)
            )
            #expect(twinAgent["target"] as? String == "dm:@\(world.twinName)~agent:dddd4444")
            #expect(twinAgent["parentChannelRef"] as? String == "dm:@\(world.twinName)~agent")
            #expect(!second.rows.contains { ($0["target"] as? String)?.hasPrefix("#dm") == true })
        }
    }
}
