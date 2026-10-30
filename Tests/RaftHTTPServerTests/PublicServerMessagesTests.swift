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

@Test func malformedPublicMessageIdsAreClean404s() async throws {
    let swallowed = encodeURIComponent("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee这条你是不是没收到")
    let headers: HTTPFields = [
        .authorization: "Bearer token",
        HTTPField.Name("X-Server-Id")!: "33333333-3333-4333-8333-333333333333",
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        ))
        try await app.testing { client in
            for bad in ["not-a-uuid", swallowed] {
                let channel = try await client.get(
                    URI(string: "/api/public/servers/hygiene-ids/channels/\(bad)/messages"),
                    headers: headers
                )
                #expect(channel.status == .notFound)
                #expect(bodyText(channel) == "{\"error\":\"Channel not found\"}")
                #expect(channel.headers[HTTPField.Name("Cache-Control")!] == "no-store")
                #expect(channel.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                assertNoLeak(bodyText(channel))

                let thread = try await client.get(
                    URI(string: "/api/public/servers/hygiene-ids/threads/\(bad)/messages"),
                    headers: headers
                )
                #expect(thread.status == .notFound)
                #expect(bodyText(thread) == "{\"error\":\"Thread not found\"}")
                #expect(thread.headers[HTTPField.Name("Cache-Control")!] == "no-store")
                assertNoLeak(bodyText(thread))
            }

            let channelId = "22222222-2222-4222-8222-222222222222"
            let unknownChannel = try await client.get(
                "/api/public/servers/hygiene-ids/channels/\(channelId)/messages"
            )
            #expect(unknownChannel.status == .notFound)
            #expect(bodyText(unknownChannel) == "{\"error\":\"Not found\"}")

            let unknownThread = try await client.get(
                "/api/public/servers/hygiene-ids/threads/\(channelId)/messages"
            )
            #expect(unknownThread.status == .notFound)
            #expect(bodyText(unknownThread) == "{\"error\":\"Not found\"}")
        }
    }
}

@Test func aLoggedOutReaderLosesThePublicServerWhenTheToggleGoesOff() async throws {
    let directory = PublicVisitDirectory()
    let open = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    directory.addServer(id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", slug: "public-server-70")
    directory.addGuestChannel(slug: "public-server-70", id: open, name: "open-channel")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let before = try await client.get("/api/public/servers/public-server-70")
            #expect(before.status == .ok)
            #expect(before.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let listed = try JSONSerialization.jsonObject(with: Data(bodyText(before).utf8)) as? [String: Any]
            let channels = listed?["channels"] as? [[String: Any]]
            #expect(channels?.compactMap { $0["id"] as? String } == [open])

            let readBefore = try await client.get("/api/public/servers/public-server-70/channels/\(open)/messages")
            #expect(readBefore.status == .ok)
            #expect(readBefore.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            #expect(bodyText(readBefore) == "{\"messages\":[]}")

            directory.setPubliclyVisible(slug: "public-server-70", visible: false)
            let afterList = try await client.get("/api/public/servers/public-server-70")
            #expect(afterList.status == .notFound)
            #expect(bodyText(afterList) == "{\"error\":\"Not found\"}")
            let afterRead = try await client.get("/api/public/servers/public-server-70/channels/\(open)/messages")
            #expect(afterRead.status == .notFound)
            #expect(bodyText(afterRead) == "{\"error\":\"Not found\"}")
        }
    }
}

