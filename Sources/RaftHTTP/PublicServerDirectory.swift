import Crypto
import Foundation

/// Owner-only public visibility and search settings, plus the timestamps the
/// public search index reads.
///
/// Search stays on by default. Going public fills missing 32-hex public ids for
/// the server's channels and threads. An admin cannot change the switch. While
/// the public-server rollout flag is off, the write is a 404.
///
/// Index lastmod follows the page each entry renders: a public channel edit
/// moves the server, that channel, and its threads; a parent edit moves the
/// channel and thread; a reply edit moves only the thread; a private channel
/// edit moves nothing.

public final class PublicServerDirectory: @unchecked Sendable {
    public var rolloutEnabled: Bool
    public var guestRolloutEnabled: Bool
    public var translationAvailable: Bool
    public var searchIndexEnabled: Bool
    private let lock = NSLock()
    private var clock: Int
    private var nextPublicId = 1
    private var tokens: [String: String] = [:]
    private var emails: [String: String] = [:]
    private var invites: [String: EmailInvite] = [:]
    private var servers: [Server] = []

    public init(
        rolloutEnabled: Bool = true,
        guestRolloutEnabled: Bool = true,
        translationAvailable: Bool = false,
        searchIndexEnabled: Bool = true,
        clock: Int = 1_700_000_000_000
    ) {
        self.rolloutEnabled = rolloutEnabled
        self.guestRolloutEnabled = guestRolloutEnabled
        self.translationAvailable = translationAvailable
        self.searchIndexEnabled = searchIndexEnabled
        self.clock = clock
    }

    public struct Seed: Sendable {
        public var serverId: String
        public var openChannelId: String
        public var hiddenChannelId: String
        public var threadId: String
        public var serverPublicId: String
        public var openPublicId: String
        public var threadPublicId: String
        public var ownerToken: String
    }

    @discardableResult
    public func addServer(
        id: String,
        name: String,
        slug: String,
        ownerId: String,
        ownerToken: String,
        adminId: String? = nil,
        adminToken: String? = nil,
        publiclyVisible: Bool = false,
        publicSearchEnabled: Bool = true,
        channels: [(id: String, name: String, description: String?, guestVisible: Bool, publicId: String?, threads: [(id: String, publicId: String?, parent: String, replies: [String])])] = []
    ) -> Seed? {
        lock.lock()
        defer { lock.unlock() }
        tokens[ownerToken] = ownerId
        if let adminId, let adminToken { tokens[adminToken] = adminId }
        var members = [ownerId: "owner"]
        if let adminId { members[adminId] = "admin" }
        let now = clock
        var record = Server(
            id: id,
            publicId: publiclyVisible ? hexId() : nil,
            name: name,
            slug: slug,
            publiclyVisible: publiclyVisible,
            publicSearchEnabled: publicSearchEnabled,
            publicGuestJoinEnabled: false,
            translationEnabled: false,
            createdAtMs: now,
            publicChangedAtMs: now,
            members: members,
            channels: []
        )
        var seedOpen = ""
        var seedHidden = ""
        var seedThread = ""
        var seedOpenPublic = ""
        var seedThreadPublic = ""
        for channel in channels {
            var threads: [Thread] = []
            for thread in channel.threads {
                let publicId = thread.publicId ?? (publiclyVisible ? hexId() : nil)
                threads.append(Thread(
                    id: thread.id,
                    publicId: publicId,
                    parentContent: thread.parent,
                    parentSeq: threads.count + 1,
                    parentCreatedAtMs: now,
                    parentUpdatedAtMs: now,
                    senderName: "\(slug)-owner",
                    createdAtMs: now,
                    publicChangedAtMs: channel.guestVisible ? now : nil,
                    replies: thread.replies.map { Reply(content: $0, createdAtMs: now, updatedAtMs: now, senderName: "\(slug)-owner") }
                ))
            }
            record.channels.append(Channel(
                id: channel.id,
                publicId: channel.publicId ?? (publiclyVisible ? hexId() : nil),
                name: channel.name,
                description: channel.description,
                guestVisible: channel.guestVisible,
                createdAtMs: now,
                publicChangedAtMs: channel.guestVisible ? now : nil,
                threads: threads
            ))
        }
        servers.append(record)
        if let open = record.channels.first(where: { $0.guestVisible }), let thread = open.threads.first {
            seedOpen = open.id
            seedOpenPublic = open.publicId ?? ""
            seedThread = thread.id
            seedThreadPublic = thread.publicId ?? ""
        }
        if let hidden = record.channels.first(where: { !$0.guestVisible }) { seedHidden = hidden.id }
        return Seed(
            serverId: id,
            openChannelId: seedOpen,
            hiddenChannelId: seedHidden,
            threadId: seedThread,
            serverPublicId: record.publicId ?? "",
            openPublicId: seedOpenPublic,
            threadPublicId: seedThreadPublic,
            ownerToken: ownerToken
        )
    }

