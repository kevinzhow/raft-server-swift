import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let assistantFlag = "identity_borrowing"
private let assistantRoomMessage = "room activity"
private let assistantThreadReply = "room thread reply"

private struct AssistantFixture {
    let accounts: EmailLoginDirectory
    let ownerId: String
    let peerId: String
    let serverId: String
    let roomId: String
    let roomName: String
    let threadId: String
    let dmId: String
    let dmThreadId: String
    let secretId: String
    let assistantId: String
}

private func makeAssistantFixture(_ suffix: String) -> AssistantFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001043\(suffix)"
    let peerId = "11111111-1111-4111-8111-000001044\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001043\(suffix)"
    accounts.addAccount(id: ownerId, email: "assistant-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: peerId, email: "assistant-peer-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: peerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "assistant-\(suffix)", name: "Assistant \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")

    let roomName = "room-\(suffix)"
    let roomId = accounts.oauth.createChannel(serverId: serverId, name: roomName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: ownerId, name: roomName)
    accounts.addPostableChannel(serverId: serverId, channelId: roomId, memberId: peerId, name: roomName)
    accounts.oauth.addChannelHuman(channelId: roomId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: roomId, userId: peerId)
    let parentMessageId = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: parentMessageId, channelId: roomId, senderId: peerId, content: assistantRoomMessage)
    let roomRecord = accounts.oauth.createMessageRecord(channelId: roomId, content: assistantRoomMessage, senderId: peerId)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: roomId, messageId: roomRecord.id)
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: roomId, parentMessageId: parentMessageId)
    accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: roomId, parentMessageId: parentMessageId, memberId: ownerId)
    accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: roomId, parentMessageId: parentMessageId, memberId: peerId)
    accounts.oauth.addChannelHuman(channelId: threadId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: threadId, userId: peerId)
    accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: threadId, senderId: peerId, content: assistantThreadReply)
    let threadRecord = accounts.oauth.createMessageRecord(channelId: threadId, content: assistantThreadReply, senderId: peerId)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: threadId, messageId: threadRecord.id)

    let dmId = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: peerId)
    accounts.addPostableChannel(serverId: serverId, channelId: dmId, memberId: ownerId, kind: "dm", name: "dm")
    accounts.addPostableChannel(serverId: serverId, channelId: dmId, memberId: peerId, kind: "dm", name: "dm")
    accounts.oauth.addChannelHuman(channelId: dmId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: dmId, userId: peerId)
    let dmParent = UUID().uuidString.lowercased()
    accounts.insertHumanMessage(id: dmParent, channelId: dmId, senderId: peerId, content: "dm activity")
    let dmRecord = accounts.oauth.createMessageRecord(channelId: dmId, content: "dm activity", senderId: peerId)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: dmId, messageId: dmRecord.id)
    let dmThreadId = accounts.oauth.createThreadChannel(parentChannelId: dmId, parentMessageId: dmParent)
    accounts.addThreadChannel(serverId: serverId, threadChannelId: dmThreadId, parentChannelId: dmId, parentMessageId: dmParent, memberId: ownerId)
    accounts.oauth.addChannelHuman(channelId: dmThreadId, userId: ownerId)
    accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: dmThreadId, senderId: peerId, content: "dm thread reply")
    let dmThreadRecord = accounts.oauth.createMessageRecord(channelId: dmThreadId, content: "dm thread reply", senderId: peerId)
    accounts.addInboxFactForTesting(receiverId: ownerId, serverId: serverId, channelId: dmThreadId, messageId: dmThreadRecord.id)

    let secretId = accounts.oauth.createChannel(serverId: serverId, name: "secret-\(suffix)", creatorUserId: peerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: secretId, memberId: peerId, kind: "private", name: "secret-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: secretId, userId: peerId)
    accounts.insertHumanMessage(id: UUID().uuidString.lowercased(), channelId: secretId, senderId: peerId, content: "private chatter")

    let assistantId = accounts.oauth.createAgent(serverId: serverId, name: "assistant-\(suffix)", creatorUserId: ownerId, runtime: "codex")
    return AssistantFixture(
        accounts: accounts, ownerId: ownerId, peerId: peerId, serverId: serverId,
        roomId: roomId, roomName: roomName, threadId: threadId,
        dmId: dmId, dmThreadId: dmThreadId, secretId: secretId, assistantId: assistantId
    )
}

