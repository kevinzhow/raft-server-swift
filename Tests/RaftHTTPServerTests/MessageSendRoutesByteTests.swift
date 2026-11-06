import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// Byte-exact replies for the three message-send routes. The service tests lock
/// the rendered trees; these lock the projection `respond{}` publishes —
/// status, the standard JSON header set and the exact body text.

@Test func messageSendRoutesPublishTheExactLegacyBytesAndHeaders() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001109001"
    let serverId = "33333333-3333-4333-8333-000001109001"
    let ownerEmail = "message-send-bytes@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "message-send-bytes", name: "Message Send Bytes", ownerId: ownerId)
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "bytes-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "bytes-room")
    let parentId = accounts.addChannelMessageForTesting(channelId: channel, content: "parent", senderId: ownerId)
    let threadId = accounts.oauth.createThreadChannel(parentChannelId: channel, parentMessageId: parentId)
    accounts.addPostableChannel(
        serverId: serverId,
        channelId: threadId,
        memberId: ownerId,
        kind: "thread",
        parentChannelId: channel,
        parentMessageId: parentId,
        name: "thread"
    )
    accounts.oauth.addChannelHuman(channelId: threadId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "Bytes Agent")
    accounts.oauth.addChannelAgent(channelId: threadId, agentId: agentId)

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
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            // 1. The attachment URL refuses an unauthenticated caller first.
            var unauthenticated = headers
            unauthenticated[.authorization] = nil
            let unauthorized = try await client.send(
                .get,
                headers: unauthenticated,
                to: "/api/attachments/44444444-4444-4444-8444-000001109001/url"
            )
            #expect(unauthorized.status == .unauthorized)
            #expect(unauthorized.body.string == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
            #expect(unauthorized.headers[HTTPField.Name("X-Robots-Tag")!] == AppFallback.robotsTag)
            #expect(unauthorized.headers[.contentType] == AppFallback.jsonContentType)
            #expect(unauthorized.headers[.contentLength] == String("{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}".utf8.count))

            // 2. A malformed attachment id publishes `code` before `error`.
            let invalidID = try await client.send(
                .get,
                headers: headers,
                to: "/api/attachments/not-a-uuid/url"
            )
            #expect(invalidID.status == .badRequest)
            #expect(invalidID.body.string == "{\"code\":\"invalid_attachment_id\",\"error\":\"Invalid attachment id\"}")

            // 3. The restore route publishes the exact confirmation bytes.
            let removal = try await client.send(
                .delete,
                headers: headers,
                to: "/api/channels/threads/\(threadId)/followers/agents/\(agentId)"
            )
            #expect(removal.status == .ok)
            let removalBody = try #require(removal.body.string)
            #expect(removalBody.hasPrefix("{\"removed\":true,\"undoToken\":\""))
            #expect(removalBody.hasSuffix("\"}"))
            let undoToken = String(removalBody.dropFirst("{\"removed\":true,\"undoToken\":\"".count).dropLast(2))
            #expect(undoToken.count == 36)

            let restore = try await client.send(
                .post,
                headers: headers,
                to: "/api/channels/threads/\(threadId)/followers/agents/\(agentId)/restore"
            ) { request in
                request.body = .init(string: "{\"undoToken\":\"\(undoToken)\"}")
            }
            #expect(restore.status == .ok)
            #expect(restore.body.string == "{\"ok\":true,\"restored\":true}")
            #expect(restore.headers[HTTPField.Name("X-Robots-Tag")!] == AppFallback.robotsTag)

            let stale = try await client.send(
                .post,
                headers: headers,
                to: "/api/channels/threads/\(threadId)/followers/agents/\(agentId)/restore"
            ) { request in
                request.body = .init(string: "{\"undoToken\":\"\(undoToken)\"}")
            }
            #expect(stale.status == .ok)
            #expect(stale.body.string == "{\"ok\":true,\"restored\":false}")

            // 4. An unauthenticated follower write publishes the bare 401.
            var anonymous = headers
            anonymous[.authorization] = nil
            let anonymousRemoval = try await client.send(
                .delete,
                headers: anonymous,
                to: "/api/channels/threads/\(threadId)/followers/agents/\(agentId)"
            )
            #expect(anonymousRemoval.status == .unauthorized)
            #expect(anonymousRemoval.body.string == "{\"error\":\"Unauthorized\"}")
        }
    }
}