    public func patchVisibility(serverId: String, authorization: String?, body: String) -> HTTPReply {
        guard let userId = userId(authorization) else { return forbiddenVisibility }
        lock.lock()
        defer { lock.unlock() }
        guard servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { return forbiddenVisibility }
        guard rolloutEnabled else { return notFound }
        guard let publiclyVisible = jsonBool(body, key: "publiclyVisible") else {
            return error(400, "publiclyVisible must be a boolean")
        }
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else {
            return error(404, "Server not found")
        }
        servers[index].publiclyVisible = publiclyVisible
        if !publiclyVisible { servers[index].publicGuestJoinEnabled = false }
        servers[index].publicChangedAtMs = bumpLocked()
        if publiclyVisible { backfillLocked(index) }
        let server = servers[index]
        let payload = "{\"publiclyVisible\":\(server.publiclyVisible),\"publicGuestJoinEnabled\":\(server.publicGuestJoinEnabled),\"publicSearchEnabled\":\(server.publicSearchEnabled)}"
        return json(200, payload)
    }

    public func patchSearch(serverId: String, authorization: String?, body: String) -> HTTPReply {
        guard let userId = userId(authorization) else { return forbiddenSearch }
        lock.lock()
        defer { lock.unlock() }
        guard servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { return forbiddenSearch }
        guard rolloutEnabled else { return notFound }
        guard let enabled = jsonBool(body, key: "publicSearchEnabled") else {
            return error(400, "publicSearchEnabled must be a boolean")
        }
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else {
            return error(404, "Server not found")
        }
        servers[index].publicSearchEnabled = enabled
        servers[index].publicChangedAtMs = bumpLocked()
        return json(200, "{\"publicSearchEnabled\":\(enabled)}")
    }

    /// Owner-only Guest admission. It cannot open before Public, and an admin cannot touch it.
    public func patchGuestJoin(serverId: String, authorization: String?, body: String) -> HTTPReply {
        guard let userId = userId(authorization) else { return forbiddenGuestJoin }
        lock.lock()
        defer { lock.unlock() }
        guard servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { return forbiddenGuestJoin }
        guard rolloutEnabled, guestRolloutEnabled else { return notFound }
        guard let enabled = jsonBool(body, key: "publicGuestJoinEnabled") else {
            return error(400, "publicGuestJoinEnabled must be a boolean")
        }
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else {
            return error(404, "Server not found")
        }
        if enabled, !servers[index].publiclyVisible {
            return error(409, "Public access must be enabled before visitors can join as Guest")
        }
        servers[index].publicGuestJoinEnabled = enabled
        return json(200, "{\"publicGuestJoinEnabled\":\(enabled)}")
    }

    public func addAccount(id: String, email: String, token: String) {
        lock.lock()
        tokens[token] = id
        emails[id] = email.lowercased()
        lock.unlock()
    }

