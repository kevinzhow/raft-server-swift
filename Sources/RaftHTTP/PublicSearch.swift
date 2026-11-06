import Foundation

public struct PublicSearchReply: Equatable, Sendable {
    public var content: String
    public var createdAt: String
    public var updatedAt: String
    public var senderName: String
    public var senderType: String

    public init(content: String, createdAt: String, updatedAt: String, senderName: String, senderType: String = "user") {
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.senderName = senderName
        self.senderType = senderType
    }
}

public struct PublicSearchThread: Equatable, Sendable {
    public var publicId: String
    public var parentContent: String
    public var parentSeq: Int
    public var parentCreatedAt: String
    public var parentUpdatedAt: String
    public var senderName: String
    public var senderType: String
    public var replies: [PublicSearchReply]
    public var indexLastmod: String?

    public init(
        publicId: String,
        parentContent: String,
        parentSeq: Int,
        parentCreatedAt: String,
        parentUpdatedAt: String,
        senderName: String,
        senderType: String = "user",
        replies: [PublicSearchReply],
        indexLastmod: String? = nil
    ) {
        self.publicId = publicId
        self.parentContent = parentContent
        self.parentSeq = parentSeq
        self.parentCreatedAt = parentCreatedAt
        self.parentUpdatedAt = parentUpdatedAt
        self.senderName = senderName
        self.senderType = senderType
        self.replies = replies
        self.indexLastmod = indexLastmod
    }
}

public struct PublicSearchChannel: Equatable, Sendable {
    public var publicId: String
    public var name: String
    public var description: String?
    public var guestVisible: Bool
    public var threads: [PublicSearchThread]
    public var indexLastmod: String?

    public init(
        publicId: String,
        name: String,
        description: String? = nil,
        guestVisible: Bool,
        threads: [PublicSearchThread] = [],
        indexLastmod: String? = nil
    ) {
        self.publicId = publicId
        self.name = name
        self.description = description
        self.guestVisible = guestVisible
        self.threads = threads
        self.indexLastmod = indexLastmod
    }
}

public struct PublicSearchServer: Equatable, Sendable {
    public var publicId: String
    public var name: String
    public var slug: String
    public var updatedAt: String
    /// Passes the anonymous search predicate: public, search enabled, not deleted, normal kind.
    public var searchable: Bool
    public var channels: [PublicSearchChannel]
    public var indexLastmod: String?

    public init(
        publicId: String,
        name: String,
        slug: String,
        updatedAt: String,
        searchable: Bool = true,
        channels: [PublicSearchChannel],
        indexLastmod: String? = nil
    ) {
        self.publicId = publicId
        self.name = name
        self.slug = slug
        self.updatedAt = updatedAt
        self.searchable = searchable
        self.channels = channels
        self.indexLastmod = indexLastmod
    }
}

public struct PublicSearchCatalog: Equatable, Sendable {
    public var servers: [PublicSearchServer]

    public init(servers: [PublicSearchServer] = []) {
        self.servers = servers
    }
}

/// Read-only public search surface from `routes/publicSearch.ts`.
///
/// GET and HEAD only. Every other method is 405 before any lookup, with
/// `Allow: GET, HEAD` and `Cache-Control: no-store`. While the search-index
/// switch is closed, `/index` is an empty list and server, channel, and thread
/// pages are `{ "error": "Not found" }` — a plain 404, not the app JSON 404.
/// Thread titles and path slugs are display-only; lookup never reads a slug.

public enum PublicSearch {
    public static let threadTitleMax = 80
    public static let slugMax = 60

    public static func publicThreadTitle(_ content: String?) -> String {
        let text = content ?? ""
        for raw in splitLines(text) {
            let stripped = stripMarkers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty { continue }
            let chars = Array(stripped)
            if chars.count > threadTitleMax {
                var cut = Array(chars.prefix(threadTitleMax - 1))
                while let last = cut.last, last.isWhitespace { cut.removeLast() }
                return String(cut) + "…"
            }
            return stripped
        }
        return "Discussion"
    }

    public static func slugifyForPublicPath(_ text: String, fallback: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        var slug = ""
        var pendingDash = false
        var started = false
        for character in normalized {
            if isSlugCharacter(character) {
                if pendingDash && started { slug.append("-") }
                pendingDash = false
                started = true
                slug.append(character)
            } else if started {
                pendingDash = true
            }
        }
        var chars = Array(slug)
        if chars.count > slugMax { chars = Array(chars.prefix(slugMax)) }
        while chars.last == "-" { chars.removeLast() }
        let capped = String(chars)
        return capped.isEmpty ? fallback : capped
    }

