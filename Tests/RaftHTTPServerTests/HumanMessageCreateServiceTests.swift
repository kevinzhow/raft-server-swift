import Dispatch
import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct CreateFixture {
    let accounts: EmailLoginDirectory
    let service: HumanMessageCreateService
    let ownerId: String
    let token: String
    let serverId: String
    let channelId: String
}

private func makeCreateFixture(_ tag: String, ownerSuffix: Int, serverSuffix: Int) -> CreateFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-1111111117\(ownerSuffix)"
    let serverId = "33333333-3333-4333-8333-3333333337\(serverSuffix)"
    accounts.addAccount(id: ownerId, email: "\(tag)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: tag, name: tag, ownerId: ownerId)
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: tag, creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: tag)
    return CreateFixture(
        accounts: accounts,
        service: accounts.humanMessageCreate,
        ownerId: ownerId,
        token: accounts.mintAccessTokenForTesting(userId: ownerId),
        serverId: serverId,
        channelId: channelId
    )
}

private func routeRequest(
    _ client: any Client,
    _ method: HTTPRequest.Method,
    _ path: String,
    body: String? = nil,
    token: String? = nil,
    serverId: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    if body != nil { headers[.contentType] = "application/json" }
    if let token { headers[.authorization] = "Bearer \(token)" }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func withCreateApp(_ accounts: EmailLoginDirectory, _ body: @escaping (any Client) async throws -> Void) async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in try await body(client) }
    }
}

private func header(_ response: ClientResponse, _ name: String) -> String? {
    response.headers[HTTPField.Name(name)!]
}

