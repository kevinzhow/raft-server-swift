import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private let leakMarkers = [
    "invalid input syntax for type uuid",
    "Failed query",
    "params:",
    "23505",
    "23503",
    "42P01",
    "22P02",
]

private func assertNoLeak(_ body: String) {
    let lowered = body.lowercased()
    for marker in leakMarkers {
        #expect(lowered.contains(marker.lowercased()) == false)
    }
    #expect(body.range(of: #"(?i)\b(select|insert|update|delete)\b[\s\S]*\bfrom\b\s+"[a-z_]+""#, options: .regularExpression) == nil)
}

private func encodeURIComponent(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.!~*'()")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func services(catalog: MessageContextCatalog = MessageContextCatalog()) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        messageContext: catalog
    )
}

private let authHeaders: HTTPFields = [
    .authorization: "Bearer token",
    HTTPField.Name("X-Server-Id")!: "33333333-3333-4333-8333-333333333333",
]

@Test func malformedMessageContextIdIsAClean400() async throws {
    let messageId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let swallowed = messageId + "这条你是不是没收到"
    try await withApp { app in
        configure(app, services: services())
        try await app.testing { client in
            for path in [
                "/api/messages/context/not-a-uuid",
                "/api/messages/context/\(encodeURIComponent(swallowed))",
            ] {
                let response = try await client.get(URI(string: path), headers: authHeaders)
                #expect(response.status == .badRequest)
                #expect(bodyText(response) == "{\"error\":\"Invalid message id\"}")
                #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                assertNoLeak(bodyText(response))
            }
        }
    }
}

@Test func malformedMessageContextChannelIdIsAClean400() async throws {
    let messageId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let channelId = "22222222-2222-4222-8222-222222222222"
    let catalog = MessageContextCatalog(messages: [
        ContextMessage(id: messageId, channelId: channelId, content: "hello", seq: 1),
    ])
    let swallowed = messageId + "这条你是不是没收到"
    try await withApp { app in
        configure(app, services: services(catalog: catalog))
        try await app.testing { client in
            for bad in ["not-a-uuid", encodeURIComponent(swallowed)] {
                let response = try await client.get(
                    "/api/messages/context/\(messageId)?channelId=\(bad)",
                    headers: authHeaders
                )
                #expect(response.status == .badRequest)
                #expect(bodyText(response) == "{\"error\":\"Invalid channel id\"}")
                assertNoLeak(bodyText(response))
            }
        }
    }
}

@Test func eightHexMessageShortIdStaysALegalContextTarget() async throws {
    let messageId = "abc123de-1111-4111-8111-111111111111"
    let channelId = "22222222-2222-4222-8222-222222222222"
    let otherChannel = "44444444-4444-4444-8444-444444444444"
    let catalog = MessageContextCatalog(messages: [
        ContextMessage(id: messageId, channelId: channelId, content: "hello", seq: 1),
    ])
    try await withApp { app in
        configure(app, services: services(catalog: catalog))
        try await app.testing { client in
            let shortId = try await client.get(
                "/api/messages/context/\(messageId.prefix(8))?channelId=\(channelId)",
                headers: authHeaders
            )
            #expect(shortId.status == .ok)
            #expect(bodyText(shortId) == "{\"channelId\":\"\(channelId)\",\"targetMessageId\":\"\(messageId)\",\"hasOlder\":false,\"hasNewer\":false,\"messages\":[{\"id\":\"\(messageId)\",\"channelId\":\"\(channelId)\",\"content\":\"hello\",\"seq\":1}],\"threadSummariesByParentMessageId\":{},\"historyLimited\":false,\"channelArchived\":false}")
            assertNoLeak(bodyText(shortId))

            let missing = try await client.get(
                "/api/messages/context/deadbeef?channelId=\(channelId)",
                headers: authHeaders
            )
            #expect(missing.status == .notFound)
            #expect(bodyText(missing) == "{\"error\":\"Message not found\"}")
            assertNoLeak(bodyText(missing))

            let other = try await client.get(
                "/api/messages/context/\(messageId.prefix(8))?channelId=\(otherChannel)",
                headers: authHeaders
            )
            #expect(other.status == .notFound)
            #expect(bodyText(other) == "{\"error\":\"Message not found\"}")
        }
    }
}

