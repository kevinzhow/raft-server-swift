import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private struct ProjectionReviewFixture {
    let accounts: EmailLoginDirectory
    let owner: String
    let peer: String
    let server: String
    let channel: String

    init() {
        let accounts = EmailLoginDirectory()
        let owner = UUID().uuidString.lowercased(), peer = UUID().uuidString.lowercased()
        let server = UUID().uuidString.lowercased()
        accounts.addAccount(id: owner, email: "projection-review-owner@slock.test", password: "password123")
        accounts.addAccount(id: peer, email: "projection-review-peer@slock.test", password: "password123")
        for user in [owner, peer] { accounts.markEmailVerified(userId: user) }
        accounts.oauth.addOwnedServer(id: server, slug: "projection-review", name: "Projection Review", ownerId: owner)
        accounts.oauth.addMember(serverId: server, userId: peer, role: "member")
        let channel = accounts.oauth.createChannel(serverId: server, name: "review", creatorUserId: owner)
        for user in [owner, peer] {
            accounts.addPostableChannel(serverId: server, channelId: channel, memberId: user, name: "review")
            accounts.oauth.addChannelHuman(channelId: channel, userId: user)
        }
        self.accounts = accounts; self.owner = owner; self.peer = peer
        self.server = server; self.channel = channel
    }

    func headers(_ user: String) -> HTTPFields {
        var result = HTTPFields()
        result[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: user))"
        result[HTTPField.Name("X-Server-Id")!] = server
        result[.contentType] = "application/json"
        return result
    }

    var services: FallbackServices {
        FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts)
    }
}

private func reviewObject(_ response: ClientResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
}

