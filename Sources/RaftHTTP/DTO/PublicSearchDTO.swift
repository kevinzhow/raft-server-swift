public struct PublicSearchResponse: JSONBodyConvertible {
    public enum Page: Sendable {
        case index(PublicSearchIndexResponse)
        case server(PublicSearchServerResponse)
        case channel(PublicSearchChannelResponse)
        case thread(PublicSearchThreadResponse)
    }
    public let page: Page
    public let isHead: Bool
    public var jsonBody: OrderedJSON {
        switch page {
        case .index(let value): value.jsonBody
        case .server(let value): value.jsonBody
        case .channel(let value): value.jsonBody
        case .thread(let value): value.jsonBody
        }
    }
}
public struct PublicSearchError: DomainError {
    public enum Reason: Sendable { case notFound, methodNotAllowed }
    public let reason: Reason
    public let isHead: Bool
    public var status: UInt { switch reason { case .notFound: 404; case .methodNotAllowed: 405 } }
    public var errorMessage: String { switch reason { case .notFound: "Not found"; case .methodNotAllowed: "Method not allowed" } }
    public var responseHeaders: [String: String] {
        var values = ["Cache-Control": "no-store"]
        if case .methodNotAllowed = reason { values["Allow"] = "GET, HEAD" }
        return values
    }
}
public struct PublicSearchIndexResponse: JSONBodyConvertible {
    public struct Entry: JSONBodyConvertible {
        public let type: String
        public let canonicalPath: String
        public let lastmod: String
        public var jsonBody: OrderedJSON { .object([
            .init("type", type), .init("canonicalPath", canonicalPath), .init("lastmod", lastmod),
        ]) }
    }
    public let entries: [Entry]
    public let nextCursor: String?
    public var jsonBody: OrderedJSON { .object([
        .init("entries", .array(entries.map(\.jsonBody))), .init("nextCursor", optional: nextCursor),
    ]) }
}
public struct PublicSearchServerSummary: JSONBodyConvertible {
    public let publicId: String
    public let name: String
    public let slug: String
    public let canonicalPath: String
    public var jsonBody: OrderedJSON { .object([
        .init("publicId", publicId), .init("name", name), .init("slug", slug), .init("canonicalPath", canonicalPath),
    ]) }
}
public struct PublicSearchChannelSummary: JSONBodyConvertible {
    public let publicId: String
    public let name: String
    public let description: String?
    public let canonicalPath: String
    public var jsonBody: OrderedJSON { .object([
        .init("publicId", publicId), .init("name", name), .init("description", optional: description),
        .init("canonicalPath", canonicalPath),
    ]) }
}
public struct PublicSearchServerResponse: JSONBodyConvertible {
    public let server: PublicSearchServerSummary
    public let updatedAt: String
    public let channels: [PublicSearchChannelSummary]
    public var jsonBody: OrderedJSON { .object([
        .init("server", .object([
            .init("publicId", server.publicId), .init("name", server.name), .init("slug", server.slug),
            .init("avatarUrl", .null), .init("updatedAt", updatedAt), .init("canonicalPath", server.canonicalPath),
        ])),
        .init("channels", .array(channels.map(\.jsonBody))),
    ]) }
}
public struct PublicSearchChannelResponse: JSONBodyConvertible {
    public struct Thread: JSONBodyConvertible {
        public let publicId: String
        public let title: String
        public let replyCount: Int
        public let lastReplyAt: String?
        public let canonicalPath: String
        public var jsonBody: OrderedJSON { .object([
            .init("publicId", publicId), .init("title", title), .init("replyCount", replyCount),
            .init("lastReplyAt", optional: lastReplyAt), .init("canonicalPath", canonicalPath),
        ]) }
    }
    public let server: PublicSearchServerSummary
    public let channel: PublicSearchChannelSummary
    public let threads: [Thread]
    public let nextCursor: String?
    public var jsonBody: OrderedJSON { .object([
        .init("server", server), .init("channel", channel),
        .init("threads", .array(threads.map(\.jsonBody))), .init("nextCursor", optional: nextCursor),
    ]) }
}
public struct PublicSearchThreadResponse: JSONBodyConvertible {
    public struct Message: JSONBodyConvertible {
        public let senderName: String
        public let senderType: String
        public let content: String
        public let createdAt: String
        public let updatedAt: String
        public var jsonBody: OrderedJSON { .object([
            .init("sender", .object([
                .init("type", senderType == "user" || senderType == "agent" ? senderType : "external"),
                .init("displayName", senderName), .init("avatarUrl", .null),
            ])),
            .init("content", content), .init("createdAt", createdAt), .init("updatedAt", updatedAt),
        ]) }
    }
    public let server: PublicSearchServerSummary
    public let channel: PublicSearchChannelSummary
    public let publicId: String
    public let title: String
    public let canonicalPath: String
    public let parent: Message
    public let replies: [Message]
    public let replyCount: Int
    public let truncated: Bool
    public var jsonBody: OrderedJSON { .object([
        .init("server", server),
        .init("channel", .object([
            .init("publicId", channel.publicId), .init("name", channel.name), .init("canonicalPath", channel.canonicalPath),
        ])),
        .init("thread", .object([
            .init("publicId", publicId), .init("title", title), .init("canonicalPath", canonicalPath),
            .init("parent", parent), .init("replies", .array(replies.map(\.jsonBody))),
            .init("replyCount", replyCount), .init("truncated", truncated),
        ])),
    ]) }
}
