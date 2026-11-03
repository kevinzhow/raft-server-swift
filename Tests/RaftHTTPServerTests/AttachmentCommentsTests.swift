import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AttachmentCommentsFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let privateChannelId: String
    let ownerId: String
    let parentMessageId: String
    let reviewerId: String
    let reviewerToken: String
    let linked: String
    let sibling: String
    let unlinked: String
    let privateAttachment: String
}

private func makeAttachmentCommentsFixture() -> AttachmentCommentsFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111644"
    let reviewerId = "11111111-1111-4111-8111-111111111645"
    let serverId = "33333333-3333-4333-8333-333333333684"
    for (id, email) in [(ownerId, "ac-owner@slock.test"), (reviewerId, "ac-reviewer@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "attachment-comments", name: "Attachment Comments", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: reviewerId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "ac-public", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "ac-public")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: reviewerId, name: "ac-public")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: reviewerId)
    let hostMessage = accounts.addChannelMessageForTesting(channelId: channelId, content: "host", senderId: ownerId)
    let linked = accounts.addChannelAttachment(channelId: channelId, uploaderId: ownerId, filename: "linked.pdf", mimeType: "application/pdf", sizeBytes: 10, messageId: hostMessage)
    let sibling = accounts.addChannelAttachment(channelId: channelId, uploaderId: ownerId, filename: "sibling.pdf", mimeType: "application/pdf", sizeBytes: 10, messageId: hostMessage)
    let unlinked = accounts.addChannelAttachment(channelId: channelId, uploaderId: ownerId, filename: "unlinked.pdf", mimeType: "application/pdf", sizeBytes: 10)
    let privateChannelId = accounts.oauth.createChannel(serverId: serverId, name: "ac-private", creatorUserId: ownerId, type: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: "ac-private")
    accounts.oauth.addChannelHuman(channelId: privateChannelId, userId: ownerId)
    let privateHost = accounts.addChannelMessageForTesting(channelId: privateChannelId, content: "private host", senderId: ownerId)
    let privateAttachment = accounts.addChannelAttachment(channelId: privateChannelId, uploaderId: ownerId, filename: "secret.pdf", mimeType: "application/pdf", sizeBytes: 10, messageId: privateHost)
    accounts.setMessageAttachmentIdsForTesting(messageId: hostMessage, attachmentIds: [linked, sibling])
    return AttachmentCommentsFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        privateChannelId: privateChannelId,
        ownerId: ownerId,
        parentMessageId: hostMessage,
        reviewerId: reviewerId,
        reviewerToken: accounts.mintAccessTokenForTesting(userId: reviewerId),
        linked: linked,
        sibling: sibling,
        unlinked: unlinked,
        privateAttachment: privateAttachment
    )
}

private func commentsRequest(
    _ client: any Client,
    _ f: AttachmentCommentsFixture,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil,
    serverId: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.reviewerToken)"
    if body != nil { headers[.contentType] = "application/json" }
    headers[HTTPField.Name("X-Server-Id")!] = serverId ?? f.serverId
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func attachmentCommentsGateAnswersBeforeBodyValidation() async throws {
    let f = makeAttachmentCommentsFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // Enabled by default: an invalid body is a normal 400.
            let invalid = try await commentsRequest(client, f, method: .post, path: "/api/attachments/\(f.linked)/comments", body: "{}")
            #expect(invalid.status == .badRequest)

            f.accounts.setFeatureFlagKillSwitchForTesting(key: "attachment_comments_v0", killSwitch: true)
            for (path, method, body) in [
                ("/api/attachments/\(f.linked)/comments", HTTPRequest.Method.post, "{}"),
                ("/api/attachments/not-a-uuid/comments", HTTPRequest.Method.post, "{}"),
                ("/api/attachments/\(f.linked)/comments", HTTPRequest.Method.get, nil),
                ("/api/attachments/comments/counts?ids=", HTTPRequest.Method.get, nil),
            ] {
                let gated = try await commentsRequest(client, f, method: method, path: path, body: body)
                #expect(gated.status == .forbidden, "\(method) \(path) must be gated")
                #expect(gated.body["code"] as? String == "attachment_comments_disabled")
            }

            // Under the kill switch a malformed id stays the same uniform 403.
            f.accounts.setFeatureFlagKillSwitchForTesting(key: "attachment_comments_v0", killSwitch: false)
            let malformed = try await commentsRequest(client, f, method: .post, path: "/api/attachments/not-a-uuid/comments", body: "{}")
            #expect(malformed.status == .badRequest)
            #expect(malformed.body["code"] as? String == "invalid_attachment_id")
        }
    }
}

