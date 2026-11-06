import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Synchronization
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func postJSON(
    _ client: any Client,
    path: String,
    body: String,
    authorization: String? = nil,
    serverId: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let authorization { headers[.authorization] = authorization }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func deleteJSON(
    _ client: any Client,
    path: String,
    body: String,
    authorization: String? = nil,
    serverId: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let authorization { headers[.authorization] = authorization }
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return try await client.send(.delete, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func postMessagesRejectsAnInvalidHumanBodyBeforeAnyWrite() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111111"
    let channelId = "22222222-2222-4222-8222-222222222222"
    let serverId = "33333333-3333-4333-8333-333333333333"
    accounts.addAccount(id: userId, email: "messages-body-boundary-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let bodies = [
        "{\"channelId\":{\"id\":\"\(channelId)\"},\"content\":\"object channelId must not reach resolve\"}",
        "{\"channelId\":\"\(channelId)\",\"content\":\"bad attachment element must not create message\",\"attachmentIds\":[\"not-a-uuid\"]}",
        "{\"channelId\":\"\(channelId)\",\"content\":\"string false must not silently create task\",\"asTask\":\"false\"}",
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-body-boundary-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sessions = accounts.sessionCount
            for body in bodies {
                let response = try await postJSON(
                    client,
                    path: "/api/messages",
                    body: body,
                    authorization: "Bearer \(token)",
                    serverId: serverId
                )
                #expect(response.status == .badRequest)
                let parsed = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                #expect(parsed?["error"] as? String == "Invalid message request body")
                #expect(accounts.humanMessageCount == 0)
                #expect(accounts.sessionCount == sessions)
                #expect(accounts.userCount == 1)
            }
        }
    }
}

@Test func postMessagesRejectsAnAppReferenceThatIsNotInstalled() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111112"
    let serverId = "33333333-3333-4333-8333-333333333334"
    let channelId = "22222222-2222-4222-8222-222222222223"
    let content = "run [@Missing](<app:custom.missing>)"
    accounts.addAccount(id: userId, email: "messages-app-ref-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId)
    accounts.allowComposerResourceReferencesForTesting(serverId: serverId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-app-ref-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let response = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(response.status == .badRequest)
            #expect(bodyText(response) == "{\"error\":\"App reference is not installed in this server\"}")
            #expect(accounts.humanMessageCount == 0)
        }
    }
}

@Test func postMessagesRejectsAnAppReferenceWhileTheServerGateIsDisabled() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111113"
    let serverId = "33333333-3333-4333-8333-333333333335"
    let channelId = "22222222-2222-4222-8222-222222222224"
    let content = "see [@Reminder](<app:system.reminder>)"
    accounts.addAccount(id: userId, email: "messages-resource-gate-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-resource-gate-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let response = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(response.status == .badRequest)
            #expect(bodyText(response) == "{\"error\":\"Computer and App references are not enabled in this server\"}")
            #expect(accounts.humanMessageCount == 0)
        }
    }
}

@Test func postMessagesRandomIdReplayStaysOnTheOriginalChannel() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111114"
    let serverId = "33333333-3333-4333-8333-333333333336"
    let privateChannel = "22222222-2222-4222-8222-222222222225"
    let publicChannel = "22222222-2222-4222-8222-222222222226"
    let randomId = "msg-scope-retry-001"
    let privateContent = "private retry payload must stay private"
    accounts.addAccount(id: userId, email: "messages-random-id-scope-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannel, memberId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-random-id-scope-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let first = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(privateChannel)\",\"content\":\"\(privateContent)\",\"randomId\":\"\(randomId)\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(first.status == .ok)
            #expect(accounts.humanMessageRandomIds(channelId: privateChannel) == [randomId])

            accounts.removeChannelMember(channelId: privateChannel, memberId: userId)
            let replay = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(publicChannel)\",\"content\":\"public request must not receive private replay\",\"randomId\":\"\(randomId)\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(replay.status == .conflict)
            let conflict = try JSONSerialization.jsonObject(with: Data(bodyText(replay).utf8)) as? [String: Any]
            #expect(conflict?["code"] as? String == "random_id_conflict")
            #expect(conflict?["error"] as? String == "randomId has already been used for a different message")
            #expect(bodyText(replay).contains(privateContent) == false)
            #expect(accounts.humanMessageRandomIds(channelId: publicChannel).isEmpty)
            #expect(accounts.humanMessageCount == 1)
        }
    }
}

@Test func postMessagesKeepsTheRequestedAttachmentOrder() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111115"
    let serverId = "33333333-3333-4333-8333-333333333337"
    let channelId = "22222222-2222-4222-8222-222222222227"
    accounts.addAccount(id: userId, email: "messages-attachment-order@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId)
    let uploadedFirst = accounts.addChannelAttachment(channelId: channelId, uploaderId: userId, filename: "uploaded-first-b.png")
    let uploadedSecond = accounts.addChannelAttachment(channelId: channelId, uploaderId: userId, filename: "uploaded-second-a.png")
    let requestedOrder = [uploadedSecond, uploadedFirst]
    let sendBody = "{\"channelId\":\"\(channelId)\",\"content\":\"attachment selection order\",\"randomId\":\"attachment-selection-order-replay\",\"attachmentIds\":[\"\(uploadedSecond)\",\"\(uploadedFirst)\"]}"
    let realtimeEvents = Mutex<[(room: String, name: String, payload: String?)]>([])
    accounts.realtimeEmitter = { room, name, payload in
        if name == "message:new" {
            realtimeEvents.withLock { $0.append((room, name, payload)) }
        }
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-attachment-order@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let send = try await postJSON(
                client,
                path: "/api/messages",
                body: sendBody,
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(send.status == .ok)
            let sent = try JSONSerialization.jsonObject(with: Data(bodyText(send).utf8)) as? [String: Any]
            let sentId = sent?["id"] as? String ?? ""
            let ackIds = (sent?["attachments"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            #expect(ackIds == requestedOrder)

            #expect(sentId.isEmpty == false)
            let emitted = realtimeEvents.withLock { $0 }
            #expect(emitted.count == 1)
            let realtime = try #require(emitted.first)
            #expect(realtime.room == "channel:\(channelId)")
            #expect(realtime.name == "message:new")
            let payload = try #require(realtime.payload)
            let decodedPayload = try JSONSerialization.jsonObject(with: Data(payload.utf8))
            let message = try #require(decodedPayload as? [String: Any])
            #expect(message["id"] as? String == sentId)
            #expect(message["channelId"] as? String == channelId)
            let realtimeAttachmentIds = (message["attachments"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            #expect(realtimeAttachmentIds == requestedOrder)

            let replay = try await postJSON(
                client,
                path: "/api/messages",
                body: sendBody,
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(replay.status == .ok)
            let replayed = try JSONSerialization.jsonObject(with: Data(bodyText(replay).utf8)) as? [String: Any]
            #expect(replayed?["id"] as? String == sentId)
            let replayAttachmentIds = (replayed?["attachments"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            #expect(replayAttachmentIds == requestedOrder)
            #expect(realtimeEvents.withLock { $0.count } == 1)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let list = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            #expect(list.status == .ok)
            let listed = try JSONSerialization.jsonObject(with: Data(bodyText(list).utf8)) as? [String: Any]
            let cold = (listed?["messages"] as? [[String: Any]])?.first { $0["id"] as? String == sentId }
            let coldIds = (cold?["attachments"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            #expect(coldIds == requestedOrder)
            #expect(accounts.linkedAttachmentPositions(ids: requestedOrder).map(\.id) == requestedOrder)
            #expect(accounts.linkedAttachmentPositions(ids: requestedOrder).map(\.messagePosition) == [0, 1])
        }
    }
}

@Test func postMessagesRandomIdReplayAcceptsOnlyTheIdenticalOrderedAttachmentSet() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111116"
    let serverId = "33333333-3333-4333-8333-333333333338"
    let channelId = "22222222-2222-4222-8222-222222222228"
    let randomId = "ordered-attachment-replay"
    accounts.addAccount(id: userId, email: "messages-attachment-replay@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId)
    let orderedIds = [
        accounts.addChannelAttachment(channelId: channelId, uploaderId: userId, filename: "first.png"),
        accounts.addChannelAttachment(channelId: channelId, uploaderId: userId, filename: "second.png"),
    ]
    func send(_ client: any Client, token: String, attachmentIds: [String], requestRandomId: String = randomId) async throws -> ClientResponse {
        let ids = attachmentIds.map { "\"\($0)\"" }.joined(separator: ",")
        return try await postJSON(
            client,
            path: "/api/messages",
            body: "{\"channelId\":\"\(channelId)\",\"content\":\"ordered attachment replay\",\"randomId\":\"\(requestRandomId)\",\"attachmentIds\":[\(ids)]}",
            authorization: "Bearer \(token)",
            serverId: serverId
        )
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-attachment-replay@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let first = try await send(client, token: token, attachmentIds: orderedIds)
            #expect(first.status == .ok)
            let firstBody = try JSONSerialization.jsonObject(with: Data(bodyText(first).utf8)) as? [String: Any]
            let firstId = firstBody?["id"] as? String ?? ""
            let firstAttachmentIds = (firstBody?["attachments"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            #expect(firstAttachmentIds == orderedIds)

            let identical = try await send(client, token: token, attachmentIds: orderedIds)
            #expect(identical.status == .ok)
            let replayBody = try JSONSerialization.jsonObject(with: Data(bodyText(identical).utf8)) as? [String: Any]
            let replayAttachmentIds = (replayBody?["attachments"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            #expect(replayBody?["id"] as? String == firstId)
            #expect(replayAttachmentIds == orderedIds)

            let reordered = try await send(client, token: token, attachmentIds: orderedIds.reversed())
            #expect(reordered.status == .badRequest)
            let reorderedBody = try JSONSerialization.jsonObject(with: Data(bodyText(reordered).utf8)) as? [String: Any]
            #expect(reorderedBody?["code"] as? String == "attachment_replay_conflict")
            #expect(reorderedBody?["error"] as? String == "This idempotent send was already committed with a different ordered attachment set.")

            let reused = try await send(client, token: token, attachmentIds: orderedIds, requestRandomId: "ordered-attachment-replay-other")
            #expect(reused.status == .badRequest)
            let reusedBody = try JSONSerialization.jsonObject(with: Data(bodyText(reused).utf8)) as? [String: Any]
            #expect(reusedBody?["code"] as? String == "attachment_already_linked")
            #expect(reusedBody?["error"] as? String == "Attachment \(orderedIds[0]) is already attached to another message. Re-upload the file and send the new attachment ID.")

            #expect(accounts.humanMessageIds(channelId: channelId) == [firstId])
            let persisted = accounts.linkedAttachmentRecords(ids: orderedIds)
            #expect(persisted.map(\.id) == orderedIds)
            #expect(persisted.map { $0.messageId ?? "" } == [firstId, firstId])
            #expect(persisted.map(\.messagePosition) == [0, 1])
        }
    }
}

@Test func postMessagesRollsBackTheMessageForDuplicateMissingOrForeignAttachmentSets() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111117"
    let otherId = "11111111-1111-4111-8111-111111111118"
    let serverId = "33333333-3333-4333-8333-333333333339"
    let channelId = "22222222-2222-4222-8222-222222222229"
    let missingId = "99999999-9999-4999-8999-999999999999"
    accounts.addAccount(id: ownerId, email: "messages-attachment-rollback@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "messages-attachment-rollback-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    let validId = accounts.addChannelAttachment(channelId: channelId, uploaderId: ownerId, filename: "valid.png")
    let foreignId = accounts.addChannelAttachment(channelId: channelId, uploaderId: otherId, filename: "foreign.png")
    let cases: [(ids: [String], code: String, error: String)] = [
        (
            [validId, validId],
            "attachment_duplicate",
            "Attachment \(validId) was requested more than once. Send each attachment ID exactly once."
        ),
        (
            [validId, missingId],
            "attachment_not_found",
            "Attachment \(missingId) is not available for this sender. Re-upload the file and send the new attachment ID."
        ),
        (
            [validId, foreignId],
            "attachment_not_found",
            "Attachment \(foreignId) is not available for this sender. Re-upload the file and send the new attachment ID."
        ),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-attachment-rollback@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            for (index, testCase) in cases.enumerated() {
                let ids = testCase.ids.map { "\"\($0)\"" }.joined(separator: ",")
                let response = try await postJSON(
                    client,
                    path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"attachment rollback \(index)\",\"attachmentIds\":[\(ids)]}",
                    authorization: "Bearer \(token)",
                    serverId: serverId
                )
                #expect(response.status == .badRequest)
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                #expect(body?["code"] as? String == testCase.code)
                #expect(body?["error"] as? String == testCase.error)
                #expect(accounts.humanMessageIds(channelId: channelId).isEmpty)
                #expect(accounts.humanMessageCount == 0)
            }
            let stillUnlinked = accounts.linkedAttachmentRecords(ids: [validId, foreignId])
            #expect(stillUnlinked.map(\.messageId) == [nil, nil])
            #expect(stillUnlinked.map(\.messagePosition) == [nil, nil])
        }
    }
}

@Test func postMessagesAcceptsRandomIdValuesThatMatchInternalSentinelText() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111119"
    let serverId = "33333333-3333-4333-8333-33333333333a"
    let channelId = "22222222-2222-4222-8222-22222222222a"
    accounts.addAccount(id: userId, email: "messages-random-id-sentinel@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-random-id-sentinel@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let response = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"literal sentinel random id\",\"randomId\":\"invalid\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(response.status == .ok)
            let message = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            #expect(message?["randomId"] as? String == "invalid")
            #expect(accounts.humanMessageRandomIds(channelId: channelId) == ["invalid"])
        }
    }
}

@Test func messageReactionsAddIdempotentlyEnrichMessagesAndRemoveCleanly() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111120"
    let serverId = "33333333-3333-4333-8333-333333333340"
    let channelId = "22222222-2222-4222-8222-222222222230"
    accounts.addAccount(id: userId, email: "reaction-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"reaction-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"reactable message\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""

            let first = try await postJSON(
                client,
                path: "/api/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👍\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(first.status == .ok)
            let firstReactions = ((try JSONSerialization.jsonObject(with: Data(bodyText(first).utf8)) as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
            let firstReaction = firstReactions.first
            #expect(firstReactions.count == 1)
            #expect(firstReaction?["emoji"] as? String == "👍")
            #expect((firstReaction?["count"] as? NSNumber)?.intValue == 1)
            #expect(firstReaction?["reactorIds"] as? [String] == [userId])
            #expect(firstReaction?["reactorNames"] as? [String] == ["reaction-owner"])

            let second = try await postJSON(
                client,
                path: "/api/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👍\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(second.status == .ok)
            let secondReactions = ((try JSONSerialization.jsonObject(with: Data(bodyText(second).utf8)) as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
            let thumbs = secondReactions.first { $0["emoji"] as? String == "👍" }
            #expect((thumbs?["count"] as? NSNumber)?.intValue == 1)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let list = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            #expect(list.status == .ok)
            let listed = try JSONSerialization.jsonObject(with: Data(bodyText(list).utf8)) as? [String: Any]
            let row = (listed?["messages"] as? [[String: Any]])?.first { $0["id"] as? String == messageId }
            let listedReactions = row?["reactions"] as? [[String: Any]] ?? []
            #expect((listedReactions.first?["count"] as? NSNumber)?.intValue == 1)

            let removed = try await deleteJSON(
                client,
                path: "/api/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👍\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(removed.status == .ok)
            let removedReactions = ((try JSONSerialization.jsonObject(with: Data(bodyText(removed).utf8)) as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
            #expect(removedReactions.isEmpty)
            #expect(accounts.storedMessageReactions(messageId: messageId).isEmpty)
        }
    }
}

@Test func postMessagesRejectsChannelIdsOutsideTheActiveServer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111121"
    let serverA = "33333333-3333-4333-8333-333333333341"
    let serverB = "33333333-3333-4333-8333-333333333342"
    let channelB = "22222222-2222-4222-8222-222222222231"
    let content = "cross-server send should not land"
    accounts.addAccount(id: ownerId, email: "messages-cross-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverB, channelId: channelB, memberId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-cross-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let response = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelB)\",\"content\":\"\(content)\"}",
                authorization: "Bearer \(token)",
                serverId: serverA
            )
            #expect(response.status == .notFound)
            #expect(accounts.humanMessageIds(channelId: channelB).isEmpty)
            #expect(accounts.humanMessageCount == 0)
            #expect(bodyText(response).contains(content) == false)
        }
    }
}

@Test func postMessagesReturnsSenderOnlyPendingMentionActions() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111122"
    let humanId = "11111111-1111-4111-8111-111111111123"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let serverId = "33333333-3333-4333-8333-333333333343"
    let channelId = "22222222-2222-4222-8222-222222222232"
    let agentName = "UserRouteMentionOutsider"
    let humanName = "messagesMentionHuman"
    let agentAvatar = "pixel:random:UserRouteMentionOutsider"
    accounts.addAccount(id: ownerId, email: "messages-mention-actions-owner@slock.test", password: "password123")
    accounts.addAccount(id: humanId, email: "messages-mention-actions-human@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: agentName, avatarUrl: agentAvatar)
    let content = "please coordinate with @\(agentName) and @\(humanName)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-mention-actions-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\",\"mentions\":[{\"type\":\"agent\",\"id\":\"\(agentId)\",\"name\":\"\(agentName)\"},{\"type\":\"user\",\"id\":\"\(humanId)\",\"name\":\"\(humanName)\"}]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let message = body?["message"] as? [String: Any]
            let messageId = message?["id"] as? String ?? ""
            #expect(message?["channelId"] as? String == channelId)
            #expect(message?["pendingMentionActions"] == nil)
            #expect(String(data: try JSONSerialization.data(withJSONObject: message ?? [:]), encoding: .utf8)?.contains("pendingMentionActions") == false)
            let actions = body?["pendingMentionActions"] as? [[String: Any]] ?? []
            #expect(actions.count == 2)
            let agent = actions.first { $0["targetType"] as? String == "agent" }
            let human = actions.first { $0["targetType"] as? String == "user" }
            #expect(agent?["messageId"] as? String == messageId)
            #expect(agent?["targetHandle"] as? String == agentName)
            #expect(agent?["targetAvatarUrl"] as? String == agentAvatar)
            #expect(agent?["reason"] as? String == "not_member")
            #expect(agent?["availableActions"] as? [String] == ["notify", "add"])
            #expect(human?["messageId"] as? String == messageId)
            #expect(human?["targetHandle"] as? String == humanName)
            #expect((human?["targetAvatarUrl"] as? NSNull) != nil)
            #expect(human?["reason"] as? String == "not_member")
            #expect(human?["availableActions"] as? [String] == ["notify", "add"])
            let uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
            let instant = /^\d{4}-\d{2}-\d{2}T/
            for action in actions {
                #expect((action["resolutionId"] as? String)?.wholeMatch(of: uuid) != nil)
                #expect((action["expiresAt"] as? String)?.firstMatch(of: instant) != nil)
            }

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let list = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            #expect(list.status == .ok)
            let listed = try JSONSerialization.jsonObject(with: Data(bodyText(list).utf8)) as? [String: Any]
            let row = (listed?["messages"] as? [[String: Any]])?.first { $0["id"] as? String == messageId }
            #expect(row?.keys.contains("pendingMentionActions") == false)
        }
    }
}

@Test func postMessagesKeepsPublicChannelNonMemberMentionsOutOfSendTimeDelivery() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111124"
    let humanId = "11111111-1111-4111-8111-111111111125"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab"
    let serverId = "33333333-3333-4333-8333-333333333344"
    let channelId = "22222222-2222-4222-8222-222222222233"
    let agentName = "UserRouteMentionDeliveryOutsider"
    let humanName = "messagesMentionDeliveryHuman"
    accounts.addAccount(id: ownerId, email: "messages-mention-delivery-owner@slock.test", password: "password123")
    accounts.addAccount(id: humanId, email: "messages-mention-delivery-human@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: agentName, avatarUrl: "pixel:random:UserRouteMentionDeliveryOutsider")
    let apiKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["mentions"], name: "messages-mention-delivery-outsider-mentions")
    let content = "please coordinate with @\(agentName) and @\(humanName)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-mention-delivery-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\",\"mentions\":[{\"type\":\"agent\",\"id\":\"\(agentId)\",\"name\":\"\(agentName)\"},{\"type\":\"user\",\"id\":\"\(humanId)\",\"name\":\"\(humanName)\"}]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sentBody = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let messageId = (sentBody?["message"] as? [String: Any])?["id"] as? String ?? sentBody?["id"] as? String ?? ""
            #expect(messageId.isEmpty == false)

            let rows = accounts.messageMentionRows(messageId: messageId).sorted { $0.targetType < $1.targetType }
            #expect(rows.map(\.targetType) == ["agent", "user"])
            #expect(rows.map(\.targetId) == [agentId, humanId])
            #expect(rows.map(\.notifiableAtSend) == [false, false])
            #expect(rows.map(\.notified) == [false, false])
            #expect(accounts.inboxFacts(messageId: messageId, receiverIds: [agentId, humanId]).isEmpty)
            #expect(accounts.agentDeliveries(agentId: agentId).isEmpty)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(apiKey)"
            let mentions = try await client.get(URI(string: "/internal/agent-api/mentions"), headers: headers)
            #expect(mentions.status == .ok)
            let mentionBody = try JSONSerialization.jsonObject(with: Data(bodyText(mentions).utf8)) as? [String: Any]
            let visible = (mentionBody?["mentions"] as? [[String: Any]])?.compactMap { $0["messageId"] as? String } ?? []
            #expect(visible.isEmpty)
        }
    }
}

@Test func postMessagesAllowsInertOutsiderMentionsInDMsWithoutNotifyOrInboxDelivery() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111126"
    let peerId = "11111111-1111-4111-8111-111111111127"
    let outsiderId = "11111111-1111-4111-8111-111111111128"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaac"
    let serverId = "33333333-3333-4333-8333-333333333345"
    let dmId = "22222222-2222-4222-8222-222222222234"
    let humanName = "messagesDmMentionOutsider"
    let agentName = "MessagesDmMentionAgent"
    accounts.addAccount(id: ownerId, email: "messages-dm-mention-owner@slock.test", password: "password123")
    accounts.addAccount(id: peerId, email: "messages-dm-mention-peer@slock.test", password: "password123")
    accounts.addAccount(id: outsiderId, email: "messages-dm-mention-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addDirectMessage(serverId: serverId, channelId: dmId, participantIds: [ownerId, peerId])
    accounts.addServerAgent(serverId: serverId, id: agentId, name: agentName, avatarUrl: nil)
    let apiKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["mentions"], name: "messages-dm-mention-agent-mentions")
    let content = "quiet reference @\(humanName) and @\(agentName)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-dm-mention-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(ownerLogin.status == .ok)
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let outsiderLogin = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-dm-mention-outsider@slock.test\",\"password\":\"password123\"}"
            )
            #expect(outsiderLogin.status == .ok)
            let outsiderToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(outsiderLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(dmId)\",\"content\":\"\(content)\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(outsiderId)\",\"name\":\"\(humanName)\"},{\"type\":\"agent\",\"id\":\"\(agentId)\",\"name\":\"\(agentName)\"}]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let messageId = body?["id"] as? String ?? ""
            #expect(messageId.isEmpty == false)
            #expect(body?["message"] == nil)
            #expect((body?["pendingMentionActions"] as? [Any])?.isEmpty != false)
            #expect((body?["mentions"] as? [Any])?.isEmpty != false)

            let rows = accounts.messageMentionRows(messageId: messageId).sorted { $0.targetType < $1.targetType }
            #expect(rows.map(\.targetType) == ["agent", "user"])
            #expect(rows.map(\.targetId) == [agentId, outsiderId])
            #expect(rows.map(\.notifiableAtSend) == [false, false])
            #expect(rows.map(\.notified) == [false, false])

            var inboxHeaders = HTTPFields()
            inboxHeaders[.authorization] = "Bearer \(outsiderToken)"
            inboxHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let inbox = try await client.get(URI(string: "/api/channels/inbox?filter=mentions"), headers: inboxHeaders)
            #expect(inbox.status == .ok)
            let inboxBody = try JSONSerialization.jsonObject(with: Data(bodyText(inbox).utf8)) as? [String: Any]
            let items = inboxBody?["items"] as? [[String: Any]] ?? []
            #expect(items.contains { ($0["channelId"] as? String) == dmId || ($0["lastMessageId"] as? String) == messageId } == false)

            var agentHeaders = HTTPFields()
            agentHeaders[.authorization] = "Bearer \(apiKey)"
            let agentMentions = try await client.get(URI(string: "/internal/agent-api/mentions"), headers: agentHeaders)
            #expect(agentMentions.status == .ok)
            let agentBody = try JSONSerialization.jsonObject(with: Data(bodyText(agentMentions).utf8)) as? [String: Any]
            let visible = (agentBody?["mentions"] as? [[String: Any]])?.compactMap { $0["messageId"] as? String } ?? []
            #expect(visible.isEmpty)
        }
    }
}

@Test func postV2MessagesSurfacesStoppedAgentDmDeliveryWarningsWithoutFailingTheSend() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111129"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaad"
    let serverId = "33333333-3333-4333-8333-333333333346"
    let dmId = "22222222-2222-4222-8222-222222222235"
    let content = "hello stopped agent"
    accounts.addAccount(id: ownerId, email: "messages-stopped-agent-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "MessagesStoppedAgent", avatarUrl: nil, status: "stopped")
    accounts.addDirectMessage(serverId: serverId, channelId: dmId, participantIds: [ownerId], agentId: agentId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-stopped-agent-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/v2/messages",
                body: "{\"channelId\":\"\(dmId)\",\"content\":\"\(content)\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let message = body?["message"] as? [String: Any]
            let messageId = message?["id"] as? String ?? ""
            #expect(message?["content"] as? String == content)
            #expect(messageId.isEmpty == false)
            let warnings = body?["deliveryWarnings"] as? [[String: Any]] ?? []
            #expect(warnings.count == 1)
            #expect(warnings.first?["targetType"] as? String == "agent")
            #expect(warnings.first?["targetId"] as? String == agentId)
            #expect(warnings.first?["reason"] as? String == "agent_stopped")
            #expect(accounts.agentDeliveries(agentId: agentId) == [messageId])
            #expect(accounts.agentDeliveryChannelTypes(agentId: agentId) == ["dm"])
        }
    }
}

@Test func mentionActionNotifyStaysWithTheSenderAndDoesNotAddTheAgent() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111112a"
    let otherId = "11111111-1111-4111-8111-11111111112b"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaae"
    let serverId = "33333333-3333-4333-8333-333333333347"
    let channelId = "22222222-2222-4222-8222-222222222236"
    let agentName = "UserRouteExecuteOutsider"
    accounts.addAccount(id: ownerId, email: "messages-actions-execute-owner@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "messages-actions-execute-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: otherId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: agentName, avatarUrl: nil)
    let content = "loop in @\(agentName)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-actions-execute-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(ownerLogin.status == .ok)
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let otherLogin = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-actions-execute-other@slock.test\",\"password\":\"password123\"}"
            )
            #expect(otherLogin.status == .ok)
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\",\"mentions\":[{\"type\":\"agent\",\"id\":\"\(agentId)\",\"name\":\"\(agentName)\"}]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sentBody = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let actions = sentBody?["pendingMentionActions"] as? [[String: Any]] ?? []
            let resolutionId = actions.first?["resolutionId"] as? String ?? ""
            #expect(resolutionId.isEmpty == false)

            let otherExecute = try await postJSON(
                client,
                path: "/api/messages/mention-actions/execute",
                body: "{\"action\":\"notify\",\"resolutionIds\":[\"\(resolutionId)\"]}",
                authorization: "Bearer \(otherToken)",
                serverId: serverId
            )
            #expect(otherExecute.status == .ok)
            let otherBody = try JSONSerialization.jsonObject(with: Data(bodyText(otherExecute).utf8)) as? [String: Any]
            let otherResults = otherBody?["results"] as? [[String: Any]] ?? []
            #expect(otherResults.first?["status"] as? String == "not_found")
            #expect(accounts.mentionActionRecord(id: resolutionId)?.notified == false)
            #expect(accounts.channelAgentIds(channelId: channelId).isEmpty)

            let notify = try await postJSON(
                client,
                path: "/api/messages/mention-actions/execute",
                body: "{\"action\":\"notify\",\"resolutionIds\":[\"\(resolutionId)\"]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(notify.status == .ok)
            let notifyBody = try JSONSerialization.jsonObject(with: Data(bodyText(notify).utf8)) as? [String: Any]
            let notifyResults = notifyBody?["results"] as? [[String: Any]] ?? []
            #expect(notifyResults.first?["status"] as? String == "queued")
            #expect(notifyResults.first?["dedupedResolutionIds"] as? [String] == [resolutionId])
            let recorded = accounts.mentionActionRecord(id: resolutionId)
            #expect(recorded?.notified == true)
            #expect(recorded?.notifiedByType == "user")
            #expect(recorded?.notifiedById == ownerId)
            #expect(recorded?.notifiedAction == "notify_only")
            #expect(accounts.channelAgentIds(channelId: channelId).isEmpty)
        }
    }
}

@Test func mentionActionAddJoinsTheTargetAndDeliversTheOriginalMessage() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111112c"
    let humanId = "11111111-1111-4111-8111-11111111112d"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaf"
    let serverId = "33333333-3333-4333-8333-333333333348"
    let channelId = "22222222-2222-4222-8222-222222222237"
    let agentName = "UserRouteAddTarget"
    let humanName = "messagesActionsAddHuman"
    accounts.addAccount(id: ownerId, email: "messages-actions-add-owner@slock.test", password: "password123")
    accounts.addAccount(id: humanId, email: "messages-actions-add-human@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: agentName, avatarUrl: nil)
    let apiKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["mentions"], name: "messages-actions-add-mentions")
    let content = "loop in @\(agentName) and @\(humanName)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-actions-add-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\",\"mentions\":[{\"type\":\"agent\",\"id\":\"\(agentId)\",\"name\":\"\(agentName)\"},{\"type\":\"user\",\"id\":\"\(humanId)\",\"name\":\"\(humanName)\"}]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sentBody = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let messageId = (sentBody?["message"] as? [String: Any])?["id"] as? String ?? ""
            let actions = sentBody?["pendingMentionActions"] as? [[String: Any]] ?? []
            let agentResolution = actions.first { $0["targetType"] as? String == "agent" }?["resolutionId"] as? String ?? ""
            let humanResolution = actions.first { $0["targetType"] as? String == "user" }?["resolutionId"] as? String ?? ""
            #expect(messageId.isEmpty == false)
            #expect(agentResolution.isEmpty == false)
            #expect(humanResolution.isEmpty == false)

            let added = try await postJSON(
                client,
                path: "/api/messages/mention-actions/execute",
                body: "{\"action\":\"add\",\"resolutionIds\":[\"\(agentResolution)\",\"\(humanResolution)\"]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(added.status == .ok)
            let addedBody = try JSONSerialization.jsonObject(with: Data(bodyText(added).utf8)) as? [String: Any]
            let results = addedBody?["results"] as? [[String: Any]] ?? []
            #expect(results.map { $0["status"] as? String } == ["delivered", "delivered"])
            #expect(results.allSatisfy { $0["reason"] == nil })
            #expect(results.map { $0["dedupedResolutionIds"] as? [String] } == [[agentResolution], [humanResolution]])
            for resolution in [agentResolution, humanResolution] {
                let recorded = accounts.mentionActionRecord(id: resolution)
                #expect(recorded?.notified == true)
                #expect(recorded?.notifiedAction == "add")
                #expect(recorded?.notifiedByType == "user")
                #expect(recorded?.notifiedById == ownerId)
            }
            #expect(accounts.channelAgentIds(channelId: channelId) == [agentId])
            #expect(accounts.channelMemberIds(channelId: channelId).contains(humanId))
            #expect(accounts.agentDeliveries(agentId: agentId) == [messageId])

            var mentionHeaders = HTTPFields()
            mentionHeaders[.authorization] = "Bearer \(apiKey)"
            let mentions = try await client.get(URI(string: "/internal/agent-api/mentions"), headers: mentionHeaders)
            #expect(mentions.status == .ok)
            let mentionBody = try JSONSerialization.jsonObject(with: Data(bodyText(mentions).utf8)) as? [String: Any]
            let visible = (mentionBody?["mentions"] as? [[String: Any]])?.compactMap { $0["messageId"] as? String } ?? []
            #expect(visible == [messageId])

            let replay = try await postJSON(
                client,
                path: "/api/messages/mention-actions/execute",
                body: "{\"action\":\"add\",\"resolutionIds\":[\"\(agentResolution)\"]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(replay.status == .ok)
            let replayBody = try JSONSerialization.jsonObject(with: Data(bodyText(replay).utf8)) as? [String: Any]
            let replayResults = replayBody?["results"] as? [[String: Any]] ?? []
            #expect(replayResults.first?["status"] as? String == "delivered")
            #expect(replayResults.first?["reason"] as? String == "already_delivered")
            #expect(accounts.agentDeliveries(agentId: agentId) == [messageId])
        }
    }
}

