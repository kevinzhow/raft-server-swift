import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct SearchRefFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001099001"
    let ownerId = "11111111-1111-4111-8111-000001099001"
    let speakerId = "11111111-1111-4111-8111-000001099002"
    let invisibleId = "11111111-1111-4111-8111-000001099003"
    var agentId = ""
    var machineId = ""
    var apiKey = ""
    var channelId = ""
    var ownerToken = ""

    mutating func seed() {
        for (id, email) in [(ownerId, "search-ref-owner"), (speakerId, "search-ref-speaker"), (invisibleId, "search-ref-invisible")] {
            accounts.addAccount(id: id, email: "\(email)@search.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: serverId, slug: "search-ref-server", name: "Search Ref Server", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: speakerId, role: "member")
        agentId = accounts.oauth.createAgent(serverId: serverId, name: "search-ref-agent", creatorUserId: ownerId, runtime: "codex")
        machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "search-ref-machine")
        apiKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agentId)
        channelId = accounts.oauth.createChannel(serverId: serverId, name: "search-ref-channel", creatorUserId: ownerId, type: "channel")
        accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "search-ref-channel", humanIds: [ownerId, speakerId], agentIds: [])
        ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    }

    func search(_ client: any Client, _ query: String) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(apiKey)"
        let response = try await client.get(URI(string: "/internal/agent/\(agentId)/search?\(query)"), headers: headers)
        return (response.status, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
    }

    func message(_ content: String, senderId: String, channelId: String? = nil, at: Date = Date().addingTimeInterval(-120)) -> String {
        let target = channelId ?? self.channelId
        let id = accounts.addHumanMessageForTesting(channelId: target, senderId: senderId, content: content)
        accounts.setMessageCreatedAtForTesting(messageId: id, at: at)
        return id
    }
}

@Test func managedSearchResolvesSenderHandlesAndAmbiguity() async throws {
    var fixture = SearchRefFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let speakerMessage = fixture.message("memberref speaker zebraneedle", senderId: fixture.speakerId)
    let ownerMessage = fixture.message("memberref owner zebraneedle", senderId: fixture.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let filtered = try await fixture.search(client, "q=zebraneedle&sender=@search-ref-speaker")
            #expect(filtered.status == .ok)
            let results = filtered.body["results"] as? [[String: Any]] ?? []
            #expect(results.compactMap { $0["id"] as? String } == [speakerMessage])
            #expect(results.first?["senderName"] as? String == "search-ref-speaker")
            #expect(results.first?["taskCurrentProjection"] == nil)
            _ = ownerMessage

            let invisible = try await fixture.search(client, "q=zebraneedle&sender=@search-ref-invisible")
            #expect(invisible.status == .notFound)
            #expect(invisible.body["errorCode"] as? String == "member_not_found")
            #expect((invisible.body["error"] as? String)?.contains("Member not found") == true)

            _ = accounts.oauth.createAgent(serverId: fixture.serverId, name: "search-ref-speaker", creatorUserId: fixture.ownerId, runtime: "codex")
            let ambiguous = try await fixture.search(client, "q=zebraneedle&sender=@search-ref-speaker")
            #expect(ambiguous.status == .conflict)
            #expect(ambiguous.body["errorCode"] as? String == "ambiguous_member_ref")
            #expect((ambiguous.body["error"] as? String)?.contains("ambiguous") == true)
        }
    }
}