private func text(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

/// Runs `body` on 16 threads at once and returns every result.
private func concurrently<T: Sendable>(_ count: Int = 16, _ body: @escaping @Sendable (Int) -> T) -> [T] {
    let box = ResultBox<T>()
    DispatchQueue.concurrentPerform(iterations: count) { index in
        box.append(body(index))
    }
    return box.values
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: - Byte-exact responses

@Test func humanMessageCreateRepliesAreByteExact() async throws {
    let f = makeCreateFixture("create-bytes", ownerSuffix: 51, serverSuffix: 51)
    try await withCreateApp(f.accounts) { client in
        // v1: the stored row alone, keys in the published order.
        let sent = try await routeRequest(
            client, .post, "/api/messages",
            body: "{\"channelId\":\"\(f.channelId)\",\"content\":\"hi \\\"there\\\"\",\"randomId\":\"r-1\"}",
            token: f.token, serverId: f.serverId
        )
        #expect(sent.status == .ok)
        let id = try #require(storedMessageId(text(sent)))
        #expect(text(sent) == "{\"id\":\"\(id)\",\"channelId\":\"\(f.channelId)\",\"content\":\"hi \\\"there\\\"\",\"attachments\":[],\"mentions\":[],\"randomId\":\"r-1\"}")
        #expect(header(sent, "Content-Length") == String(text(sent).utf8.count))
        // The same randomId replays the same row.
        let replay = try await routeRequest(
            client, .post, "/api/messages",
            body: "{\"channelId\":\"\(f.channelId)\",\"content\":\"hi \\\"there\\\"\",\"randomId\":\"r-1\"}",
            token: f.token, serverId: f.serverId
        )
        #expect(text(replay) == text(sent))
        // v2: always nested.
        let v2 = try await routeRequest(
            client, .post, "/api/v2/messages",
            body: "{\"channelId\":\"\(f.channelId)\",\"content\":\"v2\",\"randomId\":\"r-2\"}",
            token: f.token, serverId: f.serverId
        )
        let v2Id = try #require(storedMessageId(text(v2).replacingOccurrences(of: "{\"message\":", with: "")))
        #expect(text(v2) == "{\"message\":{\"id\":\"\(v2Id)\",\"channelId\":\"\(f.channelId)\",\"content\":\"v2\",\"attachments\":[],\"mentions\":[],\"randomId\":\"r-2\"}}")
        // Session refusal: public auth_required body with no-store.
        let anonymous = try await routeRequest(client, .post, "/api/messages", body: "{}", serverId: f.serverId)
        #expect(anonymous.status == .unauthorized)
        #expect(text(anonymous) == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        #expect(header(anonymous, "Cache-Control") == "private, no-store")
        #expect(header(anonymous, "Content-Length") == "74")
        let revoked = try await routeRequest(client, .post, "/api/messages", body: "{}", token: "nope", serverId: f.serverId)
        #expect(text(revoked) == "{\"error\":\"Invalid or expired token\",\"code\":\"auth_required\"}")
        // Body refusals.
        let badBody = try await routeRequest(client, .post, "/api/messages", body: "[]", token: f.token, serverId: f.serverId)
        #expect(badBody.status == .badRequest)
        #expect(text(badBody) == "{\"error\":\"Invalid message request body\"}")
        let badRandom = try await routeRequest(
            client, .post, "/api/messages",
            body: "{\"channelId\":\"\(f.channelId)\",\"content\":\"x\",\"randomId\":null}",
            token: f.token, serverId: f.serverId
        )
        #expect(text(badRandom) == "{\"error\":\"randomId must be a non-empty string with at most 128 characters\"}")
        // A rejected write keeps the message write's own body (error before code).
        let otherChannel = f.accounts.oauth.createChannel(serverId: f.serverId, name: "other", creatorUserId: f.ownerId)
        f.accounts.addPostableChannel(serverId: f.serverId, channelId: otherChannel, memberId: f.ownerId, name: "other")
        let conflict = try await routeRequest(
            client, .post, "/api/messages",
            body: "{\"channelId\":\"\(otherChannel)\",\"content\":\"hi\",\"randomId\":\"r-1\"}",
            token: f.token, serverId: f.serverId
        )
        #expect(conflict.status == .conflict)
        #expect(text(conflict) == "{\"error\":\"randomId has already been used for a different message\",\"code\":\"random_id_conflict\"}")
    }
}

private func storedMessageId(_ body: String) -> String? {
    guard let range = body.range(of: "\"id\":\"") else { return nil }
    return String(body[range.upperBound...].prefix(36))
}

@Test func pendingMentionActionsPublishTheExactMemberOrder() async throws {
    let f = makeCreateFixture("create-pending", ownerSuffix: 52, serverSuffix: 52)
    let agentId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "Outsider", avatarUrl: "pixel:random:Outsider", creatorUserId: f.ownerId)
    f.accounts.addServerAgent(serverId: f.serverId, id: agentId, name: "Outsider", avatarUrl: "pixel:random:Outsider")
    let created = try f.service.createHumanMessage(
        HumanMessageCreateRequest(
            channelId: .string(f.channelId),
            content: .string("hello @Outsider"),
            mentions: .array([.object([
                "type": .string("agent"), "id": .string(agentId), "name": .string("Outsider"),
            ])])
        ),
        authorization: "Bearer \(f.token)",
        serverId: f.serverId
    )
    let action = try #require(created.pendingMentionActions.first)
    let rendered = created.jsonBody.render()
    #expect(rendered.hasPrefix("{\"message\":{\"id\":\""))
    #expect(rendered.hasSuffix(
        "},\"pendingMentionActions\":[{\"resolutionId\":\"\(action.resolutionId)\",\"messageId\":\"\(action.messageId)\",\"targetType\":\"agent\",\"targetHandle\":\"Outsider\",\"targetAvatarUrl\":\"pixel:random:Outsider\",\"reason\":\"not_member\",\"availableActions\":[\"notify\",\"add\"],\"expiresAt\":\"\(action.expiresAt)\"}]}"
    ))
}