@Test func humanNotifyExposesTheOriginalMentionOnTheChannelList() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111112e"
    let humanId = "11111111-1111-4111-8111-11111111112f"
    let serverId = "33333333-3333-4333-8333-333333333349"
    let channelId = "22222222-2222-4222-8222-222222222238"
    let humanName = "messagesActionsHuman"
    accounts.addAccount(id: ownerId, email: "messages-actions-notify-owner@slock.test", password: "password123")
    accounts.addAccount(id: humanId, email: "messages-actions-notify-human@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    let content = "loop in @\(humanName)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-actions-notify-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(ownerLogin.status == .ok)
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let humanLogin = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-actions-notify-human@slock.test\",\"password\":\"password123\"}"
            )
            #expect(humanLogin.status == .ok)
            let humanToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(humanLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\",\"mentions\":[{\"type\":\"user\",\"id\":\"\(humanId)\",\"name\":\"\(humanName)\"}]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sentBody = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let messageId = (sentBody?["message"] as? [String: Any])?["id"] as? String ?? ""
            let resolutionId = (sentBody?["pendingMentionActions"] as? [[String: Any]])?.first?["resolutionId"] as? String ?? ""
            #expect(messageId.isEmpty == false)
            #expect(resolutionId.isEmpty == false)

            let notify = try await postJSON(
                client,
                path: "/api/messages/mention-actions/execute",
                body: "{\"action\":\"notify\",\"resolutionIds\":[\"\(resolutionId)\"]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(notify.status == .ok)
            let notifyBody = try JSONSerialization.jsonObject(with: Data(bodyText(notify).utf8)) as? [String: Any]
            let notifyResults = notifyBody?["results"] as? [[String: Any]] ?? []
            #expect(notifyResults.first?["status"] as? String == "queued")
            #expect(notifyResults.first?["dedupedResolutionIds"] as? [String] == [resolutionId])
            let recorded = accounts.mentionActionRecord(id: resolutionId)
            #expect(recorded?.notified == true)
            #expect(recorded?.notifiedAction == "notify_only")
            #expect(recorded?.notifiedByType == "user")
            #expect(recorded?.notifiedById == ownerId)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(humanToken)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let list = try await client.get(URI(string: "/api/messages/channel/\(channelId)"), headers: headers)
            #expect(list.status == .ok)
            let listed = try JSONSerialization.jsonObject(with: Data(bodyText(list).utf8)) as? [String: Any]
            let row = (listed?["messages"] as? [[String: Any]])?.first { $0["id"] as? String == messageId }
            let mentions = row?["mentions"] as? [[String: Any]] ?? []
            #expect(mentions.count == 1)
            #expect(mentions.first?["type"] as? String == "user")
            #expect(mentions.first?["id"] as? String == humanId)
            #expect(mentions.first?["name"] as? String == humanName)
        }
    }
}

@Test func privateSurfaceMentionNotifyRefusesATargetWhoCannotRead() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111130"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab0"
    let serverId = "33333333-3333-4333-8333-33333333334a"
    let privateChannel = "22222222-2222-4222-8222-222222222239"
    let threadChannel = "22222222-2222-4222-8222-22222222223a"
    let agentName = "UserRouteClosedOutsider"
    accounts.addAccount(id: ownerId, email: "messages-actions-closed-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannel, memberId: ownerId, kind: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: threadChannel, memberId: ownerId, kind: "thread", parentChannelId: privateChannel)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: agentName, avatarUrl: nil)
    func notify(_ client: any Client, token: String, channelId: String, content: String) async throws -> (status: String?, reason: String?, resolutionId: String) {
        let sent = try await postJSON(
            client,
            path: "/api/messages",
            body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\",\"mentions\":[{\"type\":\"agent\",\"id\":\"\(agentId)\",\"name\":\"\(agentName)\"}]}",
            authorization: "Bearer \(token)",
            serverId: serverId
        )
        #expect(sent.status == .ok)
        let sentBody = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
        let resolutionId = (sentBody?["pendingMentionActions"] as? [[String: Any]])?.first?["resolutionId"] as? String ?? ""
        #expect(resolutionId.isEmpty == false)
        let response = try await postJSON(
            client,
            path: "/api/messages/mention-actions/execute",
            body: "{\"action\":\"notify\",\"resolutionIds\":[\"\(resolutionId)\"]}",
            authorization: "Bearer \(token)",
            serverId: serverId
        )
        #expect(response.status == .ok)
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        let result = (body?["results"] as? [[String: Any]])?.first
        return (result?["status"] as? String, result?["reason"] as? String, resolutionId)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-actions-closed-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let channelNotify = try await notify(client, token: token, channelId: privateChannel, content: "private mention")
            #expect(channelNotify.status == "no_permission")
            #expect(channelNotify.reason == "target_lacks_read_access")
            #expect(accounts.mentionActionRecord(id: channelNotify.resolutionId)?.notified == false)
            #expect(accounts.channelAgentIds(channelId: privateChannel).isEmpty)
            #expect(accounts.agentDeliveries(agentId: agentId).isEmpty)

            let threadNotify = try await notify(client, token: token, channelId: threadChannel, content: "private thread mention")
            #expect(threadNotify.status == "no_permission")
            #expect(threadNotify.reason == "target_lacks_read_access")
            #expect(accounts.mentionActionRecord(id: threadNotify.resolutionId)?.notified == false)
            #expect(accounts.channelAgentIds(channelId: threadChannel).isEmpty)
            #expect(accounts.agentDeliveries(agentId: agentId).isEmpty)
        }
    }
}

@Test func removedSenderCannotAddThroughAMentionAction() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111131"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab1"
    let serverId = "33333333-3333-4333-8333-33333333334b"
    let channelId = "22222222-2222-4222-8222-22222222223b"
    let agentName = "UserRouteClosedOutsider"
    accounts.addAccount(id: ownerId, email: "messages-actions-removed-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: agentName, avatarUrl: nil)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"messages-actions-removed-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"public mention\",\"mentions\":[{\"type\":\"agent\",\"id\":\"\(agentId)\",\"name\":\"\(agentName)\"}]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sentBody = try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any]
            let resolutionId = (sentBody?["pendingMentionActions"] as? [[String: Any]])?.first?["resolutionId"] as? String ?? ""
            #expect(resolutionId.isEmpty == false)
            accounts.removeChannelMember(channelId: channelId, memberId: ownerId)
            let added = try await postJSON(
                client,
                path: "/api/messages/mention-actions/execute",
                body: "{\"action\":\"add\",\"resolutionIds\":[\"\(resolutionId)\"]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(added.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(added).utf8)) as? [String: Any]
            let result = (body?["results"] as? [[String: Any]])?.first
            #expect(result?["status"] as? String == "no_permission")
            #expect(result?["reason"] as? String == "sender_lacks_channel_access")
            #expect(accounts.mentionActionRecord(id: resolutionId)?.notified == false)
            #expect(accounts.channelAgentIds(channelId: channelId).isEmpty)
            #expect(accounts.agentDeliveries(agentId: agentId).isEmpty)
        }
    }
}