@Test func attachmentCommentsClosedLoopCountsAndViewer() async throws {
    let f = makeAttachmentCommentsFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"please check page 2\"}"
            )
            #expect(created.status == .ok)
            let list = try await commentsRequest(client, f, method: .get, path: "/api/attachments/\(f.linked)/comments")
            #expect(list.status == .ok)
            let comments = (list.body["comments"] as? [[String: Any]]) ?? []
            #expect(comments.count == 1)
            #expect(comments.first?["content"] as? String == "please check page 2")
            #expect((list.body["viewer"] as? [String: Any])?["canComment"] as? Bool == true)

            let counts = try await commentsRequest(
                client, f, method: .get,
                path: "/api/attachments/comments/counts?ids=\(f.linked),\(f.sibling),\(f.unlinked)"
            )
            #expect(counts.status == .ok)
            let values = (counts.body["counts"] as? [String: Any]) ?? [:]
            #expect((values[f.linked] as? NSNumber)?.intValue == 1)
            #expect((values[f.sibling] as? NSNumber)?.intValue == 0)
            #expect((values[f.unlinked] as? NSNumber)?.intValue == 0)
            let emptyIds = try await commentsRequest(client, f, method: .get, path: "/api/attachments/comments/counts?ids=")
            #expect(emptyIds.status == .badRequest)
        }
    }
}

@Test func attachmentCommentsBoundariesAndCloaks() async throws {
    let f = makeAttachmentCommentsFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unlinked = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.unlinked)/comments", body: "{\"content\":\"hi\"}"
            )
            #expect(unlinked.status == .unprocessableContent)
            #expect(unlinked.body["code"] as? String == "attachment_not_linked")

            // Another server's attachment id is indistinguishable from missing.
            let crossServer = try await commentsRequest(
                client, f, method: .get, path: "/api/attachments/\(f.linked)/comments", serverId: "33333333-3333-4333-8333-333333333685"
            )
            #expect(crossServer.status == .notFound)

            // Private-channel attachments are cloaked for non-members.
            let cloaked = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.privateAttachment)/comments", body: "{\"content\":\"peek\"}"
            )
            #expect(cloaked.status == .notFound)
            #expect(!((cloaked.body["error"] as? String) ?? "").contains("secret"))

            f.accounts.oauth.setChannelArchived(id: f.channelId, archivedAt: Date())
            let archivedList = try await commentsRequest(client, f, method: .get, path: "/api/attachments/\(f.linked)/comments")
            #expect((archivedList.body["viewer"] as? [String: Any])?["reason"] as? String == "archived")
            let archivedCreate = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments", body: "{\"content\":\"late\"}"
            )
            #expect(archivedCreate.status == .conflict)
            #expect(archivedCreate.body["code"] as? String == "channel_archived")
        }
    }
}