@Test func forwardLookupAndMentionActionBodiesAreByteExact() async throws {
    let f = makeCreateFixture("create-lookup", ownerSuffix: 53, serverSuffix: 53)
    try await withCreateApp(f.accounts) { client in
        let enabled = try await routeRequest(client, .get, "/api/messages/forward/enabled", token: f.token, serverId: f.serverId)
        #expect(text(enabled) == "{\"enabled\":true}")
        let noServer = try await routeRequest(client, .get, "/api/messages/forward/enabled", token: f.token)
        #expect(noServer.status == .badRequest)
        #expect(text(noServer) == "{\"error\":\"Missing X-Server-Id header\"}")
        let anonymous = try await routeRequest(client, .get, "/api/messages/forward/enabled", serverId: f.serverId)
        #expect(text(anonymous) == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")
        #expect(header(anonymous, "Cache-Control") == "private, no-store")
        #expect(anonymous.status == .unauthorized)
        #expect(header(anonymous, "Content-Length") == "74")
        let empty = try await routeRequest(client, .get, "/api/messages/forward/targets/search?q=%20", token: f.token, serverId: f.serverId)
        #expect(text(empty) == "{\"targets\":[]}")
        let search = try await routeRequest(client, .get, "/api/messages/forward/targets/search?q=create-lookup", token: f.token, serverId: f.serverId)
        #expect(text(search) == "{\"targets\":[{\"type\":\"channel\",\"channelType\":\"channel\",\"id\":\"\(f.channelId)\",\"title\":\"#create-lookup\",\"subtitle\":\"\",\"avatarUrl\":null,\"channelId\":\"\(f.channelId)\",\"joined\":true,\"dmExists\":null,\"canForwardNow\":true,\"requiredAction\":null}]}")
        let noAction = try await routeRequest(client, .post, "/api/messages/mention-actions/execute", body: "{}", token: f.token, serverId: f.serverId)
        #expect(text(noAction) == "{\"error\":\"action must be notify or add\"}")
        let noIds = try await routeRequest(client, .post, "/api/messages/mention-actions/execute", body: "{\"action\":\"add\"}", token: f.token, serverId: f.serverId)
        #expect(text(noIds) == "{\"error\":\"resolutionIds must include at least one id\"}")
        let missing = try await routeRequest(
            client, .post, "/api/messages/mention-actions/execute",
            body: "{\"action\":\"notify\",\"resolutionIds\":[\"x\",\"x\",7]}", token: f.token, serverId: f.serverId
        )
        #expect(text(missing) == "{\"ok\":true,\"action\":\"notify\",\"results\":[{\"resolutionId\":\"x\",\"action\":\"notify\",\"status\":\"not_found\"}]}")
    }
}

@Test func batchForwardPublishesItsOutcomeHeaderAndResultOrder() async throws {
    let f = makeCreateFixture("create-batch", ownerSuffix: 54, serverSuffix: 54)
    let destination = f.accounts.oauth.createChannel(serverId: f.serverId, name: "dest", creatorUserId: f.ownerId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: destination, memberId: f.ownerId, name: "dest")
    let source = f.accounts.addHumanMessageForTesting(channelId: f.channelId, senderId: f.ownerId, content: "forward me")
    let missing = "44444444-4444-4444-8444-444444444454"
    let requestId = "55555555-5555-4555-8555-555555555554"
    try await withCreateApp(f.accounts) { client in
        let reply = try await routeRequest(
            client, .post, "/api/messages/forward",
            body: "{\"destinationChannelIds\":[\"\(destination)\",\"\(missing)\"],\"sourceMessageIds\":[\"\(source)\"],\"requestId\":\"\(requestId)\"}",
            token: f.token, serverId: f.serverId
        )
        #expect(reply.status == .ok)
        #expect(header(reply, "X-Raft-Forward-Outcome") == "partial_failure")
        let body = text(reply)
        #expect(body.hasPrefix("{\"results\":[{\"destinationChannelId\":\"\(destination)\",\"status\":\"success\",\"message\":{\"id\":\""))
        #expect(body.hasSuffix("{\"destinationChannelId\":\"\(missing)\",\"status\":\"failed\",\"code\":\"destination_unavailable\",\"error\":\"Could not forward to this target\"}]}"))
        #expect(body.contains("\"messageType\":\"chat\",\"channelId\":\"\(destination)\",\"content\":\"Forwarded 1 message\",\"attachments\":[],\"randomId\":\"forward:\(requestId):\(destination)\",\"actionMetadata\":{\"kind\":\"forwarded-bundle\",\"destinationTargetId\":\"\(destination)\",\"forwardedItems\":[{\"sourceMessageId\":\"\(source)\""))
        // The same request replays: the success becomes an idempotent replay.
        let again = try await routeRequest(
            client, .post, "/api/messages/forward",
            body: "{\"destinationChannelIds\":[\"\(destination)\"],\"sourceMessageIds\":[\"\(source)\"],\"requestId\":\"\(requestId)\"}",
            token: f.token, serverId: f.serverId
        )
        #expect(header(again, "X-Raft-Forward-Outcome") == "idempotent_replay")
        let single = try await routeRequest(
            client, .post, "/api/messages/forward",
            body: "{\"destinationChannelId\":\"\(destination)\",\"sourceMessageIds\":[\"\(source)\"],\"note\":\" hello \",\"randomId\":\"single-1\"}",
            token: f.token, serverId: f.serverId
        )
        #expect(header(single, "X-Raft-Forward-Outcome") == "success")
        #expect(text(single).contains("\"content\":\"hello\",\"attachments\":[],\"randomId\":\"single-1\",\"actionMetadata\""))
        let invalid = try await routeRequest(
            client, .post, "/api/messages/forward", body: "{}", token: f.token, serverId: f.serverId
        )
        #expect(text(invalid) == "{\"error\":\"Destination channel and full source message ids are required\"}")
        #expect(header(invalid, "X-Raft-Forward-Outcome") == nil)
    }
}