@Test func agentReactionsAggregateWithHumanReactions() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111133"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab2"
    let serverId = "33333333-3333-4333-8333-33333333334d"
    let channelId = "22222222-2222-4222-8222-22222222223d"
    accounts.addAccount(id: ownerId, email: "agent-reaction-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "reaction-agent", avatarUrl: nil)
    accounts.addChannelAgent(channelId: channelId, agentId: agentId)
    let machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agentId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"agent-reaction-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"agent reactable message\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let agentPath = "/internal/agent/\(agentId)/messages/\(messageId)/reactions"

            let first = try await postJSON(client, path: agentPath, body: "{\"emoji\":\"👀\"}", authorization: "Bearer \(machineKey)")
            #expect(first.status == .ok)
            let firstReactions = ((try JSONSerialization.jsonObject(with: Data(bodyText(first).utf8)) as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
            #expect(firstReactions.count == 1)
            #expect(firstReactions.first?["emoji"] as? String == "👀")
            #expect((firstReactions.first?["count"] as? NSNumber)?.intValue == 1)
            #expect(firstReactions.first?["reactorIds"] as? [String] == [agentId])
            #expect(firstReactions.first?["reactorNames"] as? [String] == ["reaction-agent"])

            let second = try await postJSON(client, path: agentPath, body: "{\"emoji\":\"👀\"}", authorization: "Bearer \(machineKey)")
            #expect(second.status == .ok)
            let secondReactions = ((try JSONSerialization.jsonObject(with: Data(bodyText(second).utf8)) as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
            let secondEyes = secondReactions.first { $0["emoji"] as? String == "👀" }
            #expect((secondEyes?["count"] as? NSNumber)?.intValue == 1)

            let human = try await postJSON(
                client,
                path: "/api/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👀\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(human.status == .ok)
            let humanReactions = ((try JSONSerialization.jsonObject(with: Data(bodyText(human).utf8)) as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
            let combined = humanReactions.first { $0["emoji"] as? String == "👀" }
            #expect((combined?["count"] as? NSNumber)?.intValue == 2)
            #expect(Set(combined?["reactorIds"] as? [String] ?? []) == Set([agentId, ownerId]))
            let actors = accounts.storedMessageReactionActors(messageId: messageId)
            #expect(actors.contains { $0.reactorType == "agent" && $0.reactorId == agentId })
            #expect(actors.contains { $0.reactorType == "user" && $0.reactorId == ownerId })

            let removed = try await deleteJSON(client, path: agentPath, body: "{\"emoji\":\"👀\"}", authorization: "Bearer \(machineKey)")
            #expect(removed.status == .ok)
            let removedReactions = ((try JSONSerialization.jsonObject(with: Data(bodyText(removed).utf8)) as? [String: Any])?["reactions"] as? [[String: Any]]) ?? []
            let after = removedReactions.first { $0["emoji"] as? String == "👀" }
            #expect((after?["count"] as? NSNumber)?.intValue == 1)
            #expect(after?["reactorIds"] as? [String] == [ownerId])
        }
    }
}

@Test func messageReactionsRejectSystemMessagesAndArchivedChannels() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111134"
    let nonMemberId = "11111111-1111-4111-8111-111111111135"
    let serverId = "33333333-3333-4333-8333-33333333334e"
    let channelId = "22222222-2222-4222-8222-22222222223e"
    accounts.addAccount(id: ownerId, email: "reaction-guard-owner@slock.test", password: "password123")
    accounts.addAccount(id: nonMemberId, email: "reaction-guard-non-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: nonMemberId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    func react(_ client: any Client, method: String, messageId: String, token: String) async throws -> ClientResponse {
        let path = "/api/messages/\(messageId)/reactions"
        let body = "{\"emoji\":\"👍\"}"
        if method == "DELETE" {
            return try await deleteJSON(client, path: path, body: body, authorization: "Bearer \(token)", serverId: serverId)
        }
        return try await postJSON(client, path: path, body: body, authorization: "Bearer \(token)", serverId: serverId)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-guard-owner@slock.test\",\"password\":\"password123\"}")
            #expect(ownerLogin.status == .ok)
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let otherLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-guard-non-member@slock.test\",\"password\":\"password123\"}")
            #expect(otherLogin.status == .ok)
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let systemSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"system event\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(systemSent.status == .ok)
            let systemId = ((try JSONSerialization.jsonObject(with: Data(bodyText(systemSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.markMessageSystem(messageId: systemId)
            let systemReaction = try await react(client, method: "POST", messageId: systemId, token: ownerToken)
            #expect(systemReaction.status == .badRequest)
            let systemBody = try JSONSerialization.jsonObject(with: Data(bodyText(systemReaction).utf8)) as? [String: Any]
            #expect((systemBody?["error"] as? String)?.contains("System messages") == true)

            let chatSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"archived message\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(chatSent.status == .ok)
            let chatId = ((try JSONSerialization.jsonObject(with: Data(bodyText(chatSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            #expect((try await react(client, method: "POST", messageId: chatId, token: otherToken)).status == .forbidden)
            #expect((try await react(client, method: "DELETE", messageId: chatId, token: otherToken)).status == .forbidden)

            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: nonMemberId)
            let ownSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"former member's own message\"}",
                authorization: "Bearer \(otherToken)",
                serverId: serverId
            )
            #expect(ownSent.status == .ok)
            let ownId = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.removeChannelMember(channelId: channelId, memberId: nonMemberId)
            #expect((try await react(client, method: "POST", messageId: ownId, token: otherToken)).status == .forbidden)
            #expect((try await react(client, method: "DELETE", messageId: ownId, token: otherToken)).status == .forbidden)
            let leftover = accounts.storedMessageReactionActors(messageId: chatId) + accounts.storedMessageReactionActors(messageId: ownId)
            #expect(leftover.contains { $0.reactorType == "user" && $0.reactorId == nonMemberId } == false)

            accounts.archiveChannel(channelId: channelId)
            let archived = try await react(client, method: "POST", messageId: chatId, token: ownerToken)
            #expect(archived.status == .conflict)
            let archivedBody = try JSONSerialization.jsonObject(with: Data(bodyText(archived).utf8)) as? [String: Any]
            #expect(archivedBody?["code"] as? String == "channel_archived")

            accounts.markChannelDeleted(channelId: channelId)
            #expect((try await react(client, method: "POST", messageId: chatId, token: ownerToken)).status == .notFound)
            #expect((try await react(client, method: "DELETE", messageId: chatId, token: ownerToken)).status == .notFound)
        }
    }
}

@Test func reactionUpdateSocketOmitsStorageColumnsAndScrubsForwardedSources() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111132"
    let serverId = "33333333-3333-4333-8333-33333333334c"
    let channelId = "22222222-2222-4222-8222-22222222223c"
    let content = "reactable socket message"
    accounts.addAccount(id: userId, email: "reaction-socket-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"reaction-socket-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.setForwardedBundle(messageId: messageId, items: [
                ForwardedSource(
                    sourceServerId: serverId,
                    sourceTargetId: channelId,
                    sourceMessageId: "source-message",
                    snapshotId: channelId,
                    snapshotType: "channel",
                    snapshotLabel: "#reaction-socket-channel",
                    snapshotLabelVisibility: "public",
                    provenanceState: "available"
                ),
            ])
            let reaction = try await postJSON(
                client,
                path: "/api/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👍\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(reaction.status == .ok)
            let response = try JSONSerialization.jsonObject(with: Data(bodyText(reaction).utf8)) as? [String: Any]
            let responseItems = ((response?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
            let responseSnapshot = responseItems.first?["sourceTargetSnapshot"] as? [String: Any]
            #expect(responseSnapshot?["label"] as? String == "#reaction-socket-channel")
        }
    }
}

@Test func messageReactionsCloakPrivateMessageExistenceFromNonMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111136"
    let outsiderId = "11111111-1111-4111-8111-111111111137"
    let serverId = "33333333-3333-4333-8333-33333333334f"
    let privateChannelId = "22222222-2222-4222-8222-22222222223f"
    let publicChannelId = "22222222-2222-4222-8222-222222222240"
    let hiddenOneId = "dddddddd-1111-4111-8111-111111111111"
    let hiddenTwoId = "dddddddd-2222-4222-8222-222222222222"
    let visibleId = "dddddddd-3333-4333-8333-333333333333"
    accounts.addAccount(id: ownerId, email: "private-reaction-owner@slock.test", password: "password123")
    accounts.addAccount(id: outsiderId, email: "private-reaction-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: outsiderId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private")
    func react(_ client: any Client, method: String, messageId: String, token: String, emoji: String) async throws -> ClientResponse {
        let path = "/api/messages/\(messageId)/reactions"
        let body = "{\"emoji\":\"\(emoji)\"}"
        if method == "DELETE" {
            return try await deleteJSON(client, path: path, body: body, authorization: "Bearer \(token)", serverId: serverId)
        }
        return try await postJSON(client, path: path, body: body, authorization: "Bearer \(token)", serverId: serverId)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"private-reaction-owner@slock.test\",\"password\":\"password123\"}")
            #expect(ownerLogin.status == .ok)
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let outsiderLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"private-reaction-outsider@slock.test\",\"password\":\"password123\"}")
            #expect(outsiderLogin.status == .ok)
            let outsiderToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(outsiderLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let chatSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(privateChannelId)\",\"content\":\"private reactable message\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(chatSent.status == .ok)
            let chatId = ((try JSONSerialization.jsonObject(with: Data(bodyText(chatSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let systemSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(privateChannelId)\",\"content\":\"private system event\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(systemSent.status == .ok)
            let systemId = ((try JSONSerialization.jsonObject(with: Data(bodyText(systemSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.markMessageSystem(messageId: systemId)

            #expect((try await react(client, method: "POST", messageId: chatId, token: outsiderToken, emoji: "👍")).status == .notFound)
            #expect((try await react(client, method: "DELETE", messageId: chatId, token: outsiderToken, emoji: "👍")).status == .notFound)
            #expect((try await react(client, method: "POST", messageId: systemId, token: outsiderToken, emoji: "👍")).status == .notFound)

            accounts.insertHumanMessage(id: hiddenOneId, channelId: privateChannelId, senderId: ownerId, content: "private user reaction collision one")
            accounts.insertHumanMessage(id: hiddenTwoId, channelId: privateChannelId, senderId: ownerId, content: "private user reaction collision two")
            #expect((try await react(client, method: "POST", messageId: "dddddddd", token: outsiderToken, emoji: "👍")).status == .notFound)

            accounts.addPostableChannel(serverId: serverId, channelId: publicChannelId, memberId: outsiderId)
            accounts.insertHumanMessage(id: visibleId, channelId: publicChannelId, senderId: ownerId, content: "public user reaction collision")
            let visible = try await react(client, method: "POST", messageId: "dddddddd", token: outsiderToken, emoji: "👀")
            #expect(visible.status == .ok)
            let persisted = accounts.storedMessageReactionActors(messageId: visibleId)
            #expect(persisted.count == 1)
            #expect(persisted.first?.reactorId == outsiderId)
        }
    }
}

@Test func reactionViewerAckAndUserRoomEventShareOneVersionedSnapshot() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111138"
    let serverId = "33333333-3333-4333-8333-333333333350"
    let channelId = "22222222-2222-4222-8222-222222222241"
    accounts.addAccount(id: ownerId, email: "reaction-viewer-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    func viewerFields(_ object: [String: Any]?) -> (serverId: String, messageId: String, version: Int, emojis: [String]) {
        let version = (object?["viewerVersion"] as? NSNumber)?.intValue ?? -1
        let emojis = object?["reactedEmojis"] as? [String] ?? []
        return (object?["serverId"] as? String ?? "", object?["messageId"] as? String ?? "", version, emojis)
    }
    func react(_ client: any Client, method: String, messageId: String, token: String, emoji: String) async throws -> [String: Any] {
        let path = "/api/messages/\(messageId)/reactions"
        let body = "{\"emoji\":\"\(emoji)\"}"
        let response: ClientResponse
        if method == "DELETE" {
            response = try await deleteJSON(client, path: path, body: body, authorization: "Bearer \(token)", serverId: serverId)
        } else {
            response = try await postJSON(client, path: path, body: body, authorization: "Bearer \(token)", serverId: serverId)
        }
        #expect(response.status == .ok)
        return (try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]) ?? [:]
    }
    let viewerEvents = ReactionViewerEventCollector()
    accounts.realtimeEmitter = { room, event, payload in
        viewerEvents.append(room: room, event: event, payload: payload)
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-viewer-owner@slock.test\",\"password\":\"password123\"}")
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"reaction viewer snapshot\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""

            let first = try await react(client, method: "POST", messageId: messageId, token: token, emoji: "👍")
            let firstViewer = viewerFields(first["reactionViewer"] as? [String: Any])
            #expect(firstViewer.serverId == serverId)
            #expect(firstViewer.messageId == messageId)
            #expect(firstViewer.version == 1)
            #expect(firstViewer.emojis == ["👍"])
            let firstEvent = viewerEvents.events.last { $0.room == "user:\(ownerId)" && $0.event == "reaction_viewer:updated" }
            let firstEventBody = try JSONSerialization.jsonObject(with: Data((firstEvent?.payload ?? "").utf8)) as? [String: Any]
            #expect(viewerFields(firstEventBody) == firstViewer)

            let idempotentAdd = try await react(client, method: "POST", messageId: messageId, token: token, emoji: "👍")
            #expect(viewerFields(idempotentAdd["reactionViewer"] as? [String: Any]) == firstViewer)

            let second = try await react(client, method: "POST", messageId: messageId, token: token, emoji: "👀")
            let secondViewer = viewerFields(second["reactionViewer"] as? [String: Any])
            #expect(secondViewer.version == 2)
            #expect(secondViewer.emojis == ["👀", "👍"])

            let canonical = try await react(client, method: "POST", messageId: messageId, token: token, emoji: "❤️")
            let canonicalViewer = viewerFields(canonical["reactionViewer"] as? [String: Any])
            #expect(canonicalViewer.serverId == serverId)
            #expect(canonicalViewer.messageId == messageId)
            #expect(canonicalViewer.version == 3)
            #expect(canonicalViewer.emojis == ["❤️", "👀", "👍"])
            let canonicalEvent = viewerEvents.events.last { $0.room == "user:\(ownerId)" && $0.event == "reaction_viewer:updated" }
            let canonicalEventBody = try JSONSerialization.jsonObject(with: Data((canonicalEvent?.payload ?? "").utf8)) as? [String: Any]
            #expect(viewerFields(canonicalEventBody) == canonicalViewer)

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let hydrate = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/\(messageId)/reactions/viewer"))
            #expect(hydrate.status == .ok)
            let hydrateBody = try JSONSerialization.jsonObject(with: Data(bodyText(hydrate).utf8)) as? [String: Any]
            #expect(viewerFields(hydrateBody) == canonicalViewer)

            let removed = try await react(client, method: "DELETE", messageId: messageId, token: token, emoji: "👍")
            let removedViewer = viewerFields(removed["reactionViewer"] as? [String: Any])
            #expect(removedViewer.version == 4)
            #expect(removedViewer.emojis == ["❤️", "👀"])
            let idempotentRemove = try await react(client, method: "DELETE", messageId: messageId, token: token, emoji: "👍")
            #expect(viewerFields(idempotentRemove["reactionViewer"] as? [String: Any]) == removedViewer)
        }
    }
}

@Test func reactionActorPagesBindCursorsAndStaleAfterAgentMutations() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111139"
    let memberId = "11111111-1111-4111-8111-11111111113a"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab3"
    let serverId = "33333333-3333-4333-8333-333333333351"
    let channelId = "22222222-2222-4222-8222-222222222242"
    accounts.addAccount(id: ownerId, email: "reaction-page-owner@slock.test", password: "password123")
    accounts.addAccount(id: memberId, email: "reaction-page-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: memberId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "reaction-page-agent", avatarUrl: nil)
    accounts.addChannelAgent(channelId: channelId, agentId: agentId)
    let machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agentId)
    func actors(_ client: any Client, messageId: String, token: String, emoji: String, limit: Int? = nil, cursor: String? = nil) async throws -> ClientResponse {
        var parts = ["emoji=\(emoji.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? emoji)"]
        if let limit { parts.append("limit=\(limit)") }
        if let cursor {
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            parts.append("cursor=\(encoded)")
        }
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/\(messageId)/reactions/actors?\(parts.joined(separator: "&"))"))
    }
    func jsonBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        return (value as? NSNumber)?.boolValue ?? false
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-page-owner@slock.test\",\"password\":\"password123\"}")
            let memberLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-page-member@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let memberToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(memberLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"reaction page target\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let other = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"reaction page other target\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            let otherId = ((try JSONSerialization.jsonObject(with: Data(bodyText(other).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            for token in [ownerToken, memberToken] {
                let added = try await postJSON(
                    client,
                    path: "/api/messages/\(messageId)/reactions",
                    body: "{\"emoji\":\"👀\"}",
                    authorization: "Bearer \(token)",
                    serverId: serverId
                )
                #expect(added.status == .ok)
            }

            let firstPage = try await actors(client, messageId: messageId, token: ownerToken, emoji: "👀", limit: 1)
            #expect(firstPage.status == .ok)
            let firstBody = try JSONSerialization.jsonObject(with: Data(bodyText(firstPage).utf8)) as? [String: Any]
            #expect((firstBody?["discussionVersion"] as? NSNumber)?.intValue == 2)
            let firstActors = firstBody?["actors"] as? [[String: Any]] ?? []
            #expect(firstActors.count == 1)
            #expect((firstActors.first?["actorRef"] as? [String: Any])?["kind"] as? String == "user")
            let firstCursor = firstBody?["nextCursor"] as? String ?? ""
            #expect(firstCursor.isEmpty == false)

            let principalReplay = try await actors(client, messageId: messageId, token: memberToken, emoji: "👀", cursor: firstCursor)
            #expect(principalReplay.status == .badRequest)
            let principalBody = try JSONSerialization.jsonObject(with: Data(bodyText(principalReplay).utf8)) as? [String: Any]
            #expect(principalBody?["code"] as? String == "invalid_reaction_actors_cursor")
            #expect((try await actors(client, messageId: otherId, token: ownerToken, emoji: "👀", cursor: firstCursor)).status == .badRequest)
            #expect((try await actors(client, messageId: messageId, token: ownerToken, emoji: "👍", cursor: firstCursor)).status == .badRequest)

            let agentAdd = try await postJSON(
                client,
                path: "/internal/agent/\(agentId)/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👀\"}",
                authorization: "Bearer \(machineKey)"
            )
            #expect(agentAdd.status == .ok)
            let stale = try await actors(client, messageId: messageId, token: ownerToken, emoji: "👀", cursor: firstCursor)
            #expect(stale.status == .conflict)
            let staleBody = try JSONSerialization.jsonObject(with: Data(bodyText(stale).utf8)) as? [String: Any]
            #expect(staleBody?["error"] as? String == "Reaction discussion changed while reading this page")
            #expect(staleBody?["code"] as? String == "reaction_discussion_version_changed")
            #expect((staleBody?["currentDiscussionVersion"] as? NSNumber)?.intValue == 3)
            #expect(jsonBool(staleBody?["rebaselineRequired"]) == true)

            let postLegacy = try await actors(client, messageId: messageId, token: ownerToken, emoji: "👀", limit: 1)
            #expect(postLegacy.status == .ok)
            let postLegacyCursor = ((try JSONSerialization.jsonObject(with: Data(bodyText(postLegacy).utf8)) as? [String: Any])?["nextCursor"] as? String) ?? ""
            #expect(postLegacyCursor.isEmpty == false)

            let agentKey = accounts.mintAgentCredential(agentId: agentId, scopes: ["reactions"], name: "reaction-page-agent-api")
            let agentRemove = try await deleteJSON(
                client,
                path: "/internal/agent-api/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👀\"}",
                authorization: "Bearer \(agentKey)"
            )
            #expect(agentRemove.status == .ok)
            let agentStale = try await actors(client, messageId: messageId, token: ownerToken, emoji: "👀", cursor: postLegacyCursor)
            #expect(agentStale.status == .conflict)
            let agentStaleBody = try JSONSerialization.jsonObject(with: Data(bodyText(agentStale).utf8)) as? [String: Any]
            #expect(agentStaleBody?["error"] as? String == "Reaction discussion changed while reading this page")
            #expect(agentStaleBody?["code"] as? String == "reaction_discussion_version_changed")
            #expect((agentStaleBody?["currentDiscussionVersion"] as? NSNumber)?.intValue == 4)
            #expect(jsonBool(agentStaleBody?["rebaselineRequired"]) == true)

            let agentRestore = try await postJSON(
                client,
                path: "/internal/agent-api/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👀\"}",
                authorization: "Bearer \(agentKey)"
            )
            #expect(agentRestore.status == .ok)
            let fresh = try await actors(client, messageId: messageId, token: ownerToken, emoji: "👀", limit: 100)
            #expect(fresh.status == .ok)
            let freshBody = try JSONSerialization.jsonObject(with: Data(bodyText(fresh).utf8)) as? [String: Any]
            #expect((freshBody?["discussionVersion"] as? NSNumber)?.intValue == 5)
            let refs = Set((freshBody?["actors"] as? [[String: Any]] ?? []).compactMap { actor -> String? in
                guard let ref = actor["actorRef"] as? [String: Any],
                      let kind = ref["kind"] as? String,
                      let id = ref["id"] as? String else { return nil }
                return "\(kind):\(id)"
            })
            #expect(refs == Set(["user:\(ownerId)", "user:\(memberId)", "agent:\(agentId)"]))
        }
    }
}

@Test func reactionActorPagesHideHumansOnAllAndKeepAgentsVisible() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111113b"
    let memberId = "11111111-1111-4111-8111-11111111113c"
    let otherId = "11111111-1111-4111-8111-11111111113d"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab4"
    let serverId = "33333333-3333-4333-8333-333333333352"
    let channelId = "22222222-2222-4222-8222-222222222243"
    accounts.addAccount(id: ownerId, email: "reaction-directory-owner@slock.test", password: "password123")
    accounts.addAccount(id: memberId, email: "reaction-directory-member@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "reaction-directory-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: memberId)
    accounts.markEmailVerified(userId: otherId)
    accounts.setServerMemberRole(serverId: serverId, userId: ownerId, role: "owner")
    accounts.setServerMemberRole(serverId: serverId, userId: memberId, role: "member")
    accounts.setServerMemberRole(serverId: serverId, userId: otherId, role: "member")
    accounts.setHideHumansFromMembers(serverId: serverId, hidden: true)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "all")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: memberId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: otherId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "reaction-directory-agent", avatarUrl: nil)
    accounts.addChannelAgent(channelId: channelId, agentId: agentId)
    let machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agentId)
    func actors(_ client: any Client, token: String, messageId: String, limit: Int? = nil, cursor: String? = nil) async throws -> ClientResponse {
        var parts = ["emoji=\("👀".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "👀")"]
        if let limit { parts.append("limit=\(limit)") }
        if let cursor {
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            parts.append("cursor=\(encoded)")
        }
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/\(messageId)/reactions/actors?\(parts.joined(separator: "&"))"))
    }
    func refs(from response: ClientResponse) throws -> [String] {
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        return (body?["actors"] as? [[String: Any]] ?? []).compactMap { actor in
            guard let ref = actor["actorRef"] as? [String: Any],
                  let kind = ref["kind"] as? String,
                  let id = ref["id"] as? String else { return nil }
            return "\(kind):\(id)"
        }
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(for email: String) async throws -> String {
                let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                #expect(login.status == .ok)
                return ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            }
            let ownerToken = try await token(for: "reaction-directory-owner@slock.test")
            let memberToken = try await token(for: "reaction-directory-member@slock.test")
            let otherToken = try await token(for: "reaction-directory-other@slock.test")
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"hidden directory reaction target\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            for userToken in [ownerToken, memberToken, otherToken] {
                let added = try await postJSON(
                    client,
                    path: "/api/messages/\(messageId)/reactions",
                    body: "{\"emoji\":\"👀\"}",
                    authorization: "Bearer \(userToken)",
                    serverId: serverId
                )
                #expect(added.status == .ok)
            }
            let agentAdded = try await postJSON(
                client,
                path: "/internal/agent/\(agentId)/messages/\(messageId)/reactions",
                body: "{\"emoji\":\"👀\"}",
                authorization: "Bearer \(machineKey)"
            )
            #expect(agentAdded.status == .ok)

            var visibleRefs: [String] = []
            var cursor: String?
            var firstCursor: String?
            repeat {
                let page = try await actors(client, token: memberToken, messageId: messageId, limit: 1, cursor: cursor)
                #expect(page.status == .ok)
                visibleRefs.append(contentsOf: try refs(from: page))
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(page).utf8)) as? [String: Any]
                let next = body?["nextCursor"] as? String
                if firstCursor == nil { firstCursor = next }
                cursor = next
            } while cursor != nil
            #expect(visibleRefs == ["agent:\(agentId)", "user:\(memberId)"])
            #expect(firstCursor?.isEmpty == false)

            accounts.setHideHumansFromMembers(serverId: serverId, hidden: false)
            let changed = try await actors(client, token: memberToken, messageId: messageId, cursor: firstCursor)
            #expect(changed.status == .conflict)
            let changedBody = try JSONSerialization.jsonObject(with: Data(bodyText(changed).utf8)) as? [String: Any]
            #expect(changedBody?["error"] as? String == "Reaction actor visibility changed while reading this page")
            #expect(changedBody?["code"] as? String == "reaction_actor_visibility_changed")
            let rebaseline = changedBody?["rebaselineRequired"] as? Bool ?? (changedBody?["rebaselineRequired"] as? NSNumber)?.boolValue
            #expect(rebaseline == true)

            let ownerPage = try await actors(client, token: ownerToken, messageId: messageId, limit: 100)
            #expect(ownerPage.status == .ok)
            #expect(Set(try refs(from: ownerPage)) == Set([
                "user:\(ownerId)",
                "user:\(memberId)",
                "user:\(otherId)",
                "agent:\(agentId)",
            ]))
        }
    }
}

@Test func reactionActorReadsRejectPrivateArchivedShortIdAndBadCursor() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111113e"
    let outsiderId = "11111111-1111-4111-8111-11111111113f"
    let serverId = "33333333-3333-4333-8333-333333333353"
    let otherServerId = "33333333-3333-4333-8333-333333333354"
    let privateChannelId = "22222222-2222-4222-8222-222222222244"
    let publicChannelId = "22222222-2222-4222-8222-222222222245"
    let collisionOne = "eeeeeeee-1111-4111-8111-111111111111"
    let collisionTwo = "eeeeeeee-2222-4222-8222-222222222222"
    accounts.addAccount(id: ownerId, email: "reaction-read-guard-owner@slock.test", password: "password123")
    accounts.addAccount(id: outsiderId, email: "reaction-read-guard-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: outsiderId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private")
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannelId, memberId: ownerId)
    func actors(_ client: any Client, messageId: String, token: String, server: String, emoji: String, cursor: String? = nil) async throws -> ClientResponse {
        var parts = ["emoji=\(emoji.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? emoji)"]
        if let cursor {
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            parts.append("cursor=\(encoded)")
        }
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = server
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/\(messageId)/reactions/actors?\(parts.joined(separator: "&"))"))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-read-guard-owner@slock.test\",\"password\":\"password123\"}")
            let outsiderLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-read-guard-outsider@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let outsiderToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(outsiderLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(privateChannelId)\",\"content\":\"private actor read\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let privateMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let reacted = try await postJSON(
                client,
                path: "/api/messages/\(privateMessageId)/reactions",
                body: "{\"emoji\":\"👍\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(reacted.status == .ok)

            let privateRead = try await actors(client, messageId: privateMessageId, token: outsiderToken, server: serverId, emoji: "👍")
            #expect(privateRead.status == .notFound)

            accounts.archiveChannel(channelId: privateChannelId)
            let archivedRead = try await actors(client, messageId: privateMessageId, token: ownerToken, server: serverId, emoji: "👍")
            #expect(archivedRead.status == .conflict)
            let archivedBody = try JSONSerialization.jsonObject(with: Data(bodyText(archivedRead).utf8)) as? [String: Any]
            #expect(archivedBody?["code"] as? String == "channel_archived")

            accounts.insertHumanMessage(id: collisionOne, channelId: publicChannelId, senderId: ownerId, content: "reaction collision one")
            accounts.insertHumanMessage(id: collisionTwo, channelId: publicChannelId, senderId: ownerId, content: "reaction collision two")
            let collision = try await actors(client, messageId: "eeeeeeee", token: ownerToken, server: serverId, emoji: "👍")
            #expect(collision.status == .badRequest)

            let wrongServer = try await actors(client, messageId: collisionOne, token: ownerToken, server: otherServerId, emoji: "👍")
            #expect(wrongServer.status == .notFound)

            let invalidEmoji = try await actors(client, messageId: collisionOne, token: ownerToken, server: serverId, emoji: "not emoji")
            #expect(invalidEmoji.status == .badRequest)
            let emojiBody = try JSONSerialization.jsonObject(with: Data(bodyText(invalidEmoji).utf8)) as? [String: Any]
            #expect(emojiBody?["code"] as? String == "invalid_reaction_emoji")

            let invalidCursor = try await actors(client, messageId: collisionOne, token: ownerToken, server: serverId, emoji: "👍", cursor: "tampered")
            #expect(invalidCursor.status == .badRequest)
            let cursorBody = try JSONSerialization.jsonObject(with: Data(bodyText(invalidCursor).utf8)) as? [String: Any]
            #expect(cursorBody?["code"] as? String == "invalid_reaction_actors_cursor")
        }
    }
}