private func assistantHeaders(_ token: String, serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func assistantObject(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func setAssistant(
    _ client: any Client,
    _ fixture: AssistantFixture,
    method: HTTPRequest.Method,
    token: String,
    agentId: String? = nil,
    serverId: String? = nil
) async throws -> ClientResponse {
    try await client.send(
        method,
        headers: assistantHeaders(token, serverId: serverId ?? fixture.serverId),
        to: URI(string: "/api/agents/\(agentId ?? fixture.assistantId)/assistant-owner")
    )
}

@Test func assistantLinkRequiresCreatorFlagAndExactOwnership() async throws {
    let f = makeAssistantFixture("001")
    let accounts = f.accounts
    let ownerToken = accounts.mintAccessTokenForTesting(userId: f.ownerId)
    let peerToken = accounts.mintAccessTokenForTesting(userId: f.peerId)
    let agentKey = accounts.mintAgentCredential(agentId: f.assistantId, scopes: ["read"], name: "assistant-read")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let off = try await setAssistant(client, f, method: .put, token: ownerToken)
            #expect(off.status == .forbidden)
            #expect(try assistantObject(off)["code"] as? String == "assistant_not_enabled")

            accounts.createFeatureFlagForTesting(key: assistantFlag, defaultEnabled: true)
            let peer = try await setAssistant(client, f, method: .put, token: peerToken)
            #expect(peer.status == .forbidden)
            #expect(try assistantObject(peer)["code"] as? String == "assistant_requires_creator")

            let linked = try await setAssistant(client, f, method: .put, token: ownerToken)
            #expect(linked.status == .ok)
            #expect((try assistantObject(linked)["assistantOf"] as? [String: Any])?["userId"] as? String == f.ownerId)
            #expect(try await setAssistant(client, f, method: .put, token: ownerToken).status == .ok)

            let second = accounts.oauth.createAgent(serverId: f.serverId, name: "second-001", creatorUserId: f.ownerId, runtime: "codex")
            let conflict = try await setAssistant(client, f, method: .put, token: ownerToken, agentId: second)
            #expect(conflict.status == .conflict)
            #expect(try assistantObject(conflict)["code"] as? String == "assistant_already_set")

            #expect(try await setAssistant(client, f, method: .delete, token: peerToken).status == .forbidden)

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(agentKey)"
            let viaAgent = try await client.send(.put, headers: agentHeaders, to: URI(string: "/api/agents/\(f.assistantId)/assistant-owner"))
            #expect(viaAgent.status == .unauthorized)

            let context = try await client.get(URI(string: "/internal/agent-api/context"), headers: agentHeaders)
            #expect(context.status == .ok)
            #expect(((try assistantObject(context)["agent"] as? [String: Any])?["assistantOf"] as? [String: Any])?["userId"] as? String == f.ownerId)

            let cleared = try await setAssistant(client, f, method: .delete, token: ownerToken)
            #expect(cleared.status == .ok)
            let after = try await client.get(URI(string: "/internal/agent-api/context"), headers: agentHeaders)
            #expect((try assistantObject(after)["agent"] as? [String: Any])?["assistantOf"] is NSNull)
        }
    }
}

private func ownerInbox(_ client: any Client, _ f: AssistantFixture, token: String) async throws -> String {
    let response = try await client.get(
        URI(string: "/api/channels/inbox?filter=unread&limit=100"),
        headers: assistantHeaders(token, serverId: f.serverId)
    )
    #expect(response.status == .ok)
    return response.body.string ?? ""
}

