import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func publicThreadTitlesAndPathSlugs() {
    #expect(PublicSearch.publicThreadTitle("## Hello world\nmore") == "Hello world")
    #expect(PublicSearch.publicThreadTitle("\n\n> quoted first\n") == "quoted first")
    #expect(PublicSearch.publicThreadTitle("") == "Discussion")
    #expect(PublicSearch.publicThreadTitle("   \n  ") == "Discussion")
    let capped = PublicSearch.publicThreadTitle(String(repeating: "x", count: 200))
    #expect(Array(capped).count == 80)
    #expect(capped == String(repeating: "x", count: 79) + "…")
    #expect(PublicSearch.slugifyForPublicPath("How do I set up agents?", fallback: "discussion") == "how-do-i-set-up-agents")
    #expect(PublicSearch.slugifyForPublicPath("如何 配置 Agent", fallback: "discussion") == "如何-配置-agent")
    #expect(PublicSearch.slugifyForPublicPath("???", fallback: "discussion") == "discussion")
}

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func services() -> FallbackServices {
    FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
}

@Test func publicSearchAllowsGetAndHeadOnly() async throws {
    let server = "/api/public/search/servers/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    try await withApp { app in
        configure(app, services: services())
        try await app.testing { client in
            for method in [HTTPRequest.Method.post, .put, .patch, .delete] {
                let refused = try await client.send(method, headers: [
                    .contentType: "application/json",
                ], to: URI(string: server))
                #expect(refused.status == .methodNotAllowed)
                #expect(refused.headers[HTTPField.Name("Allow")!] == "GET, HEAD")
                #expect(refused.headers[HTTPField.Name("Cache-Control")!] == "no-store")
                #expect(bodyText(refused) == "{\"error\":\"Method not allowed\"}")
            }
            let index = try await client.send(.post, to: "/api/public/search/index")
            #expect(index.status == .methodNotAllowed)
            #expect(index.headers[HTTPField.Name("Allow")!] == "GET, HEAD")
        }
    }
}

private let serverPid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let openPid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private let hiddenPid = "cccccccccccccccccccccccccccccccc"
private let threadPid = "dddddddddddddddddddddddddddddddd"
private let hiddenThreadPid = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
private let otherServerPid = "ffffffffffffffffffffffffffffffff"
private let otherThreadPid = "11111111111111111111111111111111"
private let updatedAt = "2026-10-12T16:00:00.000Z"
private let repliedAt = "2026-10-12T16:05:00.000Z"

private func reply(_ content: String, at: String = "2026-10-12T16:05:00.000Z", name: String = "seo-dto-owner") -> PublicSearchReply {
    PublicSearchReply(content: content, createdAt: at, updatedAt: at, senderName: name)
}

private func seoCatalog(replies: [PublicSearchReply]? = nil) -> PublicSearchCatalog {
    let openReplies = replies ?? [reply("First reply")]
    let open = PublicSearchChannel(
        publicId: openPid,
        name: "open-talk",
        description: "Open to guests",
        guestVisible: true,
        threads: [
            PublicSearchThread(
                publicId: threadPid,
                parentContent: "# How do I set up agents?\nSecond line",
                parentSeq: 1,
                parentCreatedAt: updatedAt,
                parentUpdatedAt: updatedAt,
                senderName: "seo-dto-owner",
                replies: openReplies
            ),
        ]
    )
    let hidden = PublicSearchChannel(
        publicId: hiddenPid,
        name: "members-only",
        guestVisible: false,
        threads: [
            PublicSearchThread(
                publicId: hiddenThreadPid,
                parentContent: "Members only question",
                parentSeq: 1,
                parentCreatedAt: updatedAt,
                parentUpdatedAt: updatedAt,
                senderName: "seo-dto-owner",
                replies: [reply("Members only reply")]
            ),
        ]
    )
    let other = PublicSearchServer(
        publicId: otherServerPid,
        name: "Other",
        slug: "other",
        updatedAt: updatedAt,
        channels: [
            PublicSearchChannel(
                publicId: "22222222222222222222222222222222",
                name: "other-talk",
                guestVisible: true,
                threads: [
                    PublicSearchThread(
                        publicId: otherThreadPid,
                        parentContent: "Elsewhere",
                        parentSeq: 1,
                        parentCreatedAt: updatedAt,
                        parentUpdatedAt: updatedAt,
                        senderName: "other-owner",
                        replies: [reply("Other reply", name: "other-owner")]
                    ),
                ]
            ),
        ]
    )
    return PublicSearchCatalog(servers: [
        PublicSearchServer(
            publicId: serverPid,
            name: "Server seo-dto",
            slug: "seo-dto",
            updatedAt: updatedAt,
            channels: [open, hidden]
        ),
        other,
    ])
}