@Test func anonymousMessageHistoryIsANarrowProjection() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let otherServerId = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    let ownerId = "11111111-1111-4111-8111-111111111111"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let messageId = "22222222-2222-4222-8222-222222222222"
    let threadId = "33333333-3333-4333-8333-333333333333"
    let replyId = "44444444-4444-4444-8444-444444444444"
    let newerReplyId = "55555555-5555-4555-8555-555555555555"
    let storedAgentId = "66666666-6666-4666-8666-666666666666"
    let externalAgentId = "77777777-7777-4777-8777-777777777777"
    let otherAgentId = "88888888-8888-4888-8888-888888888888"
    let storedAgentMessageId = "99999999-9999-4999-8999-999999999999"
    let externalAgentMessageId = "aaaaaaaa-1111-4111-8111-111111111111"
    let userAvatar = "/api/avatars/users/\(String(repeating: "a", count: 32)).webp"
    let storedAgentAvatar = "/api/avatars/\(serverId)/\(String(repeating: "b", count: 32)).webp"
    let owner = PublicHistorySender(
        displayName: "Projection Owner",
        handle: "projection-owner",
        avatarUrl: userAvatar,
        description: "Public profile description",
        actorId: ownerId
    )
    directory.addServer(id: serverId, slug: "public-projection-70", name: "Projection")
    directory.addGuestChannel(slug: "public-projection-70", id: channelId, name: "public-projection")
    directory.addThread(slug: "public-projection-70", id: threadId, parentChannelId: channelId)
    directory.addPublicMessage(slug: "public-projection-70", message: PublicHistoryMessage(
        id: messageId,
        channelId: channelId,
        content: "Public words only",
        createdAt: "2026-10-14T00:00:00.000Z",
        seq: 1,
        senderType: "user",
        sender: owner,
        secret: "must-not-leak"
    ))
    directory.addPublicMessage(slug: "public-projection-70", message: PublicHistoryMessage(
        id: storedAgentMessageId,
        channelId: channelId,
        content: "Stored agent avatar",
        createdAt: "2026-10-14T00:01:00.000Z",
        seq: 2,
        senderType: "agent",
        sender: PublicHistorySender(
            displayName: "Stored Avatar Agent",
            handle: "stored-avatar-agent",
            avatarUrl: storedAgentAvatar,
            description: "Public agent description",
            actorId: storedAgentId,
            homeServerId: serverId
        )
    ))
    directory.addPublicMessage(slug: "public-projection-70", message: PublicHistoryMessage(
        id: externalAgentMessageId,
        channelId: channelId,
        content: "External agent avatar",
        createdAt: "2026-10-14T00:02:00.000Z",
        seq: 3,
        senderType: "agent",
        sender: PublicHistorySender(
            displayName: "External Avatar Agent",
            handle: "external-avatar-agent",
            avatarUrl: "https://third-party.example.test/private-avatar.png?signature=secret",
            description: "External avatar is filtered",
            actorId: externalAgentId,
            homeServerId: serverId
        )
    ))
    directory.addPublicMessage(slug: "public-projection-70", message: PublicHistoryMessage(
        id: "bbbbbbbb-1111-4111-8111-111111111111",
        channelId: channelId,
        content: "Cross-server agent id",
        createdAt: "2026-10-14T00:03:00.000Z",
        seq: 4,
        senderType: "agent",
        sender: PublicHistorySender(
            displayName: "Other Server Secret Agent",
            handle: "other-server-agent",
            avatarUrl: "/api/avatars/\(otherServerId)/\(String(repeating: "d", count: 32)).webp",
            description: "Must not cross the server boundary",
            actorId: otherAgentId,
            homeServerId: otherServerId
        )
    ))
    directory.addPublicReply(
        slug: "public-projection-70",
        parentMessageId: messageId,
        threadId: threadId,
        reply: PublicHistoryReply(
            id: replyId,
            content: "> quoted\n\n**reply**",
            createdAt: "2026-10-14T00:04:00.000Z",
            seq: 1,
            senderType: "user",
            sender: owner
        )
    )
    directory.addPublicReply(
        slug: "public-projection-70",
        parentMessageId: messageId,
        threadId: threadId,
        reply: PublicHistoryReply(
            id: newerReplyId,
            content: "newer reply",
            createdAt: "2026-10-14T00:05:00.000Z",
            seq: 2,
            senderType: "user",
            sender: owner
        )
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let response = try await client.get("/api/public/servers/public-projection-70/channels/\(channelId)/messages")
            #expect(response.status == .ok)
            let raw = bodyText(response)
            #expect(raw.contains("must-not-leak") == false)
            #expect(raw.contains(ownerId) == false)
            #expect(raw.contains(storedAgentId) == false)
            #expect(raw.contains(externalAgentId) == false)
            #expect(raw.contains(otherAgentId) == false)
            #expect(raw.contains("third-party.example.test") == false)
            let body = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]] ?? []
            let parent = messages.first { $0["id"] as? String == messageId }
            #expect((parent?.keys.sorted() ?? []) == [
                "attachments", "content", "createdAt", "id", "lastReplyAt", "latestReplies", "mentions", "messageType", "reactions", "replyCount", "sender", "senderType", "threadId",
            ])
            #expect(parent?["content"] as? String == "Public words only")
            #expect(parent?["threadId"] as? String == threadId)
            #expect((parent?["replyCount"] as? NSNumber)?.intValue == 2)
            #expect(parent?["lastReplyAt"] as? String == "2026-10-14T00:05:00.000Z")
            let sender = parent?["sender"] as? [String: Any]
            #expect(sender?["displayName"] as? String == "Projection Owner")
            #expect(sender?["handle"] as? String == "projection-owner")
            #expect(sender?["avatarUrl"] as? String == userAvatar)
            #expect(sender?["description"] as? String == "Public profile description")
            let previews = parent?["latestReplies"] as? [[String: Any]] ?? []
            #expect(previews.count == 2)
            #expect(previews[0].keys.sorted() == [
                "createdAt", "messageId", "preview", "senderAvatarUrl", "senderName", "senderType", "seq",
            ])
            #expect(previews[0]["messageId"] as? String == replyId)
            #expect(previews[0]["preview"] as? String == "> quoted\n\n**reply**")
            #expect(previews[0]["senderAvatarUrl"] as? String == userAvatar)
            #expect(previews[1]["messageId"] as? String == newerReplyId)
            #expect(previews[1]["preview"] as? String == "newer reply")

            let stored = messages.first { $0["id"] as? String == storedAgentMessageId }
            let storedSender = stored?["sender"] as? [String: Any]
            #expect(storedSender?["displayName"] as? String == "Stored Avatar Agent")
            #expect(storedSender?["handle"] as? String == "stored-avatar-agent")
            #expect(storedSender?["avatarUrl"] as? String == storedAgentAvatar)
            #expect(storedSender?["description"] as? String == "Public agent description")

            let external = messages.first { $0["id"] as? String == externalAgentMessageId }
            let externalSender = external?["sender"] as? [String: Any]
            #expect(externalSender?["displayName"] as? String == "External Avatar Agent")
            #expect(externalSender?["avatarUrl"] as? String == nil)
            #expect(externalSender?["description"] as? String == "External avatar is filtered")

            let foreign = messages.first { $0["content"] as? String == "Cross-server agent id" }
            let foreignSender = foreign?["sender"] as? [String: Any]
            #expect(foreignSender?["displayName"] as? String == "Unknown agent")
            #expect(foreignSender?["handle"] as? String == nil)
            #expect(foreignSender?["avatarUrl"] as? String == nil)
            #expect(foreignSender?["description"] as? String == nil)

            let thread = try await client.get("/api/public/servers/public-projection-70/threads/\(threadId)/messages")
            #expect(thread.status == .ok)
            let threadRaw = bodyText(thread)
            #expect(threadRaw.contains(ownerId) == false)
            let threadBody = try JSONSerialization.jsonObject(with: Data(threadRaw.utf8)) as? [String: Any]
            let threadMessages = threadBody?["messages"] as? [[String: Any]] ?? []
            #expect(threadMessages.first?["id"] as? String == replyId)
            #expect(threadMessages.first?["content"] as? String == "> quoted\n\n**reply**")

            let latest = try await client.get(URI(string: "/api/public/servers/public-projection-70/threads/\(threadId)/messages?limit=1"))
            let latestBody = try JSONSerialization.jsonObject(with: Data(bodyText(latest).utf8)) as? [String: Any]
            let latestMessages = latestBody?["messages"] as? [[String: Any]] ?? []
            #expect(latestMessages.map { $0["id"] as? String } == [newerReplyId])

            let older = try await client.get(URI(string: "/api/public/servers/public-projection-70/threads/\(threadId)/messages?limit=1&beforeMessageId=\(newerReplyId)"))
            let olderBody = try JSONSerialization.jsonObject(with: Data(bodyText(older).utf8)) as? [String: Any]
            let olderMessages = olderBody?["messages"] as? [[String: Any]] ?? []
            #expect(olderMessages.map { $0["id"] as? String } == [replyId])
        }
    }
}