@Test func jointReactionActorPageUsesTheRequesterLocalScope() async throws {
    let accounts = EmailLoginDirectory()
    let hostId = "11111111-1111-4111-8111-111111111140"
    let guestId = "11111111-1111-4111-8111-111111111141"
    let hostServerId = "33333333-3333-4333-8333-333333333355"
    let guestServerId = "33333333-3333-4333-8333-333333333356"
    let hostChannelId = "22222222-2222-4222-8222-222222222246"
    let guestChannelId = "22222222-2222-4222-8222-222222222247"
    accounts.addAccount(id: hostId, email: "reaction-joint-host@slock.test", password: "password123")
    accounts.addAccount(id: guestId, email: "reaction-joint-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: hostId)
    accounts.markEmailVerified(userId: guestId)
    accounts.addPostableChannel(serverId: hostServerId, channelId: hostChannelId, memberId: hostId, kind: "joint")
    accounts.addPostableChannel(serverId: guestServerId, channelId: guestChannelId, memberId: guestId, kind: "joint")
    accounts.addJointChannelProjection(localChannelId: guestChannelId, canonicalChannelId: hostChannelId, serverId: guestServerId)
    func actors(_ client: any Client, messageId: String, token: String, server: String, limit: Int? = nil, cursor: String? = nil) async throws -> ClientResponse {
        var parts = ["emoji=\("👀".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "👀")"]
        if let limit { parts.append("limit=\(limit)") }
        if let cursor {
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            parts.append("cursor=\(encoded)")
        }
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = server
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/\(messageId)/reactions/actors?\(parts.joined(separator: "&"))"))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let hostLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-joint-host@slock.test\",\"password\":\"password123\"}")
            let guestLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"reaction-joint-guest@slock.test\",\"password\":\"password123\"}")
            let hostToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(hostLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let guestToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(guestLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(hostChannelId)\",\"content\":\"joint actor page\"}",
                authorization: "Bearer \(hostToken)",
                serverId: hostServerId
            )
            #expect(sent.status == .ok)
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            for (token, server) in [(hostToken, hostServerId), (guestToken, guestServerId)] {
                let added = try await postJSON(
                    client,
                    path: "/api/messages/\(messageId)/reactions",
                    body: "{\"emoji\":\"👀\"}",
                    authorization: "Bearer \(token)",
                    serverId: server
                )
                #expect(added.status == .ok)
            }

            let guestPage = try await actors(client, messageId: messageId, token: guestToken, server: guestServerId, limit: 1)
            #expect(guestPage.status == .ok)
            let guestBody = try JSONSerialization.jsonObject(with: Data(bodyText(guestPage).utf8)) as? [String: Any]
            let discussion = guestBody?["discussion"] as? [String: Any]
            let root = discussion?["root"] as? [String: Any]
            let parent = discussion?["parentScope"] as? [String: Any]
            #expect(root?["kind"] as? String == "message")
            #expect(root?["serverId"] as? String == guestServerId)
            #expect(root?["id"] as? String == messageId)
            #expect(parent?["serverId"] as? String == guestServerId)
            #expect(parent?["scopeKind"] as? String == "channel")
            #expect(parent?["scopeId"] as? String == guestChannelId)
            let nextCursor = guestBody?["nextCursor"] as? String ?? ""
            #expect(nextCursor.isEmpty == false)

            let peerReplay = try await actors(client, messageId: messageId, token: hostToken, server: hostServerId, cursor: nextCursor)
            #expect(peerReplay.status == .badRequest)
            let peerBody = try JSONSerialization.jsonObject(with: Data(bodyText(peerReplay).utf8)) as? [String: Any]
            #expect(peerBody?["code"] as? String == "invalid_reaction_actors_cursor")
        }
    }
}