// MARK: - Atomic sections

/// Public human sends supply the real author and unique retained resolution.
private func atomicHumanOutsider(_ f: CreateFixture, name: String) -> String {
    let id = UUID().uuidString.lowercased()
    f.accounts.addAccount(id: id, email: "\(name)@slock.test", password: "password123")
    f.accounts.setAccountProfileForTesting(id: id, name: name)
    f.accounts.markEmailVerified(userId: id)
    f.accounts.oauth.addMember(serverId: f.serverId, userId: id, role: "member")
    return id
}

private func atomicHumanPending(_ f: CreateFixture, targetId: String, name: String) throws -> String {
    let result = try f.service.createHumanMessage(
        HumanMessageCreateRequest(channelId: .string(f.channelId), content: .string("hello @\(name)"),
            mentions: .array([.object(["type": .string("user"), "id": .string(targetId), "name": .string(name)])])),
        authorization: "Bearer \(f.token)", serverId: f.serverId)
    return try #require(result.pendingMentionActions.first?.resolutionId)
}

/// The atomic notification claim has one first result and fifteen idempotent results.
@Test func concurrentNotifyClaimsAMentionExactlyOnce() throws {
    let f = makeCreateFixture("atomic-notify", ownerSuffix: 55, serverSuffix: 55)
    let targetId = atomicHumanOutsider(f, name: "NotifyHuman")
    let mentionId = try atomicHumanPending(f, targetId: targetId, name: "NotifyHuman")
    let results = concurrently { _ in
        try? f.service.executeMentionActions(MentionActionsRequest(action: "notify", resolutionIds: [mentionId]),
            authorization: "Bearer \(f.token)", serverId: f.serverId)
    }
    let rows = results.compactMap { $0?.results.first }
    #expect(rows.count == 16)
    #expect(rows.allSatisfy { $0.status == "queued" })
    #expect(rows.filter { $0.reason == nil }.count == 1)
    #expect(rows.filter { $0.reason == "already_queued" }.count == 15)
    #expect(f.accounts.mentionActionRecord(id: mentionId)?.notified == true)
    #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: targetId))
}

/// Serial memory-service retries lock idempotence and actual human membership.
/// The original 16-way same-ID ADD oracle is mandatory in the real PG/public-BPR human-target axis.
@Test func serialAddRetriesDeliverMembershipExactlyOnce() throws {
    let f = makeCreateFixture("atomic-add", ownerSuffix: 56, serverSuffix: 56)
    let targetId = atomicHumanOutsider(f, name: "AddHuman")
    let mentionId = try atomicHumanPending(f, targetId: targetId, name: "AddHuman")
    let results = (0..<16).map { _ in
        try? f.service.executeMentionActions(MentionActionsRequest(action: "add", resolutionIds: [mentionId]),
            authorization: "Bearer \(f.token)", serverId: f.serverId)
    }
    let rows = results.compactMap { $0?.results.first }
    #expect(rows.count == 16)
    #expect(rows.filter { $0.status == "delivered" && $0.reason == nil }.count == 1)
    #expect(rows.filter { $0.reason == "already_delivered" }.count == 15)
    #expect(f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: targetId))
    #expect(f.accounts.channelMemberIds(channelId: f.channelId).filter { $0 == targetId }.count == 1)
}