@Test func anonymousSurfaceIsOnlyGuestVisibleOrdinaryChannels() async throws {
    let directory = PublicVisitDirectory()
    let visible = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let unmarked = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let privateMarked = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    directory.addServer(id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", slug: "public-surface-70", name: "Surface")
    directory.addGuestChannel(slug: "public-surface-70", id: visible, name: "visible")
    directory.addGuestChannel(slug: "public-surface-70", id: privateMarked, name: "private-marked", type: "private")
    directory.addServer(id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", slug: "private-server-70", publiclyVisible: false, name: "Private Server")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let listed = try await client.get("/api/public/servers/public-surface-70")
            #expect(listed.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(listed).utf8)) as? [String: Any]
            let channels = body?["channels"] as? [[String: Any]]
            #expect(channels?.compactMap { $0["id"] as? String } == [visible])

            for id in [unmarked, privateMarked] {
                let hidden = try await client.get("/api/public/servers/public-surface-70/channels/\(id)/messages")
                #expect(hidden.status == .notFound)
                #expect(bodyText(hidden) == "{\"error\":\"Not found\"}")
            }
            let readable = try await client.get("/api/public/servers/public-surface-70/channels/\(visible)/messages")
            #expect(readable.status == .ok)

            let probe = try await client.get("/api/public/servers/private-server-70")
            #expect(probe.status == .notFound)
            #expect(probe.status != .forbidden)
            #expect(bodyText(probe) == "{\"error\":\"Not found\"}")
            let again = try await client.get("/api/public/servers/private-server-70")
            #expect(again.status == .notFound)
        }
    }
}

@Test func publicServerCardShowsNameGuestJoinAndTranslation() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    directory.addServer(
        id: serverId,
        slug: "public-join-controls-74",
        name: "Join Controls",
        guestJoinEnabled: true,
        guestRolloutEnabled: true,
        translationEnabled: true,
        avatarUrl: "https://third-party.example.test/server-avatar.png?signature=secret"
    )
    directory.setTranslationAvailable(true)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            func card() async throws -> [String: Any] {
                let response = try await client.get("/api/public/servers/public-join-controls-74")
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
                return try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any] ?? [:]
            }
            let open = try await card()
            let server = open["server"] as? [String: Any]
            #expect(server?["id"] as? String == serverId)
            #expect(server?["name"] as? String == "Join Controls")
            #expect(server?["slug"] as? String == "public-join-controls-74")
            #expect((server?["avatarUrl"] as? String) == nil)
            #expect(server?["translationEnabled"] as? Bool == true)
            #expect(open["canJoinAsGuest"] as? Bool == true)
            #expect(open["translationAvailable"] as? Bool == true)

            let stored = "/api/avatars/server-\(serverId)/\(String(repeating: "c", count: 32)).webp"
            directory.setServerCard(slug: "public-join-controls-74", avatarUrl: stored)
            let withAvatar = try await card()
            #expect((withAvatar["server"] as? [String: Any])?["avatarUrl"] as? String == stored)

            directory.setServerCard(slug: "public-join-controls-74", guestRolloutEnabled: false)
            directory.setTranslationAvailable(false)
            let closed = try await card()
            #expect(closed["canJoinAsGuest"] as? Bool == false)
            #expect((closed["server"] as? [String: Any])?["translationEnabled"] as? Bool == true)
            #expect(closed["translationAvailable"] as? Bool == false)
        }
    }
}

private func jsonBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    return (value as? NSNumber)?.boolValue
}