@Test func messageSearchDefaultsToRelevanceAndAcceptsRecentSort() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111146"
    let serverId = "33333333-3333-4333-8333-33333333335a"
    let channelId = "22222222-2222-4222-8222-22222222224d"
    accounts.addAccount(id: ownerId, email: "search-sort-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    let olderAt = try #require(ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z"))
    let newerAt = try #require(ISO8601DateFormatter().date(from: "2026-05-02T00:00:00Z"))
    func search(_ client: any Client, token: String, query: String) async throws -> ClientResponse {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/search?\(query)"))
    }
    func firstId(_ response: ClientResponse) throws -> String {
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        let results = body?["results"] as? [[String: Any]] ?? []
        return results.first?["id"] as? String ?? ""
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-sort-owner@slock.test\",\"password\":\"password123\"}")
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let older = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"chronos chronos chronos chronos chronos older high relevance\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(older.status == .ok)
            let olderId = ((try JSONSerialization.jsonObject(with: Data(bodyText(older).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let newer = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"chronos newer low relevance\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(newer.status == .ok)
            let newerId = ((try JSONSerialization.jsonObject(with: Data(bodyText(newer).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.setHumanMessageCreatedAt(messageId: olderId, createdAt: olderAt)
            accounts.setHumanMessageCreatedAt(messageId: newerId, createdAt: newerAt)

            let relevance = try await search(client, token: token, query: "q=chronos&limit=2")
            #expect(relevance.status == .ok)
            #expect(try firstId(relevance) == olderId)

            let recent = try await search(client, token: token, query: "q=chronos&sort=recent&limit=2")
            #expect(recent.status == .ok)
            #expect(try firstId(recent) == newerId)

            let invalid = try await search(client, token: token, query: "q=chronos&sort=fancy")
            #expect(invalid.status == .badRequest)
        }
    }
}

@Test func messageSearchFallsBackToRelaxedChineseTokensWhenStrictMatchIsEmpty() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111147"
    let serverId = "33333333-3333-4333-8333-33333333335b"
    let channelId = "22222222-2222-4222-8222-22222222224e"
    let targetContent = "今晚真收工 Eric 的八发全中账我背书，各位辛苦。"
    accounts.addAccount(id: ownerId, email: "search-cjk-fallback-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    func search(_ client: any Client, token: String, query: String) async throws -> ClientResponse {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/search?\(query)"))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-cjk-fallback-owner@slock.test\",\"password\":\"password123\"}")
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let target = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(targetContent)\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(target.status == .ok)
            let targetId = ((try JSONSerialization.jsonObject(with: Data(bodyText(target).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let other = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"明天开讨论会。\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(other.status == .ok)
            for index in 0..<24 {
                let decoy = try await postJSON(
                    client,
                    path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"今晚 fallback decoy \(String(format: "%02d", index))\"}",
                    authorization: "Bearer \(token)",
                    serverId: serverId
                )
                #expect(decoy.status == .ok)
            }
            let encoded = "今晚八发刚收工，明天开".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let response = try await search(client, token: token, query: "q=\(encoded)&limit=20")
            #expect(response.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            let results = body?["results"] as? [[String: Any]] ?? []
            #expect(results.first?["id"] as? String == targetId)
            #expect((results.first?["content"] as? String)?.contains("今晚真收工") == true)
            #expect(results.count == 20)
            let hasMore = body?["hasMore"] as? Bool ?? (body?["hasMore"] as? NSNumber)?.boolValue
            #expect(hasMore == false)
        }
    }
}

@Test func messageSearchBrowsesBySenderAndChannelWithoutAKeyword() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111148"
    let otherId = "11111111-1111-4111-8111-111111111149"
    let serverId = "33333333-3333-4333-8333-33333333335c"
    let channelId = "22222222-2222-4222-8222-22222222224f"
    let otherChannelId = "22222222-2222-4222-8222-222222222250"
    let threadChannelId = "22222222-2222-4222-8222-222222222251"
    accounts.addAccount(id: ownerId, email: "search-filter-only-owner@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "search-filter-only-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: otherId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: otherId)
    accounts.addPostableChannel(serverId: serverId, channelId: otherChannelId, memberId: ownerId)
    func iso(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
    func search(_ client: any Client, token: String, query: String) async throws -> ClientResponse {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/search?\(query)"))
    }
    func post(_ client: any Client, token: String, channel: String, content: String) async throws -> String {
        let sent = try await postJSON(
            client,
            path: "/api/messages",
            body: "{\"channelId\":\"\(channel)\",\"content\":\"\(content)\"}",
            authorization: "Bearer \(token)",
            serverId: serverId
        )
        #expect(sent.status == .ok)
        return ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-filter-only-owner@slock.test\",\"password\":\"password123\"}")
            let otherLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-filter-only-other@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let oldOwnerId = try await post(client, token: ownerToken, channel: channelId, content: "old owner filter-only message")
            let newOwnerId = try await post(client, token: ownerToken, channel: channelId, content: "new owner filter-only message")
            _ = try await post(client, token: otherToken, channel: channelId, content: "other user filter-only message")
            let otherChannelMessageId = try await post(client, token: ownerToken, channel: otherChannelId, content: "owner in another channel")
            let parentId = try await post(client, token: ownerToken, channel: channelId, content: "thread parent filter-only message")
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadChannelId, parentChannelId: channelId, parentMessageId: parentId, memberId: ownerId)
            let threadReplyId = try await post(client, token: ownerToken, channel: threadChannelId, content: "thread reply filter-only message")
            accounts.setHumanMessageCreatedAt(messageId: oldOwnerId, createdAt: try iso("2026-05-01T00:00:00Z"))
            accounts.setHumanMessageCreatedAt(messageId: newOwnerId, createdAt: try iso("2026-05-02T00:00:00Z"))
            accounts.setHumanMessageCreatedAt(messageId: otherChannelMessageId, createdAt: try iso("2026-05-04T00:00:00Z"))
            accounts.setHumanMessageCreatedAt(messageId: parentId, createdAt: try iso("2026-04-30T00:00:00Z"))
            accounts.setHumanMessageCreatedAt(messageId: threadReplyId, createdAt: try iso("2026-05-05T00:00:00Z"))

            let empty = try await search(client, token: ownerToken, query: "limit=3")
            #expect(empty.status == .ok)
            let emptyBody = try JSONSerialization.jsonObject(with: Data(bodyText(empty).utf8)) as? [String: Any]
            #expect((emptyBody?["results"] as? [Any])?.isEmpty == true)
            #expect((emptyBody?["hasMore"] as? Bool ?? (emptyBody?["hasMore"] as? NSNumber)?.boolValue) == false)

            let filtered = try await search(client, token: ownerToken, query: "senderId=\(ownerId)&channelId=\(channelId)&limit=3")
            #expect(filtered.status == .ok)
            let filteredBody = try JSONSerialization.jsonObject(with: Data(bodyText(filtered).utf8)) as? [String: Any]
            let filteredResults = filteredBody?["results"] as? [[String: Any]] ?? []
            #expect(filteredResults.compactMap { $0["id"] as? String } == [threadReplyId, newOwnerId, oldOwnerId])
            #expect((filteredBody?["hasMore"] as? Bool ?? (filteredBody?["hasMore"] as? NSNumber)?.boolValue) == true)
            #expect(filteredResults.allSatisfy { $0["senderId"] as? String == ownerId })
            #expect(filteredResults.first?["channelId"] as? String == threadChannelId)
            #expect(filteredResults.first?["parentChannelId"] as? String == channelId)
            #expect(filteredResults.dropFirst().allSatisfy { $0["channelId"] as? String == channelId })
            #expect(filteredResults.first?["snippet"] as? String == "thread reply filter-only message")

            let senderOnly = try await search(client, token: ownerToken, query: "senderId=\(ownerId)&limit=2")
            #expect(senderOnly.status == .ok)
            let senderBody = try JSONSerialization.jsonObject(with: Data(bodyText(senderOnly).utf8)) as? [String: Any]
            let senderResults = senderBody?["results"] as? [[String: Any]] ?? []
            #expect(senderResults.compactMap { $0["id"] as? String } == [threadReplyId, otherChannelMessageId])
            #expect((senderBody?["hasMore"] as? Bool ?? (senderBody?["hasMore"] as? NSNumber)?.boolValue) == true)
            #expect(senderResults.allSatisfy { $0["senderId"] as? String == ownerId })
        }
    }
}

@Test func messageSearchFiltersBySenderTypeAndMentionSelf() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111114a"
    let otherId = "11111111-1111-4111-8111-11111111114b"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab5"
    let agentMessageId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1"
    let serverId = "33333333-3333-4333-8333-33333333335d"
    let channelId = "22222222-2222-4222-8222-222222222252"
    accounts.addAccount(id: ownerId, email: "search-scope-owner@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "search-scope-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: otherId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: otherId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "SearchScopeAgent", avatarUrl: nil)
    accounts.addChannelAgent(channelId: channelId, agentId: agentId)
    func iso(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
    func search(_ client: any Client, token: String, query: String) async throws -> ClientResponse {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/search?\(query)"))
    }
    func ids(_ response: ClientResponse) throws -> [String] {
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        return (body?["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-scope-owner@slock.test\",\"password\":\"password123\"}")
            let otherLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-scope-other@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let otherToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let humanId = ((try JSONSerialization.jsonObject(with: Data(bodyText(try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"human scoped message\"}",
                authorization: "Bearer \(otherToken)",
                serverId: serverId
            )).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.insertHumanMessage(id: agentMessageId, channelId: channelId, senderId: agentId, content: "agent scoped message", senderType: "agent")
            let mentionSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"mentioned scoped message\"}",
                authorization: "Bearer \(otherToken)",
                serverId: serverId
            )
            #expect(mentionSent.status == .ok)
            let mentionId = ((try JSONSerialization.jsonObject(with: Data(bodyText(mentionSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addMessageMention(messageId: mentionId, targetType: "user", targetId: ownerId)
            accounts.setHumanMessageCreatedAt(messageId: humanId, createdAt: try iso("2026-05-01T00:00:00Z"))
            accounts.setHumanMessageCreatedAt(messageId: agentMessageId, createdAt: try iso("2026-05-02T00:00:00Z"))
            accounts.setHumanMessageCreatedAt(messageId: mentionId, createdAt: try iso("2026-05-03T00:00:00Z"))

            let humans = try await search(client, token: ownerToken, query: "senderType=user&limit=10")
            #expect(humans.status == .ok)
            let humanBody = try JSONSerialization.jsonObject(with: Data(bodyText(humans).utf8)) as? [String: Any]
            let humanResults = humanBody?["results"] as? [[String: Any]] ?? []
            #expect(humanResults.compactMap { $0["id"] as? String } == [mentionId, humanId])
            #expect(humanResults.allSatisfy { $0["senderType"] as? String == "user" })

            let agents = try await search(client, token: ownerToken, query: "senderType=agent&limit=10")
            #expect(agents.status == .ok)
            let agentBody = try JSONSerialization.jsonObject(with: Data(bodyText(agents).utf8)) as? [String: Any]
            let agentResults = agentBody?["results"] as? [[String: Any]] ?? []
            #expect(try ids(agents) == [agentMessageId])
            #expect(agentResults.allSatisfy { $0["senderType"] as? String == "agent" })

            let mentions = try await search(client, token: ownerToken, query: "mentionTarget=self&limit=10")
            #expect(mentions.status == .ok)
            #expect(try ids(mentions) == [mentionId])

            #expect((try await search(client, token: ownerToken, query: "senderType=robot")).status == .badRequest)
            #expect((try await search(client, token: ownerToken, query: "mentionTarget=all")).status == .badRequest)
        }
    }
}

@Test func messageSearchCloaksAPrivateChannelFromNonMembers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111114c"
    let nonMemberId = "11111111-1111-4111-8111-11111111114d"
    let serverId = "33333333-3333-4333-8333-33333333335e"
    let channelId = "22222222-2222-4222-8222-222222222253"
    let payload = "private search payload"
    accounts.addAccount(id: ownerId, email: "search-private-owner@slock.test", password: "password123")
    accounts.addAccount(id: nonMemberId, email: "search-private-nonmember@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: nonMemberId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "private")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-private-owner@slock.test\",\"password\":\"password123\"}")
            let otherLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-private-nonmember@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let nonMemberToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(otherLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(payload)\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(nonMemberToken)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let response = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/search?channelId=\(channelId)&limit=2"))
            #expect(response.status == .notFound)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "Channel not found")
            #expect(bodyText(response).contains(payload) == false)
        }
    }
}

@Test func messageSearchDropsADeletedChannelAndItsThreadsButKeepsArchivedOnes() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-11111111114e"
    let memberId = "11111111-1111-4111-8111-11111111114f"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab6"
    let serverId = "33333333-3333-4333-8333-33333333335f"
    let doomedId = "22222222-2222-4222-8222-222222222254"
    let archivedId = "22222222-2222-4222-8222-222222222255"
    let threadId = "22222222-2222-4222-8222-222222222256"
    let marker = "quartzlantern"
    accounts.addAccount(id: ownerId, email: "search-deleted-owner@slock.test", password: "password123")
    accounts.addAccount(id: memberId, email: "search-deleted-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: memberId)
    accounts.addPostableChannel(serverId: serverId, channelId: doomedId, memberId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: doomedId, memberId: memberId)
    accounts.addPostableChannel(serverId: serverId, channelId: archivedId, memberId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: archivedId, memberId: memberId)
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "search-deleted-agent", avatarUrl: nil)
    let machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agentId)
    func searchIds(_ client: any Client, path: String, token: String, server: String?) async throws -> [String] {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        if let server { headers[HTTPField.Name("X-Server-Id")!] = server }
        let response = try await client.send(.get, headers: headers, to: URI(string: path))
        #expect(response.status == .ok)
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        return ((body?["results"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-deleted-owner@slock.test\",\"password\":\"password123\"}")
            let memberLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"search-deleted-member@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let memberToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(memberLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let doomedSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(doomedId)\",\"content\":\"\(marker) in the room that will be deleted\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(doomedSent.status == .ok)
            let doomedMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(doomedSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: doomedId, parentMessageId: doomedMessageId, memberId: ownerId)
            let replySent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(threadId)\",\"content\":\"\(marker) reply under the room that will be deleted\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(replySent.status == .ok)
            let replyId = ((try JSONSerialization.jsonObject(with: Data(bodyText(replySent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let archivedSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(archivedId)\",\"content\":\"\(marker) in the archived room\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(archivedSent.status == .ok)
            let archivedMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(archivedSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.archiveChannel(channelId: archivedId)
            let query = "/api/messages/search?q=\(marker)&limit=20"
            let agentQuery = "/internal/agent/\(agentId)/search?q=\(marker)&limit=20"
            let everything = [doomedMessageId, replyId, archivedMessageId].sorted()
            #expect(try await searchIds(client, path: query, token: memberToken, server: serverId) == everything)
            #expect(try await searchIds(client, path: agentQuery, token: machineKey, server: nil) == everything)

            var deleteHeaders = HTTPFields()
            deleteHeaders[.authorization] = "Bearer \(ownerToken)"
            deleteHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let deleted = try await client.send(.delete, headers: deleteHeaders, to: URI(string: "/api/channels/\(doomedId)"))
            #expect(deleted.status == .ok)
            #expect(try await searchIds(client, path: query, token: memberToken, server: serverId) == [archivedMessageId])
            #expect(try await searchIds(client, path: agentQuery, token: machineKey, server: nil) == [archivedMessageId])
        }
    }
}

@Test func messageForwardStaysAvailableAfterTheRolloutFlagIsRetired() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111150"
    let serverId = "33333333-3333-4333-8333-333333333360"
    let sourceChannelId = "22222222-2222-4222-8222-222222222257"
    let destinationChannelId = "22222222-2222-4222-8222-222222222258"
    accounts.addAccount(id: ownerId, email: "forward-retired-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: sourceChannelId, memberId: ownerId, name: "forward-retired-source")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationChannelId, memberId: ownerId, name: "forward-retired-destination")
    let killed = PublicFeatureFlag(key: "message_forwarding_v0", enabled: true, killSwitch: true, defaultEnabled: true)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            featureFlags: [killed],
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(
                client,
                path: "/api/auth/login",
                body: "{\"email\":\"forward-retired-owner@slock.test\",\"password\":\"password123\"}"
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(sourceChannelId)\",\"content\":\"forward source after retirement\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sourceMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            var headers = HTTPFields()
            headers[.authorization] = authorization
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let enabled = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/forward/enabled"))
            #expect(enabled.status == .ok)
            let enabledBody = try JSONSerialization.jsonObject(with: Data(bodyText(enabled).utf8)) as? [String: Any]
            let enabledFlag = enabledBody?["enabled"] as? Bool ?? (enabledBody?["enabled"] as? NSNumber)?.boolValue
            #expect(enabledFlag == true)
            let forwarded = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationChannelId)\",\"sourceMessageIds\":[\"\(sourceMessageId)\"],\"note\":\"\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(forwarded.status == .ok)
            let forwardedBody = try JSONSerialization.jsonObject(with: Data(bodyText(forwarded).utf8)) as? [String: Any]
            #expect(forwardedBody?["channelId"] as? String == destinationChannelId)
            #expect(forwardedBody?["content"] as? String == "Forwarded 1 message")
            #expect(forwardedBody?["id"] as? String != sourceMessageId)
            #expect(accounts.humanMessageCount == 2)
        }
    }
}

@Test func messageForwardStoresAnOrderedImmutableBundleSnapshot() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111151"
    let serverId = "33333333-3333-4333-8333-333333333361"
    let sourceChannelId = "22222222-2222-4222-8222-222222222259"
    let destinationChannelId = "22222222-2222-4222-8222-222222222260"
    accounts.addAccount(id: ownerId, email: "forward-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: sourceChannelId, memberId: ownerId, name: "forward-source")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationChannelId, memberId: ownerId, name: "forward-destination")
    let sourceAttachmentId = accounts.addChannelAttachment(
        channelId: sourceChannelId,
        uploaderId: ownerId,
        filename: "forward source.pdf",
        mimeType: "application/pdf",
        sizeBytes: 256
    )
    let randomId = "forward-test-snapshot-1"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-owner@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            let firstSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(sourceChannelId)\",\"content\":\"first source snapshot\",\"attachmentIds\":[\"\(sourceAttachmentId)\"]}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(firstSent.status == .ok)
            let firstId = ((try JSONSerialization.jsonObject(with: Data(bodyText(firstSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let secondSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(sourceChannelId)\",\"content\":\"second source snapshot\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(secondSent.status == .ok)
            let secondId = ((try JSONSerialization.jsonObject(with: Data(bodyText(secondSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime]
            accounts.setHumanMessageCreatedAt(messageId: firstId, createdAt: parser.date(from: "2026-07-17T00:20:00Z")!)
            accounts.setHumanMessageCreatedAt(messageId: secondId, createdAt: parser.date(from: "2026-07-16T23:50:00Z")!)
            let request = "{\"destinationChannelId\":\"\(destinationChannelId)\",\"sourceMessageIds\":[\"\(secondId)\",\"\(firstId)\"],\"note\":\"forwarding context\",\"randomId\":\"\(randomId)\"}"
            let forwarded = try await postJSON(client, path: "/api/messages/forward", body: request, authorization: authorization, serverId: serverId)
            #expect(forwarded.status == .ok)
            #expect(forwarded.headers[HTTPField.Name("X-Raft-Forward-Outcome")!] == "success")
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(forwarded).utf8)) as? [String: Any]
            #expect(body?["channelId"] as? String == destinationChannelId)
            #expect(body?["content"] as? String == "forwarding context")
            let metadata = body?["actionMetadata"] as? [String: Any]
            #expect(metadata?["kind"] as? String == "forwarded-bundle")
            #expect(metadata?["forwardRequestFingerprint"] == nil)
            let items = metadata?["forwardedItems"] as? [[String: Any]] ?? []
            try #require(items.count == 2)
            #expect(items.compactMap { $0["sourceMessageId"] as? String } == [secondId, firstId])
            #expect(items.compactMap { $0["contentSnapshot"] as? String } == ["second source snapshot", "first source snapshot"])
            #expect(items.map { ($0["sourceIsThreadParent"] as? Bool) ?? ($0["sourceIsThreadParent"] as? NSNumber)?.boolValue } == [false, false])
            let olderSnapshot = items[0]["sourceTargetSnapshot"] as? [String: Any]
            #expect(olderSnapshot?["label"] as? String == "#forward-source")
            #expect(olderSnapshot?["labelVisibility"] as? String == "public")
            #expect((items[0]["attachmentSnapshots"] as? [Any])?.isEmpty == true)
            #expect(items[0]["attachmentPolicy"] as? String == "excluded")
            let projected = (items[1]["attachmentSnapshots"] as? [[String: Any]]) ?? []
            try #require(projected.count == 1)
            #expect(projected[0]["id"] as? String != sourceAttachmentId)
            #expect(projected[0]["filename"] as? String == "forward source.pdf")
            #expect(projected[0]["mimeType"] as? String == "application/pdf")
            let size = projected[0]["sizeBytes"] as? Int ?? (projected[0]["sizeBytes"] as? NSNumber)?.intValue
            #expect(size == 256)
            #expect(projected[0]["width"] is NSNull)
            #expect(projected[0]["height"] is NSNull)
            #expect(projected[0]["sourceProjectionId"] == nil)
            #expect(projected[0]["url"] == nil)
            #expect(items[1]["attachmentPolicy"] as? String == "projected")
            let forwardId = body?["id"] as? String

            let replay = try await postJSON(client, path: "/api/messages/forward", body: request, authorization: authorization, serverId: serverId)
            #expect(replay.status == .ok)
            #expect(replay.headers[HTTPField.Name("X-Raft-Forward-Outcome")!] == "idempotent_replay")
            let replayBody = try JSONSerialization.jsonObject(with: Data(bodyText(replay).utf8)) as? [String: Any]
            #expect(replayBody?["id"] as? String == forwardId)
            let replayItems = (replayBody?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]
            let replayProjected = (replayItems?[1]["attachmentSnapshots"] as? [[String: Any]]) ?? []
            #expect(replayProjected.first?["id"] as? String == projected[0]["id"] as? String)

            let conflict = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationChannelId)\",\"sourceMessageIds\":[\"\(secondId)\",\"\(firstId)\"],\"note\":\"different payload\",\"randomId\":\"\(randomId)\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(conflict.status == .conflict)
            let conflictBody = try JSONSerialization.jsonObject(with: Data(bodyText(conflict).utf8)) as? [String: Any]
            #expect(conflictBody?["code"] as? String == "idempotency_conflict")
            #expect(accounts.humanMessageCount == 3)
        }
    }
}

@Test func messageForwardBatchesDestinationsAndReplaysEachOne() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111152"
    let otherId = "11111111-1111-4111-8111-111111111153"
    let serverId = "33333333-3333-4333-8333-333333333362"
    let sourceChannelId = "22222222-2222-4222-8222-222222222261"
    let destinationA = "22222222-2222-4222-8222-222222222262"
    let destinationB = "22222222-2222-4222-8222-222222222263"
    let deniedDestination = "22222222-2222-4222-8222-222222222264"
    let requestId = "11111111-2222-4333-8444-555555555555"
    accounts.addAccount(id: ownerId, email: "forward-batch-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: sourceChannelId, memberId: ownerId, name: "forward-batch-source")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationA, memberId: ownerId, name: "forward-batch-a")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationB, memberId: ownerId, name: "forward-batch-b")
    accounts.addPostableChannel(serverId: serverId, channelId: deniedDestination, memberId: otherId, kind: "private", name: "forward-batch-denied")
    func results(_ response: ClientResponse) throws -> [[String: Any]] {
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        return (body?["results"] as? [[String: Any]]) ?? []
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-batch-owner@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(sourceChannelId)\",\"content\":\"batch source snapshot\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sourceMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let payload = "{\"destinationChannelIds\":[\"\(destinationA)\",\"\(destinationB)\",\"\(destinationA)\",\"\(deniedDestination)\"],\"sourceMessageIds\":[\"\(sourceMessageId)\"],\"requestId\":\"\(requestId)\",\"note\":\"batch note\"}"
            let first = try await postJSON(client, path: "/api/messages/forward", body: payload, authorization: authorization, serverId: serverId)
            #expect(first.status == .ok)
            #expect(first.headers[HTTPField.Name("X-Raft-Forward-Outcome")!] == "partial_failure")
            let firstResults = try results(first)
            try #require(firstResults.count == 3)
            #expect(firstResults.compactMap { $0["destinationChannelId"] as? String } == [destinationA, destinationB, deniedDestination])
            #expect(firstResults.compactMap { $0["status"] as? String } == ["success", "success", "failed"])
            #expect(firstResults[2]["code"] as? String == "destination_unavailable")
            #expect(firstResults[2]["error"] as? String == "Could not forward to this target")
            let firstMessage = firstResults[0]["message"] as? [String: Any]
            let firstMetadata = firstMessage?["actionMetadata"] as? [String: Any]
            #expect(firstMetadata?["_forwardRequestDigest"] == nil)
            let firstMessageId = firstMessage?["id"] as? String
            var historyHeaders = HTTPFields()
            historyHeaders[.authorization] = authorization
            historyHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let history = try await client.send(.get, headers: historyHeaders, to: URI(string: "/api/messages/channel/\(destinationA)"))
            #expect(history.status == .ok)
            let historyBody = try JSONSerialization.jsonObject(with: Data(bodyText(history).utf8)) as? [String: Any]
            let historyMessages = (historyBody?["messages"] as? [[String: Any]]) ?? []
            let historyMessage = historyMessages.first { $0["id"] as? String == firstMessageId }
            #expect(historyMessage != nil)
            let historyMetadata = historyMessage?["actionMetadata"] as? [String: Any] ?? [:]
            #expect(historyMetadata["_forwardRequestDigest"] == nil)

            accounts.addPostableChannel(serverId: serverId, channelId: deniedDestination, memberId: ownerId, kind: "private")
            let subset = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelIds\":[\"\(deniedDestination)\"],\"sourceMessageIds\":[\"\(sourceMessageId)\"],\"requestId\":\"\(requestId)\",\"note\":\"batch note\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(subset.status == .ok)
            let subsetResults = try results(subset)
            try #require(subsetResults.count == 1)
            #expect(subsetResults[0]["status"] as? String == "success")
            let subsetMessageId = (subsetResults[0]["message"] as? [String: Any])?["id"] as? String

            let retry = try await postJSON(client, path: "/api/messages/forward", body: payload, authorization: authorization, serverId: serverId)
            #expect(retry.status == .ok)
            let retryResults = try results(retry)
            let secondMessageId = (firstResults[1]["message"] as? [String: Any])?["id"] as? String
            #expect(retryResults.compactMap { ($0["message"] as? [String: Any])?["id"] as? String } == [firstMessageId, secondMessageId, subsetMessageId])

            let conflicting = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelIds\":[\"\(destinationA)\",\"\(destinationB)\",\"\(destinationA)\",\"\(deniedDestination)\"],\"sourceMessageIds\":[\"\(sourceMessageId)\"],\"requestId\":\"\(requestId)\",\"note\":\"different payload\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(conflicting.status == .ok)
            let conflictingResults = try results(conflicting)
            #expect(conflictingResults.compactMap { $0["status"] as? String } == ["failed", "failed", "failed"])
            #expect(conflictingResults.compactMap { $0["code"] as? String } == ["request_conflict", "request_conflict", "request_conflict"])

            let missingRequestId = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelIds\":[\"\(destinationA)\"],\"sourceMessageIds\":[\"\(sourceMessageId)\"],\"note\":\"batch note\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(missingRequestId.status == .badRequest)
            let tooMany = (0..<11).map { index in
                "\"aaaaaaaa-bbbb-4ccc-8ddd-\(String(format: "%012d", index))\""
            }.joined(separator: ",")
            let tooManyDestinations = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelIds\":[\(tooMany)],\"sourceMessageIds\":[\"\(sourceMessageId)\"],\"requestId\":\"\(requestId)\",\"note\":\"batch note\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(tooManyDestinations.status == .badRequest)
            #expect(accounts.humanMessageCount == 4)
        }
    }
}

@Test func messageForwardProjectsThreadSourcesThroughTheParentChannel() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111154"
    let viewerId = "11111111-1111-4111-8111-111111111155"
    let serverId = "33333333-3333-4333-8333-333333333363"
    let parentChannelId = "22222222-2222-4222-8222-222222222265"
    let destinationId = "22222222-2222-4222-8222-222222222266"
    let threadId = "22222222-2222-4222-8222-222222222267"
    accounts.addAccount(id: ownerId, email: "forward-thread-owner@slock.test", password: "password123")
    accounts.addAccount(id: viewerId, email: "forward-thread-viewer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: viewerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parentChannelId, memberId: ownerId, name: "forward-thread-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: ownerId, name: "forward-thread-destination")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: viewerId)
    func forwardedItems(_ response: ClientResponse) throws -> [[String: Any]] {
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        let metadata = body?["actionMetadata"] as? [String: Any]
        return (metadata?["forwardedItems"] as? [[String: Any]]) ?? []
    }
    func snapshot(_ item: [String: Any]) -> [String: Any] {
        (item["sourceTargetSnapshot"] as? [String: Any]) ?? [:]
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-thread-owner@slock.test\",\"password\":\"password123\"}")
            let viewerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-thread-viewer@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let viewerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(viewerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let ownerAuth = "Bearer \(ownerToken)"
            let parentSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(parentChannelId)\",\"content\":\"thread source parent\"}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(parentSent.status == .ok)
            let parentMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(parentSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: parentChannelId, parentMessageId: parentMessageId, memberId: ownerId)
            let firstSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(threadId)\",\"content\":\"first thread snapshot\"}",
                authorization: ownerAuth,
                serverId: serverId
            )
            let secondSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(threadId)\",\"content\":\"second thread snapshot\"}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(firstSent.status == .ok)
            #expect(secondSent.status == .ok)
            let firstReplyId = ((try JSONSerialization.jsonObject(with: Data(bodyText(firstSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let secondReplyId = ((try JSONSerialization.jsonObject(with: Data(bodyText(secondSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime]
            accounts.setHumanMessageCreatedAt(messageId: parentMessageId, createdAt: parser.date(from: "2026-07-17T01:30:00Z")!)
            accounts.setHumanMessageCreatedAt(messageId: firstReplyId, createdAt: parser.date(from: "2026-07-17T01:20:00Z")!)
            accounts.setHumanMessageCreatedAt(messageId: secondReplyId, createdAt: parser.date(from: "2026-07-17T01:10:00Z")!)

            let replies = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(secondReplyId)\",\"\(firstReplyId)\"]}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(replies.status == .ok)
            let replyBody = try JSONSerialization.jsonObject(with: Data(bodyText(replies).utf8)) as? [String: Any]
            let replyItems = try forwardedItems(replies)
            try #require(replyItems.count == 2)
            #expect(replyItems[0]["sourceTargetId"] as? String == threadId)
            #expect(replyItems[0]["sourceThreadId"] as? String == threadId)
            #expect(replyItems[0]["parentChannelId"] as? String == parentChannelId)
            #expect(replyItems.compactMap { $0["sourceMessageId"] as? String } == [secondReplyId, firstReplyId])
            #expect(replyItems.compactMap { $0["contentSnapshot"] as? String } == ["second thread snapshot", "first thread snapshot"])
            #expect(replyItems.map { ($0["sourceIsThreadParent"] as? Bool) ?? ($0["sourceIsThreadParent"] as? NSNumber)?.boolValue } == [false, false])
            #expect(snapshot(replyItems[0])["type"] as? String == "thread")
            #expect(snapshot(replyItems[0])["label"] as? String == "#forward-thread-parent")
            #expect(snapshot(replyItems[0])["labelVisibility"] as? String == "public")
            #expect(replyItems[0]["provenanceState"] as? String == "available")

            let parentAndReply = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(firstReplyId)\",\"\(parentMessageId)\"]}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(parentAndReply.status == .ok)
            let parentAndReplyItems = try forwardedItems(parentAndReply)
            try #require(parentAndReplyItems.count == 2)
            #expect(parentAndReplyItems.compactMap { $0["sourceMessageId"] as? String } == [parentMessageId, firstReplyId])
            #expect(parentAndReplyItems.compactMap { $0["contentSnapshot"] as? String } == ["thread source parent", "first thread snapshot"])
            #expect(parentAndReplyItems.map { ($0["sourceIsThreadParent"] as? Bool) ?? ($0["sourceIsThreadParent"] as? NSNumber)?.boolValue } == [true, false])
            for item in parentAndReplyItems {
                #expect(item["sourceTargetId"] as? String == threadId)
                #expect(item["sourceThreadId"] as? String == threadId)
                #expect(item["parentChannelId"] as? String == parentChannelId)
                #expect(snapshot(item)["type"] as? String == "thread")
                #expect(snapshot(item)["label"] as? String == "#forward-thread-parent")
                #expect(snapshot(item)["labelVisibility"] as? String == "public")
            }

            var historyHeaders = HTTPFields()
            historyHeaders[.authorization] = "Bearer \(viewerToken)"
            historyHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let history = try await client.send(.get, headers: historyHeaders, to: URI(string: "/api/messages/channel/\(destinationId)"))
            #expect(history.status == .ok)
            let historyBody = try JSONSerialization.jsonObject(with: Data(bodyText(history).utf8)) as? [String: Any]
            let listed = ((historyBody?["messages"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == replyBody?["id"] as? String }
            let listedItems = ((listed?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
            try #require(listedItems.count >= 1)
            #expect(listedItems[0]["sourceTargetId"] as? String == threadId)
            #expect(listedItems[0]["sourceThreadId"] as? String == threadId)
            #expect(listedItems[0]["parentChannelId"] as? String == parentChannelId)
            #expect(listedItems[0]["sourceMessageId"] as? String == secondReplyId)
            #expect(listedItems[0]["provenanceState"] as? String == "available")

            let parentAndReplies = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(secondReplyId)\",\"\(parentMessageId)\",\"\(firstReplyId)\"]}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(parentAndReplies.status == .ok)
            let parentAndRepliesItems = try forwardedItems(parentAndReplies)
            try #require(parentAndRepliesItems.count == 3)
            #expect(parentAndRepliesItems.compactMap { $0["sourceMessageId"] as? String } == [parentMessageId, secondReplyId, firstReplyId])
            #expect(parentAndRepliesItems.compactMap { $0["contentSnapshot"] as? String } == ["thread source parent", "second thread snapshot", "first thread snapshot"])
            #expect(parentAndRepliesItems.allSatisfy { $0["sourceTargetId"] as? String == threadId })
            #expect(parentAndRepliesItems.allSatisfy { $0["sourceThreadId"] as? String == threadId })
            #expect(parentAndRepliesItems.allSatisfy { $0["parentChannelId"] as? String == parentChannelId })
            #expect(snapshot(parentAndRepliesItems[0])["type"] as? String == "thread")
            #expect(snapshot(parentAndRepliesItems[0])["label"] as? String == "#forward-thread-parent")
            #expect(snapshot(parentAndRepliesItems[0])["labelVisibility"] as? String == "public")

            let parentOnly = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(parentMessageId)\"]}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(parentOnly.status == .ok)
            let parentOnlyItems = try forwardedItems(parentOnly)
            try #require(parentOnlyItems.count == 1)
            #expect(parentOnlyItems[0]["sourceMessageId"] as? String == parentMessageId)
            #expect(parentOnlyItems[0]["contentSnapshot"] as? String == "thread source parent")
            #expect(parentOnlyItems[0]["sourceTargetId"] as? String == parentChannelId)
            #expect(parentOnlyItems[0]["sourceThreadId"] == nil)
            #expect(parentOnlyItems[0]["parentChannelId"] == nil)
            #expect(snapshot(parentOnlyItems[0])["type"] as? String == "channel")
            #expect(snapshot(parentOnlyItems[0])["label"] as? String == "#forward-thread-parent")

            let unrelatedSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(parentChannelId)\",\"content\":\"unrelated parent-channel body\"}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(unrelatedSent.status == .ok)
            let unrelatedId = ((try JSONSerialization.jsonObject(with: Data(bodyText(unrelatedSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let parentAndSibling = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(unrelatedId)\",\"\(parentMessageId)\"]}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(parentAndSibling.status == .ok)
            let siblingItems = try forwardedItems(parentAndSibling)
            try #require(siblingItems.count == 2)
            #expect(siblingItems.compactMap { $0["sourceMessageId"] as? String } == [parentMessageId, unrelatedId])
            for item in siblingItems {
                #expect(item["sourceTargetId"] as? String == parentChannelId)
                #expect(item["sourceThreadId"] == nil)
                #expect(item["parentChannelId"] == nil)
                #expect(snapshot(item)["type"] as? String == "channel")
                #expect(snapshot(item)["label"] as? String == "#forward-thread-parent")
            }

            let mixed = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(unrelatedId)\",\"\(firstReplyId)\"]}",
                authorization: ownerAuth,
                serverId: serverId
            )
            #expect(mixed.status == .badRequest)
            let mixedBody = try JSONSerialization.jsonObject(with: Data(bodyText(mixed).utf8)) as? [String: Any]
            #expect(mixedBody?["error"] as? String == "Forwarded bundles must come from a single source")
            #expect(mixedBody?["code"] as? String == "cross_source_bundle")
        }
    }
}

@Test func messageForwardScrubsPrivateThreadProvenanceFromParentDeniedViewers() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111156"
    let viewerId = "11111111-1111-4111-8111-111111111157"
    let serverId = "33333333-3333-4333-8333-333333333364"
    let privateParentId = "22222222-2222-4222-8222-222222222268"
    let destinationId = "22222222-2222-4222-8222-222222222269"
    let threadId = "22222222-2222-4222-8222-222222222270"
    accounts.addAccount(id: ownerId, email: "forward-private-thread-owner@slock.test", password: "password123")
    accounts.addAccount(id: viewerId, email: "forward-private-thread-viewer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: viewerId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateParentId, memberId: ownerId, kind: "private", name: "forward-private-thread-parent")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: ownerId, name: "forward-private-thread-destination")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: viewerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-private-thread-owner@slock.test\",\"password\":\"password123\"}")
            let viewerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-private-thread-viewer@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let viewerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(viewerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let parentSent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(privateParentId)\",\"content\":\"private thread parent\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(parentSent.status == .ok)
            let parentMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(parentSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: privateParentId, parentMessageId: parentMessageId, memberId: ownerId)
            let replySent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(threadId)\",\"content\":\"private thread body\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(replySent.status == .ok)
            let replyId = ((try JSONSerialization.jsonObject(with: Data(bodyText(replySent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let created = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(replyId)\"]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(created.status == .ok)
            let createdBody = try JSONSerialization.jsonObject(with: Data(bodyText(created).utf8)) as? [String: Any]
            let ownerItems = ((createdBody?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
            try #require(ownerItems.count == 1)
            #expect(ownerItems[0]["sourceTargetId"] is NSNull)
            #expect(ownerItems[0]["sourceThreadId"] == nil)
            #expect(ownerItems[0]["parentChannelId"] == nil)
            let ownerSnapshot = ownerItems[0]["sourceTargetSnapshot"] as? [String: Any]
            #expect(ownerSnapshot?["label"] as? String == "")

            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(viewerToken)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let listed = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(destinationId)"))
            #expect(listed.status == .ok)
            let listedText = bodyText(listed)
            #expect(listedText.contains(threadId) == false)
            #expect(listedText.contains(privateParentId) == false)
            let listedBody = try JSONSerialization.jsonObject(with: Data(listedText.utf8)) as? [String: Any]
            let message = ((listedBody?["messages"] as? [[String: Any]]) ?? []).first { $0["id"] as? String == createdBody?["id"] as? String }
            let viewerItems = ((message?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
            try #require(viewerItems.count == 1)
            #expect(viewerItems[0]["sourceServerId"] is NSNull)
            #expect(viewerItems[0]["sourceTargetId"] is NSNull)
            #expect(viewerItems[0]["sourceThreadId"] is NSNull)
            #expect(viewerItems[0]["parentChannelId"] is NSNull)
            #expect(viewerItems[0]["sourceMessageId"] is NSNull)
            let viewerSnapshot = viewerItems[0]["sourceTargetSnapshot"] as? [String: Any]
            #expect(viewerSnapshot?["id"] is NSNull)
            #expect(viewerSnapshot?["label"] as? String == "")
            #expect(viewerSnapshot?["labelVisibility"] as? String == "restricted")
            #expect(viewerItems[0]["provenanceState"] as? String == "original_unavailable")
        }
    }
}

@Test func messageForwardRequiresSourceReadAuthorityAndHidesPrivateProvenance() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111158"
    let viewerId = "11111111-1111-4111-8111-111111111159"
    let serverId = "33333333-3333-4333-8333-333333333365"
    let privateChannelId = "22222222-2222-4222-8222-222222222271"
    let destinationId = "22222222-2222-4222-8222-222222222272"
    accounts.addAccount(id: ownerId, email: "forward-private-owner@slock.test", password: "password123")
    accounts.addAccount(id: viewerId, email: "forward-private-viewer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: viewerId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: "private-forward-source")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: ownerId, name: "private-forward-destination")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: viewerId)
    let sourceAttachmentId = accounts.addChannelAttachment(
        channelId: privateChannelId,
        uploaderId: ownerId,
        filename: "private-source.txt",
        mimeType: "text/plain",
        sizeBytes: 24
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-private-owner@slock.test\",\"password\":\"password123\"}")
            let viewerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-private-viewer@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let viewerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(viewerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(privateChannelId)\",\"content\":\"private source body\",\"attachmentIds\":[\"\(sourceAttachmentId)\"]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let sourceMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let forged = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(sourceMessageId)\"]}",
                authorization: "Bearer \(viewerToken)",
                serverId: serverId
            )
            #expect(forged.status == .notFound)
            #expect(bodyText(forged).contains("private source body") == false)
            let created = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"\(sourceMessageId)\"]}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(created.status == .ok)
            let createdBody = try JSONSerialization.jsonObject(with: Data(bodyText(created).utf8)) as? [String: Any]
            let items = ((createdBody?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
            try #require(items.count == 1)
            #expect(items[0]["contentSnapshot"] as? String == "private source body")
            let author = items[0]["sourceAuthorSnapshot"] as? [String: Any]
            #expect(author?["uniqueName"] as? String == "forward-private-owner")
            #expect(items[0]["sourceMessageId"] is NSNull)
            #expect(items[0]["sourceMessageSeq"] is NSNull)
            #expect(items[0]["sourceServerId"] is NSNull)
            #expect(items[0]["sourceTargetId"] is NSNull)
            let snapshot = items[0]["sourceTargetSnapshot"] as? [String: Any]
            #expect(snapshot?["label"] as? String == "")
            #expect(snapshot?["id"] is NSNull)
            #expect(snapshot?["labelVisibility"] as? String == "restricted")
            let projected = (items[0]["attachmentSnapshots"] as? [[String: Any]]) ?? []
            try #require(projected.count == 1)
            let projectedId = projected[0]["id"] as? String
            #expect(projectedId != nil)
            #expect(projectedId != sourceAttachmentId)
            #expect(projected[0]["filename"] as? String == "private-source.txt")

            func attachmentURL(_ id: String, token: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.get, headers: headers, to: URI(string: "/api/attachments/\(id)/url"))
            }
            let destinationURL = try await attachmentURL(projectedId ?? "", token: viewerToken)
            #expect(destinationURL.status == .ok)
            let sourceURL = try await attachmentURL(sourceAttachmentId, token: viewerToken)
            #expect(sourceURL.status == .notFound)
            var contextHeaders = HTTPFields()
            contextHeaders[.authorization] = "Bearer \(viewerToken)"
            contextHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let context = try await client.send(.get, headers: contextHeaders, to: URI(string: "/api/messages/context/\(sourceMessageId)?channelId=\(privateChannelId)"))
            #expect(context.status == .notFound)
            #expect(bodyText(context).contains("private source body") == false)
        }
    }
}

@Test func messageForwardRejectsAShortSourceIdBeforeResolvingIt() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111160"
    let viewerId = "11111111-1111-4111-8111-111111111161"
    let serverId = "33333333-3333-4333-8333-333333333366"
    let privateChannelId = "22222222-2222-4222-8222-222222222273"
    let destinationId = "22222222-2222-4222-8222-222222222274"
    accounts.addAccount(id: ownerId, email: "forward-short-owner@slock.test", password: "password123")
    accounts.addAccount(id: viewerId, email: "forward-short-viewer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: viewerId)
    accounts.addPostableChannel(serverId: serverId, channelId: privateChannelId, memberId: ownerId, kind: "private", name: "forward-short-private")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: viewerId, name: "forward-short-destination")
    accounts.insertHumanMessage(id: "aaaaaaaa-1111-4111-8111-111111111111", channelId: privateChannelId, senderId: ownerId, content: "hidden ambiguous private one")
    accounts.insertHumanMessage(id: "aaaaaaaa-2222-4222-8222-222222222222", channelId: privateChannelId, senderId: ownerId, content: "hidden ambiguous private two")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-short-viewer@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let response = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\"aaaaaaaa\"]}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(response.status == .badRequest)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            #expect(body?["error"] as? String == "Destination channel and full source message ids are required")
            #expect(body?["error"] as? String != "Message short id is ambiguous")
            #expect(body?["code"] as? String != "source_not_found")
            #expect(bodyText(response).contains("hidden ambiguous private") == false)
            #expect(accounts.humanMessageCount == 2)
        }
    }
}

@Test func messageForwardSupportsJointDestinationsAndRestrictedSources() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111162"
    let peerId = "11111111-1111-4111-8111-111111111163"
    let guestId = "11111111-1111-4111-8111-111111111164"
    let hostServerId = "33333333-3333-4333-8333-333333333367"
    let guestServerId = "33333333-3333-4333-8333-333333333368"
    let storageServerId = "33333333-3333-4333-8333-333333333369"
    let sourceId = "22222222-2222-4222-8222-222222222275"
    let privateSourceId = "22222222-2222-4222-8222-222222222276"
    let regularDestinationId = "22222222-2222-4222-8222-222222222277"
    let privateDestinationId = "22222222-2222-4222-8222-222222222278"
    let dmDestinationId = "22222222-2222-4222-8222-222222222279"
    let guestRegularDestinationId = "22222222-2222-4222-8222-222222222280"
    let canonicalId = "22222222-2222-4222-8222-222222222281"
    let hostProjectionId = "22222222-2222-4222-8222-222222222282"
    let guestProjectionId = "22222222-2222-4222-8222-222222222283"
    accounts.addAccount(id: ownerId, email: "forward-joint-owner@slock.test", password: "password123")
    accounts.addAccount(id: peerId, email: "forward-joint-dm-peer@slock.test", password: "password123")
    accounts.addAccount(id: guestId, email: "forward-joint-guest@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: peerId)
    accounts.markEmailVerified(userId: guestId)
    accounts.addPostableChannel(serverId: hostServerId, channelId: sourceId, memberId: ownerId, name: "forward-joint-source")
    accounts.addPostableChannel(serverId: hostServerId, channelId: privateSourceId, memberId: ownerId, kind: "private", name: "forward-joint-private-source")
    accounts.addPostableChannel(serverId: hostServerId, channelId: regularDestinationId, memberId: ownerId, name: "forward-joint-regular-destination")
    accounts.addPostableChannel(serverId: hostServerId, channelId: privateDestinationId, memberId: ownerId, kind: "private", name: "forward-joint-private-destination")
    accounts.addDirectMessage(serverId: hostServerId, channelId: dmDestinationId, participantIds: [ownerId, peerId])
    accounts.addPostableChannel(serverId: guestServerId, channelId: guestRegularDestinationId, memberId: guestId, name: "forward-joint-guest-regular-destination")
    accounts.addPostableChannel(serverId: storageServerId, channelId: canonicalId, memberId: ownerId, name: "forward-joint-storage")
    accounts.addPostableChannel(serverId: hostServerId, channelId: hostProjectionId, memberId: ownerId, kind: "joint", name: "forward-joint-room")
    accounts.addPostableChannel(serverId: guestServerId, channelId: guestProjectionId, memberId: guestId, kind: "joint", name: "forward-joint-room")
    accounts.addPostableChannel(serverId: guestServerId, channelId: guestProjectionId, memberId: ownerId, kind: "joint")
    accounts.addJointChannelProjection(localChannelId: hostProjectionId, canonicalChannelId: canonicalId, serverId: hostServerId)
    accounts.addJointChannelProjection(localChannelId: guestProjectionId, canonicalChannelId: canonicalId, serverId: guestServerId)
    func items(_ response: ClientResponse) throws -> [[String: Any]] {
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        let metadata = body?["actionMetadata"] as? [String: Any]
        return (metadata?["forwardedItems"] as? [[String: Any]]) ?? []
    }
    func metadata(_ response: ClientResponse) throws -> [String: Any] {
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        return (body?["actionMetadata"] as? [String: Any]) ?? [:]
    }
    func snapshot(_ item: [String: Any]) -> [String: Any] {
        (item["sourceTargetSnapshot"] as? [String: Any]) ?? [:]
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-joint-owner@slock.test\",\"password\":\"password123\"}")
            let guestLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-joint-guest@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let guestToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(guestLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let ownerAuth = "Bearer \(ownerToken)"
            let guestAuth = "Bearer \(guestToken)"
            let publicSent = try await postJSON(client, path: "/api/messages", body: "{\"channelId\":\"\(sourceId)\",\"content\":\"public source into joint\"}", authorization: ownerAuth, serverId: hostServerId)
            let privateSent = try await postJSON(client, path: "/api/messages", body: "{\"channelId\":\"\(privateSourceId)\",\"content\":\"private source into joint\"}", authorization: ownerAuth, serverId: hostServerId)
            let dmSent = try await postJSON(client, path: "/api/messages", body: "{\"channelId\":\"\(dmDestinationId)\",\"content\":\"dm source stays restricted\"}", authorization: ownerAuth, serverId: hostServerId)
            #expect(publicSent.status == .ok)
            #expect(privateSent.status == .ok)
            #expect(dmSent.status == .ok)
            let publicSourceMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(publicSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let privateSourceMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(privateSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let dmSourceMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(dmSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            let jointSourceMessageId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
            accounts.insertHumanMessage(id: jointSourceMessageId, channelId: canonicalId, senderId: ownerId, content: "joint source stays restricted")

            let toJoint = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(hostProjectionId)\",\"sourceMessageIds\":[\"\(publicSourceMessageId)\"]}",
                authorization: ownerAuth,
                serverId: hostServerId
            )
            #expect(toJoint.status == .ok)
            let toJointBody = try JSONSerialization.jsonObject(with: Data(bodyText(toJoint).utf8)) as? [String: Any]
            #expect(toJointBody?["channelId"] as? String == hostProjectionId)
            #expect(try metadata(toJoint)["destinationTargetId"] as? String == hostProjectionId)
            let toJointItems = try items(toJoint)
            try #require(toJointItems.count == 1)
            #expect(toJointItems[0]["sourceMessageId"] as? String == publicSourceMessageId)
            #expect(toJointItems[0]["contentSnapshot"] as? String == "public source into joint")
            #expect(snapshot(toJointItems[0])["label"] as? String == "#forward-joint-source")
            #expect(snapshot(toJointItems[0])["labelVisibility"] as? String == "public")
            let toJointId = toJointBody?["id"] as? String

            let privateToJoint = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(hostProjectionId)\",\"sourceMessageIds\":[\"\(privateSourceMessageId)\"]}",
                authorization: ownerAuth,
                serverId: hostServerId
            )
            #expect(privateToJoint.status == .ok)
            let privateItems = try items(privateToJoint)
            try #require(privateItems.count == 1)
            #expect(privateItems[0]["sourceMessageId"] is NSNull)
            #expect(privateItems[0]["contentSnapshot"] as? String == "private source into joint")
            #expect(snapshot(privateItems[0])["label"] as? String == "")
            #expect(snapshot(privateItems[0])["id"] is NSNull)
            let privateToJointId = ((try JSONSerialization.jsonObject(with: Data(bodyText(privateToJoint).utf8)) as? [String: Any])?["id"] as? String) ?? ""

            func listedItem(_ path: String, token: String, server: String, messageId: String?) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = server
                let response = try await client.send(.get, headers: headers, to: URI(string: path))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                let messages = (body?["messages"] as? [[String: Any]]) ?? []
                let message = messages.first { $0["id"] as? String == messageId }
                let forwarded = ((message?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
                return forwarded.first ?? [:]
            }
            let hostItem = try await listedItem("/api/messages/channel/\(hostProjectionId)", token: ownerToken, server: hostServerId, messageId: toJointId)
            #expect(snapshot(hostItem)["label"] as? String == "#forward-joint-source")
            #expect(hostItem["sourceTargetId"] as? String == sourceId)
            #expect(hostItem["provenanceState"] as? String == "available")

            var guestHeaders = HTTPFields()
            guestHeaders[.authorization] = guestAuth
            guestHeaders[HTTPField.Name("X-Server-Id")!] = guestServerId
            let guestList = try await client.send(.get, headers: guestHeaders, to: URI(string: "/api/messages/channel/\(guestProjectionId)"))
            #expect(guestList.status == .ok)
            let guestMessages = ((try JSONSerialization.jsonObject(with: Data(bodyText(guestList).utf8)) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            func guestItem(_ id: String?) -> [String: Any] {
                let message = guestMessages.first { $0["id"] as? String == id }
                return (((message?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []).first ?? [:]
            }
            let guestPublic = guestItem(toJointId)
            let guestPrivate = guestItem(privateToJointId)
            #expect(guestPublic["contentSnapshot"] as? String == "public source into joint")
            #expect(guestPublic["sourceTargetId"] is NSNull)
            #expect(snapshot(guestPublic)["id"] is NSNull)
            #expect(snapshot(guestPublic)["label"] as? String == "")
            #expect(snapshot(guestPublic)["labelVisibility"] as? String == "restricted")
            #expect(guestPublic["provenanceState"] as? String == "original_unavailable")
            #expect(guestPrivate["contentSnapshot"] as? String == "private source into joint")
            #expect(guestPrivate["sourceTargetId"] is NSNull)
            #expect(snapshot(guestPrivate)["label"] as? String == "")
            #expect(guestPrivate["provenanceState"] as? String == "original_unavailable")

            let sameUserItem = try await listedItem("/api/messages/channel/\(guestProjectionId)", token: ownerToken, server: guestServerId, messageId: toJointId)
            #expect(sameUserItem["sourceServerId"] is NSNull)
            #expect(sameUserItem["sourceTargetId"] is NSNull)
            #expect(snapshot(sameUserItem)["id"] is NSNull)
            #expect(snapshot(sameUserItem)["label"] as? String == "")
            #expect(snapshot(sameUserItem)["labelVisibility"] as? String == "restricted")
            #expect(sameUserItem["provenanceState"] as? String == "original_unavailable")

            let guestContext = try await client.send(.get, headers: guestHeaders, to: URI(string: "/api/messages/context/\(toJointId ?? "")?channelId=\(guestProjectionId)"))
            #expect(guestContext.status == .ok)
            let guestContextMessages = ((try JSONSerialization.jsonObject(with: Data(bodyText(guestContext).utf8)) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            let guestContextItem = (((guestContextMessages.first { $0["id"] as? String == toJointId }?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []).first ?? [:]
            #expect(guestContextItem["sourceTargetId"] is NSNull)
            #expect(snapshot(guestContextItem)["label"] as? String == "")
            #expect(snapshot(guestContextItem)["labelVisibility"] as? String == "restricted")
            #expect(guestContextItem["provenanceState"] as? String == "original_unavailable")

            var ownerGuestHeaders = HTTPFields()
            ownerGuestHeaders[.authorization] = ownerAuth
            ownerGuestHeaders[HTTPField.Name("X-Server-Id")!] = guestServerId
            let sameUserContext = try await client.send(.get, headers: ownerGuestHeaders, to: URI(string: "/api/messages/context/\(toJointId ?? "")?channelId=\(guestProjectionId)"))
            #expect(sameUserContext.status == .ok)
            let sameUserContextMessages = ((try JSONSerialization.jsonObject(with: Data(bodyText(sameUserContext).utf8)) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            let sameUserContextItem = (((sameUserContextMessages.first { $0["id"] as? String == toJointId }?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []).first ?? [:]
            #expect(sameUserContextItem["sourceServerId"] is NSNull)
            #expect(snapshot(sameUserContextItem)["label"] as? String == "")
            #expect(snapshot(sameUserContextItem)["labelVisibility"] as? String == "restricted")

            let sync = try await client.send(.get, headers: ownerGuestHeaders, to: URI(string: "/api/messages/sync?since_seq=0&channel_id=\(guestProjectionId)"))
            #expect(sync.status == .ok)
            let syncMessages = (try JSONSerialization.jsonObject(with: Data(bodyText(sync).utf8)) as? [[String: Any]]) ?? []
            let syncItem = (((syncMessages.first { $0["id"] as? String == toJointId }?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []).first ?? [:]
            #expect(syncItem["sourceServerId"] is NSNull)
            #expect(snapshot(syncItem)["label"] as? String == "")
            #expect(snapshot(syncItem)["labelVisibility"] as? String == "restricted")

            let fromJoint = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(regularDestinationId)\",\"sourceMessageIds\":[\"\(jointSourceMessageId)\"]}",
                authorization: ownerAuth,
                serverId: hostServerId
            )
            #expect(fromJoint.status == .ok)
            let fromJointBody = try JSONSerialization.jsonObject(with: Data(bodyText(fromJoint).utf8)) as? [String: Any]
            #expect(fromJointBody?["channelId"] as? String == regularDestinationId)
            let fromJointItems = try items(fromJoint)
            try #require(fromJointItems.count == 1)
            #expect(fromJointItems[0]["contentSnapshot"] as? String == "joint source stays restricted")
            #expect(fromJointItems[0]["sourceServerId"] is NSNull)
            #expect(fromJointItems[0]["sourceTargetId"] is NSNull)
            #expect(fromJointItems[0]["sourceMessageId"] is NSNull)
            #expect(snapshot(fromJointItems[0])["type"] as? String == "joint")
            #expect(snapshot(fromJointItems[0])["id"] is NSNull)
            #expect(snapshot(fromJointItems[0])["label"] as? String == "")
            #expect(snapshot(fromJointItems[0])["labelVisibility"] as? String == "restricted")
            #expect(fromJointItems[0]["provenanceState"] as? String == "available")

            let guestFromJoint = try await postJSON(
                client,
                path: "/api/messages/forward",
                body: "{\"destinationChannelId\":\"\(guestRegularDestinationId)\",\"sourceMessageIds\":[\"\(jointSourceMessageId)\"]}",
                authorization: guestAuth,
                serverId: guestServerId
            )
            #expect(guestFromJoint.status == .ok)
            let guestFromBody = try JSONSerialization.jsonObject(with: Data(bodyText(guestFromJoint).utf8)) as? [String: Any]
            #expect(guestFromBody?["channelId"] as? String == guestRegularDestinationId)
            let guestFromItems = try items(guestFromJoint)
            try #require(guestFromItems.count == 1)
            #expect(guestFromItems[0]["contentSnapshot"] as? String == "joint source stays restricted")
            #expect(guestFromItems[0]["sourceServerId"] is NSNull)
            #expect(guestFromItems[0]["sourceTargetId"] is NSNull)
            #expect(guestFromItems[0]["sourceMessageId"] is NSNull)
            #expect(snapshot(guestFromItems[0])["type"] as? String == "joint")
            #expect(snapshot(guestFromItems[0])["id"] is NSNull)
            #expect(snapshot(guestFromItems[0])["label"] as? String == "")
            #expect(snapshot(guestFromItems[0])["labelVisibility"] as? String == "restricted")

            let sources: [(type: String, id: String, content: String, visibility: String)] = [
                ("channel", publicSourceMessageId, "public source into joint", "public"),
                ("private", privateSourceMessageId, "private source into joint", "restricted"),
                ("dm", dmSourceMessageId, "dm source stays restricted", "restricted"),
                ("joint", jointSourceMessageId, "joint source stays restricted", "restricted"),
            ]
            let destinations: [(type: String, id: String)] = [
                ("channel", regularDestinationId),
                ("private", privateDestinationId),
                ("dm", dmDestinationId),
                ("joint", hostProjectionId),
            ]
            var accepted: [String] = []
            for source in sources {
                for destination in destinations {
                    let response = try await postJSON(
                        client,
                        path: "/api/messages/forward",
                        body: "{\"destinationChannelId\":\"\(destination.id)\",\"sourceMessageIds\":[\"\(source.id)\"]}",
                        authorization: ownerAuth,
                        serverId: hostServerId
                    )
                    #expect(response.status == .ok)
                    let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                    #expect(body?["channelId"] as? String == destination.id)
                    #expect(try metadata(response)["destinationTargetId"] as? String == destination.id)
                    let forwarded = try items(response)
                    #expect(forwarded.first?["contentSnapshot"] as? String == source.content)
                    #expect(snapshot(forwarded.first ?? [:])["type"] as? String == source.type)
                    #expect(snapshot(forwarded.first ?? [:])["labelVisibility"] as? String == source.visibility)
                    let expectedLabel = source.visibility == "public" ? "#forward-joint-source" : ""
                    #expect(snapshot(forwarded.first ?? [:])["label"] as? String == expectedLabel)
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

@Test func messageForwardRejectsCrossSourceAndNonOrdinaryMessages() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111165"
    let serverId = "33333333-3333-4333-8333-333333333370"
    let sourceA = "22222222-2222-4222-8222-222222222284"
    let sourceB = "22222222-2222-4222-8222-222222222285"
    let destinationId = "22222222-2222-4222-8222-222222222286"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab7"
    accounts.addAccount(id: ownerId, email: "forward-reject-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: sourceA, memberId: ownerId, name: "forward-reject-source-a")
    accounts.addPostableChannel(serverId: serverId, channelId: sourceB, memberId: ownerId, name: "forward-reject-source-b")
    accounts.addPostableChannel(serverId: serverId, channelId: destinationId, memberId: ownerId, name: "forward-reject-destination")
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "forward-task-recipient", avatarUrl: nil)
    accounts.addChannelAgent(channelId: destinationId, agentId: agentId)
    let systemId = "cccccccc-cccc-4ccc-8ccc-ccccccccccc1"
    let actionId = "cccccccc-cccc-4ccc-8ccc-ccccccccccc2"
    let forwardedId = "cccccccc-cccc-4ccc-8ccc-ccccccccccc3"
    let taskFields = ["taskStatus", "taskNumber", "taskAssigneeType", "taskAssigneeId", "taskClaimedAt", "taskCompletedAt"]
    accounts.insertHumanMessage(id: systemId, channelId: sourceA, senderId: "system", content: "system source", messageType: "system")
    accounts.insertHumanMessage(id: actionId, channelId: sourceA, senderId: ownerId, content: "action source", actionKind: "action-card")
    accounts.insertHumanMessage(id: forwardedId, channelId: sourceA, senderId: ownerId, content: "forwarded source", actionKind: "forwarded-bundle")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"forward-reject-owner@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            func send(_ channelId: String, _ content: String) async throws -> String {
                let response = try await postJSON(
                    client,
                    path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"}",
                    authorization: authorization,
                    serverId: serverId
                )
                #expect(response.status == .ok)
                return ((try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            }
            let messageA = try await send(sourceA, "source a")
            let messageB = try await send(sourceB, "source b")
            let taskId = try await send(sourceA, "task source")
            accounts.setHumanMessageTask(
                messageId: taskId,
                status: "done",
                number: 1,
                assigneeType: "agent",
                assigneeId: agentId,
                claimedAt: "2026-07-16T01:00:00.000Z",
                completedAt: "2026-07-16T02:00:00.000Z"
            )
            func forward(_ ids: [String]) async throws -> ClientResponse {
                let encoded = ids.map { "\"\($0)\"" }.joined(separator: ",")
                return try await postJSON(
                    client,
                    path: "/api/messages/forward",
                    body: "{\"destinationChannelId\":\"\(destinationId)\",\"sourceMessageIds\":[\(encoded)]}",
                    authorization: authorization,
                    serverId: serverId
                )
            }
            let crossSource = try await forward([messageA, messageB])
            #expect(crossSource.status == .badRequest)
            let crossBody = try JSONSerialization.jsonObject(with: Data(bodyText(crossSource).utf8)) as? [String: Any]
            #expect(crossBody?["code"] as? String == "cross_source_bundle")

            let taskForward = try await forward([taskId])
            #expect(taskForward.status == .ok)
            let taskBody = try JSONSerialization.jsonObject(with: Data(bodyText(taskForward).utf8)) as? [String: Any]
            #expect(taskBody?["messageType"] as? String == "chat")
            let taskItems = ((taskBody?["actionMetadata"] as? [String: Any])?["forwardedItems"] as? [[String: Any]]) ?? []
            #expect(taskItems.first?["contentSnapshot"] as? String == "task source")
            for field in taskFields {
                #expect(taskBody?[field] == nil)
            }
            let taskForwardId = taskBody?["id"] as? String
            var headers = HTTPFields()
            headers[.authorization] = authorization
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let history = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(destinationId)"))
            #expect(history.status == .ok)
            let historyMessages = ((try JSONSerialization.jsonObject(with: Data(bodyText(history).utf8)) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            let historyMessage = historyMessages.first { $0["id"] as? String == taskForwardId }
            #expect(historyMessage != nil)
            for field in taskFields {
                #expect(historyMessage?[field] == nil)
            }
            let context = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/context/\(taskForwardId ?? "")?channelId=\(destinationId)"))
            #expect(context.status == .ok)
            let contextMessages = ((try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            let contextMessage = contextMessages.first { $0["id"] as? String == taskForwardId }
            #expect(contextMessage != nil)
            for field in taskFields {
                #expect(contextMessage?[field] == nil)
            }

            for sourceId in [systemId, actionId] {
                let rejected = try await forward([sourceId])
                #expect(rejected.status == .badRequest)
                let rejectedBody = try JSONSerialization.jsonObject(with: Data(bodyText(rejected).utf8)) as? [String: Any]
                #expect(rejectedBody?["code"] as? String == "unsupported_source_message")
            }
            let nested = try await forward([forwardedId])
            #expect(nested.status == .badRequest)
            let nestedBody = try JSONSerialization.jsonObject(with: Data(bodyText(nested).utf8)) as? [String: Any]
            #expect(nestedBody?["error"] as? String == "Forwarded messages can't be forwarded. Select the original message instead.")
            #expect(nestedBody?["code"] as? String == "forwarded_source_not_supported")
            #expect(accounts.humanMessageCount == 7)
        }
    }
}

@Test func messageForwardTargetSearchReturnsChannelsDMsAgentsAndHumans() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111166"
    let otherId = "11111111-1111-4111-8111-111111111167"
    let outsiderId = "11111111-1111-4111-8111-111111111168"
    let serverId = "33333333-3333-4333-8333-333333333371"
    let publicChannelId = "22222222-2222-4222-8222-222222222287"
    let joinedChannelId = "22222222-2222-4222-8222-222222222288"
    let privateVisibleId = "22222222-2222-4222-8222-222222222289"
    let privateHiddenId = "22222222-2222-4222-8222-222222222290"
    let dmChannelId = "22222222-2222-4222-8222-222222222291"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab8"
    accounts.addAccount(id: ownerId, email: "fwd-search-owner@slock.test", password: "password123")
    accounts.addAccount(id: otherId, email: "fwd-search-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: otherId)
    accounts.setServerMemberRole(serverId: serverId, userId: ownerId, role: "owner")
    accounts.setServerMemberRole(serverId: serverId, userId: otherId, role: "member")
    accounts.addPostableChannel(serverId: serverId, channelId: publicChannelId, memberId: outsiderId, name: "search-public")
    accounts.addPostableChannel(serverId: serverId, channelId: joinedChannelId, memberId: ownerId, name: "search-joined")
    accounts.addPostableChannel(serverId: serverId, channelId: privateVisibleId, memberId: ownerId, kind: "private", name: "search-private-visible")
    accounts.addPostableChannel(serverId: serverId, channelId: privateHiddenId, memberId: outsiderId, kind: "private", name: "search-private-hidden")
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "search-agent", avatarUrl: nil)
    accounts.addDirectMessage(serverId: serverId, channelId: dmChannelId, participantIds: [ownerId, agentId], agentId: agentId)
    func targets(_ client: any Client, query: String, token: String) async throws -> [[String: Any]] {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = serverId
        let response = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/forward/targets/search?q=\(query)"))
        #expect(response.status == .ok)
        let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
        return (body?["targets"] as? [[String: Any]]) ?? []
    }
    func flag(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        return (value as? NSNumber)?.boolValue
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"fwd-search-owner@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let empty = try await targets(client, query: "", token: token)
            #expect(empty.isEmpty)

            let publicTargets = try await targets(client, query: "search-public", token: token)
            let publicTarget = publicTargets.first { $0["title"] as? String == "#search-public" }
            #expect(publicTarget != nil)
            #expect(publicTarget?["type"] as? String == "channel")
            #expect(publicTarget?["channelType"] as? String == "channel")
            #expect(flag(publicTarget?["canForwardNow"]) == false)
            #expect(publicTarget?["requiredAction"] as? String == "join_channel")
            #expect(flag(publicTarget?["joined"]) == false)

            let joinedTargets = try await targets(client, query: "search-joined", token: token)
            let joinedTarget = joinedTargets.first { $0["title"] as? String == "#search-joined" }
            #expect(joinedTarget != nil)
            #expect(flag(joinedTarget?["canForwardNow"]) == true)
            #expect(flag(joinedTarget?["joined"]) == true)

            let privateTargets = try await targets(client, query: "search-private", token: token)
            #expect(privateTargets.compactMap { $0["title"] as? String } == ["#search-private-visible"])
            #expect(privateTargets.first?["channelType"] as? String == "private")
            #expect(flag(privateTargets.first?["canForwardNow"]) == true)
            #expect(privateTargets.first?["requiredAction"] == nil || privateTargets.first?["requiredAction"] is NSNull)
            #expect(bodyText(try await {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.get, headers: headers, to: URI(string: "/api/messages/forward/targets/search?q=search-private"))
            }()).contains("search-private-hidden") == false)

            let humanTargets = try await targets(client, query: "fwd-search-other", token: token)
            let human = humanTargets.first { $0["type"] as? String == "human" }
            #expect(human != nil)
            #expect(human?["requiredAction"] as? String == "create_dm")
            #expect(flag(human?["dmExists"]) == false)

            let agentTargets = try await targets(client, query: "search-agent", token: token)
            let dm = agentTargets.first { $0["type"] as? String == "dm" }
            #expect(dm != nil)
            #expect(flag(dm?["dmExists"]) == true)
        }
    }
}

@Test func mentionDeliveriesAreVisibleOnlyToTheAuthorWhoCanStillReadTheChannel() async throws {
    let accounts = EmailLoginDirectory()
    let authorId = "11111111-1111-4111-8111-111111111169"
    let peerId = "11111111-1111-4111-8111-111111111170"
    let serverId = "33333333-3333-4333-8333-333333333372"
    let otherServerId = "33333333-3333-4333-8333-333333333373"
    let channelId = "22222222-2222-4222-8222-222222222292"
    let agentId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaab9"
    let messageId = "dddddddd-dddd-4ddd-8ddd-ddddddddddd1"
    let unknownId = "dddddddd-dddd-4ddd-8ddd-ddddddddddd2"
    accounts.addAccount(id: authorId, email: "mention-delivery-author@slock.test", password: "password123")
    accounts.addAccount(id: peerId, email: "mention-delivery-peer@slock.test", password: "password123")
    accounts.markEmailVerified(userId: authorId)
    accounts.markEmailVerified(userId: peerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: authorId, kind: "private", name: "mention-delivery")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: peerId, kind: "private")
    accounts.addServerAgent(serverId: serverId, id: agentId, name: "mention-delivery-agent", avatarUrl: nil)
    accounts.insertHumanMessage(id: messageId, channelId: channelId, senderId: authorId, content: "synthetic")
    accounts.recordAgentMentionDelivery(messageId: messageId, agentId: agentId, handle: "original-name", terminalCode: "IDENTITY_DRIFT")
    let machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: agentId)
    let path = "/api/messages/\(messageId)/mention-deliveries"
    func get(_ client: any Client, url: String, token: String, server: String) async throws -> ClientResponse {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(token)"
        headers[HTTPField.Name("X-Server-Id")!] = server
        return try await client.send(.get, headers: headers, to: URI(string: url))
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let authorLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"mention-delivery-author@slock.test\",\"password\":\"password123\"}")
            let peerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"mention-delivery-peer@slock.test\",\"password\":\"password123\"}")
            let authorToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(authorLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let peerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(peerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let allowed = try await get(client, url: path, token: authorToken, server: serverId)
            #expect(allowed.status == .ok)
            #expect(bodyText(allowed) == "{\"messageId\":\"\(messageId)\",\"deliveries\":[{\"targetId\":\"\(agentId)\",\"targetHandle\":\"original-name\",\"outcome\":\"lost\",\"reasonCategory\":\"unclassified\"}]}")
            for (token, server, url) in [
                (peerToken, serverId, path),
                (authorToken, otherServerId, path),
                (authorToken, serverId, "/api/messages/\(unknownId)/mention-deliveries"),
            ] {
                let denied = try await get(client, url: url, token: token, server: server)
                #expect(denied.status == .notFound)
                #expect(bodyText(denied) == "{\"status\":\"NOT_JOINABLE\"}")
            }
            accounts.removeChannelMember(channelId: channelId, memberId: authorId)
            let revoked = try await get(client, url: path, token: authorToken, server: serverId)
            #expect(revoked.status == .notFound)
            #expect(bodyText(revoked) == "{\"status\":\"NOT_JOINABLE\"}")
            let agentRead = try await get(client, url: path, token: machineKey, server: serverId)
            #expect(agentRead.status == .unauthorized)
            #expect(bodyText(agentRead).contains("deliveries") == false)
        }
    }
}

@Test func messageContextWindowIsSizedByBeforeAndAfterAndDefaultsToFifteen() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111171"
    let serverId = "33333333-3333-4333-8333-333333333374"
    let channelId = "22222222-2222-4222-8222-222222222293"
    accounts.addAccount(id: ownerId, email: "context-window@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "context-window")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"context-window@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            var ids: [String] = []
            for index in 0..<40 {
                let sent = try await postJSON(
                    client,
                    path: "/api/messages",
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"message \(index)\"}",
                    authorization: "Bearer \(token)",
                    serverId: serverId
                )
                #expect(sent.status == .ok)
                ids.append(((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? "")
            }
            let target = ids[20]
            func context(_ query: String) async throws -> [String] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                let response = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/context/\(target)?channelId=\(channelId)\(query)"))
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                return ((body?["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            }
            #expect(try await context("&before=0&after=0") == [target])
            #expect(try await context("&before=2&after=1") == Array(ids[18..<22]))
            #expect(try await context("") == Array(ids[5..<36]))
            #expect(try await context("&before=500&after=-3") == Array(ids[5..<36]))
        }
    }
}

@Test func messageHistoryReadsNeverSerializeSearchIndexColumns() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111172"
    let serverId = "33333333-3333-4333-8333-333333333375"
    let channelId = "22222222-2222-4222-8222-222222222294"
    accounts.addAccount(id: ownerId, email: "storage-cols@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "storage-cols")
    let storageKeys = ["searchText", "searchVector"]
    func assertNoStorageKeys(_ surface: String, _ rows: [[String: Any]]) {
        #expect(!rows.isEmpty, "\(surface) must return messages to examine")
        for row in rows {
            for key in storageKeys {
                #expect(row[key] == nil, "\(surface) must not serialize storage-only \(key)")
            }
        }
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"storage-cols@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let first = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"searchable words for the index\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            let second = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"another searchable message\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(first.status == .ok)
            #expect(second.status == .ok)
            let firstId = ((try JSONSerialization.jsonObject(with: Data(bodyText(first).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let page = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(channelId)?limit=50"))
            #expect(page.status == .ok)
            let pageBody = try JSONSerialization.jsonObject(with: Data(bodyText(page).utf8)) as? [String: Any]
            assertNoStorageKeys("channel page", (pageBody?["messages"] as? [[String: Any]]) ?? [])
            let context = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/context/\(firstId)?channelId=\(channelId)"))
            #expect(context.status == .ok)
            let contextBody = try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any]
            assertNoStorageKeys("message context", (contextBody?["messages"] as? [[String: Any]]) ?? [])
            let sync = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/sync?since_seq=0&channel_id=\(channelId)"))
            #expect(sync.status == .ok)
            let syncRows = (try JSONSerialization.jsonObject(with: Data(bodyText(sync).utf8)) as? [[String: Any]]) ?? []
            assertNoStorageKeys("message sync", syncRows)
        }
    }
}

@Test func webSendRecordsAValidSenderTimeZoneAndNeverSerializesIt() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111173"
    let serverId = "33333333-3333-4333-8333-333333333376"
    let channelId = "22222222-2222-4222-8222-222222222295"
    accounts.addAccount(id: ownerId, email: "sender-tz@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "sender-tz")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"sender-tz@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            func send(path: String, content: String, timezoneJSON: String? = nil) async throws -> String? {
                let timezonePart = timezoneJSON.map { ",\"timezone\":\($0)" } ?? ""
                let response = try await postJSON(
                    client,
                    path: path,
                    body: "{\"channelId\":\"\(channelId)\",\"content\":\"\(content)\"\(timezonePart)}",
                    authorization: authorization,
                    serverId: serverId
                )
                #expect(response.status == .ok, "\(content): an unusable zone must not fail the send")
                let root = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                let message = (path == "/api/v2/messages" ? root?["message"] as? [String: Any] : root) ?? [:]
                #expect(message["senderTimezone"] == nil, "\(content): send response must not echo the zone")
                let messageId = message["id"] as? String ?? ""
                return accounts.storedSenderTimezone(messageId: messageId)
            }
            #expect(try await send(path: "/api/v2/messages", content: "valid v2", timezoneJSON: "\"Asia/Shanghai\"") == "Asia/Shanghai")
            #expect(try await send(path: "/api/messages", content: "valid v1", timezoneJSON: "\" Europe/Berlin \"") == "Europe/Berlin")
            #expect(try await send(path: "/api/v2/messages", content: "utc", timezoneJSON: "\"UTC\"") == "UTC")
            #expect(try await send(path: "/api/v2/messages", content: "unknown zone", timezoneJSON: "\"Mars/Olympus_Mons\"") == nil)
            #expect(try await send(path: "/api/v2/messages", content: "abbreviation", timezoneJSON: "\"EST\"") == nil)
            #expect(try await send(path: "/api/v2/messages", content: "offset", timezoneJSON: "\"+05:00\"") == nil)
            let overlong = "Asia/\(String(repeating: "x", count: 200))"
            #expect(try await send(path: "/api/v2/messages", content: "overlong", timezoneJSON: "\"\(overlong)\"") == nil)
            #expect(try await send(path: "/api/v2/messages", content: "non-string", timezoneJSON: "480") == nil)
            #expect(try await send(path: "/api/v2/messages", content: "null", timezoneJSON: "null") == nil)
            #expect(try await send(path: "/api/v2/messages", content: "omitted") == nil)

            var headers = HTTPFields()
            headers[.authorization] = authorization
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func assertNoSenderTimezone(_ surface: String, _ rows: [[String: Any]]) {
                #expect(!rows.isEmpty, "\(surface) must return messages to examine")
                for row in rows {
                    #expect(row["senderTimezone"] == nil, "\(surface) must not serialize senderTimezone")
                }
            }
            let page = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(channelId)?limit=50"))
            #expect(page.status == .ok)
            let pageBody = try JSONSerialization.jsonObject(with: Data(bodyText(page).utf8)) as? [String: Any]
            let pageRows = (pageBody?["messages"] as? [[String: Any]]) ?? []
            assertNoSenderTimezone("channel page", pageRows)
            let zoned = try #require(pageRows.first { $0["content"] as? String == "valid v2" })
            let zonedId = try #require(zoned["id"] as? String)
            let context = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/context/\(zonedId)?channelId=\(channelId)"))
            #expect(context.status == .ok)
            let contextBody = try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any]
            assertNoSenderTimezone("message context", (contextBody?["messages"] as? [[String: Any]]) ?? [])
            let sync = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/sync?since_seq=0&channel_id=\(channelId)"))
            #expect(sync.status == .ok)
            let syncRows = (try JSONSerialization.jsonObject(with: Data(bodyText(sync).utf8)) as? [[String: Any]]) ?? []
            assertNoSenderTimezone("message sync", syncRows)
        }
    }
}

@Test func messagesPageCarriesThreadSummariesForItsParents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111174"
    let serverId = "33333333-3333-4333-8333-333333333377"
    let channelId = "22222222-2222-4222-8222-222222222296"
    let threadId = "22222222-2222-4222-8222-222222222297"
    accounts.addAccount(id: ownerId, email: "summary-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "summaries")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"summary-owner@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            func send(_ channel: String, _ content: String) async throws -> String {
                let response = try await postJSON(
                    client,
                    path: "/api/messages",
                    body: "{\"channelId\":\"\(channel)\",\"content\":\"\(content)\"}",
                    authorization: authorization,
                    serverId: serverId
                )
                #expect(response.status == .ok)
                return ((try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            }
            let parentId = try await send(channelId, "parent with replies")
            let plainId = try await send(channelId, "plain message")
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: channelId, parentMessageId: parentId, memberId: ownerId)
            _ = try await send(threadId, "first reply")
            _ = try await send(threadId, "second reply")
            var headers = HTTPFields()
            headers[.authorization] = authorization
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let page = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(channelId)?limit=50"))
            #expect(page.status == .ok)
            let pageBody = try #require(JSONSerialization.jsonObject(with: Data(bodyText(page).utf8)) as? [String: Any])
            let pageRows = (pageBody["messages"] as? [[String: Any]]) ?? []
            let summaries = try #require(pageBody["threadSummariesByParentMessageId"] as? [String: Any])
            let summary = try #require(summaries[parentId] as? [String: Any])
            #expect((summary["replyCount"] as? NSNumber)?.intValue == 2)
            let latest = (summary["latestReplies"] as? [[String: Any]]) ?? []
            #expect(latest.contains { $0["preview"] as? String == "second reply" })
            #expect(summaries[plainId] == nil)
            let pageIds = Set(pageRows.compactMap { $0["id"] as? String })
            for key in summaries.keys {
                #expect(pageIds.contains(key), "summary key \(key) must reference a message in this page")
            }
        }
    }
}

@Test func messageContextCarriesThreadSummariesForItsWindow() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111175"
    let serverId = "33333333-3333-4333-8333-333333333378"
    let channelId = "22222222-2222-4222-8222-222222222298"
    let threadId = "22222222-2222-4222-8222-222222222299"
    accounts.addAccount(id: ownerId, email: "summary-context@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "context-summaries")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"summary-context@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"context parent\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let parentId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: channelId, parentMessageId: parentId, memberId: ownerId)
            let reply = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(threadId)\",\"content\":\"context reply\"}",
                authorization: authorization,
                serverId: serverId
            )
            #expect(reply.status == .ok)
            var headers = HTTPFields()
            headers[.authorization] = authorization
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let context = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/context/\(parentId)?channelId=\(channelId)"))
            #expect(context.status == .ok)
            let body = try #require(JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any])
            let summaries = try #require(body["threadSummariesByParentMessageId"] as? [String: Any])
            let summary = try #require(summaries[parentId] as? [String: Any])
            #expect((summary["replyCount"] as? NSNumber)?.intValue == 1)
            let latest = (summary["latestReplies"] as? [[String: Any]]) ?? []
            #expect(latest.contains { $0["preview"] as? String == "context reply" })
            let contextIds = Set(((body["messages"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
            for key in summaries.keys {
                #expect(contextIds.contains(key), "summary key \(key) must reference a message in this context window")
            }
        }
    }
}

@Test func messagesPageReturnsAnEmptySummaryMapWhenThePageHasNoThreadParents() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111176"
    let serverId = "33333333-3333-4333-8333-333333333379"
    let channelId = "22222222-2222-4222-8222-222222222300"
    accounts.addAccount(id: ownerId, email: "summary-empty@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "no-threads")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"summary-empty@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"just a message\"}",
                authorization: "Bearer \(token)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let page = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(channelId)"))
            #expect(page.status == .ok)
            let body = try #require(JSONSerialization.jsonObject(with: Data(bodyText(page).utf8)) as? [String: Any])
            let summaries = try #require(body["threadSummariesByParentMessageId"] as? [String: Any])
            #expect(summaries.isEmpty)
        }
    }
}

@Test func threadSummaryScopeIsBoundToTheRequestedPageWindow() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111177"
    let serverId = "33333333-3333-4333-8333-333333333380"
    let channelId = "22222222-2222-4222-8222-222222222301"
    let threadId = "22222222-2222-4222-8222-222222222302"
    accounts.addAccount(id: ownerId, email: "summary-window@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, name: "windowed")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"summary-window@slock.test\",\"password\":\"password123\"}")
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let authorization = "Bearer \(token)"
            func send(_ channel: String, _ content: String) async throws -> String {
                let response = try await postJSON(
                    client,
                    path: "/api/messages",
                    body: "{\"channelId\":\"\(channel)\",\"content\":\"\(content)\"}",
                    authorization: authorization,
                    serverId: serverId
                )
                #expect(response.status == .ok)
                return ((try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            }
            let oldParentId = try await send(channelId, "old parent")
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: channelId, parentMessageId: oldParentId, memberId: ownerId)
            _ = try await send(threadId, "old reply")
            _ = try await send(channelId, "newer one")
            _ = try await send(channelId, "newer two")
            var headers = HTTPFields()
            headers[.authorization] = authorization
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let page = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(channelId)?limit=2"))
            #expect(page.status == .ok)
            let body = try #require(JSONSerialization.jsonObject(with: Data(bodyText(page).utf8)) as? [String: Any])
            let messages = (body["messages"] as? [[String: Any]]) ?? []
            #expect(!messages.contains { $0["id"] as? String == oldParentId })
            let summaries = (body["threadSummariesByParentMessageId"] as? [String: Any]) ?? [:]
            #expect(summaries[oldParentId] == nil)
        }
    }
}

@Test func channelAccessStillGatesTheSummariesCarryingPage() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111178"
    let outsiderId = "11111111-1111-4111-8111-111111111179"
    let serverId = "33333333-3333-4333-8333-333333333381"
    let channelId = "22222222-2222-4222-8222-222222222303"
    let threadId = "22222222-2222-4222-8222-222222222304"
    accounts.addAccount(id: ownerId, email: "summary-access@slock.test", password: "password123")
    accounts.addAccount(id: outsiderId, email: "summary-outsider@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: outsiderId)
    accounts.setServerMemberRole(serverId: serverId, userId: outsiderId, role: "member")
    accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: ownerId, kind: "private", name: "locked")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let ownerLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"summary-access@slock.test\",\"password\":\"password123\"}")
            let ownerToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(ownerLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let sent = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"secret parent\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(sent.status == .ok)
            let parentId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addThreadChannel(serverId: serverId, threadChannelId: threadId, parentChannelId: channelId, parentMessageId: parentId, memberId: ownerId)
            let reply = try await postJSON(
                client,
                path: "/api/messages",
                body: "{\"channelId\":\"\(threadId)\",\"content\":\"secret reply\"}",
                authorization: "Bearer \(ownerToken)",
                serverId: serverId
            )
            #expect(reply.status == .ok)
            let outsiderLogin = try await postJSON(client, path: "/api/auth/login", body: "{\"email\":\"summary-outsider@slock.test\",\"password\":\"password123\"}")
            let outsiderToken = ((try JSONSerialization.jsonObject(with: Data(bodyText(outsiderLogin).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(outsiderToken)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let page = try await client.send(.get, headers: headers, to: URI(string: "/api/messages/channel/\(channelId)"))
            #expect(page.status == .forbidden || page.status == .notFound)
        }
    }
}


private final class ReactionViewerEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []

    func append(room: String, event: String, payload: String?) {
        lock.lock()
        storage.append((room, event, payload))
        lock.unlock()
    }

    var events: [(room: String, event: String, payload: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
