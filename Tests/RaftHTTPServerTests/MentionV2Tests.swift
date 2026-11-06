import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct MentionV2Fixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerId: String
    let ownerEmail: String
    let sameHandleHuman: String
    let sameHandleAgent: String
}

private func makeMentionV2Fixture(suffix: String) -> MentionV2Fixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 940_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 940_000 + number)
    let humanId = String(format: "11111111-1111-4111-8111-%012d", 941_000 + number)
    let ownerEmail = "message-v2-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: humanId, email: "message-v2-human-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: humanId)
    accounts.setAccountProfileForTesting(id: humanId, name: "same_handle")
    accounts.oauth.addOwnedServer(id: serverId, slug: "message-v2-\(suffix)", name: "Message V2 Server", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: humanId, role: "member")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "same_handle", runtime: "claude")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "message-v2-room-\(suffix)", creatorUserId: ownerId)
    for member in [ownerId, humanId, agent] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: member, name: "message-v2-room-\(suffix)")
    }
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: humanId)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    return MentionV2Fixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channel,
        ownerId: ownerId,
        ownerEmail: ownerEmail,
        sameHandleHuman: humanId,
        sameHandleAgent: agent
    )
}

private func mentionLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func mentionHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func mentionSend(_ client: any Client, headers: HTTPFields, path: String, body: String) async throws -> ClientResponse {
    try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func mentionObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func v2MentionWarningsAreSenderOnlyAndBindTypedNames() async throws {
    let fixture = makeMentionV2Fixture(suffix: "971")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await mentionLogin(client, email: fixture.ownerEmail)
            let headers = mentionHeaders(token, fixture.serverId)

            let v1 = try await mentionSend(
                client,
                headers: headers,
                path: "/api/messages",
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"v1 @same_handle\"}"
            )
            #expect(v1.status == .ok)
            let v1Body = try mentionObject(v1)
            let v1Id = try #require(v1Body["id"] as? String)
            #expect(v1Body["message"] == nil)
            #expect(v1Body["unresolvedMentionHandles"] == nil)
            let v1Rows = fixture.accounts.messageMentionRows(messageId: v1Id)
                .map { "\($0.targetType):\($0.targetId)" }
                .sorted()
            #expect(v1Rows == ["agent:\(fixture.sameHandleAgent)", "user:\(fixture.sameHandleHuman)"].sorted())

            let ambiguous = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"v2 raw @same_handle\"}"
            )
            #expect(ambiguous.status == .ok)
            let ambiguousBody = try mentionObject(ambiguous)
            let ambiguousMessage = try #require(ambiguousBody["message"] as? [String: Any])
            let ambiguousId = try #require(ambiguousMessage["id"] as? String)
            #expect(ambiguousBody["unresolvedMentionHandles"] as? [String] == ["@same_handle"])
            #expect(fixture.accounts.messageMentionRows(messageId: ambiguousId).isEmpty)

            let typed = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"v2 typed @same_handle\",\"mentions\":[{\"type\":\"agent\",\"id\":\"\(fixture.sameHandleAgent)\",\"name\":\"same_handle\"}]}"
            )
            #expect(typed.status == .ok)
            let typedBody = try mentionObject(typed)
            #expect(typedBody["unresolvedMentionHandles"] == nil)
            let typedMessage = try #require(typedBody["message"] as? [String: Any])
            let typedId = try #require(typedMessage["id"] as? String)
            let typedRows = fixture.accounts.messageMentionRows(messageId: typedId)
                .map { "\($0.targetType):\($0.targetId)" }
            #expect(typedRows == ["agent:\(fixture.sameHandleAgent)"])

            let before = fixture.accounts.humanMessageCount
            let conflict = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(fixture.channelId)\",\"content\":\"v2 conflict @same_handle\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(fixture.sameHandleHuman)\",\"name\":\"same_handle\"},{\"type\":\"agent\",\"id\":\"\(fixture.sameHandleAgent)\",\"name\":\"same_handle\"}]}"
            )
            #expect(conflict.status == .badRequest)
            #expect(try mentionObject(conflict)["code"] as? String == "mention_binding_conflict")
            #expect(fixture.accounts.humanMessageCount == before)
        }
    }
}

