import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
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

@Test func forwardScrubsPrivateProvenanceForDeniedViewers() async throws {
    let fixture = makeForwardFixture(suffix: "998")
    let viewerId = "11111111-1111-4111-8111-000000990998"
    let viewerEmail = "forward-viewer-998@slock.test"
    fixture.accounts.addAccount(id: viewerId, email: viewerEmail, password: "password123")
    fixture.accounts.markEmailVerified(userId: viewerId)
    fixture.accounts.oauth.addMember(serverId: fixture.serverId, userId: viewerId, role: "member")
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: fixture.destinationId, memberId: viewerId, name: "forward-destination-998")
    fixture.accounts.oauth.addChannelHuman(channelId: fixture.destinationId, userId: viewerId)
    let privateParent = fixture.accounts.oauth.createChannel(serverId: fixture.serverId, name: "forward-private-parent-998", creatorUserId: fixture.ownerId, type: "private")
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: privateParent, memberId: fixture.ownerId, kind: "private", name: "forward-private-parent-998")
    fixture.accounts.oauth.addChannelHuman(channelId: privateParent, userId: fixture.ownerId)
    let parent = fixture.accounts.addChannelMessageForTesting(channelId: privateParent, content: "private thread parent", senderId: fixture.ownerId)
    let thread = fixture.accounts.oauth.createThreadChannel(parentChannelId: privateParent, parentMessageId: parent)
    fixture.accounts.addPostableChannel(serverId: fixture.serverId, channelId: thread, memberId: fixture.ownerId, kind: "thread", parentChannelId: privateParent, parentMessageId: parent, name: "thread")
    let reply = fixture.accounts.addChannelMessageForTesting(channelId: thread, content: "private thread body", senderId: fixture.ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            let owner = try await forwardLogin(client, email: fixture.ownerEmail)
            let viewer = try await forwardLogin(client, email: viewerEmail)
            let created = try await client.send(.post, headers: forwardHeaders(owner, fixture.serverId), to: "/api/messages/forward") { request in
                request.body = .init(string: "{\"destinationChannelId\":\"\(fixture.destinationId)\",\"sourceMessageIds\":[\"\(reply)\"]}")
            }
            #expect(created.status == .ok)
            let createdBody = try forwardObject(created)
            let ownerItem = try #require(((createdBody["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]])?.first)
            #expect(ownerItem["sourceTargetId"] is NSNull)
            #expect(ownerItem["sourceThreadId"] == nil)
            #expect(ownerItem["parentChannelId"] == nil)
            #expect((ownerItem["sourceTargetSnapshot"] as? [String: Any])?["label"] as? String == "")
            #expect((ownerItem["sourceTargetSnapshot"] as? [String: Any])?["labelVisibility"] as? String == "restricted")

            let viewerList = try await client.get("/api/messages/channel/\(fixture.destinationId)", headers: forwardHeaders(viewer, fixture.serverId))
            #expect(viewerList.status == .ok)
            let forwardId = try #require(createdBody["id"] as? String)
            let rows = (try forwardObject(viewerList)["messages"] as? [[String: Any]] ?? [])
            let row = try #require(rows.first { $0["id"] as? String == forwardId })
            let viewerItem = try #require(((row["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]])?.first)
            #expect(viewerItem["sourceServerId"] is NSNull)
            #expect(viewerItem["sourceTargetId"] is NSNull)
            #expect(viewerItem["sourceThreadId"] is NSNull)
            #expect(viewerItem["parentChannelId"] is NSNull)
            #expect(viewerItem["sourceMessageId"] is NSNull)
            #expect((viewerItem["sourceTargetSnapshot"] as? [String: Any])?["id"] is NSNull)
            #expect((viewerItem["sourceTargetSnapshot"] as? [String: Any])?["label"] as? String == "")
            #expect((viewerItem["sourceTargetSnapshot"] as? [String: Any])?["labelVisibility"] as? String == "restricted")
            #expect(viewerItem["provenanceState"] as? String == "original_unavailable")
        }
    }
}