/// Node permits two distinct actual messages in this group, never duplicate
/// (message,target) rows. The external agent-target queue is a mandatory PG case.
@Test func concurrentAgentNotifyDedupesSiblingRowsExactlyOnce() async throws {
    let f = makeCreateFixture("atomic-agent", ownerSuffix: 57, serverSuffix: 57)
    let targetId = atomicHumanOutsider(f, name: "AtomicHuman")
    let senderId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "AtomicSender", creatorUserId: f.ownerId)
    f.accounts.oauth.addChannelAgent(channelId: f.channelId, agentId: senderId)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: f.channelId, memberId: senderId)
    let key = f.accounts.mintAgentCredential(agentId: senderId, scopes: ["read", "send", "mentions"], name: "atomic")
    try await withCreateApp(f.accounts) { client in
        var pendingIds: [String] = []
        var hostIds: [String] = []
        for index in 0..<2 {
            let response = try await routeRequest(client, .post, "/internal/agent-api/send",
                body: "{\"target\":\"#atomic-agent\",\"content\":\"host \(index) @AtomicHuman\"}", token: key)
            #expect(response.status == .ok)
            let body = try #require(try JSONSerialization.jsonObject(with: Data(text(response).utf8)) as? [String: Any])
            #expect(body["state"] as? String == "sent")
            hostIds.append(try #require(body["messageId"] as? String))
            pendingIds.append(try #require((body["pendingMentionActions"] as? [[String: Any]])?.first?["resolutionId"] as? String))
        }
        #expect(Set(hostIds).count == 2)
        #expect(Set(pendingIds).count == 2)
        let first = pendingIds[0]
        let second = pendingIds[1]
        let results = concurrently { _ in
            try? f.service.agentMentionActionsExecute(authorization: "Bearer \(key)",
                MentionActionsRequest(action: "notify", resolutionIds: [first]))
        }
        let deduped = results.compactMap { $0?.results.first?.deduped }
        #expect(deduped.count == 16)
        #expect(deduped.filter { $0.count == 2 && $0.contains(second) }.count == 1)
        #expect(deduped.filter { $0 == [first] }.count == 15)
        #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: targetId))
    }
}

/// `resolvePendingMentionRows`: concurrent identical sends of one `randomId`
/// share one stored resolution row per outsider target.
@Test func concurrentReplaysShareOnePendingMentionResolution() throws {
    let f = makeCreateFixture("atomic-pending", ownerSuffix: 58, serverSuffix: 58)
    let agentId = f.accounts.oauth.createAgent(serverId: f.serverId, name: "PendingOutsider", creatorUserId: f.ownerId)
    f.accounts.addServerAgent(serverId: f.serverId, id: agentId, name: "PendingOutsider", avatarUrl: nil)
    let service = f.service
    let token = f.token
    let serverId = f.serverId
    let channelId = f.channelId
    let results = concurrently { _ in
        try? service.createHumanMessage(
            HumanMessageCreateRequest(
                channelId: .string(channelId),
                content: .string("ping @PendingOutsider"),
                mentions: .array([.object([
                    "type": .string("agent"), "id": .string(agentId), "name": .string("PendingOutsider"),
                ])]),
                randomId: .string("pending-replay")
            ),
            authorization: "Bearer \(token)",
            serverId: serverId
        )
    }
    let resolutionIds = Set(results.compactMap { $0?.pendingMentionActions.first?.resolutionId })
    #expect(results.count == 16)
    #expect(resolutionIds.count == 1)
    #expect(Set(results.compactMap { $0?.pendingMentionActions.first?.messageId }).count == 1)
}

/// `recordStoppedAgentDelivery`: every send to a stopped agent's DM appends
/// exactly one delivery, and a running agent's DM appends none.
@Test func stoppedAgentDeliveryIsRecordedOncePerSend() throws {
    let f = makeCreateFixture("atomic-stopped", ownerSuffix: 59, serverSuffix: 59)
    let stoppedId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa59"
    let runningId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbb59"
    let stoppedDm = "22222222-2222-4222-8222-222222222259"
    let runningDm = "22222222-2222-4222-8222-222222222260"
    f.accounts.addServerAgent(serverId: f.serverId, id: stoppedId, name: "StoppedOne", avatarUrl: nil, status: "stopped")
    f.accounts.addServerAgent(serverId: f.serverId, id: runningId, name: "RunningOne", avatarUrl: nil, status: "active")
    f.accounts.addDirectMessage(serverId: f.serverId, channelId: stoppedDm, participantIds: [f.ownerId], agentId: stoppedId)
    f.accounts.addDirectMessage(serverId: f.serverId, channelId: runningDm, participantIds: [f.ownerId], agentId: runningId)
    let service = f.service
    let token = f.token
    let serverId = f.serverId
    let warnings = concurrently { index in
        let dm = index % 2 == 0 ? stoppedDm : runningDm
        let created = try? service.createHumanMessage(
            HumanMessageCreateRequest(channelId: dm, content: "hello \(index)"),
            authorization: "Bearer \(token)",
            serverId: serverId,
            contract: .v2
        )
        return (stopped: index % 2 == 0, count: created?.deliveryWarnings.count ?? -1)
    }
    #expect(warnings.filter { $0.stopped }.allSatisfy { $0.count == 1 })
    #expect(warnings.filter { !$0.stopped }.allSatisfy { $0.count == 0 })
    #expect(f.accounts.agentDeliveryChannelTypes(agentId: stoppedId).count == 8)
}

/// `applyThreadReplyFollows`: the sender follows, a mentioned member of the
/// parent follows, and a suppressed follow of a non-parent member stays
/// suppressed.
@Test func threadReplyWritesFollowsAndKeepsOutsiderSuppression() throws {
    let f = makeCreateFixture("atomic-thread", ownerSuffix: 60, serverSuffix: 60)
    let memberId = "11111111-1111-4111-8111-111111111761"
    f.accounts.addAccount(id: memberId, email: "atomic-thread-member@slock.test", password: "password123")
    f.accounts.setAccountProfileForTesting(id: memberId, name: "member")
    f.accounts.oauth.addChannelHuman(channelId: f.channelId, userId: memberId)
    f.accounts.oauth.addMember(serverId: f.serverId, userId: memberId, role: "member")
    let parentMessage = f.accounts.addHumanMessageForTesting(channelId: f.channelId, senderId: f.ownerId, content: "parent")
    let threadId = "22222222-2222-4222-8222-222222222261"
    f.accounts.addPostableChannel(
        serverId: f.serverId, channelId: threadId, memberId: f.ownerId, kind: "thread",
        parentChannelId: f.channelId, parentMessageId: parentMessage, name: "thread"
    )
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: f.channelId, memberId: memberId, name: "atomic-thread")
    f.accounts.unfollowThreadForTesting(
        serverId: f.serverId, userId: memberId, threadChannelId: threadId, parentMessageId: parentMessage
    )
    #expect(f.accounts.threadUnfollowSuppressedForTesting(serverId: f.serverId, userId: memberId, threadChannelId: threadId))
    _ = try f.service.createHumanMessage(
        HumanMessageCreateRequest(
            channelId: .string(threadId),
            content: .string("reply @member"),
            mentions: .array([.object([
                "type": .string("user"), "id": .string(memberId), "name": .string("member"),
            ])])
        ),
        authorization: "Bearer \(f.token)",
        serverId: f.serverId
    )
    let followers = f.accounts.threadFollowerIdsForTesting(threadChannelId: threadId)
    #expect(followers.contains(f.ownerId))
    // The mentioned member belongs to the parent channel, so the suppression lifts.
    #expect(followers.contains(memberId))
    #expect(!f.accounts.threadUnfollowSuppressedForTesting(serverId: f.serverId, userId: memberId, threadChannelId: threadId))
}