private func indexedServices(_ catalog: PublicSearchCatalog) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        publicSearchIndexEnabled: true,
        publicSearch: catalog
    )
}

private func jsonObject(_ response: ClientResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any] ?? [:]
}

@Test func publicSearchPagesAndIndexWhenTheSwitchIsOn() async throws {
    let catalog = seoCatalog()
    let serverPath = "/servers/\(serverPid)/seo-dto"
    let channelPath = "\(serverPath)/\(openPid)/open-talk"
    let threadPath = "\(channelPath)/\(threadPid)/how-do-i-set-up-agents"
    try await withApp { app in
        configure(app, services: indexedServices(catalog))
        try await app.testing { client in
            let server = try await client.get("/api/public/search/servers/\(serverPid)")
            let channel = try await client.get("/api/public/search/servers/\(serverPid)/channels/\(openPid)")
            let thread = try await client.get("/api/public/search/servers/\(serverPid)/threads/\(threadPid)")
            let index = try await client.get("/api/public/search/index")
            for response in [server, channel, thread, index] {
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
                let text = bodyText(response)
                #expect(text.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: .regularExpression) == nil)
                #expect(text.contains("seo-dto-owner@slock.test") == false)
            }

            let serverBody = try jsonObject(server)
            let serverObject = serverBody["server"] as? [String: Any]
            #expect(serverObject?["canonicalPath"] as? String == serverPath)
            let channels = serverBody["channels"] as? [[String: Any]] ?? []
            #expect(channels.compactMap { $0["publicId"] as? String } == [openPid])

            let channelBody = try jsonObject(channel)
            let threads = channelBody["threads"] as? [[String: Any]] ?? []
            #expect(threads.count == 1)
            #expect(threads[0]["title"] as? String == "How do I set up agents?")
            #expect((threads[0]["replyCount"] as? NSNumber)?.intValue == 1)
            #expect(threads[0]["canonicalPath"] as? String == threadPath)

            let threadBody = try jsonObject(thread)
            let threadObject = threadBody["thread"] as? [String: Any]
            let parent = threadObject?["parent"] as? [String: Any]
            let sender = parent?["sender"] as? [String: Any]
            #expect(sender?["displayName"] as? String == "seo-dto-owner")
            #expect(sender?.keys.sorted() == ["avatarUrl", "displayName", "type"])
            let replies = threadObject?["replies"] as? [[String: Any]] ?? []
            #expect(replies.compactMap { $0["content"] as? String } == ["First reply"])
            #expect((threadObject?["truncated"] as? NSNumber)?.boolValue == false)

            let indexBody = try jsonObject(index)
            let entries = indexBody["entries"] as? [[String: Any]] ?? []
            let paths = entries.compactMap { $0["canonicalPath"] as? String }.filter { $0.contains(serverPid) }
            #expect(paths.count == 3)
            #expect(paths.contains(serverPath))
            #expect(paths.contains(channelPath))
            #expect(paths.contains(threadPath))
            #expect(paths.contains { $0.contains(hiddenPid) || $0.contains(hiddenThreadPid) } == false)
        }
    }
}