@Test func jointChannelPermalinkPreviewResolvesThroughTheCallersLocalProjection() async throws {
    let accounts = EmailLoginDirectory()
    let hostOwner = "11111111-1111-4111-8111-11111111111a"
    let guestOwner = "11111111-1111-4111-8111-11111111111b"
    let outsider = "11111111-1111-4111-8111-11111111111c"
    let guestServer = "33333333-3333-4333-8333-33333333333c"
    let hostChannel = "22222222-2222-4222-8222-22222222222b"
    let guestChannel = "22222222-2222-4222-8222-22222222222c"
    let messageId = "a1b2c3d4-5555-4555-8555-555555555555"
    let content = "joint permalink target"
    accounts.addAccount(id: hostOwner, email: "joint-link-host@slock.test", password: "password123")
    accounts.addAccount(id: guestOwner, email: "joint-link-guest@slock.test", password: "password123")
    accounts.addAccount(id: outsider, email: "joint-link-outsider@slock.test", password: "password123")
    let catalog = MessageContextCatalog(
        messages: [ContextMessage(id: messageId, channelId: hostChannel, content: content, seq: 1)],
        jointProjections: [JointChannelProjection(
            localChannelId: guestChannel,
            canonicalChannelId: hostChannel,
            serverId: guestServer,
            memberIds: [guestOwner]
        )]
    )
    func login(_ client: any Client, email: String) async throws -> String {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
            request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
        }
        #expect(response.status == .ok)
        return ((try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            messageContext: catalog,
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let guestToken = try await login(client, email: "joint-link-guest@slock.test")
            var guestHeaders = HTTPFields()
            guestHeaders[.authorization] = "Bearer \(guestToken)"
            guestHeaders[HTTPField.Name("X-Server-Id")!] = guestServer
            let context = try await client.get(
                URI(string: "/api/messages/context/\(messageId.prefix(8))?channelId=\(guestChannel)"),
                headers: guestHeaders
            )
            #expect(context.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any]
            #expect(body?["channelId"] as? String == guestChannel)
            #expect(body?["targetMessageId"] as? String == messageId)
            let messages = body?["messages"] as? [[String: Any]] ?? []
            #expect(messages.contains { message in
                message["id"] as? String == messageId
                    && message["channelId"] as? String == guestChannel
                    && message["content"] as? String == content
            })

            let outsiderToken = try await login(client, email: "joint-link-outsider@slock.test")
            var outsiderHeaders = HTTPFields()
            outsiderHeaders[.authorization] = "Bearer \(outsiderToken)"
            outsiderHeaders[HTTPField.Name("X-Server-Id")!] = guestServer
            let denied = try await client.get(
                URI(string: "/api/messages/context/\(messageId.prefix(8))?channelId=\(guestChannel)"),
                headers: outsiderHeaders
            )
            #expect(denied.status == .notFound)
            #expect(bodyText(denied).contains(content) == false)
        }
    }
}

