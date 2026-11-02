import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentAttachmentCommentsAreReadOnlyAndResolveForTheParentAuthor() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001034001"
    let ownerId = "11111111-1111-4111-8111-000001034001"
    let ownerEmail = "comment-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "comments", name: "Comments", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "comments-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "comments-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "CommentBot", runtime: "codex")
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let readKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "read")
    let sendKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send"], name: "send")
    let ownerMessage = accounts.addChannelMessageForTesting(channelId: channel, content: "owner attachment message", senderId: ownerId)
    let agentMessage = accounts.addChannelMessageForTesting(channelId: channel, content: "agent attachment message", senderId: agent, senderType: "agent")
    let linked = accounts.addChannelAttachment(channelId: channel, uploaderId: ownerId, filename: "linked.txt", mimeType: "text/plain", sizeBytes: 10, messageId: ownerMessage)
    let agentAttachment = accounts.addChannelAttachment(channelId: channel, uploaderId: agent, filename: "agent.txt", mimeType: "text/plain", sizeBytes: 10, messageId: agentMessage)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"\(ownerEmail)\",\"password\":\"password123\"}")
            }
            let ownerToken = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var ownerHeaders = HTTPFields()
            ownerHeaders[.authorization] = "Bearer \(ownerToken)"
            ownerHeaders[.contentType] = "application/json"
            var readHeaders = HTTPFields()
            readHeaders[.authorization] = "Bearer \(readKey)"
            var sendHeaders = HTTPFields()
            sendHeaders[.authorization] = "Bearer \(sendKey)"

            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let denied = try await client.send(.post, headers: readHeaders, to: URI(string: "/internal/agent-api/attachments/\(linked)/comments")) { request in
                request.body = .init(string: "{\"content\":\"agent should not write\"}")
            }
            #expect(denied.status == .forbidden)
            #expect(body(denied)["code"] as? String == "agent_comment_create_disabled")

            let human = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/attachments/\(linked)/comments")) { request in
                request.body = .init(string: "{\"content\":\"排序还有问题\",\"anchor\":{\"type\":\"lines\",\"startLine\":3,\"endLine\":3}}")
            }
            #expect(human.status == .ok)
            let commentId = try #require((body(human)["message"] as? [String: Any])?["id"] as? String)

            let list = try await client.get(URI(string: "/internal/agent-api/attachments/\(linked)/comments"), headers: readHeaders)
            #expect(list.status == .ok)
            let listBody = body(list)
            let comments = try #require(listBody["comments"] as? [[String: Any]])
            #expect(comments.count == 1)
            #expect(comments[0]["id"] as? String == commentId)
            #expect(comments[0]["senderType"] as? String == "user")
            #expect((comments[0]["anchor"] as? [String: Any])?["type"] as? String == "lines")
            #expect(comments[0]["resolved"] as? Bool == false)
            #expect(comments[0]["resolvedBy"] is NSNull)
            let viewer = try #require(listBody["viewer"] as? [String: Any])
            #expect(viewer["canComment"] as? Bool == false)
            #expect(viewer["reason"] as? String == "agent_descoped")
            #expect(viewer["canResolve"] as? Bool == false)
            #expect(viewer["resolveAction"] == nil)

            let noRead = try await client.get(URI(string: "/internal/agent-api/attachments/\(linked)/comments"), headers: sendHeaders)
            #expect(noRead.status == .forbidden)
            #expect(body(noRead)["code"] as? String == "capability_not_authorized")
            let malformed = try await client.get(URI(string: "/internal/agent-api/attachments/e66f3b51/comments"), headers: readHeaders)
            #expect(malformed.status == .notFound)
            #expect(body(malformed)["error"] as? String == "Attachment not found")
            let malformedCreate = try await client.send(.post, headers: readHeaders, to: URI(string: "/internal/agent-api/attachments/e66f3b51/comments")) { request in
                request.body = .init(string: "{\"content\":\"should not hit attachment lookup\"}")
            }
            #expect(malformedCreate.status == .notFound)
            #expect(body(malformedCreate)["error"] as? String == "Attachment not found")

            accounts.addMessageReactionForTesting(messageId: commentId, emoji: "✅", reactorId: ownerId, reactorType: "user")
            let resolved = try await client.get(URI(string: "/internal/agent-api/attachments/\(linked)/comments"), headers: readHeaders)
            let resolvedComments = body(resolved)["comments"] as? [[String: Any]] ?? []
            #expect(resolvedComments[0]["resolved"] as? Bool == true)
            #expect((resolvedComments[0]["resolvedBy"] as? [String: Any])?["reactorId"] as? String == ownerId)

            let agentComment = try await client.send(.post, headers: ownerHeaders, to: URI(string: "/api/attachments/\(agentAttachment)/comments")) { request in
                request.body = .init(string: "{\"content\":\"请检查一下\"}")
            }
            #expect(agentComment.status == .ok)
            let agentList = try await client.get(URI(string: "/internal/agent-api/attachments/\(agentAttachment)/comments"), headers: readHeaders)
            let agentViewer = try #require(body(agentList)["viewer"] as? [String: Any])
            #expect(agentViewer["canResolve"] as? Bool == true)
            #expect(agentViewer["resolveAction"] as? [String: Any] != nil)
            #expect((agentViewer["resolveAction"] as? [String: Any])?["emoji"] as? String == "✅")
        }
    }
}