@Test func forwardRejectsShortIDsNonOrdinaryAndForwardedSources() async throws {
    let fixture = makeForwardFixture(suffix: "999")
    let systemMessage = fixture.accounts.addChannelMessageForTesting(
        channelId: fixture.sourceId,
        content: "system event",
        senderId: "system",
        senderType: "system",
        messageType: "system"
    )
    let ordinary = fixture.accounts.addChannelMessageForTesting(channelId: fixture.sourceId, content: "ordinary source", senderId: fixture.ownerId)
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
            func forward(_ ids: [String], note: String = "") async throws -> ClientResponse {
                let list = ids.map { "\"\($0)\"" }.joined(separator: ",")
                return try await client.send(.post, headers: headers, to: "/api/messages/forward") { request in
                    request.body = .init(string: "{\"destinationChannelId\":\"\(fixture.destinationId)\",\"sourceMessageIds\":[\(list)],\"note\":\"\(note)\"}")
                }
            }
            let short = try await forward([String(ordinary.prefix(8))])
            #expect(short.status == .badRequest)

            let system = try await forward([systemMessage])
            #expect(system.status == .badRequest)
            #expect(try forwardObject(system)["code"] as? String == "unsupported_source_message")

            let firstForward = try await forward([ordinary])
            #expect(firstForward.status == .ok)
            let forwardedMessageId = try #require(try forwardObject(firstForward)["id"] as? String)
            let nested = try await forward([forwardedMessageId], note: "nested")
            #expect(nested.status == .badRequest)
            #expect(try forwardObject(nested)["code"] as? String == "forwarded_source_not_supported")
        }
    }
}