    /// Non-GET/HEAD under `/api/public/search`. Nil when this request is not that surface.
    public static func methodNotAllowed(method: String) -> PublicSearchError {
        PublicSearchError(reason: .methodNotAllowed, isHead: method.uppercased() == "HEAD")
    }

    /// Answer a public-search path. Nil when the path is not one of the search routes.
    public static func route(
        method: String,
        path: String,
        cursor: String?,
        indexEnabled: Bool,
        catalog: PublicSearchCatalog = PublicSearchCatalog()
    ) throws -> PublicSearchResponse? {
        if path == "/api/public/search/index" {
            if parseIndexCursor(cursor) == .invalid {
                throw notFound(method: method)
            }
            let page = indexEnabled ? indexPage(catalog, cursor: cursor) : PublicSearchIndexResponse(entries: [], nextCursor: nil)
            return PublicSearchResponse(page: .index(page), isHead: method.uppercased() == "HEAD")
        }
        guard indexEnabled else {
            if isServerPath(path) || isChannelPath(path) || isThreadPath(path) {
                throw notFound(method: method)
            }
            return nil
        }
        let pieces = parts(path)
        if isServerPath(path), let serverPid = pieces.dropFirst(4).first {
            guard let server = searchableServer(serverPid, catalog) else { throw notFound(method: method) }
            return PublicSearchResponse(page: .server(serverPage(server)), isHead: method.uppercased() == "HEAD")
        }
        if isChannelPath(path) {
            guard let serverPid = pieces.dropFirst(4).first, let channelPid = pieces.dropFirst(6).first else {
                throw notFound(method: method)
            }
            guard isPublicId(channelPid), let server = searchableServer(serverPid, catalog),
                  let channel = guestChannel(channelPid, on: server)
            else { throw notFound(method: method) }
            if let cursor, cursor.wholeMatch(of: /^\d{1,18}$/) == nil {
                throw notFound(method: method)
            }
            let seq = cursor.flatMap(Int.init)
            return PublicSearchResponse(page: .channel(channelPage(server, channel, beforeSeq: seq)), isHead: method.uppercased() == "HEAD")
        }
        if isThreadPath(path) {
            guard let serverPid = pieces.dropFirst(4).first, let threadPid = pieces.dropFirst(6).first else {
                throw notFound(method: method)
            }
            guard isPublicId(threadPid), let server = searchableServer(serverPid, catalog),
                  let located = guestThread(threadPid, on: server)
            else { throw notFound(method: method) }
            return PublicSearchResponse(page: .thread(threadPage(server, located.channel, located.thread)), isHead: method.uppercased() == "HEAD")
        }
        return nil
    }

    public static func isSearchPath(_ path: String) -> Bool {
        path == "/api/public/search" || path.hasPrefix("/api/public/search/")
    }

    private static func notFound(method: String) -> PublicSearchError {
        PublicSearchError(reason: .notFound, isHead: method.uppercased() == "HEAD")
    }

    private static func isServerPath(_ path: String) -> Bool {
        parts(path).count == 5 && parts(path)[3] == "servers"
    }

    private static func isChannelPath(_ path: String) -> Bool {
        let pieces = parts(path)
        return pieces.count == 7 && pieces[3] == "servers" && pieces[5] == "channels"
    }

    private static func isThreadPath(_ path: String) -> Bool {
        let pieces = parts(path)
        return pieces.count == 7 && pieces[3] == "servers" && pieces[5] == "threads"
    }

    /// `/api/public/search/...` split on `/`, dropping the empty leading piece.
    private static func parts(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }

    private enum IndexCursor {
        case none
        case invalid
        case resume
    }

