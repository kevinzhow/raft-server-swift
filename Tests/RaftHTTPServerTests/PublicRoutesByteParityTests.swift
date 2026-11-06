import Crypto
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func publicBytesServices(
    visits: PublicVisitDirectory? = nil,
    search: PublicSearchCatalog = .init(),
    notes: [ReleaseNoteRecord] = []
) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
        publicSearchIndexEnabled: true, publicSearch: search, releaseNotes: notes, publicVisits: visits
    )
}

@Test func publicReleaseNotesPreserveOrderedBytesETagAndConditionalHeaders() async throws {
    let id = "11111111-1111-4111-8111-111111111111"
    let note = ReleaseNoteRecord(
        id: id, releaseKey: "release/一", version: "1.0", tag: "v1", date: "2026-09-01",
        currentRevision: 2, snapshotHash: "hash", entries: [
            .init(entryId: "old", type: "fix", text: "hidden", ordinal: 0, revision: 1),
            .init(entryId: "entry", type: "fix", text: "line\n\"一\"/", emphasis: true, ordinal: 3, revision: 2),
        ]
    )
    let expected = #"{"releaseId":"11111111-1111-4111-8111-111111111111","releaseKey":"release/一","version":"1.0","tag":"v1","date":"2026-09-01","revision":2,"snapshotHash":"hash","publishedAt":null,"state":"published","entries":[{"entryId":"entry","type":"fix","text":"line\n\"一\"/","emphasis":true,"ordinal":3}]}"#
    let etag = "\"" + SHA256.hash(data: Data(expected.utf8)).map { String(format: "%02x", $0) }.joined() + "\""
    try await withApp { app in
        configure(app, services: publicBytesServices(notes: [note]))
        try await app.testing { client in
            let detail = try await client.get(URI(string: "/api/release-notes/\(id)"))
            #expect(detail.status == .ok)
            #expect(detail.body.string == expected)
            #expect(detail.headers[.contentLength] == String(expected.utf8.count))
            #expect(detail.headers[.eTag] == etag)
            #expect(detail.headers[.cacheControl] == "public, max-age=30")
            let cached = try await client.get(URI(string: "/api/release-notes/\(id)"), headers: [.ifNoneMatch: etag])
            #expect(cached.status == .notModified)
            #expect((cached.body.string ?? "").isEmpty)
            #expect(cached.headers[.contentLength] == "0")
            #expect(cached.headers[.contentType] == nil)
            #expect(cached.headers[.eTag] == etag)
            #expect(cached.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
            let list = try await client.get("/api/release-notes")
            #expect(list.body.string == "{\"items\":[\(expected)],\"nextCursor\":null}")
        }
    }
}

@Test func publicHistoryAndPagePreserveNestedOrderedBytesWithoutPrivateFields() async throws {
    let visits = PublicVisitDirectory()
    let server = "33333333-3333-4333-8333-333333333333"
    let channel = "22222222-2222-4222-8222-222222222222"
    visits.addServer(id: server, slug: "bytes", visitorIdEnabled: true, name: "一/\"server\"")
    visits.addGuestChannel(slug: "bytes", id: channel, name: "general")
    visits.addPublicMessage(slug: "bytes", message: .init(
        id: "message", channelId: channel, content: "hello\n一", createdAt: "now", seq: 1,
        senderType: "user", sender: .init(displayName: "Alice", handle: "alice", avatarUrl: nil, description: "profile", actorId: "PRIVATE"),
        secret: "PRIVATE", attachments: [.init(id: "attachment", filename: "一.txt", mimeType: " text/plain ", sizeBytes: 9, width: nil, height: 2, storageKey: "PRIVATE")],
        reactions: [.init(emoji: "👍", createdAt: "now", reactorId: "PRIVATE")]
    ))
    let page = #"{"server":{"id":"33333333-3333-4333-8333-333333333333","name":"一/\"server\"","slug":"bytes","avatarUrl":null,"translationEnabled":false},"channels":[{"id":"22222222-2222-4222-8222-222222222222","name":"general","description":null}],"canJoinAsGuest":false,"translationAvailable":false,"visitorIdMode":"default_on"}"#
    let history = #"{"messages":[{"id":"message","senderType":"user","sender":{"displayName":"Alice","handle":"alice","avatarUrl":null,"description":"profile"},"messageType":"text","content":"hello\n一","createdAt":"now","attachments":[{"id":"attachment","filename":"一.txt","mimeType":"text/plain","sizeBytes":9,"width":null,"height":2}],"mentions":[],"reactions":[{"emoji":"👍","count":1}],"threadId":null,"replyCount":0,"lastReplyAt":null,"latestReplies":[]}]}"#
    try await withApp { app in
        configure(app, services: publicBytesServices(visits: visits))
        try await app.testing { client in
            let card = try await client.get("/api/public/servers/bytes", headers: [HTTPField.Name("CloudFront-Viewer-Country")!: "US"])
            #expect(card.body.string == page)
            #expect(card.headers[.contentLength] == String(page.utf8.count))
            let messages = try await client.get(URI(string: "/api/public/servers/bytes/channels/\(channel)/messages"))
            #expect(messages.body.string == history)
            #expect(messages.headers[.contentLength] == String(history.utf8.count))
            #expect(messages.headers[.cacheControl] == "no-store")
        }
    }
}

