import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AuditSeed {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerEmail: String
    let guestEmail: String
    let guestId: String
    let channelId: String
}

private struct AuditInboxFixture {
    let seed: AuditSeed
    let parentId: String
    let threadId: String
    let guestToken: String
    var accounts: EmailLoginDirectory { seed.accounts }
    var serverId: String { seed.serverId }
    var guestId: String { seed.guestId }
    var channelId: String { seed.channelId }
}

private func auditLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func auditHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func makeAuditSeed(_ suffix: String) -> AuditSeed {
    let accounts = EmailLoginDirectory()
    let n = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 800_000 + n)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 500_000 + n)
    let guestId = String(format: "11111111-1111-4111-8111-%012d", 600_000 + n)
    let ownerEmail = "audit-medium-owner-\(suffix)@slock.test"
    let guestEmail = "audit-medium-guest-\(suffix)@slock.test"
    for (id, email, role) in [
        (ownerId, ownerEmail, "owner"),
        (guestId, guestEmail, "guest"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "audit-medium-\(suffix)", name: "Audit Medium \(suffix)", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "audit-medium-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "audit-medium-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.setChannelGuestVisibleForTesting(channelId: channel, visible: true)
    return AuditSeed(
        accounts: accounts,
        serverId: serverId,
        ownerEmail: ownerEmail,
        guestEmail: guestEmail,
        guestId: guestId,
        channelId: channel
    )
}

private func prepareAuditInbox(_ client: any Client, _ seed: AuditSeed) async throws -> AuditInboxFixture {
    let ownerToken = try await auditLogin(client, email: seed.ownerEmail)
    let guestToken = try await auditLogin(client, email: seed.guestEmail)
    let serverId = seed.serverId
    let channel = seed.channelId

    let parent = try await client.send(.post, headers: auditHeaders(ownerToken, serverId), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(channel)\",\"content\":\"audit-inbox-secret\"}")
    }
    let parentId = (try JSONSerialization.jsonObject(with: Data((parent.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
    let thread = try await client.send(.post, headers: auditHeaders(ownerToken, serverId), to: "/api/channels/\(channel)/threads") { request in
        request.body = .init(string: "{\"parentMessageId\":\"\(parentId)\"}")
    }
    let threadId = (try JSONSerialization.jsonObject(with: Data((thread.body.string ?? "").utf8)) as? [String: Any])?["threadChannelId"] as? String ?? ""
    _ = try await client.send(.post, headers: auditHeaders(ownerToken, serverId), to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(threadId)\",\"content\":\"audit-new-thread-secret\"}")
    }
    _ = try await client.send(.post, headers: auditHeaders(guestToken, serverId), to: "/api/channels/threads/follow") { request in
        request.body = .init(string: "{\"threadChannelId\":\"\(threadId)\"}")
    }
    return AuditInboxFixture(seed: seed, parentId: parentId, threadId: threadId, guestToken: guestToken)
}

@Test func guestDoneReadsRecheckCurrentVisibility() async throws {
    let seed = makeAuditSeed("401")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let fixture = try await prepareAuditInbox(client, seed)
            let headers = auditHeaders(fixture.guestToken, fixture.serverId)
            let done = try await client.send(.post, headers: headers, to: "/api/channels/inbox/done") { request in
                request.body = .init(string: "{\"channelId\":\"\(fixture.channelId)\"}")
            }
            #expect(done.status == .ok)
            let before = try await client.get(URI(string: "/api/channels/inbox/done"), headers: headers)
            #expect(before.status == .ok)
            #expect((before.body.string ?? "").contains(fixture.channelId))

            fixture.accounts.setChannelGuestVisibleForTesting(channelId: fixture.channelId, visible: false)
            let after = try await client.get(URI(string: "/api/channels/inbox/done"), headers: headers)
            #expect(after.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [String: Any]
            #expect((body?["items"] as? [[String: Any]] ?? []).isEmpty)
        }
    }
}

@Test func guestFollowedThreadsRecheckCurrentVisibility() async throws {
    let seed = makeAuditSeed("402")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let fixture = try await prepareAuditInbox(client, seed)
            let headers = auditHeaders(fixture.guestToken, fixture.serverId)
            let before = try await client.get(URI(string: "/api/channels/threads/followed"), headers: headers)
            #expect(before.status == .ok)
            #expect((before.body.string ?? "").contains(fixture.threadId))

            fixture.accounts.setChannelGuestVisibleForTesting(channelId: fixture.channelId, visible: false)
            let after = try await client.get(URI(string: "/api/channels/threads/followed"), headers: headers)
            #expect(after.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [String: Any]
            #expect((body?["threads"] as? [[String: Any]] ?? []).isEmpty)
        }
    }
}

@Test func guestMentionReadsRecheckCurrentVisibility() async throws {
    let seed = makeAuditSeed("403")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: seed.accounts
        ))
        try await app.testing { client in
            let fixture = try await prepareAuditInbox(client, seed)
            fixture.accounts.addStoredMentionForTesting(channelId: fixture.channelId, messageId: fixture.parentId, targetId: fixture.guestId)
            fixture.accounts.addInboxFactForTesting(
                receiverId: fixture.guestId,
                serverId: fixture.serverId,
                channelId: fixture.channelId,
                messageId: fixture.parentId
            )
            let headers = auditHeaders(fixture.guestToken, fixture.serverId)
            let before = try await client.get(URI(string: "/api/channels/inbox?filter=mentions"), headers: headers)
            #expect(before.status == .ok)
            #expect((before.body.string ?? "").contains(fixture.channelId))

            fixture.accounts.setChannelGuestVisibleForTesting(channelId: fixture.channelId, visible: false)
            let after = try await client.get(URI(string: "/api/channels/inbox?filter=mentions"), headers: headers)
            #expect(after.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((after.body.string ?? "").utf8)) as? [String: Any]
            #expect((body?["items"] as? [[String: Any]] ?? []).isEmpty)
        }
    }
}
