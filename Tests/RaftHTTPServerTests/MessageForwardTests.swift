import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct ForwardFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let sourceId: String
    let destinationId: String
    let ownerId: String
    let ownerEmail: String
}

private func makeForwardFixture(suffix: String) -> ForwardFixture {
    let accounts = EmailLoginDirectory()
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 990_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 990_000 + number)
    let ownerEmail = "forward-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "forward-\(suffix)", name: "Forward Server", ownerId: ownerId)
    let source = accounts.oauth.createChannel(serverId: serverId, name: "forward-source-\(suffix)", creatorUserId: ownerId)
    let destination = accounts.oauth.createChannel(serverId: serverId, name: "forward-destination-\(suffix)", creatorUserId: ownerId)
    for channel in [source, destination] {
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "forward-room-\(suffix)")
        accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    }
    return ForwardFixture(
        accounts: accounts,
        serverId: serverId,
        sourceId: source,
        destinationId: destination,
        ownerId: ownerId,
        ownerEmail: ownerEmail
    )
}

private func forwardLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func forwardHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func forwardObject(_ response: ClientResponse) throws -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

@Test func forwardStoresAnImmutableOrderedSnapshotAndReplaysIdempotently() async throws {
    let fixture = makeForwardFixture(suffix: "995")
    let attachment = fixture.accounts.addChannelAttachment(
        channelId: fixture.sourceId,
        uploaderId: fixture.ownerId,
        filename: "forward source.pdf",
        mimeType: "application/pdf",
        sizeBytes: 256
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await forwardLogin(client, email: fixture.ownerEmail)
            let headers = forwardHeaders(token, fixture.serverId)
            func send(_ content: String, attachments: [String] = []) async throws -> String {
                let ids = attachments.map { "\"\($0)\"" }.joined(separator: ",")
                let response = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                    request.body = .init(string: "{\"channelId\":\"\(fixture.sourceId)\",\"content\":\"\(content)\",\"attachmentIds\":[\(ids)]}")
                }
                #expect(response.status == .ok)
                return try #require(try forwardObject(response)["id"] as? String)
            }
            let first = try await send("first source snapshot", attachments: [attachment])
            let second = try await send("second source snapshot")
            fixture.accounts.setChannelMessageCreatedAtForTesting(id: first, createdAt: Date(timeIntervalSince1970: 1_784_244_000))
            fixture.accounts.setChannelMessageCreatedAtForTesting(id: second, createdAt: Date(timeIntervalSince1970: 1_784_200_000))

            let enabled = try await client.get("/api/messages/forward/enabled", headers: headers)
            #expect(enabled.status == .ok)
            #expect(try forwardObject(enabled)["enabled"] as? Bool == true)

            let randomId = "forward-test-995"
            let body = "{\"destinationChannelId\":\"\(fixture.destinationId)\",\"sourceMessageIds\":[\"\(second)\",\"\(first)\"],\"note\":\"forwarding context\",\"randomId\":\"\(randomId)\"}"
            let forwarded = try await client.send(.post, headers: headers, to: "/api/messages/forward") { request in
                request.body = .init(string: body)
            }
            #expect(forwarded.status == .ok)
            #expect(forwarded.headers[HTTPField.Name("X-Raft-Forward-Outcome")!] == "success")
            let forwardedBody = try forwardObject(forwarded)
            let messageId = try #require(forwardedBody["id"] as? String)
            #expect(forwardedBody["channelId"] as? String == fixture.destinationId)
            #expect(forwardedBody["content"] as? String == "forwarding context")
            let metadata = try #require(forwardedBody["actionMetadata"] as? [String: Any])
            #expect(metadata["kind"] as? String == "forwarded-bundle")
            #expect(metadata["forwardRequestFingerprint"] == nil)
            let items = metadata["forwardedItems"] as? [[String: Any]] ?? []
            #expect(items.map { $0["sourceMessageId"] as? String } == [second, first])
            #expect(items.map { $0["contentSnapshot"] as? String } == ["second source snapshot", "first source snapshot"])
            #expect(items.map { $0["sourceIsThreadParent"] as? Bool } == [false, false])
            let target = items[0]["sourceTargetSnapshot"] as? [String: Any]
            #expect(target?["label"] as? String == "#forward-room-995")
            #expect(target?["labelVisibility"] as? String == "public")
            #expect(items[0]["attachmentSnapshots"] as? [Any] != nil)
            #expect((items[0]["attachmentSnapshots"] as? [[String: Any]] ?? []).isEmpty)
            let snapshots = items[1]["attachmentSnapshots"] as? [[String: Any]] ?? []
            #expect(snapshots.count == 1)
            let snapshot = try #require(snapshots.first)
            #expect(snapshot["id"] as? String != attachment)
            #expect(snapshot["filename"] as? String == "forward source.pdf")
            #expect(snapshot["mimeType"] as? String == "application/pdf")
            #expect(snapshot["sizeBytes"] as? Int == 256)
            #expect(snapshot["width"] is NSNull)
            #expect(snapshot["height"] is NSNull)
            #expect(snapshot["url"] == nil)
            #expect(items[0]["attachmentPolicy"] as? String == "excluded")
            #expect(items[1]["attachmentPolicy"] as? String == "projected")

            let replay = try await client.send(.post, headers: headers, to: "/api/messages/forward") { request in
                request.body = .init(string: body)
            }
            #expect(replay.status == .ok)
            #expect(replay.headers[HTTPField.Name("X-Raft-Forward-Outcome")!] == "idempotent_replay")
            let replayBody = try forwardObject(replay)
            #expect(replayBody["id"] as? String == messageId)
            #expect((replayBody["actionMetadata"] as? [String: Any])
                .flatMap { $0["forwardedItems"] as? [[String: Any]] }?
                .last?["attachmentSnapshots"] as? NSArray == snapshots as NSArray)

            let conflict = try await client.send(.post, headers: headers, to: "/api/messages/forward") { request in
                request.body = .init(string: body.replacingOccurrences(of: "forwarding context", with: "different payload"))
            }
            #expect(conflict.status == .conflict)
            #expect(try forwardObject(conflict)["code"] as? String == "idempotency_conflict")
        }
    }
}

