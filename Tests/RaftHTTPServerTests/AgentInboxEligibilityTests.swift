import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct InboxEligibilityFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let channelId: String
    let ownerId: String
    let agentId: String
    let agentKey: String
    let ownerToken: String
}

private func makeInboxEligibilityFixture(runtime: String, suffix: String) -> InboxEligibilityFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111164\(suffix)"
    let serverId = "33333333-3333-4333-8333-33333333368\(suffix)"
    accounts.addAccount(id: ownerId, email: "inbox-elig-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "inbox-elig-\(suffix)", name: "Inbox Eligibility", ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "elig-room-\(suffix)", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "channel", name: "elig-room-\(suffix)")
    accounts.oauth.addChannelHuman(channelId: channelId, userId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "EligBot\(suffix)", creatorUserId: ownerId, runtime: runtime)
    return InboxEligibilityFixture(
        accounts: accounts,
        serverId: serverId,
        channelId: channelId,
        ownerId: ownerId,
        agentId: agentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["channels", "read", "send"], name: "elig-\(suffix)"),
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId)
    )
}

private func inboxEligibilityRequest(
    _ client: any Client,
    _ f: InboxEligibilityFixture,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.agentKey)"
    if body != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private func inboxHumanPost(
    _ client: any Client,
    _ f: InboxEligibilityFixture,
    content: String
) async throws {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.ownerToken)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = f.serverId
    let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
        request.body = .init(string: "{\"channelId\":\"\(f.channelId)\",\"content\":\"\(content)\"}")
    }
    #expect(response.status == .ok)
}

private func wakeHintMessageIds(_ body: [String: Any]) -> [String] {
    ((body["wake_hints"] as? [[String: Any]]) ?? []).compactMap { $0["message_id"] as? String }
}

private func eventMessageIds(_ body: [String: Any]) -> [String] {
    ((body["events"] as? [[String: Any]]) ?? []).compactMap { $0["message_id"] as? String }
}

@Test func externalAgentOwnMembershipNoticeIsNeitherAnnouncedNorPulled() async throws {
    let f = makeInboxEligibilityFixture(runtime: "external", suffix: "01")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let joined = try await inboxEligibilityRequest(
                client, f, method: .post,
                path: "/internal/agent-api/channels/\(f.channelId)/join"
            )
            #expect(joined.status == .ok)

            // The membership notice the agent caused is born-read for it: the
            // wake hints and the durable event pull both stay empty.
            let hints = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/wake-hints?since=0")
            #expect(wakeHintMessageIds(hints.body).isEmpty, "a born-read notice must not be announced")
            let events = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/events")
            #expect(eventMessageIds(events.body).isEmpty, "the pull agrees: nothing unread")

            // The next ordinary message is announced and returned, alone.
            try await inboxHumanPost(client, f, content: "welcome aboard")
            let nextHints = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/wake-hints?since=0")
            #expect(wakeHintMessageIds(nextHints.body).count == 1)
            let nextEvents = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/events")
            #expect(eventMessageIds(nextEvents.body).count == 1)
        }
    }
}

@Test func managedAgentOwnMembershipNoticeDoesNotWakeIt() async throws {
    let f = makeInboxEligibilityFixture(runtime: "claude", suffix: "02")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let joined = try await inboxEligibilityRequest(
                client, f, method: .post,
                path: "/internal/agent-api/channels/\(f.channelId)/join"
            )
            #expect(joined.status == .ok)
            let hints = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/wake-hints?since=0")
            #expect(wakeHintMessageIds(hints.body).isEmpty, "a managed agent is not woken by its own membership notice")

            try await inboxHumanPost(client, f, content: "managed welcome")
            let nextHints = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/wake-hints?since=0")
            #expect(wakeHintMessageIds(nextHints.body).count == 1)
        }
    }
}

@Test func someoneElseCausedMembershipNoticeStaysUnread() async throws {
    let f = makeInboxEligibilityFixture(runtime: "external", suffix: "03")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // A human adds the agent: the notice is not the agent's own action,
            // so every transport still treats it as unread attention.
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(f.ownerToken)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = f.serverId
            let added = try await client.send(.post, headers: headers, to: "/api/channels/\(f.channelId)/members") { request in
                request.body = .init(string: "{\"agentId\":\"\(f.agentId)\"}")
            }
            #expect(added.status == .ok)

            let hints = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/wake-hints?since=0")
            let hintIds = wakeHintMessageIds(hints.body)
            #expect(hintIds.count == 1, "someone else's membership notice is unread")
            let events = try await inboxEligibilityRequest(client, f, method: .get, path: "/internal/agent-api/events")
            #expect(eventMessageIds(events.body) == hintIds, "announcement and pull agree")
        }
    }
}