private func postJSON(_ client: any Client, _ path: String, body: String) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func publicRichFieldsAreDisplayOnly() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let ownerId = "11111111-1111-4111-8111-111111111111"
    let monaId = "22222222-2222-4222-8222-222222222222"
    let agentId = "33333333-3333-4333-8333-333333333333"
    let editedId = "44444444-4444-4444-8444-444444444444"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let messageId = "55555555-5555-4555-8555-555555555555"
    let imageId = "66666666-6666-4666-8666-666666666666"
    let htmlId = "77777777-7777-4777-8777-777777777777"
    directory.addServer(id: serverId, slug: "public-rich-128", name: "Attachments")
    directory.addGuestChannel(slug: "public-rich-128", id: channelId, name: "public-files")
    directory.addPublicMessage(slug: "public-rich-128", message: PublicHistoryMessage(
        id: messageId,
        channelId: channelId,
        content: "hi @mona and @helper-bot, see files",
        createdAt: "2026-01-01T00:00:00.000Z",
        seq: 1,
        senderType: "user",
        sender: PublicHistorySender(
            displayName: "Owner",
            handle: "owner",
            avatarUrl: nil,
            description: nil,
            actorId: ownerId
        ),
        attachments: [
            PublicHistoryAttachment(
                id: imageId,
                filename: "photo.png",
                mimeType: "image/png",
                sizeBytes: 5,
                width: 64,
                height: 48,
                storageKey: "\(serverId)/photo.png",
                thumbnailKey: "thumbnails/\(imageId).webp",
                uploaderId: ownerId
            ),
            PublicHistoryAttachment(
                id: htmlId,
                filename: "page.html",
                mimeType: "text/html",
                sizeBytes: 5,
                width: nil,
                height: nil,
                storageKey: "\(serverId)/page.html",
                thumbnailKey: "thumbnails/\(htmlId).webp",
                uploaderId: ownerId
            ),
        ],
        mentions: [
            PublicHistoryMention(type: "user", name: "mona", displayName: "Mona Display", createdAt: "2026-01-01T00:00:00.000Z", targetId: monaId),
            PublicHistoryMention(type: "agent", name: "helper-bot", displayName: "Helper Bot", createdAt: "2026-01-01T00:00:01.000Z", targetId: agentId),
            PublicHistoryMention(type: "user", name: "edited-away", displayName: "Edited Away", createdAt: "2026-01-01T00:00:02.000Z", targetId: editedId),
        ],
        reactions: [
            PublicHistoryReaction(emoji: "👍", createdAt: "2026-01-01T00:00:00.000Z", reactorId: ownerId),
            PublicHistoryReaction(emoji: "🎉", createdAt: "2026-01-01T00:00:01.000Z", reactorId: agentId),
            PublicHistoryReaction(emoji: "👍", createdAt: "2026-01-01T00:00:02.000Z", reactorId: monaId),
        ]
    ))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let response = try await client.get("/api/public/servers/public-rich-128/channels/\(channelId)/messages")
            #expect(response.status == .ok)
            let text = bodyText(response)
            let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            let row = (body?["messages"] as? [[String: Any]])?.first
            let attachments = row?["attachments"] as? [[String: Any]] ?? []
            #expect(attachments.map { $0["id"] as? String } == [imageId, htmlId])
            #expect(attachments.map { $0["filename"] as? String } == ["photo.png", "page.html"])
            #expect(attachments.map { $0["mimeType"] as? String } == ["image/png", "text/html"])
            #expect(attachments.map { ($0["sizeBytes"] as? NSNumber)?.intValue } == [5, 5])
            #expect((attachments[0]["width"] as? NSNumber)?.intValue == 64)
            #expect((attachments[0]["height"] as? NSNumber)?.intValue == 48)
            #expect(attachments[1]["width"] is NSNull)
            #expect(attachments[1]["height"] is NSNull)
            let mentions = row?["mentions"] as? [[String: Any]] ?? []
            #expect(mentions.map { $0["name"] as? String } == ["mona", "helper-bot"])
            #expect(mentions.map { $0["type"] as? String } == ["user", "agent"])
            #expect(mentions.map { $0["displayName"] as? String } == ["Mona Display", "Helper Bot"])
            let reactions = row?["reactions"] as? [[String: Any]] ?? []
            #expect(reactions.map { $0["emoji"] as? String } == ["👍", "🎉"])
            #expect(reactions.map { ($0["count"] as? NSNumber)?.intValue } == [2, 1])
            for secret in [ownerId, monaId, agentId, editedId, "edited-away", "thumbnails/", serverId] {
                #expect(text.contains(secret) == false)
            }
        }
    }
}

@Test func typedNamesHighlightOnlyCurrentMembersAndAgents() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let ownerId = "11111111-1111-4111-8111-111111111111"
    let danaId = "22222222-2222-4222-8222-222222222222"
    let agentId = "33333333-3333-4333-8333-333333333333"
    let outsiderId = "44444444-4444-4444-8444-444444444444"
    let deletedAgentId = "55555555-5555-4555-8555-555555555555"
    let foreignAgentId = "66666666-6666-4666-8666-666666666666"
    let projectionId = "77777777-7777-4777-8777-777777777777"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let messageId = "88888888-8888-4888-8888-888888888888"
    let externalId = "99999999-9999-4999-8999-999999999999"
    directory.addServer(id: serverId, slug: "public-typed-128", name: "Attachments")
    directory.addGuestChannel(slug: "public-typed-128", id: channelId, name: "public-files")
    directory.addMentionMember(slug: "public-typed-128", userId: danaId, name: "dana", displayName: "Dana Display")
    directory.addMentionAgent(slug: "public-typed-128", agentId: agentId, name: "typed-bot", displayName: "Typed Bot")
    directory.addMentionAgent(slug: "public-typed-128", agentId: deletedAgentId, name: "gone-bot", displayName: "Gone Bot", deleted: true)
    directory.addMentionOutsider(slug: "public-typed-128", userId: outsiderId, name: "outsider", displayName: "Outsider")
    directory.addServer(id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", slug: "public-typed-other", publiclyVisible: false, name: "Other")
    directory.addMentionAgent(slug: "public-typed-other", agentId: foreignAgentId, name: "foreign-bot", displayName: "Foreign Bot")
    directory.addPublicMessage(slug: "public-typed-128", message: PublicHistoryMessage(
        id: messageId,
        channelId: channelId,
        content: "cc @dana @typed-bot @outsider @gone-bot @foreign-bot @ghost and `@dana` in code",
        createdAt: "2026-01-01T00:00:00.000Z",
        seq: 1,
        senderType: "user",
        sender: PublicHistorySender(
            displayName: "Owner",
            handle: "owner",
            avatarUrl: nil,
            description: nil,
            actorId: ownerId
        )
    ))
    directory.addPublicMessage(slug: "public-typed-128", message: PublicHistoryMessage(
        id: externalId,
        channelId: channelId,
        content: "from slack: @dana and @ada",
        createdAt: "2026-01-01T00:01:00.000Z",
        seq: 2,
        senderType: "external_projection",
        sender: PublicHistorySender(
            displayName: "External",
            handle: nil,
            avatarUrl: nil,
            description: nil,
            actorId: projectionId
        ),
        secret: "U-ada",
        mentions: [
            PublicHistoryMention(
                type: "external",
                name: "ada",
                displayName: "ada",
                createdAt: "2026-01-01T00:01:00.000Z",
                targetId: projectionId
            ),
        ]
    ))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let response = try await client.get("/api/public/servers/public-typed-128/channels/\(channelId)/messages")
            #expect(response.status == .ok)
            let text = bodyText(response)
            let body = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]] ?? []
            let row = messages.first { $0["id"] as? String == messageId }
            let mentions = row?["mentions"] as? [[String: Any]] ?? []
            let names = mentions.compactMap { $0["name"] as? String }.sorted()
            #expect(names == ["dana", "typed-bot"])
            let byName = Dictionary(uniqueKeysWithValues: mentions.compactMap { item -> (String, [String: Any])? in
                guard let name = item["name"] as? String else { return nil }
                return (name, item)
            })
            #expect(byName["dana"]?["type"] as? String == "user")
            #expect(byName["dana"]?["displayName"] as? String == "Dana Display")
            #expect(byName["typed-bot"]?["type"] as? String == "agent")
            #expect(byName["typed-bot"]?["displayName"] as? String == "Typed Bot")
            for secret in [danaId, agentId, outsiderId, deletedAgentId, foreignAgentId, "Outsider"] {
                #expect(text.contains(secret) == false)
            }

            let external = messages.first { $0["id"] as? String == externalId }
            let externalMentions = external?["mentions"] as? [[String: Any]] ?? []
            #expect(externalMentions.count == 1)
            #expect(externalMentions.first?["type"] as? String == "external")
            #expect(externalMentions.first?["name"] as? String == "ada")
            #expect(externalMentions.first?["displayName"] as? String == "ada")
            for secret in [danaId, projectionId, "U-ada"] {
                #expect(text.contains(secret) == false)
            }
        }
    }
}