@Test func attachmentCommentsLiveInTheHostMessageThreadAndCascadeWithIt() async throws {
    let f = makeAttachmentCommentsFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments", body: "{\"content\":\"first\"}"
            )
            #expect(first.status == .ok)
            let message = try #require(first.body["message"] as? [String: Any])
            let threadChannelId = try #require(first.body["threadChannelId"] as? String)
            #expect(threadChannelId != f.channelId, "a comment lives in the host message thread, not the parent channel")
            #expect(message["channelId"] as? String == threadChannelId)

            // A sibling attachment under the same host message shares the thread.
            let sibling = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.sibling)/comments", body: "{\"content\":\"sibling\"}"
            )
            #expect(sibling.body["threadChannelId"] as? String == threadChannelId)

            // The scoped list only carries this attachment's comment.
            let list = try await commentsRequest(client, f, method: .get, path: "/api/attachments/\(f.linked)/comments")
            let comments = (list.body["comments"] as? [[String: Any]]) ?? []
            #expect(comments.count == 1)
            #expect(comments.first?["content"] as? String == "first")
            let counts = try await commentsRequest(
                client, f, method: .get, path: "/api/attachments/comments/counts?ids=\(f.linked),\(f.sibling)"
            )
            let values = (counts.body["counts"] as? [String: Any]) ?? [:]
            #expect((values[f.linked] as? NSNumber)?.intValue == 1)
            #expect((values[f.sibling] as? NSNumber)?.intValue == 1)

            // Hard-deleting the comment message cascades its ref row.
            let commentId = try #require(message["id"] as? String)
            f.accounts.removeMessageForTesting(messageId: commentId)
            let after = try await commentsRequest(client, f, method: .get, path: "/api/attachments/\(f.linked)/comments")
            #expect(((after.body["comments"] as? [[String: Any]]) ?? []).isEmpty, "the ref row cascades with the message")
        }
    }
}

@Test func attachmentCommentAnchorsAreCanonicalAndMentionsRideTheSharedPipeline() async throws {
    let f = makeAttachmentCommentsFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // A known anchor round-trips and anchorless rows report null.
            let anchored = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"anchored\",\"anchor\":{\"type\":\"md-section\",\"data\":{\"headingId\":\"activation\",\"headingTitle\":\"Activation\",\"quote\":\"D0>=35\"}}}"
            )
            #expect(anchored.status == .ok)
            let anchoredId = try #require(((anchored.body["message"] as? [String: Any])?["id"]) as? String)
            let plain = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments", body: "{\"content\":\"plain\"}"
            )
            #expect(plain.status == .ok)
            let plainId = try #require(((plain.body["message"] as? [String: Any])?["id"]) as? String)
            let listed = try await commentsRequest(client, f, method: .get, path: "/api/attachments/\(f.linked)/comments")
            let rows = (listed.body["comments"] as? [[String: Any]]) ?? []
            let anchoredRow = rows.first { ($0["id"] as? String) == anchoredId }
            let anchor = anchoredRow?["anchor"] as? [String: Any]
            #expect(anchor?["type"] as? String == "md-section")
            #expect((anchor?["data"] as? [String: Any])?["headingId"] as? String == "activation")
            #expect(rows.first { ($0["id"] as? String) == plainId }?["anchor"] is NSNull)

            // Closed vocabulary and shape errors.
            let badType = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"x\",\"anchor\":{\"type\":\"dom-xpath\",\"data\":{}}}"
            )
            #expect(badType.body["code"] as? String == "anchor_type_invalid")
            let badShape = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"x\",\"anchor\":{\"type\":\"lines\",\"data\":[1,2]}}"
            )
            #expect(badShape.body["code"] as? String == "anchor_invalid")
            let tooLarge = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"x\",\"anchor\":{\"type\":\"lines\",\"data\":{\"quote\":\"\(String(repeating: "q", count: 5000))\"}}}"
            )
            #expect(tooLarge.body["code"] as? String == "anchor_too_large")
            for anchorBody in [
                "{\"type\":\"md-section\",\"data\":{}}",
                "{\"type\":\"lines\",\"data\":{\"start\":0,\"end\":2}}",
                "{\"type\":\"lines\",\"data\":{\"start\":5,\"end\":2}}",
                "{\"type\":\"csv-rows\",\"data\":{\"start\":1.5,\"end\":2}}",
                "{\"type\":\"html-region\",\"data\":{\"x\":-1,\"y\":0,\"w\":10,\"h\":10,\"viewportWidth\":800,\"documentWidth\":1000,\"documentHeight\":2000}}",
            ] {
                let invalid = try await commentsRequest(
                    client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                    body: "{\"content\":\"x\",\"anchor\":\(anchorBody)}"
                )
                #expect(invalid.body["code"] as? String == "anchor_invalid", "\(anchorBody)")
            }

            // Extras never reach storage; html-region numbers round.
            let padded = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"padded\",\"anchor\":{\"type\":\"lines\",\"data\":{\"start\":2,\"end\":4,\"quote\":\"q\",\"extra\":\"DROP ME\"}}}"
            )
            let paddedId = try #require(((padded.body["message"] as? [String: Any])?["id"]) as? String)
            let region = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"region\",\"anchor\":{\"type\":\"html-region\",\"data\":{\"x\":10.6,\"y\":20.2,\"w\":0,\"h\":0,\"viewportWidth\":1280,\"documentWidth\":1280,\"documentHeight\":4000.9,\"spoofed\":true}}}"
            )
            #expect(region.status == .ok, "\(region.body)")
            let regionId = try #require(((region.body["message"] as? [String: Any])?["id"]) as? String)
            let finalList = try await commentsRequest(client, f, method: .get, path: "/api/attachments/\(f.linked)/comments")
            let finalRows = (finalList.body["comments"] as? [[String: Any]]) ?? []
            #expect(finalRows.count == 4, "rejected anchors wrote nothing")
            let paddedData = ((finalRows.first { ($0["id"] as? String) == paddedId }?["anchor"] as? [String: Any])?["data"]) as? [String: Any]
            #expect(paddedData?["start"] as? Int == 2)
            #expect(paddedData?["end"] as? Int == 4)
            #expect(paddedData?["quote"] as? String == "q")
            #expect(paddedData?["extra"] == nil)
            let regionData = ((finalRows.first { ($0["id"] as? String) == regionId }?["anchor"] as? [String: Any])?["data"]) as? [String: Any]
            #expect(regionData?["x"] as? Int == 11)
            #expect(regionData?["y"] as? Int == 20)
            #expect(regionData?["documentHeight"] as? Int == 4001)

            // Structured mentions persist through the shared pipeline.
            let mentioned = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"@\(f.ownerId) look\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(f.ownerId)\",\"name\":\"owner\"}]}"
            )
            #expect(mentioned.status == .ok)
            let mentionedId = try #require(((mentioned.body["message"] as? [String: Any])?["id"]) as? String)
            #expect(!f.accounts.messageMentionRows(messageId: mentionedId).isEmpty, "the mention row rides the message pipeline")
            let badMention = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments",
                body: "{\"content\":\"x\",\"mentions\":[{\"type\":\"user\",\"id\":\"not-a-uuid\",\"name\":\"x\"}]}"
            )
            #expect(badMention.status == .badRequest)
            #expect(badMention.body["code"] as? String == "mentions_invalid")
        }
    }
}