@Test func publicSettingsKeepLastDuplicateMemberAndLegacyBooleanCoercion() async throws {
    let directory = PublicServerDirectory()
    _ = directory.addServer(id: "srv", name: "Settings", slug: "settings", ownerId: "owner", ownerToken: "owner-token")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicServerDirectory: directory))
        try await app.testing { client in
            for (body, expected) in [
                (#"{"publiclyVisible":false,"publiclyVisible":1}"#, true),
                (#"{"publiclyVisible":true,"publiclyVisible":0.0}"#, false),
                (#"{"publiclyVisible":1.0,"ignored":{"anything":true}}"#, true),
                (#"{"publiclyVisible":1,"publiclyVisible":false}"#, false),
            ] {
                let response = try await client.send(.patch, headers: [.authorization: "Bearer owner-token", .contentType: "application/json"], to: "/api/servers/srv/public-visibility") {
                    $0.body = .init(string: body)
                }
                #expect(response.status == .ok)
                #expect(response.body.string == "{\"publiclyVisible\":\(expected),\"publicGuestJoinEnabled\":false,\"publicSearchEnabled\":true}")
            }
            let invalid = try await client.send(.patch, headers: [.authorization: "Bearer owner-token", .contentType: "application/json"], to: "/api/servers/srv/public-visibility") {
                $0.body = .init(string: #"{"publiclyVisible":2}"#)
            }
            #expect(invalid.status == .badRequest)
            #expect(invalid.body.string == #"{"error":"publiclyVisible must be a boolean"}"#)
            let anonymous = try await client.send(.patch, headers: [.contentType: "application/json"], to: "/api/servers/srv/public-visibility") {
                $0.body = .init(string: #"{"publiclyVisible":"invalid"}"#)
            }
            #expect(anonymous.status == .forbidden)
            #expect(anonymous.body.string == #"{"error":"Only the server owner can manage public visibility"}"#)
        }
    }
}

@Test func publicReleaseCursorKeepsLastDuplicateFieldsAndIgnoresUnknownFields() async throws {
    let older = ReleaseNoteRecord(id: "11111111-1111-4111-8111-111111111111", releaseKey: "old", version: "1", tag: "v1", date: "2026-09-01", currentRevision: 1, snapshotHash: "h")
    let newer = ReleaseNoteRecord(id: "22222222-2222-4222-8222-222222222222", releaseKey: "new", version: "2", tag: "v2", date: "2026-09-02", currentRevision: 1, snapshotHash: "h")
    let cursorBody = #" {"date":"invalid","date":"2026-09-02","id":false,"id":"22222222-2222-4222-8222-222222222222","unknown":true} "#
    let cursor = Data(cursorBody.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    try await withApp { app in
        configure(app, services: publicBytesServices(notes: [older, newer]))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/release-notes?cursor=\(cursor)"))
            #expect(response.status == .ok)
            #expect(response.body.string == #"{"items":[{"releaseId":"11111111-1111-4111-8111-111111111111","releaseKey":"old","version":"1","tag":"v1","date":"2026-09-01","revision":1,"snapshotHash":"h","publishedAt":null,"state":"published","entries":[]}],"nextCursor":null}"#)
        }
    }
}

@Test func publicTranslationKeepsLastDuplicateLanguageAndFiltersHeterogeneousIDs() async throws {
    let visits = PublicVisitDirectory()
    visits.addServer(id: "srv", slug: "translation", translationEnabled: true)
    visits.setTranslationAvailable(true)
    try await withApp { app in
        configure(app, services: publicBytesServices(visits: visits))
        try await app.testing { client in
            let response = try await client.send(.post, headers: [.contentType: "application/json"], to: "/api/public/servers/translation/message-translations:batch") {
                $0.body = .init(string: #"{"targetLanguage":"unsupported","targetLanguage":"en","mode":"manual","messageIds":[null,1,"bad","11111111-1111-4111-8111-111111111111"],"unknown":true}"#)
            }
            #expect(response.status == .ok)
            #expect(response.body.string == #"{"results":[{"messageId":"11111111-1111-4111-8111-111111111111","status":"not_found","targetLanguage":"en"}]}"#)
            #expect(response.headers[.cacheControl] == "no-store")
        }
    }
}

@Test func publicSearchHEADPreservesPopulatedAndErrorRepresentationLengths() async throws {
    let serverId = String(repeating: "a", count: 32)
    let channelId = String(repeating: "b", count: 32)
    let threadId = String(repeating: "c", count: 32)
    let serverPath = "/servers/\(serverId)/alpha"
    let channelPath = "\(serverPath)/\(channelId)/general"
    let threadPath = "\(channelPath)/\(threadId)/hello"
    let catalog = PublicSearchCatalog(servers: [.init(
        publicId: serverId, name: "一", slug: "alpha", updatedAt: "now", channels: [.init(
            publicId: channelId, name: "general", guestVisible: true, threads: [.init(
                publicId: threadId, parentContent: "Hello", parentSeq: 1, parentCreatedAt: "now", parentUpdatedAt: "now", senderName: "Alice",
                replies: [.init(content: "一", createdAt: "later", updatedAt: "later", senderName: "Bot", senderType: "other")]
            )]
        )]
    )])
    let expectedThread = #"{"server":{"publicId":"\#(serverId)","name":"一","slug":"alpha","canonicalPath":"\#(serverPath)"},"channel":{"publicId":"\#(channelId)","name":"general","canonicalPath":"\#(channelPath)"},"thread":{"publicId":"\#(threadId)","title":"Hello","canonicalPath":"\#(threadPath)","parent":{"sender":{"type":"user","displayName":"Alice","avatarUrl":null},"content":"Hello","createdAt":"now","updatedAt":"now"},"replies":[{"sender":{"type":"external","displayName":"Bot","avatarUrl":null},"content":"一","createdAt":"later","updatedAt":"later"}],"replyCount":1,"truncated":false}}"#
    try await withApp { app in
        configure(app, services: publicBytesServices(search: catalog))
        try await app.testing { client in
            for path in [
                "/api/public/search/index", "/api/public/search/servers/\(serverId)",
                "/api/public/search/servers/\(serverId)/channels/\(channelId)",
                "/api/public/search/servers/\(serverId)/threads/\(threadId)",
                "/api/public/search/servers/invalid", "/api/public/search/index?cursor=invalid",
            ] {
                let get = try await client.get(URI(string: path))
                let head = try await client.send(.head, to: URI(string: path))
                #expect(head.status == get.status)
                #expect((head.body.string ?? "").isEmpty)
                #expect(head.headers[.contentLength] == String((get.body.string ?? "").utf8.count))
                #expect(head.headers[.cacheControl] == "no-store")
                #expect(head.headers[.contentType] == get.headers[.contentType])
                if path.hasSuffix("/threads/\(threadId)") { #expect(get.body.string == expectedThread) }
            }
        }
    }
}