@Test func hiddenHumanDirectoryIsNotEnumerableThroughMentions() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-333333333972"
    let ownerId = "11111111-1111-4111-8111-111111111972"
    let senderId = "11111111-1111-4111-8111-111111111973"
    let peerId = "11111111-1111-4111-8111-111111111974"
    let hiddenId = "11111111-1111-4111-8111-111111111975"
    let ownerEmail = "hidden-mention-owner-972@slock.test"
    let senderEmail = "hidden-mention-sender-972@slock.test"
    for (id, email) in [
        (ownerId, ownerEmail), (senderId, senderEmail),
        (peerId, "hidden-mention-visible-972@slock.test"), (hiddenId, "hidden-mention-target-972@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.setAccountProfileForTesting(id: hiddenId, name: "hidden_target")
    accounts.oauth.addOwnedServer(id: serverId, slug: "community-972", name: "Community", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: senderId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: hiddenId, role: "member")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "hidden-mention-shared-972", creatorUserId: senderId)
    for member in [senderId, peerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: member, name: "hidden-mention-shared-972")
    }
    accounts.oauth.addChannelHuman(channelId: channel, userId: senderId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: peerId)
    let agentName = "hidden_mention_agent"
    let outsiderAgent = accounts.oauth.createAgent(serverId: serverId, name: agentName, runtime: "claude")
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await mentionLogin(client, email: senderEmail)
            let headers = mentionHeaders(token, serverId)

            let raw = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(channel)\",\"content\":\"hidden raw @hidden_target\"}"
            )
            #expect(raw.status == .ok)
            let rawBody = try mentionObject(raw)
            let rawMessage = try #require(rawBody["message"] as? [String: Any])
            let rawId = try #require(rawMessage["id"] as? String)
            #expect(rawBody["unresolvedMentionHandles"] as? [String] == ["@hidden_target"])
            #expect(rawBody["pendingMentionActions"] == nil)
            #expect(accounts.messageMentionRows(messageId: rawId).isEmpty)

            let typed = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(channel)\",\"content\":\"hidden typed @hidden_target\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(hiddenId)\",\"name\":\"hidden_target\"}]}"
            )
            #expect(typed.status == .ok)
            let typedBody = try mentionObject(typed)
            #expect(typedBody["unresolvedMentionHandles"] == nil)
            #expect(typedBody["pendingMentionActions"] == nil)
            let typedId = try #require((typedBody["message"] as? [String: Any])?["id"] as? String)
            #expect(accounts.messageMentionRows(messageId: typedId).isEmpty)

            let legacy = try await mentionSend(
                client,
                headers: headers,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channel)\",\"content\":\"legacy hidden @hidden_target\"}"
            )
            #expect(legacy.status == .ok)
            let legacyId = try #require(try mentionObject(legacy)["id"] as? String)
            #expect(accounts.messageMentionRows(messageId: legacyId).isEmpty)

            // A joint peer in the sender's joint roster is visible again.
            let canonical = accounts.oauth.createChannel(serverId: serverId, name: "joint-canonical-972", creatorUserId: senderId)
            let localJoint = accounts.oauth.createChannel(serverId: serverId, name: "joint-local-972", creatorUserId: senderId, type: "joint")
            let peerServerId = "33333333-3333-4333-8333-333333333976"
            accounts.oauth.addOwnedServer(id: peerServerId, slug: "peer-972", name: "Peer", ownerId: peerId)
            let peerJoint = accounts.oauth.createChannel(serverId: peerServerId, name: "joint-peer-972", creatorUserId: peerId, type: "joint")
            accounts.addPostableChannel(serverId: serverId, channelId: localJoint, memberId: senderId, kind: "joint", name: "joint-local-972")
            accounts.addPostableChannel(serverId: peerServerId, channelId: peerJoint, memberId: hiddenId, kind: "joint", name: "joint-peer-972")
            accounts.addJointChannelProjection(localChannelId: localJoint, canonicalChannelId: canonical, serverId: serverId)
            accounts.addJointChannelProjection(localChannelId: peerJoint, canonicalChannelId: canonical, serverId: peerServerId)

            let visible = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(channel)\",\"content\":\"visible typed\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(hiddenId)\",\"name\":\"hidden_target\"},{\"type\":\"user\",\"id\":\"\(ownerId)\",\"name\":\"hidden_mention_owner\"},{\"type\":\"agent\",\"id\":\"\(outsiderAgent)\",\"name\":\"\(agentName)\"}]}"
            )
            #expect(visible.status == .ok)
            let visibleBody = try mentionObject(visible)
            let visibleId = try #require((visibleBody["message"] as? [String: Any])?["id"] as? String)
            let actions = visibleBody["pendingMentionActions"] as? [[String: Any]] ?? []
            #expect(actions.compactMap { $0["targetType"] as? String }.sorted() == ["agent", "user", "user"])
            let rows = accounts.messageMentionRows(messageId: visibleId)
            #expect(rows.count == 3)

            accounts.setHideHumansFromMembers(serverId: serverId, hidden: false)
            let nonHidden = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(channel)\",\"content\":\"non-hidden typed\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(hiddenId)\",\"name\":\"hidden_target\"}]}"
            )
            #expect(nonHidden.status == .ok)
            let nonHiddenBody = try mentionObject(nonHidden)
            let nonHiddenActions = nonHiddenBody["pendingMentionActions"] as? [[String: Any]] ?? []
            #expect(nonHiddenActions.map { $0["targetType"] as? String } == ["user"])
            let nonHiddenId = try #require((nonHiddenBody["message"] as? [String: Any])?["id"] as? String)
            #expect(accounts.messageMentionRows(messageId: nonHiddenId).count == 1)

            accounts.oauth.removeMember(serverId: serverId, userId: senderId)
            let beforeOrphan = accounts.humanMessageCount
            let orphan = try await mentionSend(
                client,
                headers: headers,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(channel)\",\"content\":\"orphan human @hidden_target\"}"
            )
            #expect(orphan.status == .forbidden)
            #expect(try mentionObject(orphan) as NSDictionary == ["error": "Not a member of this server"] as NSDictionary)
            #expect(accounts.humanMessageCount == beforeOrphan)
        }
    }
}