@Test func forwardBatchReportsPartialFailureAndRetriesIdempotently() async throws {
    let fixture = makeForwardFixture(suffix: "996")
    let destinationB = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "forward-b-996", creatorUserId: fixture.ownerId)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: destinationB, memberId: fixture.ownerId, name: "forward-b-996")
    fixture.accounts.oauth.addChannelHuman(channelId: destinationB, userId: fixture.ownerId)
    let denied = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "forward-denied-996", creatorUserId: fixture.ownerId, type: "private")
    // The owner is not a member of this private destination.
    let sourceMessage = fixture.accounts.addChannelMessageForTesting(channelId: fixture.sourceId, content: "batch source snapshot", senderId: fixture.ownerId)
    let requestId = "11111111-2222-4333-8444-555555555996"

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await forwardLogin(client, email: fixture.ownerEmail)
            let headers = forwardHeaders(token, fixture.serverId)
            func send(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/messages/forward") { request in
                    request.body = .init(string: body)
                }
            }
            let payload = "{\"destinationChannelIds\":[\"\(fixture.destinationId)\",\"\(destinationB)\",\"\(fixture.destinationId)\",\"\(denied)\"],\"sourceMessageIds\":[\"\(sourceMessage)\"],\"requestId\":\"\(requestId)\",\"note\":\"batch note\"}"
            let first = try await send(payload)
            #expect(first.status == .ok)
            #expect(first.headers[HTTPField.Name("X-Raft-Forward-Outcome")!] == "partial_failure")
            let results = try forwardObject(first)["results"] as? [[String: Any]] ?? []
            #expect(results.map { $0["destinationChannelId"] as? String } == [fixture.destinationId, destinationB, denied])
            #expect(results.map { $0["status"] as? String } == ["success", "success", "failed"])
            #expect(results[2]["code"] as? String == "destination_unavailable")
            #expect(results[2]["error"] as? String == "Could not forward to this target")
            let firstIds = results.prefix(2).compactMap { ($0["message"] as? [String: Any])?["id"] as? String }
            #expect(firstIds.count == 2)

            fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: denied, memberId: fixture.ownerId, kind: "private", name: "forward-denied-996")
            fixture.accounts.oauth.addChannelHuman(channelId: denied, userId: fixture.ownerId)
            let subset = try await send("{\"destinationChannelIds\":[\"\(denied)\"],\"sourceMessageIds\":[\"\(sourceMessage)\"],\"requestId\":\"\(requestId)\",\"note\":\"batch note\"}")
            #expect(subset.status == .ok)
            let subsetResults = try forwardObject(subset)["results"] as? [[String: Any]] ?? []
            #expect(subsetResults.map { $0["status"] as? String } == ["success"])
            let deniedId = (subsetResults[0]["message"] as? [String: Any])?["id"] as? String

            let retry = try await send(payload)
            #expect(retry.status == .ok)
            let retryResults = try forwardObject(retry)["results"] as? [[String: Any]] ?? []
            #expect(retryResults.compactMap { ($0["message"] as? [String: Any])?["id"] as? String } == firstIds + [deniedId].compactMap { $0 })

            let conflicting = try await send(payload.replacingOccurrences(of: "batch note", with: "different payload"))
            #expect(conflicting.status == .ok)
            let conflictingResults = try forwardObject(conflicting)["results"] as? [[String: Any]] ?? []
            #expect(conflictingResults.map { $0["status"] as? String } == ["failed", "failed", "failed"])
            #expect(conflictingResults.map { $0["code"] as? String } == ["request_conflict", "request_conflict", "request_conflict"])

            let missing = try await send("{\"destinationChannelIds\":[\"\(fixture.destinationId)\"],\"sourceMessageIds\":[\"\(sourceMessage)\"],\"note\":\"batch note\"}")
            #expect(missing.status == .badRequest)
            let tooMany = (0..<11).map { String(format: "aaaaaaaa-bbbb-4ccc-8ddd-%012d", $0) }
            let ids = tooMany.map { "\"\($0)\"" }.joined(separator: ",")
            let overflow = try await send("{\"destinationChannelIds\":[\(ids)],\"sourceMessageIds\":[\"\(sourceMessage)\"],\"requestId\":\"\(requestId)\",\"note\":\"batch note\"}")
            #expect(overflow.status == .badRequest)
        }
    }
}