@Test func coldTaskHostsOverlayCanonicalTransitionsWithoutRewritingStoredMessages() async throws {
    let f = ProjectionReviewFixture()
    try await withApp { app in
        configure(app, services: f.services)
        try await app.testing { client in
            let ownerHeaders = f.headers(f.owner)
            let peerHeaders = f.headers(f.peer)
            func post(_ path: String, _ body: [String: Any]) async throws -> ClientResponse {
                let data = try JSONSerialization.data(withJSONObject: body)
                return try await client.send(.post, headers: ownerHeaders, to: URI(string: path)) { $0.body = .init(data: data) }
            }
            let sent = try await post("/api/messages", ["channelId": f.channel, "content": "canonical read overlay host"])
            #expect(sent.status == .ok)
            let hostId = try #require(try reviewObject(sent)["id"] as? String)
            let stored = try #require(f.accounts.messagesAndThreadsStore.humanMessageRow(id: hostId))
            let converted = try await post("/api/tasks/convert-message", ["messageId": hostId])
            #expect(converted.status == .ok)
            let task = try #require(try reviewObject(converted)["task"] as? [String: Any])
            let taskId = try #require(task["id"] as? String)
            let number = try #require(task["taskNumber"] as? Int)
            #expect(number > 0)

            func cold(_ status: String, assignee: String?, claimed: Bool, completed: Bool) async throws {
                for path in ["/api/messages/channel/\(f.channel)",
                             "/api/messages/context/\(hostId)?channelId=\(f.channel)",
                             "/api/messages/sync?channel_id=\(f.channel)&since_seq=0",
                             "/api/messages/sync?since_seq=0"] {
                    let response = try await client.get(URI(string: path), headers: ownerHeaders)
                    #expect(response.status == .ok)
                    let value = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))
                    let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
                    let row = try #require(rows.first { $0["id"] as? String == hostId })
                    #expect(row["taskStatus"] as? String == status)
                    #expect(row["taskNumber"] as? Int == number)
                    if let assignee {
                        #expect(row["taskAssigneeId"] as? String == assignee)
                        #expect(row["taskAssigneeType"] as? String == "user")
                        #expect(row["taskAssigneeName"] as? String == (assignee == f.owner ? "projection-review-owner" : "projection-review-peer"))
                    } else {
                        #expect(row["taskAssigneeId"] is NSNull)
                        #expect(row["taskAssigneeType"] is NSNull)
                        #expect(row["taskAssigneeName"] is NSNull)
                    }
                    if claimed { #expect(row["taskClaimedAt"] is String) }
                    else { #expect(row["taskClaimedAt"] is NSNull) }
                    if completed { #expect(row["taskCompletedAt"] is String) }
                    else { #expect(row["taskCompletedAt"] is NSNull) }
                    let current = try #require(row["taskCurrentProjection"] as? [String: Any])
                    #expect(current["title"] as? String == "canonical read overlay host")
                    #expect(current["source"] as? String == "tasks_current_projection")
                    #expect(row["content"] as? String == stored.content)
                    #expect(row["seq"] as? Int == stored.seq)
                }
                let unchanged = try #require(f.accounts.messagesAndThreadsStore.humanMessageRow(id: hostId))
                #expect(unchanged.content == stored.content && unchanged.createdAt == stored.createdAt && unchanged.seq == stored.seq)
                #expect(unchanged.messageType == stored.messageType && unchanged.actionKind == stored.actionKind)
                #expect(unchanged.taskStatus == stored.taskStatus && unchanged.taskNumber == stored.taskNumber)
                #expect(unchanged.taskAssigneeType == stored.taskAssigneeType && unchanged.taskAssigneeId == stored.taskAssigneeId)
                #expect(unchanged.taskClaimedAt == stored.taskClaimedAt && unchanged.taskCompletedAt == stored.taskCompletedAt)
            }
            func assign(_ user: String?) async throws {
                let assignee: Any
                if let user { assignee = ["type": "user", "id": user] }
                else { assignee = NSNull() }
                let data = try JSONSerialization.data(withJSONObject: ["assignee": assignee])
                let response = try await client.send(.patch, headers: ownerHeaders, to: URI(string: "/api/tasks/\(taskId)/assignee")) { $0.body = .init(data: data) }
                #expect(response.status == .ok)
            }
            try await cold("todo", assignee: nil, claimed: false, completed: false)
            try await assign(f.owner)
            try await cold("todo", assignee: f.owner, claimed: false, completed: false)
            try await assign(f.peer)
            try await cold("todo", assignee: f.peer, claimed: false, completed: false)
            try await assign(nil)
            try await cold("todo", assignee: nil, claimed: false, completed: false)
            try await assign(f.peer)
            let claimed = try await client.send(.patch, headers: peerHeaders, to: URI(string: "/api/tasks/\(taskId)/claim"))
            #expect(claimed.status == .ok)
            try await cold("in_progress", assignee: f.peer, claimed: true, completed: false)
            let done = try await client.send(.patch, headers: peerHeaders, to: URI(string: "/api/tasks/\(taskId)/status")) {
                $0.body = .init(string: "{\"status\":\"done\"}")
            }
            #expect(done.status == .ok)
            try await cold("done", assignee: f.peer, claimed: true, completed: true)
        }
    }
}

@Test func bundledThreadUnreadRequiresAnActiveNonDoneFollowAndIncludesOwnRows() async throws {
    let f = ProjectionReviewFixture()
    try await withApp { app in
        configure(app, services: f.services)
        try await app.testing { client in
            let ownerHeaders = f.headers(f.owner)
            let peerHeaders = f.headers(f.peer)
            func send(_ channel: String, _ text: String, _ peer: Bool = false) async throws -> String {
                let data = try JSONSerialization.data(withJSONObject: ["channelId": channel, "content": text])
                let response = try await client.send(.post, headers: peer ? peerHeaders : ownerHeaders, to: "/api/messages") { $0.body = .init(data: data) }
                #expect(response.status == .ok)
                return try #require(try reviewObject(response)["id"] as? String)
            }
            func pair(_ text: String) async throws -> (parent: String, thread: String) {
                let parent = try await send(f.channel, text)
                let data = try JSONSerialization.data(withJSONObject: ["parentMessageId": parent])
                let response = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/channels/\(f.channel)/threads")) { $0.body = .init(data: data) }
                #expect(response.status == .ok)
                return (parent, try #require(try reviewObject(response)["threadChannelId"] as? String))
            }
            func mutate(_ thread: String, _ action: String) async throws {
                let data = try JSONSerialization.data(withJSONObject: ["threadChannelId": thread])
                let response = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/channels/threads/\(action)")) { $0.body = .init(data: data) }
                #expect(response.status == .ok)
            }
            let active = try await pair("active parent")
            try await mutate(active.thread, "follow")
            let ownReply = try await send(active.thread, "own unread reply")
            // POST advances this sender's cursor. The real mark-unread route
            // moves it back; with no peer row in this thread its cursor is zero.
            let markedUnread = try await client.send(.post, headers: ownerHeaders,
                to: URI(string: "/api/channels/\(active.thread)/unread"))
            #expect(markedUnread.status == .ok)
            let ownSeq = try #require(f.accounts.messagesAndThreadsStore.humanMessageRow(id: ownReply)?.seq)
            let actualCursor = try #require(try reviewObject(markedUnread)["maxReadSeq"] as? Int)
            #expect(actualCursor < ownSeq)
            let done = try await pair("done parent")
            _ = try await send(done.thread, "first before done", true)
            let lastDoneReply = try await send(done.thread, "second before done", true)
            try await mutate(done.thread, "follow")
            try await mutate(done.thread, "done")
            // No later send reopens this scope. These are actual retained facts:
            // thread-done records the marker/frontier, not the OAuth cursor.
            #expect(f.accounts.messagesAndThreadsStore.state.inboxDoneScopes.contains("\(f.owner)\n\(done.thread)"))
            let lastDoneSeq = try #require(f.accounts.messagesAndThreadsStore.humanMessageRow(id: lastDoneReply)?.seq)
            #expect(f.accounts.oauth.channelReadCursor(channelId: done.thread, userId: f.owner) < lastDoneSeq)
            let unfollowed = try await pair("unfollowed parent")
            _ = try await send(unfollowed.thread, "unfollowed reply", true)
            try await mutate(unfollowed.thread, "follow")
            try await mutate(unfollowed.thread, "unfollow")
            for path in ["/api/messages/channel/\(f.channel)", "/api/messages/context/\(unfollowed.parent)?channelId=\(f.channel)"] {
                let response = try await client.get(URI(string: path), headers: ownerHeaders)
                #expect(response.status == .ok)
                let summaries = try #require(try reviewObject(response)["threadSummariesByParentMessageId"] as? [String: Any])
                let activeSummary = try #require(summaries[active.parent] as? [String: Any])
                #expect(activeSummary["followed"] as? Bool == true)
                #expect(activeSummary["unreadCount"] as? Int == 1)
                #expect(activeSummary["firstUnreadMessageId"] as? String == ownReply)
                for (parent, followed) in [(done.parent, true), (unfollowed.parent, false)] {
                    let summary = try #require(summaries[parent] as? [String: Any])
                    #expect(summary["followed"] as? Bool == followed)
                    #expect(summary["unreadCount"] as? Int == 0)
                    #expect(summary["firstUnreadMessageId"] is NSNull)
                }
            }
        }
    }
}

@Test func bundledChildThreadsRequireTheirOwnCurrentServerAndActiveJointAuthority() async throws {
    let accounts = EmailLoginDirectory()
    let host = UUID().uuidString.lowercased(), peer = UUID().uuidString.lowercased()
    let hostServer = UUID().uuidString.lowercased(), peerServer = UUID().uuidString.lowercased()
    for (id, email) in [(host, "joint-review-host@slock.test"), (peer, "joint-review-peer@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123"); accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: hostServer, slug: "joint-review-host", name: "Host", ownerId: host)
    accounts.oauth.addOwnedServer(id: peerServer, slug: "joint-review-peer", name: "Peer", ownerId: peer)
    func channel(_ server: String, _ user: String, _ name: String, _ kind: String) -> String {
        let id = accounts.oauth.createChannel(serverId: server, name: name, creatorUserId: user, type: kind)
        accounts.addPostableChannel(serverId: server, channelId: id, memberId: user, kind: kind, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: user)
        return id
    }
    let canonical = channel(hostServer, host, "storage", "channel")
    let hostParent = channel(hostServer, host, "host-local", "joint")
    let peerParent = channel(peerServer, peer, "peer-local", "joint")
    accounts.addJointChannelProjection(localChannelId: hostParent, canonicalChannelId: canonical, serverId: hostServer)
    accounts.addJointChannelProjection(localChannelId: peerParent, canonicalChannelId: canonical, serverId: peerServer)
    let parent = accounts.addChannelMessageForTesting(channelId: canonical, content: "readable shared parent", senderId: host)
    let otherParent = accounts.addChannelMessageForTesting(channelId: canonical, content: "other shared parent", senderId: host)
    let storageThread = UUID().uuidString.lowercased(), localThread = UUID().uuidString.lowercased()
    let hostThread = UUID().uuidString.lowercased(), foreignThread = UUID().uuidString.lowercased()
    accounts.addThreadChannel(serverId: hostServer, threadChannelId: storageThread, parentChannelId: canonical, parentMessageId: parent, memberId: host)
    accounts.addThreadChannel(serverId: hostServer, threadChannelId: hostThread, parentChannelId: hostParent, parentMessageId: parent, memberId: host)
    accounts.addThreadChannel(serverId: peerServer, threadChannelId: localThread, parentChannelId: peerParent, parentMessageId: parent, memberId: peer)
    accounts.addJointChannelProjection(localChannelId: hostThread, canonicalChannelId: storageThread, serverId: hostServer)
    accounts.addJointChannelProjection(localChannelId: localThread, canonicalChannelId: storageThread, serverId: peerServer)
    accounts.setJointProjectionStatusForTesting(localChannelId: localThread, serverId: peerServer, status: "inactive")
    let secret = accounts.addChannelMessageForTesting(channelId: storageThread, content: "INACTIVE-CANONICAL-SECRET", senderId: host)
    accounts.addThreadChannel(serverId: hostServer, threadChannelId: foreignThread, parentChannelId: peerParent, parentMessageId: otherParent, memberId: peer)
    _ = accounts.addChannelMessageForTesting(channelId: foreignThread, content: "WRONG-SERVER-SECRET", senderId: host)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: peer))"
    headers[HTTPField.Name("X-Server-Id")!] = peerServer
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            for active in [false, true] {
                if active { accounts.setJointProjectionStatusForTesting(localChannelId: localThread, serverId: peerServer, status: "active") }
                for path in ["/api/messages/channel/\(peerParent)", "/api/messages/context/\(parent)?channelId=\(peerParent)"] {
                    let response = try await client.get(URI(string: path), headers: headers)
                    #expect(response.status == .ok)
                    let text = response.body.string ?? ""
                    let body = try reviewObject(response)
                    let summaries = try #require(body["threadSummariesByParentMessageId"] as? [String: Any])
                    #expect(summaries[otherParent] == nil)
                    #expect(!text.contains("WRONG-SERVER-SECRET") && !text.contains(foreignThread))
                    let rows = try #require(body["messages"] as? [[String: Any]])
                    let row = try #require(rows.first { $0["id"] as? String == parent })
                    if active {
                        let summary = try #require(summaries[parent] as? [String: Any])
                        #expect(summary["threadChannelId"] as? String == localThread)
                        #expect(row["threadId"] as? String == localThread)
                        let replies = try #require(summary["latestReplies"] as? [[String: Any]])
                        #expect(replies.first?["messageId"] as? String == secret)
                    } else {
                        #expect(summaries[parent] == nil)
                        #expect(row["threadId"] is NSNull)
                        #expect(!text.contains("INACTIVE-CANONICAL-SECRET") && !text.contains(secret))
                        #expect(!text.contains(localThread) && !text.contains(storageThread))
                    }
                }
            }
        }
    }
}