@Test func anonymousAttachmentReadsFollowThePublicMessage() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let privateId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let unmarkedId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let archivedId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    let threadId = "ffffffff-ffff-4fff-8fff-ffffffffffff"
    let privateThreadId = "11111111-1111-4111-8111-111111111111"
    let imageId = "22222222-2222-4222-8222-222222222222"
    let htmlId = "33333333-3333-4333-8333-333333333333"
    let svgId = "44444444-4444-4444-8444-444444444444"
    let draftId = "55555555-5555-4555-8555-555555555555"
    let privateFileId = "66666666-6666-4666-8666-666666666666"
    let unmarkedFileId = "77777777-7777-4777-8777-777777777777"
    let archivedFileId = "88888888-8888-4888-8888-888888888888"
    let threadFileId = "99999999-9999-4999-8999-999999999999"
    let privateThreadFileId = "aaaaaaaa-1111-4111-8111-111111111111"
    let messageId = "bbbbbbbb-1111-4111-8111-111111111111"
    directory.addServer(id: serverId, slug: "public-download-128", name: "Attachments")
    directory.addGuestChannel(slug: "public-download-128", id: channelId, name: "public-files")
    directory.addGuestChannel(slug: "public-download-128", id: privateId, name: "private-files", type: "private")
    directory.addGuestChannel(slug: "public-download-128", id: archivedId, name: "archived-files")
    directory.archiveChannel(slug: "public-download-128", id: archivedId)
    directory.addThread(slug: "public-download-128", id: threadId, parentChannelId: channelId)
    directory.addThread(slug: "public-download-128", id: privateThreadId, parentChannelId: privateId)
    directory.addServer(id: "cccccccc-1111-4111-8111-111111111111", slug: "public-download-other-128", name: "Other")
    func store(_ id: String, _ channel: String, _ message: String?, _ filename: String, _ mime: String, _ key: String, _ bytes: String) {
        directory.addPublicAttachment(id: id, channelId: channel, messageId: message, filename: filename, mimeType: mime, storageKey: key)
        directory.putPublicObject(key: key, bytes: bytes)
    }
    store(imageId, channelId, messageId, "photo.png", "image/png", "\(serverId)/photo.png", "PNG!!")
    store(htmlId, channelId, messageId, "page.html", "text/html", "\(serverId)/page.html", "<b>x</b>")
    store(svgId, channelId, messageId, "logo.svg", "image/svg+xml", "\(serverId)/logo.svg", "<svg/>")
    store(draftId, channelId, nil, "draft.png", "image/png", "\(serverId)/draft.png", "DRAFT")
    store(privateFileId, privateId, messageId, "hidden.png", "image/png", "\(serverId)/hidden-private.png", "HIDE!")
    store(unmarkedFileId, unmarkedId, messageId, "hidden.png", "image/png", "\(serverId)/hidden-unmarked.png", "HIDE!")
    store(archivedFileId, archivedId, messageId, "hidden.png", "image/png", "\(serverId)/hidden-archived.png", "HIDE!")
    store(threadFileId, threadId, messageId, "reply.png", "image/png", "\(serverId)/reply.png", "REPLY")
    store(privateThreadFileId, privateThreadId, messageId, "private-reply.png", "image/png", "\(serverId)/private-reply.png", "PRIVR")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let image = try await client.get("/api/public/servers/public-download-128/attachments/\(imageId)")
            #expect(image.status == .ok)
            #expect(bodyText(image) == "PNG!!")
            #expect(image.headers[.contentType] == "image/png")
            #expect(image.headers[HTTPField.Name("Content-Disposition")!] == "inline; filename=\"photo.png\"; filename*=UTF-8''photo.png")
            #expect(image.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            #expect(image.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
            #expect(image.headers[HTTPField.Name("Cross-Origin-Resource-Policy")!] == "cross-origin")

            let forced = try await client.get(URI(string: "/api/public/servers/public-download-128/attachments/\(imageId)?download=1"))
            #expect(forced.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename=\"photo.png\"; filename*=UTF-8''photo.png")

            let html = try await client.get("/api/public/servers/public-download-128/attachments/\(htmlId)")
            #expect(html.status == .ok)
            #expect(html.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename=\"page.html\"; filename*=UTF-8''page.html")
            #expect(html.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
            let svg = try await client.get("/api/public/servers/public-download-128/attachments/\(svgId)")
            #expect(svg.status == .ok)
            #expect(svg.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename=\"logo.svg\"; filename*=UTF-8''logo.svg")
            #expect(svg.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")

            let thread = try await client.get("/api/public/servers/public-download-128/attachments/\(threadFileId)")
            #expect(thread.status == .ok)
            #expect(bodyText(thread) == "REPLY")

            let missing = try await client.get("/api/public/servers/public-download-128/attachments/12121212-1212-4121-8121-121212121212")
            #expect(missing.status == .notFound)
            let missingBody = bodyText(missing)
            let refusals = [
                privateFileId, unmarkedFileId, archivedFileId, draftId, privateThreadFileId,
            ]
            for id in refusals {
                let refused = try await client.get("/api/public/servers/public-download-128/attachments/\(id)")
                #expect(refused.status == .notFound)
                #expect(bodyText(refused) == missingBody)
            }
            let other = try await client.get("/api/public/servers/public-download-other-128/attachments/\(imageId)")
            #expect(other.status == .notFound)
            #expect(bodyText(other) == missingBody)
            let malformed = try await client.get("/api/public/servers/public-download-128/attachments/not-a-uuid")
            #expect(malformed.status == .notFound)

            directory.setPublicEnabled(slug: "public-download-128", enabled: false)
            let closed = try await client.get("/api/public/servers/public-download-128/attachments/\(imageId)")
            #expect(closed.status == .notFound)
            directory.setPublicEnabled(slug: "public-download-128", enabled: true)
            let reopened = try await client.get("/api/public/servers/public-download-128/attachments/\(imageId)")
            #expect(reopened.status == .ok)

            directory.setPubliclyVisible(slug: "public-download-128", visible: false)
            let hidden = try await client.get("/api/public/servers/public-download-128/attachments/\(imageId)")
            #expect(hidden.status == .notFound)
            let hiddenThread = try await client.get("/api/public/servers/public-download-128/attachments/\(threadFileId)")
            #expect(hiddenThread.status == .notFound)
        }
    }
}