@Test func managedSearchDateFiltersRequireOffsetsAndApplyAbsoluteInstants() async throws {
    var fixture = SearchRefFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let speakerMessage = fixture.message("zebraneedle dated", senderId: fixture.speakerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let missingOffset = try await fixture.search(client, "q=zebraneedle&after=2026-08-06T04:38:36")
            #expect(missingOffset.status == .badRequest)
            #expect(missingOffset.body["errorCode"] as? String == "INVALID_DATE_FILTER")
            let message = missingOffset.body["error"] as? String ?? ""
            #expect(message.lowercased().contains("missing a timezone offset"))
            #expect(message.contains("+08:00"))
            #expect(message.contains("raft CLI"))

            func ids(_ query: String) async throws -> [String] {
                let response = try await fixture.search(client, "q=zebraneedle&sender=@search-ref-speaker&sort=recent&\(query)")
                #expect(response.status == .ok)
                return (response.body["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            let created = try #require(accounts.messageCreatedAtForTesting(messageId: speakerMessage))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
            let before = formatter.string(from: created.addingTimeInterval(-60))
            let after = formatter.string(from: created.addingTimeInterval(60))
            let afterAtBefore = try await ids("after=\(before)")
            let afterAtAfter = try await ids("after=\(after)")
            let beforeAtAfter = try await ids("before=\(after)")
            let beforeAtBefore = try await ids("before=\(before)")
            #expect(afterAtBefore == [speakerMessage])
            #expect(afterAtAfter.isEmpty)
            #expect(beforeAtAfter == [speakerMessage])
            #expect(beforeAtBefore.isEmpty)
        }
    }
}

@Test func managedSearchProjectsThreadRepliesAndAmendedTaskHost() async throws {
    var fixture = SearchRefFixture()
    fixture.seed()
    let accounts = fixture.accounts
    let parent = fixture.message("thread parent without the regression token", senderId: fixture.ownerId)
    let threadId = accounts.oauth.createChannel(serverId: fixture.serverId, name: "thread", creatorUserId: fixture.ownerId, type: "joint")
    accounts.seedPostableChannelForTesting(serverId: fixture.serverId, channelId: threadId, name: "thread", humanIds: [fixture.ownerId], agentIds: [])
    accounts.addThreadChannel(serverId: fixture.serverId, threadChannelId: threadId, parentChannelId: fixture.channelId, parentMessageId: parent, memberId: fixture.ownerId)
    let firstReply = fixture.message("minimaxgrouping first reply", senderId: fixture.ownerId, channelId: threadId)
    let secondReply = fixture.message("minimaxgrouping second reply", senderId: fixture.ownerId, channelId: threadId)

    let host = fixture.message("supersessionneedle original premise", senderId: fixture.ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var humanHeaders = HTTPFields()
            humanHeaders[.authorization] = "Bearer \(fixture.ownerToken)"
            humanHeaders[.contentType] = "application/json"
            humanHeaders[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let converted = try await client.send(.post, headers: humanHeaders, to: URI(string: "/api/tasks/convert-message")) { request in
                request.body = .init(string: "{\"messageId\":\"\(host)\"}")
            }
            #expect(converted.status == .ok, Comment(rawValue: converted.body.string ?? ""))
            let convertedBody = (try? JSONSerialization.jsonObject(with: Data((converted.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let convertedTaskId = try #require((convertedBody["task"] as? [String: Any])?["id"] as? String)
            let taskNumber = try #require(accounts.taskNumberForTaskIdForTesting(taskId: convertedTaskId))
            accounts.amendTaskForTesting(taskId: convertedTaskId, title: "intermediate premise", description: "intermediate details", amendedByName: "search-ref-owner")
            accounts.amendTaskForTesting(taskId: convertedTaskId, title: "final current premise", description: "final current details", amendedByName: "search-ref-owner")
            _ = taskNumber
            _ = humanHeaders
            let threadHits = try await fixture.search(client, "q=minimaxgrouping&sort=recent")
            let rows = threadHits.body["results"] as? [[String: Any]] ?? []
            let replies = rows.filter { ($0["id"] as? String) == firstReply || ($0["id"] as? String) == secondReply }
            #expect(replies.count == 2)
            #expect(Set(replies.compactMap { $0["threadId"] as? String }) == [threadId])
            #expect(Set(replies.compactMap { $0["parentMessageId"] as? String }) == [parent])
            #expect(Set(replies.compactMap { $0["channelType"] as? String }) == ["thread"])
            #expect(Set(replies.compactMap { $0["channelId"] as? String }) == [threadId])
            #expect(replies.allSatisfy { ($0["parentMessageContent"] as? String) == "thread parent without the regression token" })

            let taskHits = try await fixture.search(client, "q=supersessionneedle")
            let hostHit = (taskHits.body["results"] as? [[String: Any]] ?? []).first { ($0["id"] as? String) == host }
            let projection = try #require(hostHit?["taskCurrentProjection"] as? [String: Any])
            #expect(projection["title"] as? String == "final current premise")
            #expect(projection["description"] as? String == "final current details")
            #expect(projection["superseded"] as? Bool == true)
            #expect(projection["source"] as? String == "tasks_current_projection")
        }
    }
}