@Test func jointChannelThreadPermalinkPreviewResolvesRepliesThroughTheCallersLocalProjection() async throws {
    let accounts = EmailLoginDirectory()
    let guestOwner = "11111111-1111-4111-8111-11111111111d"
    let hostChannel = "22222222-2222-4222-8222-22222222222d"
    let guestChannel = "22222222-2222-4222-8222-22222222222e"
    let guestServer = "33333333-3333-4333-8333-33333333333d"
    let canonicalThread = "55555555-5555-4555-8555-555555555555"
    let localThread = "66666666-6666-4666-8666-666666666666"
    let parentId = "b1b2c3d4-6666-4666-8666-666666666666"
    let replyId = "c1b2c3d4-7777-4777-8777-777777777777"
    let reply = "joint thread reply target"
    accounts.addAccount(id: guestOwner, email: "joint-thread-link-guest@slock.test", password: "password123")
    let catalog = MessageContextCatalog(
        messages: [
            ContextMessage(id: parentId, channelId: hostChannel, content: "joint thread parent", seq: 1),
            ContextMessage(id: replyId, channelId: canonicalThread, content: reply, seq: 1),
        ],
        jointProjections: [JointChannelProjection(
            localChannelId: guestChannel,
            canonicalChannelId: hostChannel,
            serverId: guestServer,
            memberIds: [guestOwner]
        )],
        jointThreads: [JointThreadProjection(
            localParentChannelId: guestChannel,
            canonicalParentChannelId: hostChannel,
            canonicalParentMessageId: parentId,
            canonicalThreadChannelId: canonicalThread,
            localThreadChannelId: localThread,
            localServerId: guestServer,
            memberIds: [guestOwner]
        )]
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            messageContext: catalog,
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"joint-thread-link-guest@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            var guestHeaders = HTTPFields()
            guestHeaders[.authorization] = "Bearer \(token)"
            guestHeaders[HTTPField.Name("X-Server-Id")!] = guestServer

            let context = try await client.get(
                URI(string: "/api/messages/context/\(replyId.prefix(8))?channelId=\(guestChannel)"),
                headers: guestHeaders
            )
            #expect(context.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any]
            let canonical = body?["canonicalTarget"] as? [String: Any]
            #expect(body?["channelId"] as? String == localThread)
            #expect(body?["targetMessageId"] as? String == replyId)
            #expect(canonical?["kind"] as? String == "thread")
            #expect(canonical?["channelId"] as? String == guestChannel)
            #expect(canonical?["threadChannelId"] as? String == localThread)
            #expect(canonical?["messageId"] as? String == replyId)
            #expect(canonical?["threadParentMessageId"] as? String == parentId)
            let messages = body?["messages"] as? [[String: Any]] ?? []
            #expect(messages.contains { message in
                message["id"] as? String == replyId
                    && message["channelId"] as? String == localThread
                    && message["content"] as? String == reply
            })

            let focused = try await client.get(
                URI(string: "/api/messages/context/\(replyId.prefix(8))?channelId=\(localThread)"),
                headers: guestHeaders
            )
            #expect(focused.status == .ok)
            let focusedBody = try JSONSerialization.jsonObject(with: Data(bodyText(focused).utf8)) as? [String: Any]
            #expect(focusedBody?["channelId"] as? String == localThread)
            #expect(focusedBody?["targetMessageId"] as? String == replyId)
            let focusedMessages = focusedBody?["messages"] as? [[String: Any]] ?? []
            #expect(focusedMessages.contains { message in
                message["id"] as? String == replyId
                    && message["channelId"] as? String == localThread
                    && message["content"] as? String == reply
            })
        }
    }
}

@Test func dmMessageContextResolvesAShortIdForAParticipant() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111142"
    let recipientId = "11111111-1111-4111-8111-111111111143"
    let serverId = "33333333-3333-4333-8333-333333333357"
    let dmId = "22222222-2222-4222-8222-222222222248"
    let content = "dm short id context target"
    accounts.addAccount(id: ownerId, email: "dm-link-owner@slock.test", password: "password123")
    accounts.addAccount(id: recipientId, email: "dm-link-recipient@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: recipientId)
    accounts.addDirectMessage(serverId: serverId, channelId: dmId, participantIds: [ownerId, recipientId])
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                #expect(response.status == .ok)
                return ((try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            }
            let ownerToken = try await login("dm-link-owner@slock.test")
            let recipientToken = try await login("dm-link-recipient@slock.test")
            var sendHeaders = HTTPFields()
            sendHeaders[.contentType] = "application/json"
            sendHeaders[.authorization] = "Bearer \(ownerToken)"
            sendHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let sent = try await client.send(.post, headers: sendHeaders, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(dmId)\",\"content\":\"\(content)\"}")
            }
            #expect(sent.status == .ok)
            let messageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(sent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            var readHeaders = HTTPFields()
            readHeaders[.authorization] = "Bearer \(recipientToken)"
            readHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let context = try await client.get(
                URI(string: "/api/messages/context/\(messageId.prefix(8))?channelId=\(dmId)"),
                headers: readHeaders
            )
            #expect(context.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any]
            #expect(body?["channelId"] as? String == dmId)
            #expect(body?["targetMessageId"] as? String == messageId)
            let messages = body?["messages"] as? [[String: Any]] ?? []
            #expect(messages.contains { message in
                message["id"] as? String == messageId && message["content"] as? String == content
            })
        }
    }
}