@Test func attachmentCommentRefRidesTheCreateAndListingOnlyForEnabledViewers() async throws {
    let f = makeAttachmentCommentsFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments", body: "{\"content\":\"chip probe\"}"
            )
            let message = try #require(created.body["message"] as? [String: Any])
            let threadChannelId = try #require(created.body["threadChannelId"] as? String)
            let commentId = try #require(message["id"] as? String)
            let commentRef = try #require(message["commentRef"] as? [String: Any])
            #expect(commentRef["attachmentId"] as? String == f.linked)
            #expect((commentRef["hostSource"] as? [String: Any])?["rootThreadChannelId"] as? String == threadChannelId)

            // The thread listing carries the same chip coordinates.
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.reviewerToken)"
            headers[HTTPField.Name("X-Server-Id")!] = f.serverId
            let listing = try await client.get(URI(string: "/api/messages/channel/\(threadChannelId)?limit=50"), headers: headers)
            let body = (try JSONSerialization.jsonObject(with: Data((listing.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let rows = (body["messages"] as? [[String: Any]]) ?? []
            let row = rows.first { ($0["id"] as? String) == commentId }
            #expect(row != nil, "thread listing has the comment message; rows=\(rows.map { $0["id"] as? String ?? "?" })")
            #expect(row?["commentRef"] != nil)

            // A user-stage deny hides the scoped chip and gates the comment routes.
            f.accounts.addFeatureFlagRuleForTesting(key: "attachment_comments_v0", stage: "user", decision: "deny", values: [f.reviewerId])
            let deniedList = try await commentsRequest(client, f, method: .get, path: "/api/attachments/\(f.linked)/comments")
            #expect(deniedList.status == .forbidden)
            let deniedCounts = try await commentsRequest(client, f, method: .get, path: "/api/attachments/comments/counts?ids=\(f.linked)")
            #expect(deniedCounts.status == .forbidden)
            let deniedListing = try await client.get(URI(string: "/api/messages/channel/\(threadChannelId)?limit=50"), headers: headers)
            let deniedBody = (try JSONSerialization.jsonObject(with: Data((deniedListing.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let deniedRow = ((deniedBody["messages"] as? [[String: Any]]) ?? []).first { ($0["id"] as? String) == commentId }
            #expect(deniedRow?["commentRef"] is NSNull || deniedRow?["commentRef"] == nil, "a denied viewer must not observe the scoped chip")
        }
    }
}

@Test func attachmentCommentCountsAndRefsProjectThroughSyncAndContext() async throws {
    let f = makeAttachmentCommentsFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let created = try await commentsRequest(
                client, f, method: .post, path: "/api/attachments/\(f.linked)/comments", body: "{\"content\":\"projected\"}"
            )
            let threadChannelId = try #require(created.body["threadChannelId"] as? String)
            let commentId = try #require((created.body["message"] as? [String: Any])?["id"] as? String)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.reviewerToken)"
            headers[HTTPField.Name("X-Server-Id")!] = f.serverId
            func jsonObject(_ path: String) async throws -> Any? {
                let response = try await client.get(URI(string: path), headers: headers)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))
            }
            func commentRef(_ rows: [[String: Any]], _ id: String) -> Any? {
                rows.first { ($0["id"] as? String) == id }?["commentRef"]
            }
            func commentCount(_ rows: [[String: Any]], _ messageId: String, _ attachmentId: String) -> Int? {
                let attachments = (rows.first { ($0["id"] as? String) == messageId }?["attachments"] as? [[String: Any]]) ?? []
                return ((attachments.first { ($0["id"] as? String) == attachmentId }?["commentCount"]) as? NSNumber)?.intValue
            }

            // Enabled viewer: commentRef and commentCount project everywhere.
            let threadSync = ((try await jsonObject("/api/messages/sync?channel_id=\(threadChannelId)&since_seq=0&limit=50") as? [[String: Any]]) ?? [])
            #expect(commentRef(threadSync, commentId) != nil)
            let parentSync = ((try await jsonObject("/api/messages/sync?channel_id=\(f.channelId)&since_seq=0&limit=50") as? [[String: Any]]) ?? [])
            #expect(commentCount(parentSync, f.parentMessageId, f.linked) == 1)

            let commentContext = ((try await jsonObject("/api/messages/context/\(commentId)?channelId=\(threadChannelId)") as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            #expect(commentRef(commentContext, commentId) != nil)
            let parentContext = ((try await jsonObject("/api/messages/context/\(f.parentMessageId)?channelId=\(f.channelId)") as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            #expect(commentCount(parentContext, f.parentMessageId, f.linked) == 1)

            // A user-denied viewer observes zero count and no scoped ref.
            f.accounts.addFeatureFlagRuleForTesting(key: "attachment_comments_v0", stage: "user", decision: "deny", values: [f.reviewerId])
            let deniedThreadSync = ((try await jsonObject("/api/messages/sync?channel_id=\(threadChannelId)&since_seq=0&limit=50") as? [[String: Any]]) ?? [])
            #expect(commentRef(deniedThreadSync, commentId) is NSNull || commentRef(deniedThreadSync, commentId) == nil)
            let deniedParentSync = ((try await jsonObject("/api/messages/sync?channel_id=\(f.channelId)&since_seq=0&limit=50") as? [[String: Any]]) ?? [])
            #expect(commentCount(deniedParentSync, f.parentMessageId, f.linked) == 0)
            let deniedCommentContext = ((try await jsonObject("/api/messages/context/\(commentId)?channelId=\(threadChannelId)") as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            #expect(commentRef(deniedCommentContext, commentId) is NSNull || commentRef(deniedCommentContext, commentId) == nil)
            let deniedParentContext = ((try await jsonObject("/api/messages/context/\(f.parentMessageId)?channelId=\(f.channelId)") as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            #expect(commentCount(deniedParentContext, f.parentMessageId, f.linked) == 0)
        }
    }
}