@Test func forwardSupportsThreadSourcesThroughParentAuthority() async throws {
    let fixture = makeForwardFixture(suffix: "997")
    let parentChannel = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "forward-thread-parent-997", creatorUserId: fixture.ownerId)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: parentChannel, memberId: fixture.ownerId, name: "forward-thread-parent-997")
    fixture.accounts.oauth.addChannelHuman(channelId: parentChannel, userId: fixture.ownerId)
    let parent = fixture.accounts.addChannelMessageForTesting(channelId: parentChannel, content: "thread source parent", senderId: fixture.ownerId)
    let thread = fixture.accounts.oauth.createThreadChannel(parentChannelId: parentChannel, parentMessageId: parent)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: thread, memberId: fixture.ownerId, kind: "thread", parentChannelId: parentChannel, parentMessageId: parent, name: "thread")
    let first = fixture.accounts.addChannelMessageForTesting(channelId: thread, content: "first thread snapshot", senderId: fixture.ownerId)
    let second = fixture.accounts.addChannelMessageForTesting(channelId: thread, content: "second thread snapshot", senderId: fixture.ownerId)
    fixture.accounts.setChannelMessageCreatedAtForTesting(id: parent, createdAt: Date(timeIntervalSince1970: 1_784_245_800))
    fixture.accounts.setChannelMessageCreatedAtForTesting(id: first, createdAt: Date(timeIntervalSince1970: 1_784_245_200))
    fixture.accounts.setChannelMessageCreatedAtForTesting(id: second, createdAt: Date(timeIntervalSince1970: 1_784_244_600))
    let sibling = fixture.accounts.addChannelMessageForTesting(channelId: parentChannel, content: "unrelated parent-channel body", senderId: fixture.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let token = try await forwardLogin(client, email: fixture.ownerEmail)
            let headers = forwardHeaders(token, fixture.serverId)
            func forward(_ ids: [String]) async throws -> ClientResponse {
                let list = ids.map { "\"\($0)\"" }.joined(separator: ",")
                return try await client.send(.post, headers: headers, to: "/api/messages/forward") { request in
                    request.body = .init(string: "{\"destinationChannelId\":\"\(fixture.destinationId)\",\"sourceMessageIds\":[\(list)]}")
                }
            }
            func items(_ response: ClientResponse) throws -> [[String: Any]] {
                ((try forwardObject(response)["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
            }

            let replies = try await forward([second, first])
            #expect(replies.status == .ok)
            let replyItems = try items(replies)
            #expect(replyItems.map { $0["sourceMessageId"] as? String } == [second, first])
            #expect(replyItems.map { $0["contentSnapshot"] as? String } == ["second thread snapshot", "first thread snapshot"])
            #expect(replyItems.allSatisfy { $0["sourceTargetId"] as? String == thread })
            #expect(replyItems.allSatisfy { $0["sourceThreadId"] as? String == thread })
            #expect(replyItems.allSatisfy { $0["parentChannelId"] as? String == parentChannel })
            let replyTarget = replyItems[0]["sourceTargetSnapshot"] as? [String: Any]
            #expect(replyTarget?["type"] as? String == "thread")
            #expect(replyTarget?["label"] as? String == "#forward-thread-parent-997")
            #expect(replyTarget?["labelVisibility"] as? String == "public")

            let parentOnly = try await forward([parent])
            #expect(parentOnly.status == .ok)
            let parentItems = try items(parentOnly)
            #expect(parentItems.count == 1)
            #expect(parentItems[0]["sourceTargetId"] as? String == parentChannel)
            #expect(parentItems[0]["sourceThreadId"] == nil)
            #expect((parentItems[0]["sourceTargetSnapshot"] as? [String: Any])?["type"] as? String == "channel")

            let parentAndReply = try await forward([first, parent])
            #expect(parentAndReply.status == .ok)
            let combined = try items(parentAndReply)
            #expect(combined.map { $0["sourceMessageId"] as? String } == [parent, first])
            #expect(combined.map { $0["sourceIsThreadParent"] as? Bool } == [true, false])
            #expect(combined.allSatisfy { $0["sourceTargetId"] as? String == thread })

            let mixed = try await forward([sibling, first])
            #expect(mixed.status == .badRequest)
            #expect(try forwardObject(mixed) as NSDictionary == [
                "error": "Forwarded bundles must come from a single source",
                "code": "cross_source_bundle",
            ] as NSDictionary)
        }
    }
}