    public func addEmailInvite(serverId: String, email: String, role: String, rawToken: String, expiresAt: Date) {
        lock.lock()
        invites[Self.sha256Hex(rawToken)] = EmailInvite(
            serverId: serverId,
            email: email.lowercased(),
            role: role,
            expiresAt: expiresAt,
            status: "pending"
        )
        lock.unlock()
    }

    public func memberRole(serverId: String, userId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return servers.first { $0.id == serverId }?.members[userId]
    }

    /// Email invites keep the role stored on the invite. Public admission is not consulted.
    public func acceptInvite(authorization: String?, body: String, now: Date = Date()) -> HTTPReply {
        guard let userId = userId(authorization) else {
            let message = authorization?.hasPrefix("Bearer ") == true
                ? "Invalid or expired token"
                : "Missing or invalid Authorization header"
            return error(401, message, code: "auth_required")
        }
        guard let token = jsonStringValue(body, key: "token"), !token.isEmpty else {
            return error(400, "Invite token is required")
        }
        lock.lock()
        defer { lock.unlock() }
        guard let email = emails[userId] else { return error(401, "Invalid or expired token", code: "auth_required") }
        let hash = Self.sha256Hex(token)
        guard var invite = invites[hash], invite.status == "pending", invite.expiresAt > now else {
            return error(400, "Invalid invite token")
        }
        guard invite.email == email else {
            return error(400, "This invite was sent to a different email address")
        }
        guard let index = servers.firstIndex(where: { $0.id == invite.serverId }) else {
            return error(404, "Server not found")
        }
        guard servers[index].members[userId] == nil else {
            return error(400, "You are already a member of this server")
        }
        servers[index].members[userId] = invite.role
        invite.status = "accepted"
        invites[hash] = invite
        let server = servers[index]
        return json(200, "{\"serverId\":\(jsonString(server.id)),\"serverName\":\(jsonString(server.name))}")
    }

    public func setTranslationEnabled(serverId: String, enabled: Bool) {
        lock.lock()
        if let index = servers.firstIndex(where: { $0.id == serverId }) {
            servers[index].translationEnabled = enabled
        }
        lock.unlock()
    }

    public func readVisibility(serverId: String, authorization: String?) -> HTTPReply {
        guard let userId = userId(authorization) else { return forbiddenVisibility }
        lock.lock()
        defer { lock.unlock() }
        guard servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { return forbiddenVisibility }
        guard rolloutEnabled else { return notFound }
        guard let server = servers.first(where: { $0.id == serverId }) else { return error(404, "Server not found") }
        let exposed = server.channels.filter(\.guestVisible).sorted { $0.name < $1.name }
        let listed = exposed.map { channel in
            let description = channel.description.map { jsonString($0) } ?? "null"
            return "{\"id\":\(jsonString(channel.id)),\"name\":\(jsonString(channel.name)),\"description\":\(description)}"
        }.joined(separator: ",")
        return json(200, "{\"publiclyVisible\":\(server.publiclyVisible),\"publicGuestJoinEnabled\":\(server.publicGuestJoinEnabled),\"publicSearchEnabled\":\(server.publicSearchEnabled),\"slug\":\(jsonString(server.slug)),\"exposedChannels\":[\(listed)]}")
    }

