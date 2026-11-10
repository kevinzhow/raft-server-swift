import Foundation
import HTTPTypes
import Testing
import TestSupport
import Vapor
import VaporTesting
import RaftHTTPServer
@testable import RaftHTTP

private struct ReplyFollowActors {
    let accounts: EmailLoginDirectory
    let server: String
    let owner: String
    let token: String
    let parent: String
    let parentName: String
    let anchor: String
    let thread: String
    let a: String
    let b: String
    let outsider: String
    let aName: String
    let outsiderName: String
    let aKey: String
    let bKey: String
    let outsiderKey: String
    var target: String { "#\(parentName):\(anchor.prefix(8))" }

    init() {
        let accounts = EmailLoginDirectory()
        let owner = UUID().uuidString.lowercased(), server = UUID().uuidString.lowercased()
        accounts.addAccount(id: owner, email: "reply-follow-\(owner)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: owner)
        accounts.oauth.addOwnedServer(id: server, slug: "reply-follow", name: "Reply follow", ownerId: owner)
        let name = "reply-follow-\(UUID().uuidString.lowercased().prefix(8))"
        let parent = accounts.oauth.createChannel(serverId: server, name: name, creatorUserId: owner)
        accounts.addPostableChannel(serverId: server, channelId: parent, memberId: owner, name: name)
        accounts.oauth.addChannelHuman(channelId: parent, userId: owner)
        let anchor = accounts.addChannelMessageForTesting(channelId: parent, content: "Actual authored parent", senderId: owner)
        let thread = accounts.oauth.createThreadChannel(parentChannelId: parent, parentMessageId: anchor)
        accounts.addPostableChannel(serverId: server, channelId: thread, memberId: owner, kind: "thread",
            parentChannelId: parent, parentMessageId: anchor, name: "thread")
        let a = accounts.oauth.createAgent(serverId: server, name: "ReplyFollowA", creatorUserId: owner, runtime: "claude")
        let b = accounts.oauth.createAgent(serverId: server, name: "ReplyFollowB", creatorUserId: owner, runtime: "claude")
        let outsider = accounts.oauth.createAgent(serverId: server, name: "ReplyFollowOutside", creatorUserId: owner, runtime: "claude")
        for id in [a, b] { accounts.oauth.addChannelAgent(channelId: parent, agentId: id) }
        self.accounts = accounts; self.owner = owner; self.server = server; self.parent = parent
        self.parentName = name; self.anchor = anchor; self.thread = thread
        self.a = a; self.b = b; self.outsider = outsider
        self.aName = accounts.oauth.agentRuntimeInfo(id: a)!.name
        self.outsiderName = accounts.oauth.agentRuntimeInfo(id: outsider)!.name
        self.token = accounts.mintAccessTokenForTesting(userId: owner)
        self.aKey = accounts.mintAgentCredential(agentId: a, scopes: ["read", "send"], name: "reply-a")
        self.bKey = accounts.mintAgentCredential(agentId: b, scopes: ["read", "send"], name: "reply-b")
        self.outsiderKey = accounts.mintAgentCredential(agentId: outsider, scopes: ["read", "send"], name: "reply-outsider")
    }
}

/// Published HTTP and actual retained follow facts. These non-Codex fixtures
/// make no PG, NIO, daemon, model, or agent-message delivery claim.
@Test(arguments: ["self-v1", "self-v2", "mention-v1", "mention-v2"])
func committedAgentRepliesReactivateOnlyActualParentMembers(_ mode: String) async throws {
    let f = ReplyFollowActors()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            func request(_ method: HTTPRequest.Method, _ path: String, key: String? = nil, body: [String: Any]? = nil) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(key ?? f.token)"
                headers[.contentType] = "application/json"
                if key == nil { headers[HTTPField.Name("X-Server-Id")!] = f.server }
                let bytes = try body.map { try JSONSerialization.data(withJSONObject: $0) }
                let response = try await client.send(method, headers: headers, to: URI(string: path)) {
                    if let bytes { $0.body = .init(data: bytes) }
                }
                let json = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "{}").utf8)) as? [String: Any] ?? [:]
                return (response, json)
            }
            func removeA() async throws -> String {
                let response = try await request(.delete, "/api/channels/threads/\(f.thread)/followers/agents/\(f.a)")
                try #require(response.0.status == .ok)
                return try #require(response.1["undoToken"] as? String)
            }
            func restoreA(_ token: String) async throws -> Bool {
                let response = try await request(.post, "/api/channels/threads/\(f.thread)/followers/agents/\(f.a)/restore", body: ["undoToken": token])
                try #require(response.0.status == .ok)
                return try #require(response.1["restored"] as? Bool)
            }
            func suppressed(_ id: String) -> Bool {
                f.accounts.messagesAndThreadsStore.threadFollowSnapshot().unfollows.contains("\(f.server)\n\(id)\n\(f.thread)")
            }
            func follows(_ id: String) -> Bool {
                f.accounts.messagesAndThreadsStore.threadFollowSnapshot().follows.contains("\(f.server)\n\(id)\n\(f.thread)") && !suppressed(id)
            }
            // Seed the recipient follow through the actual human mention path.
            let seeded = try await request(.post, "/api/messages", body: ["channelId": f.thread,
                "content": "Seed @\(f.aName)", "mentions": [["type": "agent", "id": f.a, "name": f.aName]]])
            try #require(seeded.0.status == .ok)
            try #require(follows(f.a))
            let ownerUnfollow = try await request(.post, "/api/channels/threads/unfollow", body: ["threadChannelId": f.thread])
            try #require(ownerUnfollow.0.status == .ok)
            try #require(suppressed(f.owner))
            let firstUndo = try await removeA()
            try #require(suppressed(f.a))
            let isMention = mode.hasPrefix("mention")
            let path = mode.hasSuffix("v2") ? "/internal/agent-api/v2/send" : "/internal/agent-api/send"
            let senderKey = isMention ? f.bKey : f.aKey
            let draft: [String: Any] = ["target": f.target,
                "content": isMention ? "Actual eligible @\(f.aName) and outside @\(f.outsiderName)" : "Actual sender self-reply",
                "idempotencyKey": "actual-reply-once", "mentions": [
                    ["type": "agent", "id": f.a, "name": f.aName],
                    ["type": "agent", "id": f.outsider, "name": f.outsiderName],
                ]]
            let fresh = try await request(.post, path, key: senderKey, body: draft)
            try #require(fresh.0.status == .ok)
            try #require(fresh.1["state"] as? String == "sent")
            let messageId = try #require(fresh.1["messageId"] as? String)
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.contains { $0.id == messageId && $0.senderType == "agent" })
            #expect(follows(f.a))
            #expect(!suppressed(f.a))
            #expect(suppressed(f.owner), "ordinary parent-author auto-follow must preserve explicit suppression")
            #expect(!follows(f.outsider))
            #expect(try await restoreA(firstUndo) == false)
            let secondUndo = try await removeA()
            try #require(suppressed(f.a))
            let count = f.accounts.messagesAndThreadsStore.humanMessageRows.count
            let replay = try await request(.post, path, key: senderKey, body: draft)
            #expect(replay.0.status == .ok)
            #expect(replay.1["messageId"] as? String == messageId)
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == count)
            #expect(suppressed(f.a))
            #expect(suppressed(f.owner))
            // The v2 negative needs real canonical identities and a visible authored token.
            let collisionHuman = UUID().uuidString.lowercased()
            f.accounts.addAccount(id: collisionHuman, email: "reply-follow-collision-\(collisionHuman)@slock.test", password: "password123")
            f.accounts.setAccountProfileForTesting(id: collisionHuman, name: f.aName)
            f.accounts.markEmailVerified(userId: collisionHuman)
            f.accounts.oauth.addMember(serverId: f.server, userId: collisionHuman, role: "member")
            f.accounts.oauth.addChannelHuman(channelId: f.parent, userId: collisionHuman)
            f.accounts.addPostableChannel(serverId: f.server, channelId: f.parent, memberId: collisionHuman, name: f.parentName)
            #expect(collisionHuman != f.a)
            #expect(f.accounts.authProfileStore.account(userId: collisionHuman)?.name == f.aName)
            #expect(f.accounts.oauth.memberRole(serverId: f.server, userId: collisionHuman) == "member")
            #expect(f.accounts.oauth.isChannelParticipant(channelId: f.parent, userId: collisionHuman))
            #expect(f.accounts.oauth.agentRuntimeInfo(id: f.a)?.name == f.aName)
            let beforeDenied = f.accounts.messagesAndThreadsStore.threadFollowSnapshot()
            let invalid = try await request(.post, "/internal/agent-api/v2/send", key: f.aKey,
                body: ["target": f.target, "content": "Denied binding @\(f.aName)", "mentions": [
                    ["type": "agent", "id": f.a, "name": f.aName], ["type": "user", "id": collisionHuman, "name": f.aName]]])
            #expect(invalid.0.status == .badRequest)
            #expect(invalid.1["code"] as? String == "mention_binding_conflict")
            let outsider = try await request(.post, path, key: f.outsiderKey, body: ["target": f.target, "content": "Denied nonmember"])
            #expect(outsider.0.status == .forbidden)
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == count)
            #expect(f.accounts.messagesAndThreadsStore.threadFollowSnapshot().follows == beforeDenied.follows)
            #expect(f.accounts.messagesAndThreadsStore.threadFollowSnapshot().unfollows == beforeDenied.unfollows)
            #expect(try await restoreA(secondUndo) == true)
            // A real human self-reply reactivates, but its replay cannot undo a
            // later explicit unfollow. This uses the same actual commit ledger.
            let humanBody: [String: Any] = ["channelId": f.thread, "content": "Actual human self-reply", "randomId": "human-reply-once"]
            let human = try await request(.post, "/api/messages", body: humanBody)
            try #require(human.0.status == .ok)
            #expect(follows(f.owner))
            let humanId = try #require(human.1["id"] as? String)
            _ = try await request(.post, "/api/channels/threads/unfollow", body: ["threadChannelId": f.thread])
            let humanCount = f.accounts.messagesAndThreadsStore.humanMessageRows.count
            let humanReplay = try await request(.post, "/api/messages", body: humanBody)
            #expect(humanReplay.1["id"] as? String == humanId)
            #expect(suppressed(f.owner))
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == humanCount)
            // Revoked private parent access must not create a new reply or follow.
            let visibility = try await request(.patch, "/api/channels/\(f.parent)", body: ["visibility": "private"])
            try #require(visibility.0.status == .ok)
            let removedMember = try await request(.delete, "/api/channels/\(f.parent)/members/agent/\(f.a)")
            try #require(removedMember.0.status == .ok)
            let privateBefore = f.accounts.messagesAndThreadsStore.threadFollowSnapshot()
            let privateCount = f.accounts.messagesAndThreadsStore.humanMessageRows.count
            let privateDenied = try await request(.post, path, key: f.aKey, body: ["target": f.target, "content": "Denied private parent"])
            #expect(privateDenied.0.status == .notFound)
            #expect(f.accounts.messagesAndThreadsStore.humanMessageRows.count == privateCount)
            #expect(f.accounts.messagesAndThreadsStore.threadFollowSnapshot().follows == privateBefore.follows)
            #expect(f.accounts.messagesAndThreadsStore.threadFollowSnapshot().unfollows == privateBefore.unfollows)
        }
    }
}
