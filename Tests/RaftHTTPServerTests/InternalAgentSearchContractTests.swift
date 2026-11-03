import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct LegacySearchFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let ownerName: String
    let speakerId: String
    let speakerName: String
    let agentId: String
    let machineKey: String
    let channelId: String
}

private func makeLegacySearchFixture(_ suffix: String) -> LegacySearchFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001360\(suffix)"
    let speakerId = "11111111-1111-4111-8111-000001361\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001360\(suffix)"
    let ownerName = "legacy-search-owner-\(suffix)"
    let speakerName = "legacy-search-speaker-\(suffix)"
    for (id, email) in [
        (ownerId, "\(ownerName)@slock.test"),
        (speakerId, "\(speakerName)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "legacy-search-\(suffix)", name: "Legacy Search \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: speakerId, role: "member")
    let channelName = "legacy-search-room-\(suffix)"
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: channelName, creatorUserId: ownerId)
    for id in [ownerId, speakerId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, kind: "channel", name: channelName)
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "legacy-search-bot-\(suffix)", creatorUserId: ownerId, runtime: "codx")
    accounts.oauth.addChannelAgent(channelId: channelId, agentId: agentId)
    return LegacySearchFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        ownerName: ownerName,
        speakerId: speakerId,
        speakerName: speakerName,
        agentId: agentId,
        machineKey: accounts.registerMachineForAgent(serverId: serverId, agentId: agentId),
        channelId: channelId
    )
}

private func legacySearchGet(
    _ client: any Client,
    f: LegacySearchFixture,
    params: [String: String]
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(f.machineKey)"
    let query = params
        .sorted { $0.key < $1.key }
        .map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(encoded)"
        }
        .joined(separator: "&")
    let response = try await client.get(URI(string: "/internal/agent/\(f.agentId)/search?\(query)"), headers: headers)
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@discardableResult
private func legacyInsert(
    _ f: LegacySearchFixture,
    channelId: String,
    senderId: String,
    content: String,
    senderType: String = "user"
) -> String {
    let id = UUID().uuidString.lowercased()
    f.accounts.insertHumanMessage(id: id, channelId: channelId, senderId: senderId, content: content, senderType: senderType)
    return id
}

@Test func internalAgentSearchResolvesSenderHandles() async throws {
    let f = makeLegacySearchFixture("901")
    let speakerMessage = legacyInsert(f, channelId: f.channelId, senderId: f.speakerId, content: "zebraneedle from speaker")
    legacyInsert(f, channelId: f.channelId, senderId: f.ownerId, content: "zebraneedle from owner")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let result = try await legacySearchGet(client, f: f, params: ["q": "zebraneedle", "sender": "@\(f.speakerName)"])
            #expect(result.status == .ok)
            let rows = (result.body["results"] as? [[String: Any]]) ?? []
            #expect(rows.map { $0["id"] as? String } == [speakerMessage])
            #expect(rows[0]["senderName"] as? String == f.speakerName)
            #expect(rows[0]["taskCurrentProjection"] == nil)
        }
    }
}

@Test func internalAgentSearchProjectsThreadReplyHits() async throws {
    let f = makeLegacySearchFixture("902")
    let parent = legacyInsert(f, channelId: f.channelId, senderId: f.ownerId, content: "thread parent without the regression token")
    let threadId = f.accounts.oauth.createThreadChannel(parentChannelId: f.channelId, parentMessageId: parent)
    f.accounts.addPostableChannel(
        serverId: f.serverId,
        channelId: threadId,
        memberId: f.ownerId,
        kind: "thread",
        parentChannelId: f.channelId,
        parentMessageId: parent,
        name: "thread"
    )
    let firstReply = legacyInsert(f, channelId: threadId, senderId: f.ownerId, content: "minimaxgrouping first reply")
    let secondReply = legacyInsert(f, channelId: threadId, senderId: f.ownerId, content: "minimaxgrouping second reply")

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let result = try await legacySearchGet(client, f: f, params: ["q": "minimaxgrouping", "sort": "recent"])
            #expect(result.status == .ok)
            let rows = (result.body["results"] as? [[String: Any]]) ?? []
            let replyRows = rows.filter { ($0["id"] as? String) == firstReply || ($0["id"] as? String) == secondReply }
            #expect(replyRows.count == 2)
            #expect(Set(replyRows.compactMap { $0["threadId"] as? String }) == [threadId])
            #expect(Set(replyRows.compactMap { $0["parentMessageId"] as? String }) == [parent])
            #expect(Set(replyRows.compactMap { $0["channelType"] as? String }) == ["thread"])
            #expect(Set(replyRows.compactMap { $0["channelId"] as? String }) == [threadId])
            #expect(replyRows.allSatisfy { $0["parentMessageContent"] as? String == "thread parent without the regression token" })
        }
    }
}