@Test func forwardSupportsJointDestinationsAndJointSources() async throws {
    let accounts = EmailLoginDirectory()
    let hostId = "33333333-3333-4333-8333-000000991001"
    let guestId = "33333333-3333-4333-8333-000000991002"
    let hostOwner = "11111111-1111-4111-8111-000000991003"
    let guestOwner = "11111111-1111-4111-8111-000000991004"
    let dmPeer = "11111111-1111-4111-8111-000000991005"
    let hostEmail = "forward-joint-host-991@slock.test"
    let guestEmail = "forward-joint-guest-991@slock.test"
    for (id, email) in [(hostOwner, hostEmail), (guestOwner, guestEmail), (dmPeer, "forward-joint-dm-991@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: hostId, slug: "forward-joint-host-991", name: "Host", ownerId: hostOwner)
    accounts.oauth.addOwnedServer(id: guestId, slug: "forward-joint-guest-991", name: "Guest", ownerId: guestOwner)
    accounts.oauth.addMember(serverId: hostId, userId: dmPeer, role: "member")
    accounts.oauth.addMember(serverId: guestId, userId: hostOwner, role: "member")
    let source = accounts.oauth.createChannel(serverId: hostId, name: "forward-joint-source-991", creatorUserId: hostOwner)
    let destination = accounts.oauth.createChannel(serverId: hostId, name: "forward-joint-regular-991", creatorUserId: hostOwner)
    let guestDestination = accounts.oauth.createChannel(serverId: guestId, name: "forward-joint-guest-dest-991", creatorUserId: guestOwner)
    for (channel, server, member) in [(source, hostId, hostOwner), (destination, hostId, hostOwner), (guestDestination, guestId, guestOwner)] {
        accounts.addPostableChannel(serverId: server, channelId: channel, memberId: member, name: "forward-991")
        accounts.oauth.addChannelHuman(channelId: channel, userId: member)
    }
    let canonical = accounts.oauth.createChannel(serverId: hostId, name: "forward-joint-storage-991", creatorUserId: hostOwner)
    accounts.addPostableChannel(serverId: hostId, channelId: canonical, memberId: hostOwner, name: "forward-joint-storage-991")
    let hostProjection = accounts.oauth.createChannel(serverId: hostId, name: "forward-joint-room-991", creatorUserId: hostOwner, type: "joint")
    let guestProjection = accounts.oauth.createChannel(serverId: guestId, name: "forward-joint-room-991", creatorUserId: guestOwner, type: "joint")
    for (channel, server, member) in [(hostProjection, hostId, hostOwner), (guestProjection, guestId, guestOwner), (guestProjection, guestId, hostOwner)] {
        accounts.addPostableChannel(serverId: server, channelId: channel, memberId: member, kind: "joint", name: "forward-joint-room-991")
    }
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: canonical, serverId: hostId)
    accounts.addJointChannelProjection(localChannelId: guestProjection, canonicalChannelId: canonical, serverId: guestId)
    let publicMessage = accounts.addChannelMessageForTesting(channelId: source, content: "public source into joint", senderId: hostOwner)
    let jointMessage = accounts.addChannelMessageForTesting(channelId: canonical, content: "joint source stays restricted", senderId: hostOwner)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let host = try await forwardLogin(client, email: hostEmail)
            let guest = try await forwardLogin(client, email: guestEmail)
            func forward(_ token: String, _ server: String, destination: String, source: String) async throws -> ClientResponse {
                try await client.send(.post, headers: forwardHeaders(token, server), to: "/api/messages/forward") { request in
                    request.body = .init(string: "{\"destinationChannelId\":\"\(destination)\",\"sourceMessageIds\":[\"\(source)\"]}")
                }
            }
            let toJoint = try await forward(host, hostId, destination: hostProjection, source: publicMessage)
            #expect(toJoint.status == .ok)
            let toJointBody = try forwardObject(toJoint)
            #expect(toJointBody["channelId"] as? String == hostProjection)
            #expect((toJointBody["actionMetadata"] as? [String: Any])?["destinationTargetId"] as? String == hostProjection)
            let toJointItem = try #require(((toJointBody["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]])?.first)
            #expect(toJointItem["sourceMessageId"] as? String == publicMessage)
            #expect((toJointItem["sourceTargetSnapshot"] as? [String: Any])?["label"] as? String == "#forward-991")

            let guestList = try await client.get("/api/messages/channel/\(guestProjection)", headers: forwardHeaders(guest, guestId))
            #expect(guestList.status == .ok)
            let guestRows = try forwardObject(guestList)["messages"] as? [[String: Any]] ?? []
            let guestForward = try #require(guestRows.first { $0["id"] as? String == toJointBody["id"] as? String })
            let guestItem = try #require(((guestForward["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]])?.first)
            #expect(guestItem["sourceTargetId"] is NSNull)
            #expect((guestItem["sourceTargetSnapshot"] as? [String: Any])?["label"] as? String == "")
            #expect((guestItem["sourceTargetSnapshot"] as? [String: Any])?["labelVisibility"] as? String == "restricted")
            #expect(guestItem["provenanceState"] as? String == "original_unavailable")

            let fromJoint = try await forward(host, hostId, destination: destination, source: jointMessage)
            #expect(fromJoint.status == .ok)
            let fromJointBody = try forwardObject(fromJoint)
            #expect(fromJointBody["channelId"] as? String == destination)
            let jointItem = try #require(((fromJointBody["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]])?.first)
            #expect(jointItem["contentSnapshot"] as? String == "joint source stays restricted")
            #expect(jointItem["sourceMessageId"] is NSNull)
            #expect(jointItem["sourceTargetId"] is NSNull)
            #expect((jointItem["sourceTargetSnapshot"] as? [String: Any])?["type"] as? String == "joint")
            #expect((jointItem["sourceTargetSnapshot"] as? [String: Any])?["label"] as? String == "")
            #expect((jointItem["sourceTargetSnapshot"] as? [String: Any])?["labelVisibility"] as? String == "restricted")
            #expect(jointItem["provenanceState"] as? String == "available")

            let guestFromJoint = try await forward(guest, guestId, destination: guestDestination, source: jointMessage)
            #expect(guestFromJoint.status == .ok)
            #expect(try forwardObject(guestFromJoint)["channelId"] as? String == guestDestination)
        }
    }
}

