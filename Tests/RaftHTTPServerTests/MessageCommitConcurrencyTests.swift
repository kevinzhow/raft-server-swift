import Foundation
import HTTPTypes
import RaftHTTPServer
import RaftRealtime
import Testing
import TestSupport
import Vapor
import VaporTesting
@testable import RaftHTTP

private struct CommitSocketAuth: RealtimeAuthorizing {
    let core: AuthCoreService
    let membership: SocketMembershipService
    func userId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.userId }
    func sessionFamilyId(forAccessToken token: String) -> String? { core.sessionIdentity(accessToken: token)?.familyId }
    func serverRole(serverId: String, userId: String) -> String? { membership.serverRole(serverId: serverId, userId: userId) }
    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        membership.visibleChannelIds(serverId: serverId, userId: userId).channelIds
    }
}

private struct CommitFixture: Sendable {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let channelName: String
    let ownerId: String
    let token: String
    let agentId: String
    let agentKey: String
    let peerId: String
}

private func commitFixture(_ suffix: String) -> CommitFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000009200\(suffix)"
    let peerId = "11111111-1111-4111-8111-000009201\(suffix)"
    let serverId = "33333333-3333-4333-8333-000009200\(suffix)"
    accounts.addAccount(id: ownerId, email: "commit-owner-\(suffix)@test.local", password: "password123")
    accounts.addAccount(id: peerId, email: "commit-peer-\(suffix)@test.local", password: "password123")
    accounts.setAccountProfileForTesting(id: ownerId, name: "commitowner")
    accounts.setAccountProfileForTesting(id: peerId, name: "commitpeer")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "message-commit-\(suffix)", name: "Commit", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    let channelName = "commit-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    for id in [ownerId, peerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: channelName)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "CommitBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    accounts.setSendFreshnessModeForTesting("off")
    return CommitFixture(
        accounts: accounts, serverId: serverId, channelId: channelId, channelName: channelName,
        ownerId: ownerId, token: accounts.mintAccessTokenForTesting(userId: ownerId), agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send", "mentions"], name: "commit"),
        peerId: peerId
    )
}

private func commitHeaders(_ f: CommitFixture, agent: Bool = false) -> HTTPFields {
    var fields = HTTPFields()
    fields[.authorization] = "Bearer \(agent ? f.agentKey : f.token)"
    fields[.contentType] = "application/json"
    fields[HTTPField.Name("X-Server-Id")!] = f.serverId
    return fields
}

private struct CommitReply: Decodable, Sendable {
    let id: String?
    let messageId: String?
    let messageSeq: Int?
    let threadChannelId: String?
    let state: String?
    let code: String?
    let messages: [CommitHistoryRow]?
    let message: CommitCommentRow?

    var committedId: String? { id ?? messageId ?? message?.id }
}

private struct CommitCommentRow: Decodable, Sendable {
    let id: String
}

private struct CommitHistoryRow: Decodable, Sendable {
    let id: String
    let seq: Int?
    let content: String?
}

private struct CommitHTTPResult: Sendable {
    let status: Int
    let reply: CommitReply
}