@Test func onlyAPdfIsInlineWhenThePreviewAsks() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let pdfId = "22222222-2222-4222-8222-222222222222"
    let htmlId = "33333333-3333-4333-8333-333333333333"
    let svgId = "44444444-4444-4444-8444-444444444444"
    let messageId = "bbbbbbbb-1111-4111-8111-111111111111"
    directory.addServer(id: serverId, slug: "public-pdf-preview", name: "Attachments")
    directory.addGuestChannel(slug: "public-pdf-preview", id: channelId, name: "public-files")
    func store(_ id: String, _ filename: String, _ mime: String, _ key: String, _ bytes: String) {
        directory.addPublicAttachment(
            id: id, channelId: channelId, messageId: messageId,
            filename: filename, mimeType: mime, storageKey: key
        )
        directory.putPublicObject(key: key, bytes: bytes)
    }
    store(pdfId, "paper.pdf", "application/pdf", "\(serverId)/paper.pdf", "%PDF-")
    store(htmlId, "page.html", "text/html", "\(serverId)/page.html", "<b>x</b>")
    store(svgId, "logo.svg", "image/svg+xml", "\(serverId)/logo.svg", "<svg/>")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let inline = try await client.get(URI(string: "/api/public/servers/public-pdf-preview/attachments/\(pdfId)?disposition=inline"))
            #expect(inline.status == .ok)
            #expect(bodyText(inline) == "%PDF-")
            #expect(inline.headers[.contentType] == "application/pdf")
            #expect(inline.headers[HTTPField.Name("Content-Disposition")!] == "inline; filename=\"paper.pdf\"; filename*=UTF-8''paper.pdf")
            #expect(inline.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
            #expect(inline.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let csp = inline.headers[HTTPField.Name("Content-Security-Policy")!] ?? ""
            #expect(csp.hasPrefix("frame-ancestors 'self'"))
            #expect(csp.contains("sandbox") == false)
            #expect(inline.headers[HTTPField.Name("X-Frame-Options")!] == nil)
            #expect(inline.headers[HTTPField.Name("Cross-Origin-Resource-Policy")!] == "cross-origin")
            #expect(inline.headers[HTTPField.Name("Referrer-Policy")!] == "no-referrer")

            for query in ["", "?disposition=inline&download=1"] {
                let download = try await client.get(URI(string: "/api/public/servers/public-pdf-preview/attachments/\(pdfId)\(query)"))
                #expect(download.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename=\"paper.pdf\"; filename*=UTF-8''paper.pdf")
                #expect(download.headers[HTTPField.Name("Content-Security-Policy")!] == "default-src 'none'; sandbox")
            }
            let html = try await client.get(URI(string: "/api/public/servers/public-pdf-preview/attachments/\(htmlId)?disposition=inline"))
            #expect(html.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename=\"page.html\"; filename*=UTF-8''page.html")
            #expect(html.headers[HTTPField.Name("Content-Security-Policy")!] == "default-src 'none'; sandbox")
            let svg = try await client.get(URI(string: "/api/public/servers/public-pdf-preview/attachments/\(svgId)?disposition=inline"))
            #expect(svg.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename=\"logo.svg\"; filename*=UTF-8''logo.svg")
            #expect(svg.headers[HTTPField.Name("Content-Security-Policy")!] == "default-src 'none'; sandbox")

            directory.setPubliclyVisible(slug: "public-pdf-preview", visible: false)
            let closed = try await client.get(URI(string: "/api/public/servers/public-pdf-preview/attachments/\(pdfId)?disposition=inline"))
            #expect(closed.status == .notFound)
        }
    }
}