@Test func publicSearchTruncatesALongThread() async throws {
    let replies = [reply("First reply")] + (2...52).map { reply("Reply \($0)") }
    try await withApp { app in
        configure(app, services: indexedServices(seoCatalog(replies: replies)))
        try await app.testing { client in
            let response = try await client.get("/api/public/search/servers/\(serverPid)/threads/\(threadPid)")
            let body = try jsonObject(response)
            let thread = body["thread"] as? [String: Any]
            let shown = thread?["replies"] as? [[String: Any]] ?? []
            #expect((thread?["replyCount"] as? NSNumber)?.intValue == 52)
            #expect(shown.count == 50)
            #expect(shown[0]["content"] as? String == "First reply")
            #expect((thread?["truncated"] as? NSNumber)?.boolValue == true)
        }
    }
}

@Test func publicSearchWrongIdsAndABadCursorArePlain404s() async throws {
    try await withApp { app in
        configure(app, services: indexedServices(seoCatalog()))
        try await app.testing { client in
            let paths = [
                "/api/public/search/servers/\(serverPid)/threads/\(otherThreadPid)",
                "/api/public/search/servers/\(serverPid)/channels/22222222222222222222222222222222",
                "/api/public/search/servers/\(serverPid)/threads/\(openPid)",
                "/api/public/search/servers/\(serverPid)/channels/\(threadPid)",
                "/api/public/search/servers/\(serverPid)/threads/\(hiddenThreadPid)",
                "/api/public/search/servers/\(serverPid)/channels/\(openPid)?cursor=x",
            ]
            for path in paths {
                let response = try await client.get(URI(string: path))
                #expect(response.status == .notFound)
                #expect(bodyText(response) == "{\"error\":\"Not found\"}")
            }
        }
    }
}

@Test func publicSearchStaysClosedWhenTheIndexSwitchIsOff() async throws {
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicSearch: seoCatalog()
        ))
        try await app.testing { client in
            let server = try await client.get("/api/public/search/servers/\(serverPid)")
            let index = try await client.get("/api/public/search/index")
            #expect(server.status == .notFound)
            #expect(bodyText(server) == "{\"error\":\"Not found\"}")
            #expect(bodyText(index) == "{\"entries\":[],\"nextCursor\":null}")
        }
    }
}

@Test func publicSearchIndexIsEmptyWhileTheMasterSwitchIsClosed() async throws {
    try await withApp { app in
        configure(app, services: services())
        try await app.testing { client in
            let index = try await client.get("/api/public/search/index")
            #expect(index.status == .ok)
            #expect(index.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            #expect(bodyText(index) == "{\"entries\":[],\"nextCursor\":null}")

            let head = try await client.send(.head, to: "/api/public/search/index")
            #expect(head.status == .ok)
            #expect(bodyText(head).isEmpty)
            #expect(head.headers[.contentLength] == String("{\"entries\":[],\"nextCursor\":null}".utf8.count))
            #expect(head.headers[HTTPField.Name("Cache-Control")!] == "no-store")

            let badCursor = try await client.get("/api/public/search/index?cursor=thread:nope")
            #expect(badCursor.status == .notFound)
            #expect(bodyText(badCursor) == "{\"error\":\"Not found\"}")
            #expect(badCursor.headers[HTTPField.Name("Cache-Control")!] == "no-store")

            let pid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            for path in [
                "/api/public/search/servers/\(pid)",
                "/api/public/search/servers/\(pid)/channels/\(pid)",
                "/api/public/search/servers/\(pid)/threads/\(pid)",
            ] {
                let missing = try await client.get(URI(string: path))
                #expect(missing.status == .notFound)
                #expect(bodyText(missing) == "{\"error\":\"Not found\"}")
                #expect(missing.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            }
        }
    }
}