    /// Anonymous card for this directory. Unknown slugs and servers that are
    /// not public are the same 404, so a probe cannot tell them apart.
    public func publicCard(slug: String) -> HTTPReply {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers.first(where: { $0.slug == slug }), rolloutEnabled, server.publiclyVisible else {
            return notFound
        }
        let channels = server.channels.filter(\.guestVisible).sorted { $0.name < $1.name }
        let listed = channels.map { "{\"id\":\(jsonString($0.id))}" }.joined(separator: ",")
        let canJoin = server.publicGuestJoinEnabled && guestRolloutEnabled
        let serverJSON = "{\"id\":\(jsonString(server.id)),\"name\":\(jsonString(server.name)),\"slug\":\(jsonString(server.slug)),\"avatarUrl\":null,\"translationEnabled\":\(server.translationEnabled)}"
        let body = "{\"server\":\(serverJSON),\"channels\":[\(listed)],\"canJoinAsGuest\":\(canJoin),\"translationAvailable\":\(translationAvailable)}"
        return HTTPReply(
            status: 200,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "no-store",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    public func publicIds(serverId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let server = servers.first(where: { $0.id == serverId }) else { return [] }
        return server.channels.flatMap { channel -> [String] in
            var ids = channel.publicId.map { [$0] } ?? []
            ids.append(contentsOf: channel.threads.compactMap(\.publicId))
            return ids
        }
    }

    public enum Edit: Sendable {
        case renameChannel(id: String, name: String)
        case editChannelDescription(id: String, description: String)
        case editParent(channelId: String, content: String)
        case editReply(threadId: String, content: String)
        case addReply(threadId: String, content: String)
        case renameServer(id: String, name: String)
        case renamePrivateChannel(id: String, name: String)
        case setServerPublic(id: String, visible: Bool)
        case setServerSearch(id: String, enabled: Bool)
        case setServerDeleted(id: String, deleted: Bool)
        case setChannelGuestVisible(id: String, visible: Bool)
        case setChannelArchived(id: String, archived: Bool)
        case setChannelDeleted(id: String, deleted: Bool)
        case setChannelPrivate(id: String, privateChannel: Bool)
    }

    public func apply(_ edit: Edit) {
        lock.lock()
        defer { lock.unlock() }
        let now = bumpLocked()
        switch edit {
        case .renameChannel(let id, let name):
            mutateChannel(id) { channel in
                channel.name = name
                if channel.guestVisible { channel.publicChangedAtMs = now }
            }
        case .editChannelDescription(let id, let description):
            mutateChannel(id) { channel in
                channel.description = description
                if channel.guestVisible { channel.publicChangedAtMs = now }
            }
        case .editParent(let channelId, let content):
            mutateChannel(channelId) { channel in
                if !channel.threads.isEmpty { channel.threads[0].parentContent = content; channel.threads[0].parentUpdatedAtMs = now }
            }
        case .editReply(let threadId, let content):
            mutateThread(threadId) { thread in
                if !thread.replies.isEmpty { thread.replies[0].content = content; thread.replies[0].updatedAtMs = now }
            }
        case .addReply(let threadId, let content):
            mutateThread(threadId) { thread in
                thread.replies.append(Reply(content: content, createdAtMs: now, updatedAtMs: now, senderName: thread.senderName))
            }
        case .renameServer(let id, let name):
            if let index = servers.firstIndex(where: { $0.id == id }) {
                servers[index].name = name
                servers[index].publicChangedAtMs = now
            }
        case .renamePrivateChannel(let id, let name):
            mutateChannel(id) { channel in
                channel.name = name
            }
        case .setServerPublic(let id, let visible):
            if let index = servers.firstIndex(where: { $0.id == id }) {
                servers[index].publiclyVisible = visible
                servers[index].publicChangedAtMs = now
            }
        case .setServerSearch(let id, let enabled):
            if let index = servers.firstIndex(where: { $0.id == id }) {
                servers[index].publicSearchEnabled = enabled
                servers[index].publicChangedAtMs = now
            }
        case .setServerDeleted(let id, let deleted):
            if let index = servers.firstIndex(where: { $0.id == id }) { servers[index].deleted = deleted }
        case .setChannelGuestVisible(let id, let visible):
            mutateChannel(id) { channel in
                channel.guestVisible = visible
                if visible { channel.publicChangedAtMs = now }
            }
        case .setChannelArchived(let id, let archived):
            mutateChannel(id) { channel in
                channel.archived = archived
                channel.publicChangedAtMs = now
            }
        case .setChannelDeleted(let id, let deleted):
            mutateChannel(id) { channel in
                channel.deleted = deleted
                channel.publicChangedAtMs = now
            }
        case .setChannelPrivate(let id, let privateChannel):
            mutateChannel(id) { channel in
                channel.isPrivate = privateChannel
                channel.publicChangedAtMs = now
            }
        }
    }

    public func projectedCatalog() -> PublicSearchCatalog {
        lock.lock()
        defer { lock.unlock() }
        let projected = servers.compactMap { server -> PublicSearchServer? in
            guard rolloutEnabled, server.publiclyVisible, !server.deleted, let publicId = server.publicId else { return nil }
            let serverLast = iso(serverLastmod(server))
            let channels = server.channels.compactMap { channel -> PublicSearchChannel? in
                guard let channelPublicId = channel.publicId, !channel.archived, !channel.deleted, !channel.isPrivate else { return nil }
                let threads = channel.threads.compactMap { thread -> PublicSearchThread? in
                    guard let threadPublicId = thread.publicId else { return nil }
                    return PublicSearchThread(
                        publicId: threadPublicId,
                        parentContent: thread.parentContent,
                        parentSeq: thread.parentSeq,
                        parentCreatedAt: iso(thread.parentCreatedAtMs),
                        parentUpdatedAt: iso(thread.parentUpdatedAtMs),
                        senderName: thread.senderName,
                        replies: thread.replies.map {
                            PublicSearchReply(content: $0.content, createdAt: iso($0.createdAtMs), updatedAt: iso($0.updatedAtMs), senderName: $0.senderName)
                        },
                        indexLastmod: iso(threadLastmod(server, channel, thread))
                    )
                }
                return PublicSearchChannel(
                    publicId: channelPublicId,
                    name: channel.name,
                    description: channel.description,
                    guestVisible: channel.guestVisible,
                    threads: threads,
                    indexLastmod: iso(channelLastmod(server, channel))
                )
            }
            return PublicSearchServer(
                publicId: publicId,
                name: server.name,
                slug: server.slug,
                updatedAt: serverLast,
                searchable: server.publicSearchEnabled,
                channels: server.publicSearchEnabled ? channels : [],
                indexLastmod: serverLast
            )
        }
        return PublicSearchCatalog(servers: projected)
    }

    private func userId(_ authorization: String?) -> String? {
        guard let header = authorization, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        lock.lock()
        defer { lock.unlock() }
        return tokens[token]
    }

    private func backfillLocked(_ index: Int) {
        if servers[index].publicId == nil { servers[index].publicId = hexId() }
        for channelIndex in servers[index].channels.indices {
            if servers[index].channels[channelIndex].publicId == nil {
                servers[index].channels[channelIndex].publicId = hexId()
            }
            for threadIndex in servers[index].channels[channelIndex].threads.indices {
                if servers[index].channels[channelIndex].threads[threadIndex].publicId == nil {
                    servers[index].channels[channelIndex].threads[threadIndex].publicId = hexId()
                }
            }
        }
    }

    private func bumpLocked() -> Int {
        clock += 1
        return clock
    }

    private func hexId() -> String {
        nextPublicId += 1
        return String(format: "%032x", nextPublicId)
    }

    private func mutateChannel(_ id: String, _ body: (inout Channel) -> Void) {
        for serverIndex in servers.indices {
            if let channelIndex = servers[serverIndex].channels.firstIndex(where: { $0.id == id }) {
                body(&servers[serverIndex].channels[channelIndex])
                return
            }
        }
    }

    private func mutateThread(_ id: String, _ body: (inout Thread) -> Void) {
        for serverIndex in servers.indices {
            for channelIndex in servers[serverIndex].channels.indices {
                if let threadIndex = servers[serverIndex].channels[channelIndex].threads.firstIndex(where: { $0.id == id }) {
                    body(&servers[serverIndex].channels[channelIndex].threads[threadIndex])
                    return
                }
            }
        }
    }

    private func serverLastmod(_ server: Server) -> Int {
        var values = [server.createdAtMs, server.publicChangedAtMs]
        for channel in server.channels where channel.guestVisible {
            values.append(channel.createdAtMs)
            if let changed = channel.publicChangedAtMs { values.append(changed) }
        }
        return values.max() ?? server.createdAtMs
    }

    private func channelLastmod(_ server: Server, _ channel: Channel) -> Int {
        var values = [server.createdAtMs, server.publicChangedAtMs, channel.createdAtMs]
        if let changed = channel.publicChangedAtMs { values.append(changed) }
        for thread in channel.threads {
            values.append(thread.createdAtMs)
            values.append(thread.parentCreatedAtMs)
            values.append(thread.parentUpdatedAtMs)
            if let changed = thread.publicChangedAtMs { values.append(changed) }
            if let newest = thread.replies.map(\.createdAtMs).max() { values.append(newest) }
        }
        return values.max() ?? channel.createdAtMs
    }

    private func threadLastmod(_ server: Server, _ channel: Channel, _ thread: Thread) -> Int {
        var values = [server.createdAtMs, server.publicChangedAtMs, channel.createdAtMs, thread.createdAtMs, thread.parentUpdatedAtMs]
        if let changed = channel.publicChangedAtMs { values.append(changed) }
        if let changed = thread.publicChangedAtMs { values.append(changed) }
        for reply in thread.replies {
            values.append(reply.createdAtMs)
            values.append(reply.updatedAtMs)
        }
        return values.max() ?? thread.createdAtMs
    }

    private func jsonBool(_ body: String, key: String) -> Bool? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key]
        else { return nil }
        if let bool = value as? Bool { return bool }
        return nil
    }