@Test func objectStoragePresignsAPublicAttachmentForOneMinute() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let htmlId = "33333333-3333-4333-8333-333333333333"
    let messageId = "bbbbbbbb-1111-4111-8111-111111111111"
    directory.addServer(id: serverId, slug: "public-presign-128", name: "Attachments")
    directory.addGuestChannel(slug: "public-presign-128", id: channelId, name: "public-files")
    directory.addPublicAttachment(
        id: htmlId,
        channelId: channelId,
        messageId: messageId,
        filename: "page.html",
        mimeType: "text/html",
        storageKey: "\(serverId)/page.html"
    )
    directory.enablePresign("https://storage.example.test/presigned")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let response = try await client.get("/api/public/servers/public-presign-128/attachments/\(htmlId)")
            #expect(response.status == .found)
            #expect(response.headers[HTTPField.Name("Location")!] == "https://storage.example.test/presigned")
            #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            #expect(response.headers[HTTPField.Name("Cross-Origin-Resource-Policy")!] == "cross-origin")
            #expect(PublicAttachments.presignedURLTTLSeconds == 60)
            #expect(directory.presignCalls == [
                PublicPresignRequest(
                    key: "\(serverId)/page.html",
                    expiresIn: 60,
                    responseContentDisposition: "attachment; filename=\"page.html\"; filename*=UTF-8''page.html",
                    responseContentType: "text/html; charset=utf-8"
                ),
            ])
        }
    }
}

@Test func anInlinePdfPresignsInlineAndAPlainGetPresignsAttachment() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let pdfId = "22222222-2222-4222-8222-222222222222"
    let messageId = "bbbbbbbb-1111-4111-8111-111111111111"
    directory.addServer(id: serverId, slug: "public-pdf-presign", name: "Attachments")
    directory.addGuestChannel(slug: "public-pdf-presign", id: channelId, name: "public-files")
    directory.addPublicAttachment(
        id: pdfId,
        channelId: channelId,
        messageId: messageId,
        filename: "paper.pdf",
        mimeType: "application/pdf",
        storageKey: "\(serverId)/paper.pdf"
    )
    directory.enablePresign("https://storage.example.test/presigned")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let inline = try await client.get(URI(string: "/api/public/servers/public-pdf-presign/attachments/\(pdfId)?disposition=inline"))
            #expect(inline.status == .found)
            let plain = try await client.get("/api/public/servers/public-pdf-presign/attachments/\(pdfId)")
            #expect(plain.status == .found)
            #expect(directory.presignCalls == [
                PublicPresignRequest(
                    key: "\(serverId)/paper.pdf",
                    expiresIn: 60,
                    responseContentDisposition: "inline; filename=\"paper.pdf\"; filename*=UTF-8''paper.pdf",
                    responseContentType: "application/pdf"
                ),
                PublicPresignRequest(
                    key: "\(serverId)/paper.pdf",
                    expiresIn: 60,
                    responseContentDisposition: "attachment; filename=\"paper.pdf\"; filename*=UTF-8''paper.pdf",
                    responseContentType: "application/pdf"
                ),
            ])
            #expect(PublicAttachments.presignedURLTTLSeconds == 60)
        }
    }
}

@Test func publicTranslationBatchReportsValidationAbsenceAndSuccess() async throws {
    let directory = PublicVisitDirectory()
    let messageId = "22222222-2222-4222-8222-222222222222"
    directory.addServer(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        slug: "public-translate-70",
        name: "Translate",
        translationEnabled: false
    )
    let valid = "{\"targetLanguage\":\"EN\",\"mode\":\"manual\",\"messageIds\":[\"\(messageId)\"]}"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let invalid = try await postJSON(client, "/api/public/servers/public-translate-70/message-translations:batch", body: "{}")
            #expect(invalid.status == .badRequest)
            #expect(bodyText(invalid) == "{\"error\":\"Invalid public translation request\"}")

            let missing = try await postJSON(client, "/api/public/servers/does-not-exist/message-translations:batch", body: valid)
            #expect(missing.status == .notFound)
            #expect(bodyText(missing) == "{\"error\":\"Not found\"}")

            let disabled = try await postJSON(client, "/api/public/servers/public-translate-70/message-translations:batch", body: valid)
            #expect(disabled.status == .notFound)
            #expect(bodyText(disabled) == "{\"error\":\"Not found\"}")

            directory.setServerCard(slug: "public-translate-70", translationEnabled: true)
            let noProvider = try await postJSON(client, "/api/public/servers/public-translate-70/message-translations:batch", body: valid)
            #expect(noProvider.status == .notFound)

            directory.setTranslationAvailable(true)
            directory.setLlmTranslationUnavailable(true)
            let blocked = try await postJSON(client, "/api/public/servers/public-translate-70/message-translations:batch", body: valid)
            #expect(blocked.status == .forbidden)
            #expect(bodyText(blocked) == "{\"error\":\"LLM translation is not available for this server\"}")

            directory.setLlmTranslationUnavailable(false)
            let ready = try await postJSON(client, "/api/public/servers/public-translate-70/message-translations:batch", body: valid)
            #expect(ready.status == .ok)
            #expect(bodyText(ready) == "{\"results\":[{\"messageId\":\"\(messageId)\",\"status\":\"not_found\",\"targetLanguage\":\"en\"}]}")
        }
    }
}