/// The production service already accepts this clock. All retained owners and
/// collaborators are preserved; only observation time advances, never history.
private func mentionServiceAt(_ original: HumanMessageCreateService, _ time: Date) -> HumanMessageCreateService {
    var dependencies = original.dependencies
    dependencies.now = { time }
    return HumanMessageCreateService(channels: original.channels, messages: original.messages, agents: original.agents,
        profiles: original.profiles, oauth: original.oauth, dependencies: dependencies, machines: original.machines, execution: original.execution)
}

@Test func actualMentionRowsExpireAfterSevenDaysWithoutRewritingTheirHistory() async throws {
    let f = makeCreateFixture("mention-expiry", ownerSuffix: 62, serverSuffix: 62)
    let humanId = atomicHumanOutsider(f, name: "ExpiryHuman")
    let sender = f.accounts.oauth.createAgent(serverId: f.serverId, name: "ExpirySender", creatorUserId: f.ownerId)
    f.accounts.oauth.addChannelAgent(channelId: f.channelId, agentId: sender)
    f.accounts.addPostableChannel(serverId: f.serverId, channelId: f.channelId, memberId: sender)
    let key = f.accounts.mintAgentCredential(agentId: sender, scopes: ["send", "read", "mentions"], name: "expiry")
    try await withCreateApp(f.accounts) { client in
        let human = try await routeRequest(client, .post, "/api/v2/messages",
            body: "{\"channelId\":\"\(f.channelId)\",\"content\":\"hello @ExpiryHuman\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(humanId)\",\"name\":\"ExpiryHuman\"}]}",
            token: f.token, serverId: f.serverId)
        #expect(human.status == .ok)
        let humanBody = try #require(try JSONSerialization.jsonObject(with: Data(text(human).utf8)) as? [String: Any])
        let humanPending = try #require((humanBody["pendingMentionActions"] as? [[String: Any]])?.first)
        let humanResolution = try #require(humanPending["resolutionId"] as? String)
        let agent = try await routeRequest(client, .post, "/internal/agent-api/v2/send",
            body: "{\"target\":\"#mention-expiry\",\"content\":\"hello @ExpiryHuman\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(humanId)\",\"name\":\"ExpiryHuman\"}]}", token: key)
        #expect(agent.status == .ok)
        let agentBody = try #require(try JSONSerialization.jsonObject(with: Data(text(agent).utf8)) as? [String: Any])
        let agentPending = try #require((agentBody["pendingMentionActions"] as? [[String: Any]])?.first)
        let agentResolution = try #require(agentPending["resolutionId"] as? String)
        let stored = f.accounts.messagesAndThreadsStore.state.storedMentions
        let humanRow = try #require(stored.first { $0.id == humanResolution })
        let agentRow = try #require(stored.first { $0.id == agentResolution })
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (pending, createdAt) in [(humanPending, humanRow.createdAt), (agentPending, agentRow.createdAt)] {
            let expiryText = try #require(pending["expiresAt"] as? String)
            let expiry = try #require(format.date(from: expiryText))
            #expect(abs(expiry.timeIntervalSince(createdAt) - 7 * 24 * 60 * 60) < 0.01)
        }
        let beforeExpiry = mentionServiceAt(f.service, agentRow.createdAt.addingTimeInterval(6 * 24 * 60 * 60))
        let pending = try beforeExpiry.agentMentionActionsPending(authorization: "Bearer \(key)")
        #expect(pending.pendingMentionActions.map(\.resolutionId) == [agentResolution], "agent TTL is seven days, not the old random report's24h")
        let afterExpiry = mentionServiceAt(f.service, max(humanRow.createdAt, agentRow.createdAt).addingTimeInterval(8 * 24 * 60 * 60))
        #expect(try afterExpiry.agentMentionActionsPending(authorization: "Bearer \(key)").pendingMentionActions.isEmpty)
        let expiredHuman = try afterExpiry.executeMentionActions(MentionActionsRequest(action: "notify", resolutionIds: [humanResolution]),
            authorization: "Bearer \(f.token)", serverId: f.serverId)
        let expiredAgent = try afterExpiry.agentMentionActionsExecute(authorization: "Bearer \(key)",
            MentionActionsRequest(action: "notify", resolutionIds: [agentResolution]))
        #expect(expiredHuman.results.first?.status == "expired")
        #expect(expiredAgent.results.first?.status == "expired")
        #expect(expiredHuman.results.first?.deduped == nil)
        #expect(expiredAgent.results.first?.deduped == nil)
        let after = f.accounts.messagesAndThreadsStore.state.storedMentions
        #expect(after.first { $0.id == humanResolution }?.createdAt == humanRow.createdAt)
        #expect(after.first { $0.id == agentResolution }?.createdAt == agentRow.createdAt)
        #expect(f.accounts.mentionActionRecord(id: humanResolution)?.notified == false)
        #expect(f.accounts.mentionActionRecord(id: agentResolution)?.notified == false)
        #expect(!f.accounts.oauth.isChannelParticipant(channelId: f.channelId, userId: humanId))
    }
}