    private func json(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    private func error(_ status: Int, _ message: String, code: String? = nil) -> HTTPReply {
        if let code {
            return json(status, "{\"error\":\(jsonString(message)),\"code\":\(jsonString(code))}")
        }
        return json(status, "{\"error\":\(jsonString(message))}")
    }

    private func jsonStringValue(_ body: String, key: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct EmailInvite {
        var serverId: String
        var email: String
        var role: String
        var expiresAt: Date
        var status: String
    }

    private var forbiddenVisibility: HTTPReply { error(403, "Only the server owner can manage public visibility") }
    private var forbiddenGuestJoin: HTTPReply { error(403, "Only the server owner can manage public Guest admission") }
    private var forbiddenSearch: HTTPReply { error(403, "Only the server owner can manage public search") }
    private var notFound: HTTPReply { error(404, "Not found") }

    private func iso(_ ms: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, ms % 1000
        )
    }

    private struct Reply {
        var content: String
        var createdAtMs: Int
        var updatedAtMs: Int
        var senderName: String
    }

    private struct Thread {
        var id: String
        var publicId: String?
        var parentContent: String
        var parentSeq: Int
        var parentCreatedAtMs: Int
        var parentUpdatedAtMs: Int
        var senderName: String
        var createdAtMs: Int
        var publicChangedAtMs: Int?
        var replies: [Reply]
    }

    private struct Channel {
        var id: String
        var publicId: String?
        var name: String
        var description: String?
        var guestVisible: Bool
        var createdAtMs: Int
        var publicChangedAtMs: Int?
        var threads: [Thread]
        var archived: Bool = false
        var deleted: Bool = false
        var isPrivate: Bool = false
    }

    private struct Server {
        var id: String
        var publicId: String?
        var name: String
        var slug: String
        var publiclyVisible: Bool
        var publicSearchEnabled: Bool
        var publicGuestJoinEnabled: Bool
        var translationEnabled: Bool
        var createdAtMs: Int
        var publicChangedAtMs: Int
        var members: [String: String]
        var channels: [Channel]
        var deleted: Bool = false
    }
}