private func commitPost(
    _ client: any Client, f: CommitFixture, path: String, body: String, agent: Bool = false
) async throws -> CommitHTTPResult {
    let response = try await client.send(.post, headers: commitHeaders(f, agent: agent), to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
    return CommitHTTPResult(status: response.status.code, reply: try JSONDecoder().decode(CommitReply.self, from: Data((response.body.string ?? "").utf8)))
}

private func commitHistory(_ client: any Client, f: CommitFixture, target: String) async throws -> [CommitHistoryRow] {
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
    let response = try await client.get(
        URI(string: "/internal/agent-api/history?channel=\(encoded)&limit=100&consume=false"), headers: commitHeaders(f, agent: true)
    )
    #expect(response.status == .ok)
    return try JSONDecoder().decode(CommitReply.self, from: Data((response.body.string ?? "").utf8)).messages ?? []
}

@Test func messageCommitMixedHumanAgentAndCommentWritersAgreeOnHistoryAndResume() async throws {
    let f = commitFixture("801")
    let attachmentId = f.accounts.addChannelAttachment(channelId: f.channelId, uploaderId: f.ownerId, filename: "host.pdf")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let host = try await commitPost(client, f: f, path: "/api/messages", body: "{\"channelId\":\"\(f.channelId)\",\"content\":\"host\",\"attachmentIds\":[\"\(attachmentId)\"]}")
            #expect(host.status == 200)
            let hostId = try #require(host.reply.id)
            let warmup = try await commitPost(client, f: f, path: "/api/attachments/\(attachmentId)/comments", body: "{\"content\":\"warmup\"}")
            #expect(warmup.status == 200)
            let threadId = try #require(warmup.reply.threadChannelId)
            f.accounts.oauth.addChannelAgent(channelId: threadId, agentId: f.agentId)
            f.accounts.addPostableChannel(serverId: f.serverId, channelId: threadId, memberId: f.agentId, kind: "thread", parentChannelId: f.channelId, parentMessageId: hostId, name: "thread")
            let follow = try await client.send(.post, headers: commitHeaders(f), to: "/api/channels/threads/follow") { request in
                request.body = .init(string: "{\"threadChannelId\":\"\(threadId)\"}")
            }
            #expect(follow.status == .ok)
            let results = try await withThrowingTaskGroup(of: CommitHTTPResult.self) { group in
                for index in 0..<96 {
                    group.addTask {
                        switch index % 3 {
                        case 0:
                            try await commitPost(client, f: f, path: "/api/messages", body: "{\"channelId\":\"\(f.channelId)\",\"content\":\"mixed-human-\(index)\",\"timezone\":\"Asia/Tokyo\"}")
                        case 1:
                            try await commitPost(client, f: f, path: "/internal/agent-api/send", body: "{\"target\":\"#\(f.channelName)\",\"content\":\"mixed-agent-\(index)\"}", agent: true)
                        default:
                            try await commitPost(client, f: f, path: "/api/attachments/\(attachmentId)/comments", body: "{\"content\":\"mixed-comment-\(index)\"}")
                        }
                    }
                }
                var results: [CommitHTTPResult] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(results.allSatisfy { $0.status == 200 || $0.status == 201 })
            let ids = results.compactMap { $0.reply.committedId }
            #expect(ids.count == 96)
            #expect(Set(ids).count == 96)
            let resume = try #require(f.accounts.socketMembership.syncMessages(serverId: f.serverId, userId: f.ownerId, lastSeq: 1, limit: 200))
            #expect(resume.messages.count == 97)
            #expect(Set(resume.messages.map(\.seq)).count == 97)
            #expect(Set(resume.messages.map(\.seq)) == Set(2...98))
            #expect(Set(ids).isSubset(of: Set(resume.messages.map(\.id))))
            let channelHistory = try await commitHistory(client, f: f, target: "#\(f.channelName)")
            let threadHistory = try await commitHistory(client, f: f, target: "#\(f.channelName):\(hostId.prefix(8))")
            let mirrored = channelHistory + threadHistory
            let byId = Dictionary(mirrored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for row in resume.messages {
                let mirror = try #require(byId[row.id])
                #expect(mirror.seq == row.seq)
                #expect(mirror.content == row.content)
            }
        }
    }
}

@Test(arguments: [false, true])
func messageCommitAttachmentCompetitionLeavesNoLosingRowsMentionsOrBroadcasts(agent: Bool) async throws {
    let f = commitFixture(agent ? "803" : "802")
    let uploaderId = agent ? f.agentId : f.ownerId
    let attachmentId = f.accounts.addChannelAttachment(channelId: f.channelId, uploaderId: uploaderId, filename: "one.pdf")
    let realtime = try await RealtimeServer.start(auth: CommitSocketAuth(core: f.accounts.authCore, membership: f.accounts.socketMembership))
    let socket = try await SocketIOTestClient(port: realtime.port)
    defer { socket.close(); Task { try? await realtime.close() } }
    _ = try #require(await socket.waitForText { $0.hasPrefix("0") })
    socket.send("40{\"token\":\"\(f.token)\",\"serverId\":\"\(f.serverId)\"}")
    _ = try #require(await socket.waitForText { $0 == "42[\"rooms:joined\"]" })
    let frameStart = socket.textFrames.count
    let hub = realtime.hub
    f.accounts.realtimeRelay.install { room, event, payload in
        hub.emit(room: room, event: event, payloadJSON: payload)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let results = try await withThrowingTaskGroup(of: CommitHTTPResult.self) { group in
                for index in 0..<32 {
                    group.addTask {
                        let destination = agent ? "\"target\":\"#\(f.channelName)\"" : "\"channelId\":\"\(f.channelId)\""
                        return try await commitPost(
                            client, f: f, path: agent ? "/internal/agent-api/send" : "/api/messages",
                            body: "{\(destination),\"content\":\"attachment-contender-\(index) @commitpeer\",\"attachmentIds\":[\"\(attachmentId)\"],\"mentions\":[{\"type\":\"user\",\"id\":\"\(f.peerId)\",\"name\":\"commitpeer\"}]}", agent: agent
                        )
                    }
                }
                var results: [CommitHTTPResult] = []
                for try await result in group { results.append(result) }
                return results
            }
            let winners = results.filter { $0.status == 200 }
            #expect(winners.count == 1)
            #expect(results.filter { $0.status == 400 && $0.reply.code == "attachment_already_linked" }.count == 31)
            let winner = try #require(winners.first)
            let winnerId = try #require(winner.reply.id ?? winner.reply.messageId)
            let rows = try await commitHistory(client, f: f, target: "#\(f.channelName)")
            #expect(rows.map(\.id) == [winnerId])
            let ownerState = f.accounts.messagesAndThreadsStore.state
            #expect(ownerState.humanMessageRows.map(\.id) == [winnerId])
            #expect(ownerState.channelAttachments[attachmentId]?.messageId == winnerId)
            #expect(ownerState.storedMentions.allSatisfy { $0.messageId == winnerId })
            // Bound the actual socket queue after all 32 HTTP responses. Only
            // this test fence is injected; every message frame comes from send.
            let nonce = UUID().uuidString.lowercased()
            let fencePayload = "{\"nonce\":\"\(nonce)\"}"
            let fence = "42[\"test:commit-fence\",\(fencePayload)]"
            hub.emit(room: "user:\(f.ownerId)", event: "test:commit-fence", payloadJSON: fencePayload)
            _ = try #require(await socket.waitForText { $0 == fence })
            let frames = socket.textFrames
            let end = try #require(frames.indices.first { $0 >= frameStart && frames[$0] == fence })
            let emitted = try frames[frameStart..<end].filter { $0.hasPrefix("42") }.compactMap { frame -> [String: Any]? in
                let event = try #require(try JSONSerialization.jsonObject(with: Data(frame.dropFirst(2).utf8)) as? [Any])
                guard event.first as? String == "message:new" else { return nil }
                return try #require(event.count == 2 ? event[1] as? [String: Any] : nil)
            }
            #expect(emitted.count == 1)
            let payload = try #require(emitted.first)
            #expect(payload["id"] as? String == winnerId)
            #expect(payload["channelId"] as? String == f.channelId)
            #expect(payload["content"] as? String == rows.first?.content)
            #expect(ownerState.humanMessageRows.first?.seq == rows.first?.seq)
            if agent {
                #expect(payload["seq"] as? Int == rows.first?.seq)
                #expect(payload["senderId"] as? String == f.agentId)
                #expect(payload["senderType"] as? String == "agent")
            }
            let attachments = try #require(payload["attachments"] as? [[String: Any]])
            #expect(attachments.compactMap { $0["id"] as? String } == [attachmentId])
            let mentions = try #require(payload["mentions"] as? [[String: Any]])
            #expect(mentions.compactMap { $0["id"] as? String } == [f.peerId])
        }
    }
}