@Test func parentChannelShortLinkToAThreadReplyRewritesOntoTheThread() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111144"
    let serverId = "33333333-3333-4333-8333-333333333358"
    let parentChannelId = "22222222-2222-4222-8222-222222222249"
    let threadChannelId = "22222222-2222-4222-8222-22222222224a"
    accounts.addAccount(id: ownerId, email: "thread-context-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parentChannelId, memberId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"thread-context-owner@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let parentSent = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(parentChannelId)\",\"content\":\"thread parent\"}")
            }
            #expect(parentSent.status == .ok)
            let parentMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(parentSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addThreadChannel(
                serverId: serverId,
                threadChannelId: threadChannelId,
                parentChannelId: parentChannelId,
                parentMessageId: parentMessageId,
                memberId: ownerId
            )
            let replySent = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(threadChannelId)\",\"content\":\"thread reply\"}")
            }
            #expect(replySent.status == .ok)
            let replyId = ((try JSONSerialization.jsonObject(with: Data(bodyText(replySent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            var readHeaders = HTTPFields()
            readHeaders[.authorization] = "Bearer \(token)"
            readHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let context = try await client.get(
                URI(string: "/api/messages/context/\(replyId.prefix(8))?channelId=\(parentChannelId)"),
                headers: readHeaders
            )
            #expect(context.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any]
            #expect(body?["channelId"] as? String == threadChannelId)
            #expect(body?["targetMessageId"] as? String == replyId)
            let canonical = body?["canonicalTarget"] as? [String: Any]
            #expect(canonical?["kind"] as? String == "thread")
            #expect(canonical?["channelId"] as? String == parentChannelId)
            #expect(canonical?["messageId"] as? String == replyId)
            #expect(canonical?["threadParentMessageId"] as? String == parentMessageId)
            #expect(canonical?["threadChannelId"] as? String == threadChannelId)
            let messages = body?["messages"] as? [[String: Any]] ?? []
            #expect(messages.isEmpty == false)
            #expect(messages.allSatisfy { $0["channelId"] as? String == threadChannelId })
        }
    }
}

@Test func threadChannelShortIdOnTheParentChannelLandsOnTheParentMessage() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111145"
    let serverId = "33333333-3333-4333-8333-333333333359"
    let parentChannelId = "22222222-2222-4222-8222-22222222224b"
    let threadChannelId = "abcd1234-2222-4222-8222-22222222224c"
    let parentContent = "thread-channel-id parent"
    accounts.addAccount(id: ownerId, email: "thread-channel-ref-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: parentChannelId, memberId: ownerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"thread-channel-ref-owner@slock.test\",\"password\":\"password123\"}")
            }
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let parentSent = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(parentChannelId)\",\"content\":\"\(parentContent)\"}")
            }
            #expect(parentSent.status == .ok)
            let parentMessageId = ((try JSONSerialization.jsonObject(with: Data(bodyText(parentSent).utf8)) as? [String: Any])?["id"] as? String) ?? ""
            accounts.addThreadChannel(
                serverId: serverId,
                threadChannelId: threadChannelId,
                parentChannelId: parentChannelId,
                parentMessageId: parentMessageId,
                memberId: ownerId
            )
            let replySent = try await client.send(.post, headers: headers, to: "/api/messages") { request in
                request.body = .init(string: "{\"channelId\":\"\(threadChannelId)\",\"content\":\"thread-channel-id reply\"}")
            }
            #expect(replySent.status == .ok)
            var readHeaders = HTTPFields()
            readHeaders[.authorization] = "Bearer \(token)"
            readHeaders[HTTPField.Name("X-Server-Id")!] = serverId
            let context = try await client.get(
                URI(string: "/api/messages/context/\(threadChannelId.prefix(8))?channelId=\(parentChannelId)"),
                headers: readHeaders
            )
            #expect(context.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(context).utf8)) as? [String: Any]
            #expect(body?["channelId"] as? String == parentChannelId)
            #expect(body?["targetMessageId"] as? String == parentMessageId)
            let messages = body?["messages"] as? [[String: Any]] ?? []
            #expect(messages.contains { message in
                message["id"] as? String == parentMessageId && message["content"] as? String == parentContent
            })
        }
    }
}
