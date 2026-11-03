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
    return AttachmentCommentsFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        privateChannelId: privateChannelId,
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