@Test func messageCommitConcurrentRoleNoticesReuseOneDM() async throws {
    let f = commitFixture("804")
    // This is the production notice-domain entry point used after a validated
    // role transition. Exercise two notice commits, then read the served DM.
    await withTaskGroup(of: Void.self) { group in
        for (from, to) in [("member", "admin"), ("admin", "member")] {
            group.addTask {
                f.accounts.agentRoleNotices.post(
                    serverId: f.serverId, actorUserId: f.ownerId, agentId: f.agentId,
                    agentName: "CommitBot804", from: from, to: to
                )
            }
        }
    }
    let dms = f.accounts.serversAndChannelsStore.state.postableChannels.filter { _, row in
        row.serverId == f.serverId && row.kind == "dm"
            && row.memberIds.contains(f.ownerId) && row.memberIds.contains(f.agentId)
    }
    #expect(dms.count == 1)
    let dmId = try #require(dms.first?.key)
    #expect(f.accounts.oauth.channelAgentIds(channelId: dmId).contains(f.agentId))
    #expect(f.accounts.oauth.channelHumanIds(channelId: dmId).contains(f.ownerId))
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let rows = try await commitHistory(client, f: f, target: "dm:@commitowner")
            #expect(rows.count == 2)
            #expect(Set(rows.compactMap(\.seq)) == Set([1, 2]))
            #expect(rows.allSatisfy { $0.content?.contains("changed @CommitBot804's server role") == true })
            let resume = try #require(f.accounts.socketMembership.syncMessages(serverId: f.serverId, userId: f.ownerId, lastSeq: 1, limit: 10))
            #expect(resume.messages.count == 1)
            #expect(resume.messages.first?.channelId == dmId)
            let last = try #require(resume.messages.first)
            #expect(rows.contains { $0.id == last.id && $0.seq == last.seq })
        }
    }
}