@Test func assistantOwnerInboxListsOwnerViewWithoutDMsOrReads() async throws {
    let f = makeAssistantFixture("002")
    let accounts = f.accounts
    accounts.createFeatureFlagForTesting(key: assistantFlag, defaultEnabled: true)
    _ = accounts.agentAssistantOwner(
        authorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: f.ownerId))",
        serverId: f.serverId,
        agentId: f.assistantId,
        method: "PUT"
    )
    let agentKey = accounts.mintAgentCredential(agentId: f.assistantId, scopes: ["read"], name: "assistant-read")
    let ownerToken = accounts.mintAccessTokenForTesting(userId: f.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let before = try await ownerInbox(client, f, token: ownerToken)
            #expect(before.contains(f.dmId), "fixture: the owner has unread DM activity")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(agentKey)"
            let inbox = try await client.get(URI(string: "/internal/agent-api/assistant/owner-inbox?filter=unread&limit=50"), headers: headers)
            #expect(inbox.status == .ok)
            let body = try assistantObject(inbox)
            #expect((body["owner"] as? [String: Any])?["userId"] as? String == f.ownerId)
            let items = body["items"] as? [[String: Any]] ?? []
            let ids = items.compactMap { $0["channelId"] as? String }
            #expect(ids.contains(f.roomId))
            #expect(ids.contains(f.threadId))
            #expect(!ids.contains(f.dmId), "a DM never comes back")
            #expect(!ids.contains(f.dmThreadId), "a thread under a DM never comes back")
            #expect(!ids.contains(f.secretId), "a channel the owner cannot see never comes back")
            let thread = items.first { $0["channelId"] as? String == f.threadId }
            #expect(thread?["kind"] as? String == "thread")
            #expect(thread?["parentChannelId"] as? String == f.roomId)

            #expect(try await ownerInbox(client, f, token: ownerToken) == before, "listing changes none of the owner's read state")
        }
    }
}

@Test func assistantOwnerMessagesFiltersVisibilityAndReadsNothing() async throws {
    let f = makeAssistantFixture("003")
    let accounts = f.accounts
    accounts.createFeatureFlagForTesting(key: assistantFlag, defaultEnabled: true)
    _ = accounts.agentAssistantOwner(
        authorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: f.ownerId))",
        serverId: f.serverId,
        agentId: f.assistantId,
        method: "PUT"
    )
    let agentKey = accounts.mintAgentCredential(agentId: f.assistantId, scopes: ["read"], name: "assistant-read")
    let ownerToken = accounts.mintAccessTokenForTesting(userId: f.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let before = try await ownerInbox(client, f, token: ownerToken)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(agentKey)"

            let room = try await client.get(URI(string: "/internal/agent-api/assistant/owner-messages?channelId=\(f.roomId)"), headers: headers)
            #expect(room.status == .ok)
            #expect((try assistantObject(room)["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String } == [assistantRoomMessage])

            let thread = try await client.get(URI(string: "/internal/agent-api/assistant/owner-messages?channelId=\(f.threadId)"), headers: headers)
            #expect(thread.status == .ok)
            #expect((try assistantObject(thread)["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String } == [assistantThreadReply])

            for channelId in [f.dmId, f.dmThreadId, f.secretId, UUID().uuidString.lowercased()] {
                let refused = try await client.get(URI(string: "/internal/agent-api/assistant/owner-messages?channelId=\(channelId)"), headers: headers)
                #expect(refused.status == .notFound, "\(channelId)")
                #expect(try assistantObject(refused)["code"] as? String == "channel_not_found")
            }

            #expect(try await ownerInbox(client, f, token: ownerToken) == before, "reading changes none of the owner's read state")
        }
    }
}