    private static func isPublicId(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-f]{32}$/) != nil
    }

    private static func searchableServer(_ publicId: String, _ catalog: PublicSearchCatalog) -> PublicSearchServer? {
        guard isPublicId(publicId) else { return nil }
        return catalog.servers.first { $0.publicId == publicId && $0.searchable }
    }

    private static func guestChannel(_ publicId: String, on server: PublicSearchServer) -> PublicSearchChannel? {
        server.channels.first { $0.publicId == publicId && $0.guestVisible }
    }

    private static func guestThread(_ publicId: String, on server: PublicSearchServer) -> (channel: PublicSearchChannel, thread: PublicSearchThread)? {
        for channel in server.channels where channel.guestVisible {
            if let thread = channel.threads.first(where: { $0.publicId == publicId }) {
                return (channel, thread)
            }
        }
        return nil
    }

    private static func serverPath(_ server: PublicSearchServer) -> String {
        "/servers/\(encodeURIComponent(server.publicId))/\(encodeURIComponent(slugifyForPublicPath(server.slug, fallback: "server")))"
    }

    private static func channelPath(_ server: PublicSearchServer, _ channel: PublicSearchChannel) -> String {
        "\(serverPath(server))/\(encodeURIComponent(channel.publicId))/\(encodeURIComponent(slugifyForPublicPath(channel.name, fallback: "channel")))"
    }

    private static func threadPath(_ server: PublicSearchServer, _ channel: PublicSearchChannel, _ thread: PublicSearchThread) -> String {
        let title = publicThreadTitle(thread.parentContent)
        return "\(channelPath(server, channel))/\(encodeURIComponent(thread.publicId))/\(encodeURIComponent(slugifyForPublicPath(title, fallback: "discussion")))"
    }

    private static func serverSummary(_ server: PublicSearchServer) -> PublicSearchServerSummary {
        .init(publicId: server.publicId, name: server.name, slug: server.slug, canonicalPath: serverPath(server))
    }

    private static func channelSummary(_ server: PublicSearchServer, _ channel: PublicSearchChannel) -> PublicSearchChannelSummary {
        .init(publicId: channel.publicId, name: channel.name, description: channel.description,
              canonicalPath: channelPath(server, channel))
    }

    private static func serverPage(_ server: PublicSearchServer) -> PublicSearchServerResponse {
        let channels = server.channels.filter(\.guestVisible).sorted { $0.name < $1.name }
        return .init(server: serverSummary(server), updatedAt: server.updatedAt,
                     channels: channels.map { channelSummary(server, $0) })
    }

    private static func channelPage(_ server: PublicSearchServer, _ channel: PublicSearchChannel, beforeSeq: Int?) -> PublicSearchChannelResponse {
        var threads = channel.threads.filter { !$0.replies.isEmpty }
        if let beforeSeq { threads = threads.filter { $0.parentSeq < beforeSeq } }
        threads.sort { $0.parentSeq > $1.parentSeq }
        let page = Array(threads.prefix(50))
        return .init(
            server: serverSummary(server), channel: channelSummary(server, channel),
            threads: page.map { thread in
                .init(publicId: thread.publicId, title: publicThreadTitle(thread.parentContent),
                      replyCount: thread.replies.count, lastReplyAt: thread.replies.map(\.createdAt).max(),
                      canonicalPath: threadPath(server, channel, thread))
            },
            nextCursor: threads.count > 50 ? String(page[page.count - 1].parentSeq) : nil
        )
    }

    private static func threadPage(_ server: PublicSearchServer, _ channel: PublicSearchChannel, _ thread: PublicSearchThread) -> PublicSearchThreadResponse {
        let shown = Array(thread.replies.prefix(50))
        return .init(
            server: serverSummary(server), channel: channelSummary(server, channel), publicId: thread.publicId,
            title: publicThreadTitle(thread.parentContent), canonicalPath: threadPath(server, channel, thread),
            parent: .init(senderName: thread.senderName, senderType: thread.senderType, content: thread.parentContent,
                          createdAt: thread.parentCreatedAt, updatedAt: thread.parentUpdatedAt),
            replies: shown.map { .init(senderName: $0.senderName, senderType: $0.senderType, content: $0.content,
                                      createdAt: $0.createdAt, updatedAt: $0.updatedAt) },
            replyCount: thread.replies.count, truncated: thread.replies.count > shown.count
        )
    }

    private static func indexPage(_ catalog: PublicSearchCatalog, cursor: String?) -> PublicSearchIndexResponse {
        let servers = catalog.servers.sorted { $0.publicId < $1.publicId }
        let start = cursor.flatMap { Int($0.prefix(32), radix: 16) } ?? 0
        var entries: [PublicSearchIndexResponse.Entry] = []
        var index = max(0, min(start, servers.count))
        var scanned = 0
        while index < servers.count, scanned < 500, entries.count < 75 {
            let server = servers[index]
            guard server.searchable else {
                index += 1
                scanned += 1
                continue
            }
            var serverEntries: [PublicSearchIndexResponse.Entry] = []
            let serverLastmod = server.indexLastmod ?? server.updatedAt
            serverEntries.append(indexEntry("server", serverPath(server), serverLastmod))
            let channels = server.channels.filter(\.guestVisible).sorted { $0.publicId < $1.publicId }
            for channel in channels {
                serverEntries.append(indexEntry("channel", channelPath(server, channel), channel.indexLastmod ?? serverLastmod))
            }
            let threads = channels.flatMap { channel in
                channel.threads.filter { !$0.replies.isEmpty }.map { (channel, $0) }
            }.sorted { $0.1.publicId < $1.1.publicId }
            for (channel, thread) in threads {
                serverEntries.append(indexEntry("thread", threadPath(server, channel, thread), thread.indexLastmod ?? serverLastmod))
            }
            if !entries.isEmpty, entries.count + serverEntries.count > 75 { break }
            entries.append(contentsOf: serverEntries)
            index += 1
            scanned += 1
        }
        var nextCursor: String?
        if index < servers.count {
            let hex = String(index, radix: 16)
            let padded = String(repeating: "0", count: max(0, 32 - hex.count)) + hex + ":done"
            nextCursor = padded
        }
        return PublicSearchIndexResponse(entries: entries, nextCursor: nextCursor)
    }

    private static func indexEntry(_ type: String, _ path: String, _ lastmod: String) -> PublicSearchIndexResponse.Entry {
        .init(type: type, canonicalPath: path, lastmod: lastmod)
    }

    private static func encodeURIComponent(_ value: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
        var out = ""
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func parseIndexCursor(_ raw: String?) -> IndexCursor {
        guard let raw else { return .none }
        if raw.wholeMatch(of: /^[0-9a-f]{32}:done$/) != nil { return .resume }
        if raw.wholeMatch(of: /^[0-9a-f]{32}:(server|channel|thread)(?::[0-9a-f]{32})?$/) != nil { return .resume }
        return .invalid
    }

    private static func splitLines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false) { character in
            character == "\n" || character == "\r" || character == "\r\n"
        }.map { line in
            var line = String(line)
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
    }

    private static func stripMarkers(_ line: String) -> String {
        var rest = Substring(line)
        while let first = rest.first, first.isWhitespace {
            rest.removeFirst()
        }
        while consumeHeading(&rest) || consumeQuote(&rest) || consumeBullet(&rest) || consumeNumbered(&rest) {}
        return String(rest)
    }

    private static func consumeHeading(_ rest: inout Substring) -> Bool {
        var index = rest.startIndex
        var hashes = 0
        while index < rest.endIndex, rest[index] == "#", hashes < 6 {
            hashes += 1
            index = rest.index(after: index)
        }
        guard hashes > 0, index < rest.endIndex, rest[index].isWhitespace else { return false }
        while index < rest.endIndex, rest[index].isWhitespace {
            index = rest.index(after: index)
        }
        rest = rest[index...]
        return true
    }

    private static func consumeQuote(_ rest: inout Substring) -> Bool {
        guard rest.first == ">" else { return false }
        var index = rest.index(after: rest.startIndex)
        while index < rest.endIndex, rest[index].isWhitespace {
            index = rest.index(after: index)
        }
        rest = rest[index...]
        return true
    }

    private static func consumeBullet(_ rest: inout Substring) -> Bool {
        guard let first = rest.first, first == "-" || first == "*" || first == "+" else { return false }
        let next = rest.index(after: rest.startIndex)
        guard next < rest.endIndex, rest[next].isWhitespace else { return false }
        var index = next
        while index < rest.endIndex, rest[index].isWhitespace {
            index = rest.index(after: index)
        }
        rest = rest[index...]
        return true
    }

    private static func consumeNumbered(_ rest: inout Substring) -> Bool {
        var index = rest.startIndex
        var digits = 0
        while index < rest.endIndex, rest[index].isNumber {
            digits += 1
            index = rest.index(after: index)
        }
        guard digits > 0, index < rest.endIndex, rest[index] == "." || rest[index] == ")" else { return false }
        index = rest.index(after: index)
        guard index < rest.endIndex, rest[index].isWhitespace else { return false }
        while index < rest.endIndex, rest[index].isWhitespace {
            index = rest.index(after: index)
        }
        rest = rest[index...]
        return true
    }

    private static func isSlugCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                true
            default:
                false
            }
        }
    }
}