@Test func forwardAcceptsEverySourceAndDestinationKind() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000992001"
    let ownerId = "11111111-1111-4111-8111-000000992002"
    let dmPeer = "11111111-1111-4111-8111-000000992003"
    let ownerEmail = "forward-matrix-992@slock.test"
    for (id, email) in [(ownerId, ownerEmail), (dmPeer, "forward-matrix-dm-992@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "forward-matrix-992", name: "Matrix", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: dmPeer, role: "member")

    func channel(_ name: String, _ kind: String) -> String {
        let id = accounts.oauth.createChannel(serverId: serverId, name: name, creatorUserId: ownerId, type: kind)
        accounts.addPostableChannel(serverId: serverId, channelId: id, memberId: ownerId, kind: kind, name: name)
        accounts.oauth.addChannelHuman(channelId: id, userId: ownerId)
        return id
    }
    let publicSource = channel("forward-joint-source", "channel")
    let privateSource = channel("forward-matrix-private-source", "private")
    let publicDestination = channel("forward-matrix-public-dest", "channel")
    let privateDestination = channel("forward-matrix-private-dest", "private")
    let dmSource = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: dmPeer)
    for member in [ownerId, dmPeer] {
        accounts.addPostableChannel(serverId: serverId, channelId: dmSource, memberId: member, kind: "dm", name: "dm")
    }
    let dmDestination = accounts.oauth.createDirectChannel(serverId: serverId, firstUserId: ownerId, secondUserId: dmPeer)
    for member in [ownerId, dmPeer] {
        accounts.addPostableChannel(serverId: serverId, channelId: dmDestination, memberId: member, kind: "dm", name: "dm")
    }
    let canonical = accounts.oauth.createChannel(serverId: serverId, name: "forward-matrix-storage", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: canonical, memberId: ownerId, name: "forward-matrix-storage")
    let jointDestination = accounts.oauth.createChannel(serverId: serverId, name: "forward-matrix-joint", creatorUserId: ownerId, type: "joint")
    accounts.addPostableChannel(serverId: serverId, channelId: jointDestination, memberId: ownerId, kind: "joint", name: "forward-matrix-joint")
    accounts.addJointChannelProjection(localChannelId: jointDestination, canonicalChannelId: canonical, serverId: serverId)

    let sources: [(type: String, message: String, content: String, visibility: String)] = [
        ("channel", accounts.addChannelMessageForTesting(channelId: publicSource, content: "public source into joint", senderId: ownerId), "public source into joint", "public"),
        ("private", accounts.addChannelMessageForTesting(channelId: privateSource, content: "private source into joint", senderId: ownerId), "private source into joint", "restricted"),
        ("dm", accounts.addChannelMessageForTesting(channelId: dmSource, content: "dm source stays restricted", senderId: ownerId), "dm source stays restricted", "restricted"),
        ("joint", accounts.addChannelMessageForTesting(channelId: canonical, content: "joint source stays restricted", senderId: ownerId), "joint source stays restricted", "restricted"),
    ]
    let destinations: [(type: String, channel: String)] = [
        ("channel", publicDestination),
        ("private", privateDestination),
        ("dm", dmDestination),
        ("joint", jointDestination),
    ]

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await forwardLogin(client, email: ownerEmail)
            var accepted: [String] = []
            for source in sources {
                for destination in destinations {
                    let response = try await client.send(.post, headers: forwardHeaders(token, serverId), to: "/api/messages/forward") { request in
                        request.body = .init(string: "{\"destinationChannelId\":\"\(destination.channel)\",\"sourceMessageIds\":[\"\(source.message)\"]}")
                    }
                    #expect(response.status == .ok)
                    let body = try forwardObject(response)
                    #expect(body["channelId"] as? String == destination.channel)
                    #expect((body["actionMetadata"] as? [String: Any])?["destinationTargetId"] as? String == destination.channel)
                    let item = try #require(((body["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]])?.first)
                    #expect(item["contentSnapshot"] as? String == source.content)
                    let target = try #require(item["sourceTargetSnapshot"] as? [String: Any])
                    #expect(target["type"] as? String == source.type)
                    #expect(target["labelVisibility"] as? String == source.visibility)
                    #expect(target["label"] as? String == (source.visibility == "public" ? "#forward-joint-source" : ""))
                    accepted.append("\(source.type)->\(destination.type)")
                }
            }
            #expect(accepted == [
                "channel->channel", "channel->private", "channel->dm", "channel->joint",
                "private->channel", "private->private", "private->dm", "private->joint",
                "dm->channel", "dm->private", "dm->dm", "dm->joint",
                "joint->channel", "joint->private", "joint->dm", "joint->joint",
            ])
        }
    }
}