@Test func assistantReadsRecheckLinkFlagAndMembership() async throws {
    let f = makeAssistantFixture("004")
    let accounts = f.accounts
    accounts.createFeatureFlagForTesting(key: assistantFlag, defaultEnabled: true)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: f.ownerId)
    let agentKey = accounts.mintAgentCredential(agentId: f.assistantId, scopes: ["read"], name: "assistant-read")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(agentKey)"
            func refused() async throws {
                for path in ["/internal/agent-api/assistant/owner-inbox", "/internal/agent-api/assistant/owner-messages?channelId=\(f.roomId)"] {
                    let response = try await client.get(URI(string: path), headers: headers)
                    #expect(response.status == .forbidden, "\(path)")
                    #expect(try assistantObject(response)["code"] as? String == "assistant_not_enabled", "\(path)")
                }
            }
            try await refused()

            #expect(try await setAssistant(client, f, method: .put, token: ownerToken).status == .ok)
            #expect(try await client.get(URI(string: "/internal/agent-api/assistant/owner-inbox"), headers: headers).status == .ok)

            accounts.setFeatureFlagDefaultForTesting(key: assistantFlag, defaultEnabled: false)
            try await refused()
            accounts.setFeatureFlagDefaultForTesting(key: assistantFlag, defaultEnabled: true)
            #expect(try await client.get(URI(string: "/internal/agent-api/assistant/owner-inbox"), headers: headers).status == .ok)

            #expect(try await setAssistant(client, f, method: .delete, token: ownerToken).status == .ok)
            try await refused()
            #expect(try await setAssistant(client, f, method: .put, token: ownerToken).status == .ok)

            // Owner leaves the hosted Server: the link stops authorizing.
            let hostId = "11111111-1111-4111-8111-000001045004"
            let hostedId = "33333333-3333-4333-8333-000001045004"
            accounts.addAccount(id: hostId, email: "assistant-host-004@slock.test", password: "password123")
            accounts.markEmailVerified(userId: hostId)
            accounts.oauth.addOwnedServer(id: hostedId, slug: "assistant-hosted-004", name: "Hosted", ownerId: hostId)
            accounts.oauth.addMember(serverId: hostedId, userId: f.ownerId, role: "member")
            let hostedAgent = accounts.oauth.createAgent(serverId: hostedId, name: "hosted-004", creatorUserId: f.ownerId, runtime: "codex")
            let hostedKey = accounts.mintAgentCredential(agentId: hostedAgent, scopes: ["read"], name: "hosted-read")
            let link = try await setAssistant(client, f, method: .put, token: ownerToken, agentId: hostedAgent, serverId: hostedId)
            #expect(link.status == .ok)
            var hostedHeaders = HTTPFields()
            hostedHeaders[.authorization] = "Bearer \(hostedKey)"
            #expect(try await client.get(URI(string: "/internal/agent-api/assistant/owner-inbox"), headers: hostedHeaders).status == .ok)
            accounts.oauth.removeMember(serverId: hostedId, userId: f.ownerId)
            let afterRemoval = try await client.get(URI(string: "/internal/agent-api/assistant/owner-inbox"), headers: hostedHeaders)
            #expect(afterRemoval.status == .forbidden)
            #expect(try assistantObject(afterRemoval)["code"] as? String == "assistant_not_enabled")
        }
    }
}

@Test func assistantIsConfinedToItsOwnerDM() async throws {
    let f = makeAssistantFixture("005")
    let accounts = f.accounts
    accounts.createFeatureFlagForTesting(key: assistantFlag, defaultEnabled: true)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: f.ownerId)
    let sendKey = accounts.mintAgentCredential(agentId: f.assistantId, scopes: ["send", "read"], name: "assistant-send")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            accounts.oauth.addChannelAgent(channelId: f.roomId, agentId: f.assistantId)
            let busy = try await setAssistant(client, f, method: .put, token: ownerToken)
            #expect(busy.status == .conflict)
            #expect(try assistantObject(busy)["code"] as? String == "assistant_has_channels")
            accounts.oauth.removeChannelAgent(channelId: f.roomId, agentId: f.assistantId)
            #expect(try await setAssistant(client, f, method: .put, token: ownerToken).status == .ok)

            let add = try await client.send(
                .post,
                headers: assistantHeaders(ownerToken, serverId: f.serverId),
                to: URI(string: "/api/channels/\(f.roomId)/members")
            ) { request in
                request.body = .init(string: "{\"agentId\":\"\(f.assistantId)\"}")
            }
            #expect(add.status == .forbidden)
            #expect(try assistantObject(add)["code"] as? String == "assistant_channel_forbidden")

            var sendHeaders = HTTPFields()
            sendHeaders[.authorization] = "Bearer \(sendKey)"
            sendHeaders[.contentType] = "application/json"
            func send(_ target: String) async throws -> ClientResponse {
                try await client.send(.post, headers: sendHeaders, to: "/internal/agent-api/send") { request in
                    request.body = .init(string: "{\"target\":\"\(target)\",\"content\":\"to \(target)\"}")
                }
            }
            #expect(try await send("dm:@assistant-owner-005").status == .ok)
            #expect(try await send("dm:@assistant-peer-005").status != .ok)
            #expect(try await send("#\(f.roomName)").status != .ok)
        }
    }
}