@Test func internalAgentSearchCloaksInvisibleAndAmbiguousSenderHandles() async throws {
    let f = makeLegacySearchFixture("903")
    legacyInsert(f, channelId: f.channelId, senderId: f.speakerId, content: "zebraneedle body")
    let invisibleName = "legacy-search-invisible-903"
    f.accounts.addAccount(id: "11111111-1111-4111-8111-000001362903", email: "\(invisibleName)@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let invisible = try await legacySearchGet(client, f: f, params: ["q": "zebraneedle", "sender": "@\(invisibleName)"])
            #expect(invisible.status == .notFound)
            #expect(invisible.body["errorCode"] as? String == "member_not_found")
            #expect((invisible.body["error"] as? String)?.contains("Member not found") == true)

            // An agent and a human sharing one handle make the reference ambiguous.
            _ = f.accounts.oauth.createAgent(serverId: f.serverId, name: f.speakerName, creatorUserId: f.ownerId, runtime: "codx")
            let ambiguous = try await legacySearchGet(client, f: f, params: ["q": "zebraneedle", "sender": "@\(f.speakerName)"])
            #expect(ambiguous.status == .conflict)
            #expect(ambiguous.body["errorCode"] as? String == "ambiguous_member_ref")
            #expect((ambiguous.body["error"] as? String)?.lowercased().contains("ambiguous") == true)
        }
    }
}

@Test func internalAgentSearchRequiresOffsetsAndComparesAbsoluteInstants() async throws {
    let f = makeLegacySearchFixture("904")
    let message = legacyInsert(f, channelId: f.channelId, senderId: f.speakerId, content: "zebraneedle boundary")
    f.accounts.setHumanMessageCreatedAt(messageId: message, createdAt: Date(timeIntervalSince1970: 1_785_962_317)) // 2026-08-05T20:38:37Z

    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let missingOffset = try await legacySearchGet(
                client,
                f: f,
                params: ["q": "zebraneedle", "after": "2026-08-06T04:38:36"]
            )
            #expect(missingOffset.status == .badRequest)
            #expect(missingOffset.body["errorCode"] as? String == "INVALID_DATE_FILTER")
            let messageText = (missingOffset.body["error"] as? String) ?? ""
            #expect(messageText.lowercased().contains("missing a timezone offset"))
            #expect(messageText.contains("+08:00"))
            #expect(messageText.contains("raft CLI"))

            func ids(_ params: [String: String]) async throws -> [String] {
                let result = try await legacySearchGet(
                    client,
                    f: f,
                    params: ["q": "zebraneedle", "sender": "@\(f.speakerName)", "sort": "recent"].merging(params) { _, new in new }
                )
                #expect(result.status == .ok)
                return ((result.body["results"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            }

            #expect(try await ids(["after": "2026-08-06T04:38:36+08:00"]) == [message])
            #expect(try await ids(["after": "2026-08-06T04:38:38+08:00"]) == [])
            #expect(try await ids(["before": "2026-08-06T04:38:38+08:00"]) == [message])
            #expect(try await ids(["before": "2026-08-06T04:38:36+08:00"]) == [])
        }
    }
}
