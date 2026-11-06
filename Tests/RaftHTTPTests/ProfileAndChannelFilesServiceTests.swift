import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The reaction surface owns byte-exact ACK/viewer/actor bodies and the one
/// store critical section each write takes. The HTTP tests lock status codes;
/// these tests lock the published bytes and the atomic row change.

private struct ReactionServiceFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let messageId: String
    let ownerId: String
    let ownerName: String
    let token: String
}

private func makeServiceFixture(suffix: String) -> ReactionServiceFixture {
    let accounts = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 900_000 + (Int(suffix) ?? 0))
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 900_000 + (Int(suffix) ?? 0))
    let channelId = String(format: "22222222-2222-4222-8222-%012d", 900_000 + (Int(suffix) ?? 0))
    let ownerName = "reaction-service-\(suffix)"
    let email = "reaction-service-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: ownerName)
    accounts.oauth.addOwnedServer(
        id: serverId,
        slug: "reaction-service-\(suffix)",
        name: "Reaction Service",
        ownerId: ownerId
    )
    let channel = accounts.oauth.createChannel(
        serverId: serverId,
        name: "reaction-service-\(suffix)",
        creatorUserId: ownerId
    )
    accounts.addPostableChannel(
        serverId: serverId,
        channelId: channel,
        memberId: ownerId,
        name: "reaction-service-\(suffix)"
    )
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let message = accounts.addChannelMessageForTesting(
        channelId: channel,
        content: "reactable service message",
        senderId: ownerId
    )
    let login = accounts.login(body: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    let token = (try? JSONSerialization.jsonObject(with: Data(login.body.utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
    return ReactionServiceFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channel,
        messageId: message,
        ownerId: ownerId,
        ownerName: ownerName,
        token: token
    )
}

@Test func reactionAckAndViewerPublishExactLegacyBytes() throws {
    let fixture = makeServiceFixture(suffix: "901")
    let service = fixture.accounts.profileAndChannelFiles
    let add = try service.addMessageReaction(
        messageId: fixture.messageId,
        emoji: "👍",
        authorization: "Bearer \(fixture.token)",
        serverId: fixture.serverId
    )
    #expect(add.jsonBody.render() == """
    {"reactions":[{"emoji":"👍","count":1,"reactorIds":["\(fixture.ownerId)"],"reactorNames":["\(fixture.ownerName)"]}],"commentRef":null,"attachments":[],"reactionViewer":{"serverId":"\(fixture.serverId)","messageId":"\(fixture.messageId)","viewerVersion":1,"reactedEmojis":["👍"]}}
    """)

    let idempotent = try service.addMessageReaction(
        messageId: fixture.messageId,
        emoji: "👍",
        authorization: "Bearer \(fixture.token)",
        serverId: fixture.serverId
    )
    #expect(idempotent.jsonBody.render() == add.jsonBody.render())

    let removed = try service.removeMessageReaction(
        messageId: fixture.messageId,
        emoji: "👍",
        authorization: "Bearer \(fixture.token)",
        serverId: fixture.serverId
    )
    #expect(removed.jsonBody.render() == """
    {"reactions":[],"commentRef":null,"attachments":[],"reactionViewer":{"serverId":"\(fixture.serverId)","messageId":"\(fixture.messageId)","viewerVersion":2,"reactedEmojis":[]}}
    """)
}

@Test func reactionViewerAndActorPagesPublishExactLegacyBytes() throws {
    let fixture = makeServiceFixture(suffix: "902")
    let service = fixture.accounts.profileAndChannelFiles
    _ = try service.addMessageReaction(
        messageId: fixture.messageId,
        emoji: "👀",
        authorization: "Bearer \(fixture.token)",
        serverId: fixture.serverId
    )
    let viewer = try service.reactionViewer(
        messageId: fixture.messageId,
        authorization: "Bearer \(fixture.token)",
        serverId: fixture.serverId
    )
    #expect(viewer.jsonBody.render() == """
    {"serverId":"\(fixture.serverId)","messageId":"\(fixture.messageId)","viewerVersion":1,"reactedEmojis":["👀"]}
    """)

    let actors = try service.listReactionActors(
        messageId: fixture.messageId,
        authorization: "Bearer \(fixture.token)",
        serverId: fixture.serverId,
        emoji: "👀",
        limit: nil,
        cursor: nil
    )
    #expect(actors.jsonBody.render() == """
    {"discussion":{"root":{"kind":"message","serverId":"\(fixture.serverId)","id":"\(fixture.messageId)"},"relation":{"kind":"reactionActors","emoji":"👀"},"parentScope":{"serverId":"\(fixture.serverId)","scopeKind":"channel","scopeId":"\(fixture.channelId)"}},"discussionVersion":1,"actors":[{"actorRef":{"kind":"user","id":"\(fixture.ownerId)"}}],"nextCursor":null}
    """)
}

@Test func reactionRefusalsCarryTheirExactPublishedBodies() throws {
    let fixture = makeServiceFixture(suffix: "903")
    let service = fixture.accounts.profileAndChannelFiles

    func refusal(_ body: () throws -> Void) -> ProfileAndChannelFilesError? {
        do {
            try body()
            return nil
        } catch let error as ProfileAndChannelFilesError {
            return error
        } catch {
            return nil
        }
    }

    let missingEmoji = refusal {
        _ = try service.addMessageReaction(
            messageId: fixture.messageId,
            emoji: "not emoji",
            authorization: "Bearer \(fixture.token)",
            serverId: fixture.serverId
        )
    }
    #expect(missingEmoji?.status == 400)
    #expect(missingEmoji?.publishedErrorBody.render() == #"{"error":"A valid emoji is required"}"#)

    let unauthenticated = refusal {
        _ = try service.addMessageReaction(
            messageId: fixture.messageId,
            emoji: "👍",
            authorization: nil,
            serverId: fixture.serverId
        )
    }
    #expect(unauthenticated?.status == 401)
    #expect(unauthenticated?.responseHeaders == ["Cache-Control": "no-store"])
    #expect(unauthenticated?.publishedErrorBody.render() == """
    {"error":"Missing or invalid Authorization header","code":"auth_required"}
    """)

    let notFound = refusal {
        _ = try service.addMessageReaction(
            messageId: "99999999-9999-4999-8999-999999999999",
            emoji: "👍",
            authorization: "Bearer \(fixture.token)",
            serverId: fixture.serverId
        )
    }
    #expect(notFound?.status == 404)
    #expect(notFound?.publishedErrorBody.render() == #"{"error":"Message not found"}"#)

    fixture.accounts.archiveChannel(channelId: fixture.channelId)
    let archived = refusal {
        _ = try service.addMessageReaction(
            messageId: fixture.messageId,
            emoji: "👍",
            authorization: "Bearer \(fixture.token)",
            serverId: fixture.serverId
        )
    }
    #expect(archived?.status == 409)
    #expect(archived?.publishedErrorBody.render() == """
    {"error":"This channel is archived","code":"channel_archived"}
    """)
}

@Test func thirdPartyDeliveryPublishesTheLegacyShapeAndRefusals() throws {
    let fixture = makeServiceFixture(suffix: "904")
    let agent = fixture.accounts.oauth.createAgent(
        serverId: fixture.serverId,
        name: "reaction-delivery-agent-904",
        runtime: "codex"
    )
    let key = fixture.accounts.mintAgentCredential(
        agentId: agent,
        scopes: ["read"],
        name: "delivery-904"
    )
    let delivered = try fixture.accounts.profileAndChannelFiles.reportThirdPartyEventsDelivered(
        authorization: "Bearer \(key)",
        eventIds: [.string("00000000-0000-4000-8000-000000000904")]
    )
    #expect(delivered.jsonBody.render() == #"{"ok":true,"delivered":0}"#)

    #expect(throws: ProfileAndChannelFilesError.eventIdsNotEmpty) {
        _ = try fixture.accounts.profileAndChannelFiles.reportThirdPartyEventsDelivered(
            authorization: "Bearer \(key)",
            eventIds: []
        )
    }
    #expect(throws: ProfileAndChannelFilesError.eventIdsInvalid) {
        _ = try fixture.accounts.profileAndChannelFiles.reportThirdPartyEventsDelivered(
            authorization: "Bearer \(key)",
            eventIds: [.string("not-an-event-id")]
        )
    }
}

/// The human add is one messages-store critical section: 40 concurrent adds of
/// the same `(message,user,emoji)` leave one row and one version bump.
@Test func concurrentReactionWritesStayOneCriticalSection() async {
    let fixture = makeServiceFixture(suffix: "905")
    let store = fixture.accounts.messagesAndThreadsStore
    let storeBox = StoreBox(store)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<40 {
            group.addTask {
                _ = storeBox.store.applyUserReaction(
                    messageId: fixture.messageId,
                    userId: fixture.ownerId,
                    emoji: "🔥",
                    remove: false
                )
            }
        }
    }
    #expect(store.messageReactions.count == 1)
    #expect(store.reactionViewerVersions["\(fixture.messageId)\n\(fixture.ownerId)"] == 1)
    #expect(store.reactionDiscussionVersions["\(fixture.messageId)\n🔥"] == 1)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<40 {
            group.addTask {
                _ = storeBox.store.applyUserReaction(
                    messageId: fixture.messageId,
                    userId: fixture.ownerId,
                    emoji: "🔥",
                    remove: true
                )
            }
        }
    }
    #expect(store.messageReactions.isEmpty)
    #expect(store.reactionViewerVersions["\(fixture.messageId)\n\(fixture.ownerId)"] == 2)
    #expect(store.reactionDiscussionVersions["\(fixture.messageId)\n🔥"] == 2)
}

/// A `Sendable` box so the task group can capture the store without a warning.
private struct StoreBox: @unchecked Sendable {
    let store: MessagesAndThreadsStore

    init(_ store: MessagesAndThreadsStore) {
        self.store = store
    }
}