@Test func publicTranslationSharesTheOneHundredTwentyPerMinuteBudget() async throws {
    let path = "/api/public/servers/rate-limit-probe/message-translations:batch"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        ))
        try await app.testing { client in
            let uri = URI(string: path)
            for index in 1...120 {
                let response = try await client.send(.post, headers: [.contentType: "application/json"], to: uri) { request in
                    request.body = .init(string: "{}")
                }
                #expect(response.status == .badRequest, "request \(index) reaches validation before the budget is spent")
                #expect(bodyText(response) == "{\"error\":\"Invalid public translation request\"}")
            }
            let limited = try await client.send(.post, headers: [.contentType: "application/json"], to: uri) { request in
                request.body = .init(string: "{}")
            }
            #expect(limited.status == .tooManyRequests)
            #expect(bodyText(limited) == "{\"error\":\"Too many public translation requests, please slow down\"}")
        }
    }
}

@Test func publicAttachmentDownloadsHaveTheirOwnOneHundredTwentyPerMinuteBudget() async throws {
    let attachmentId = "12121212-1212-4121-8121-121212121212"
    let path = "/api/public/servers/rate-limit-probe/attachments/\(attachmentId)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        ))
        try await app.testing { client in
            let uri = URI(string: path)
            for index in 1...120 {
                let response = try await client.get(uri)
                #expect(response.status == .notFound, "request \(index) reaches authorization before the budget is spent")
            }
            let limited = try await client.get(uri)
            #expect(limited.status == .tooManyRequests)
            #expect(bodyText(limited) == "{\"error\":\"Too many public attachment requests, please slow down\"}")
        }
    }
}

@Test func loggedOutVisitorHasNoWritePath() async throws {
    let directory = PublicVisitDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111111"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    directory.addServer(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        slug: "public-nowrite-70",
        memberIds: [ownerId],
        name: "NoWrite"
    )
    directory.addGuestChannel(slug: "public-nowrite-70", id: channelId, name: "readable")
    directory.addChannelMember(channelId: channelId, userId: ownerId)
    let before = directory.messageCount(slug: "public-nowrite-70", channelId: channelId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let readable = try await client.get("/api/public/servers/public-nowrite-70/channels/\(channelId)/messages")
            #expect(readable.status == .ok)

            let send = try await postJSON(
                client,
                "/api/messages",
                body: "{\"channelId\":\"\(channelId)\",\"content\":\"anonymous write\"}"
            )
            #expect(send.status == .unauthorized)
            #expect(bodyText(send) == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")

            let publicWrite = try await postJSON(
                client,
                "/api/public/servers/public-nowrite-70/channels/\(channelId)/messages",
                body: "{\"content\":\"anonymous write\"}"
            )
            #expect(publicWrite.status.code >= 400)

            let join = try await client.send(.post, to: "/api/channels/\(channelId)/join")
            #expect(join.status == .unauthorized)
            #expect(bodyText(join) == "{\"error\":\"Missing or invalid Authorization header\",\"code\":\"auth_required\"}")

            #expect(directory.messageCount(slug: "public-nowrite-70", channelId: channelId) == before)
            #expect(directory.channelMemberIds(channelId: channelId) == [ownerId])
            let after = try await client.get("/api/public/servers/public-nowrite-70/channels/\(channelId)/messages")
            #expect(bodyText(after) == "{\"messages\":[]}")
            #expect(bodyText(after).contains("anonymous write") == false)
        }
    }
}

@Test func memberServerListSaysWhetherThePublicPageIsLive() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let ownerId = "11111111-1111-4111-8111-111111111111"
    let memberId = "22222222-2222-4222-8222-222222222222"
    let guestId = "33333333-3333-4333-8333-333333333333"
    directory.addServer(
        id: serverId,
        slug: "public-live-128",
        publiclyVisible: false,
        publicEnabled: false,
        memberIds: [ownerId, memberId],
        name: "Public Live"
    )
    directory.addUser(PublicVisitUser(id: ownerId, shareUsageData: nil, analyticsId: nil))
    directory.addUser(PublicVisitUser(id: memberId, shareUsageData: nil, analyticsId: nil))
    directory.addToken("member-token", userId: memberId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            func list(token: String) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                let response = try await client.get("/api/servers", headers: headers)
                #expect(response.status == .ok)
                let rows = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [[String: Any]]
                return rows?.first { $0["id"] as? String == serverId } ?? [:]
            }

            let privateRow = try await list(token: "member-token")
            #expect(jsonBool(privateRow["publicPageLive"]) == false)
            #expect(privateRow.keys.contains("publiclyVisible") == false)

            directory.setPubliclyVisible(slug: "public-live-128", visible: true)
            #expect(jsonBool(try await list(token: "member-token")["publicPageLive"]) == false)
            let hidden = try await client.get("/api/public/servers/public-live-128")
            #expect(hidden.status == .notFound)

            directory.setPublicEnabled(slug: "public-live-128", enabled: true)
            #expect(jsonBool(try await list(token: "member-token")["publicPageLive"]) == true)
            let anonymous = try await client.get("/api/public/servers/public-live-128")
            #expect(anonymous.status == .ok)

            directory.addUser(PublicVisitUser(id: guestId, shareUsageData: nil, analyticsId: nil))
            directory.addToken("guest-token", userId: guestId)
            directory.addMember(slug: "public-live-128", userId: guestId)
            let guestRow = try await list(token: "guest-token")
            #expect(jsonBool(guestRow["publicPageLive"]) == true)
            #expect(guestRow.keys.contains("publiclyVisible") == false)

            directory.setPubliclyVisible(slug: "public-live-128", visible: false)
            #expect(jsonBool(try await list(token: "member-token")["publicPageLive"]) == false)
            let anonymousOff = try await client.get("/api/public/servers/public-live-128")
            #expect(anonymousOff.status == .notFound)
        }
    }
}
