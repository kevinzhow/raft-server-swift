import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct SendMentionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let channelId: String
    let channelName: String
    let agentKey: String
    let outsiderName: String
    let outsiderAvatar: String
    let hiddenHumanName: String
}

private func makeSendMentionFixture(_ suffix: String) -> SendMentionFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001150\(suffix)"
    let hiddenId = "11111111-1111-4111-8111-000001151\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001150\(suffix)"
    accounts.addAccount(id: ownerId, email: "send-mention-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: hiddenId, email: "send-hidden-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: hiddenId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "send-mention-\(suffix)", name: "Send Mention \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: hiddenId, role: "member")
    let channelName = "send-mention-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: channelName)
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "MentionBot\(suffix)", creatorUserId: ownerId, runtime: "claude")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    let outsiderName = "MentionOutsider\(suffix)"
    let outsiderAvatar = "pixel:random:\(outsiderName)"
    _ = accounts.oauth.createAgent(
        serverId: serverId,
        name: outsiderName,
        avatarUrl: outsiderAvatar,
        creatorUserId: ownerId,
        runtime: "claude"
    )
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)
    return SendMentionFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        channelId: channelId,
        channelName: channelName,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read", "send"], name: "mention-\(suffix)"),
        outsiderName: outsiderName,
        outsiderAvatar: outsiderAvatar,
        hiddenHumanName: "send-hidden-\(suffix)"
    )
}

private func mentionAgentHeaders(_ key: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    headers[.contentType] = "application/json"
    return headers
}

private func mentionJSON(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func mentionSend(
    _ client: any Client,
    key: String,
    path: String,
    body: String
) async throws -> ClientResponse {
    try await client.send(.post, headers: mentionAgentHeaders(key), to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func agentApiSendReturnsPendingMentionActionsForANonMemberAgent() async throws {
    let f = makeSendMentionFixture("001")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let sent = try await mentionSend(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/send",
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"please coordinate with @\(f.outsiderName)\"}"
            )
            #expect(sent.status == .ok)
            let body = try mentionJSON(sent)
            #expect(body["state"] as? String == "sent")
            let messageId = try #require(body["messageId"] as? String)
            let pending = try #require(body["pendingMentionActions"] as? [[String: Any]])
            #expect(pending.count == 1)
            let action = try #require(pending.first)
            #expect(action["messageId"] as? String == messageId)
            #expect(action["targetType"] as? String == "agent")
            #expect(action["targetHandle"] as? String == f.outsiderName)
            #expect(action["targetAvatarUrl"] as? String == f.outsiderAvatar)
            #expect(action["reason"] as? String == "not_member")
            #expect(action["availableActions"] as? [String] == ["notify"])
            #expect(action["resolutionId"] as? String != nil)
            #expect(action["expiresAt"] as? String != nil)
        }
    }
}

@Test func agentApiV2SendReportsUnresolvedMentionHandlesAndSkipsCode() async throws {
    let f = makeSendMentionFixture("002")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let missing = try await mentionSend(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"please coordinate with @DefinitelyMissingAgent\"}"
            )
            #expect(missing.status == .ok)
            let missingBody = try mentionJSON(missing)
            #expect(missingBody["state"] as? String == "sent")
            #expect(missingBody["pendingMentionActions"] == nil)
            #expect(missingBody["unresolvedMentionHandles"] as? [String] == ["@DefinitelyMissingAgent"])

            let code = try await mentionSend(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"external `@DefinitelyMissingAgent` and\\n```txt\\n@AnotherMissingAgent\\n```\"}"
            )
            #expect(code.status == .ok)
            let codeBody = try mentionJSON(code)
            #expect(codeBody["unresolvedMentionHandles"] == nil)
        }
    }
}

@Test func agentApiV2SendCloaksAHiddenHumanBehindAnUnresolvedHandle() async throws {
    let f = makeSendMentionFixture("003")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let raw = try await mentionSend(
                client,
                key: f.agentKey,
                path: "/internal/agent-api/v2/send",
                body: "{\"target\":\"#\(f.channelName)\",\"content\":\"hidden human raw @\(f.hiddenHumanName)\"}"
            )
            #expect(raw.status == .ok)
            let rawBody = try mentionJSON(raw)
            #expect(rawBody["pendingMentionActions"] == nil)
            #expect(rawBody["unresolvedMentionHandles"] as? [String] == ["@\(f.hiddenHumanName)"])
        }
    }
}
