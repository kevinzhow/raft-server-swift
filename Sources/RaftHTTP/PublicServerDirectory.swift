import Crypto
import Foundation
import Synchronization

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

public final class PublicServerDirectory: Sendable {
    struct State: Sendable {
        var rolloutEnabled: Bool
        var guestRolloutEnabled: Bool
        var translationAvailable: Bool
        var searchIndexEnabled: Bool
        var clock: Int
        var nextPublicId = 1
        var tokens: [String: String] = [:]
        var emails: [String: String] = [:]
        var invites: [String: EmailInvite] = [:]
        var servers: [Server] = []
    }

    /// Internal so the dedicated test seam can borrow the same protected state.
    let state: Mutex<State>

    public var rolloutEnabled: Bool {
        get { state.withLock { $0.rolloutEnabled } }
        set { state.withLock { $0.rolloutEnabled = newValue } }
    }

    public var guestRolloutEnabled: Bool {
        get { state.withLock { $0.guestRolloutEnabled } }
        set { state.withLock { $0.guestRolloutEnabled = newValue } }
    }

    public var translationAvailable: Bool {
        get { state.withLock { $0.translationAvailable } }
        set { state.withLock { $0.translationAvailable = newValue } }
    }

    public var searchIndexEnabled: Bool {
        get { state.withLock { $0.searchIndexEnabled } }
        set { state.withLock { $0.searchIndexEnabled = newValue } }
    }

    public init(
        rolloutEnabled: Bool = true,
        guestRolloutEnabled: Bool = true,
        translationAvailable: Bool = false,
        searchIndexEnabled: Bool = true,
        clock: Int = 1_700_000_000_000
    ) {
        state = Mutex(State(
            rolloutEnabled: rolloutEnabled,
            guestRolloutEnabled: guestRolloutEnabled,
            translationAvailable: translationAvailable,
            searchIndexEnabled: searchIndexEnabled,
            clock: clock
        ))
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
        return state.withLock { state in
            state.tokens[ownerToken] = ownerId
            if let adminId, let adminToken { state.tokens[adminToken] = adminId }
            var members = [ownerId: "owner"]
            if let adminId { members[adminId] = "admin" }
            let now = state.clock
            var record = Server(
                id: id,
                publicId: publiclyVisible ? Self.hexId(state: &state) : nil,
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
                    let publicId = thread.publicId ?? (publiclyVisible ? Self.hexId(state: &state) : nil)
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
                    publicId: channel.publicId ?? (publiclyVisible ? Self.hexId(state: &state) : nil),
                    name: channel.name,
                    description: channel.description,
                    guestVisible: channel.guestVisible,
                    createdAtMs: now,
                    publicChangedAtMs: channel.guestVisible ? now : nil,
                    threads: threads
                ))
            }
            state.servers.append(record)
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
    }

    public func patchVisibility(serverId: String, authorization: String?, body: String) throws -> PublicVisibilityUpdateResponse {
        guard let userId = userId(authorization) else { throw PublicSettingsError.forbiddenVisibility }
        return try state.withLock { state in
            guard state.servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { throw PublicSettingsError.forbiddenVisibility }
            guard state.rolloutEnabled else { throw PublicSettingsError.notFound }
            guard let publiclyVisible = jsonBool(body, key: "publiclyVisible") else {
                throw PublicSettingsError.invalidVisibility
            }
            guard let index = state.servers.firstIndex(where: { $0.id == serverId }) else {
                throw PublicSettingsError.serverNotFound
            }
            state.servers[index].publiclyVisible = publiclyVisible
            if !publiclyVisible { state.servers[index].publicGuestJoinEnabled = false }
            let changedAt = Self.bumpLocked(state: &state)
            state.servers[index].publicChangedAtMs = changedAt
            if publiclyVisible { Self.backfillLocked(state: &state, index) }
            let server = state.servers[index]
            return PublicVisibilityUpdateResponse(
                publiclyVisible: server.publiclyVisible,
                publicGuestJoinEnabled: server.publicGuestJoinEnabled,
                publicSearchEnabled: server.publicSearchEnabled
            )
        }
    }

    public func patchSearch(serverId: String, authorization: String?, body: String) throws -> PublicSearchSettingResponse {
        guard let userId = userId(authorization) else { throw PublicSettingsError.forbiddenSearch }
        return try state.withLock { state in
            guard state.servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { throw PublicSettingsError.forbiddenSearch }
            guard state.rolloutEnabled else { throw PublicSettingsError.notFound }
            guard let enabled = jsonBool(body, key: "publicSearchEnabled") else {
                throw PublicSettingsError.invalidSearch
            }
            guard let index = state.servers.firstIndex(where: { $0.id == serverId }) else {
                throw PublicSettingsError.serverNotFound
            }
            state.servers[index].publicSearchEnabled = enabled
            let changedAt = Self.bumpLocked(state: &state)
            state.servers[index].publicChangedAtMs = changedAt
            return PublicSearchSettingResponse(publicSearchEnabled: enabled)
        }
    }

    /// Owner-only Guest admission. It cannot open before Public, and an admin cannot touch it.
    public func patchGuestJoin(serverId: String, authorization: String?, body: String) throws -> PublicGuestJoinSettingResponse {
        guard let userId = userId(authorization) else { throw PublicSettingsError.forbiddenGuestJoin }
        return try state.withLock { state in
            guard state.servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { throw PublicSettingsError.forbiddenGuestJoin }
            guard state.rolloutEnabled, state.guestRolloutEnabled else { throw PublicSettingsError.notFound }
            guard let enabled = jsonBool(body, key: "publicGuestJoinEnabled") else {
                throw PublicSettingsError.invalidGuestJoin
            }
            guard let index = state.servers.firstIndex(where: { $0.id == serverId }) else {
                throw PublicSettingsError.serverNotFound
            }
            if enabled, !state.servers[index].publiclyVisible {
                throw PublicSettingsError.publicRequired
            }
            state.servers[index].publicGuestJoinEnabled = enabled
            return PublicGuestJoinSettingResponse(publicGuestJoinEnabled: enabled)
        }
    }

    public func addAccount(id: String, email: String, token: String) {
        state.withLock { state in
            state.tokens[token] = id
            state.emails[id] = email.lowercased()
        }
    }

    public func addEmailInvite(serverId: String, email: String, role: String, rawToken: String, expiresAt: Date) {
        state.withLock { state in
            state.invites[Self.sha256Hex(rawToken)] = EmailInvite(
                serverId: serverId,
                email: email.lowercased(),
                role: role,
                expiresAt: expiresAt,
                status: "pending"
            )
        }
    }

    public func memberRole(serverId: String, userId: String) -> String? {
        return state.withLock { state in
            return state.servers.first { $0.id == serverId }?.members[userId]
        }
    }

    /// Email invites keep the role stored on the invite. Public admission is not consulted.
    public func acceptInvite(authorization: String?, body: String, now: Date = Date()) throws -> PublicServerJoinedResponse {
        guard let userId = userId(authorization) else {
            throw PublicSettingsError.authentication(invalidToken: authorization?.hasPrefix("Bearer ") == true)
        }
        guard let token = jsonStringValue(body, key: "token"), !token.isEmpty else {
            throw PublicSettingsError.inviteTokenRequired
        }
        return try state.withLock { state in
            guard let email = state.emails[userId] else { throw PublicSettingsError.authentication(invalidToken: true) }
            let hash = Self.sha256Hex(token)
            guard var invite = state.invites[hash], invite.status == "pending", invite.expiresAt > now else {
                throw PublicSettingsError.invalidInvite
            }
            guard invite.email == email else {
                throw PublicSettingsError.wrongEmail
            }
            guard let index = state.servers.firstIndex(where: { $0.id == invite.serverId }) else {
                throw PublicSettingsError.serverNotFound
            }
            guard state.servers[index].members[userId] == nil else {
                throw PublicSettingsError.alreadyMember
            }
            state.servers[index].members[userId] = invite.role
            invite.status = "accepted"
            state.invites[hash] = invite
            let server = state.servers[index]
            return PublicServerJoinedResponse(serverId: server.id, serverName: server.name)
        }
    }

    public func setTranslationEnabled(serverId: String, enabled: Bool) {
        state.withLock { state in
            if let index = state.servers.firstIndex(where: { $0.id == serverId }) {
                state.servers[index].translationEnabled = enabled
            }
        }
    }

    public func readVisibility(serverId: String, authorization: String?) throws -> PublicVisibilityResponse {
        guard let userId = userId(authorization) else { throw PublicSettingsError.forbiddenVisibility }
        return try state.withLock { state in
            guard state.servers.first(where: { $0.id == serverId })?.members[userId] == "owner" else { throw PublicSettingsError.forbiddenVisibility }
            guard state.rolloutEnabled else { throw PublicSettingsError.notFound }
            guard let server = state.servers.first(where: { $0.id == serverId }) else { throw PublicSettingsError.serverNotFound }
            let exposed = server.channels.filter(\.guestVisible).sorted { $0.name < $1.name }
            return PublicVisibilityResponse(
                settings: PublicVisibilityUpdateResponse(
                    publiclyVisible: server.publiclyVisible,
                    publicGuestJoinEnabled: server.publicGuestJoinEnabled,
                    publicSearchEnabled: server.publicSearchEnabled
                ),
                slug: server.slug,
                exposedChannels: exposed.map { .init(id: $0.id, name: $0.name, description: $0.description) }
            )
        }
    }

    /// Unknown and non-public slugs share one refusal.
    public func publicCard(slug: String) throws -> PublicDirectoryCardResponse {
        return try state.withLock { state in
            guard let server = state.servers.first(where: { $0.slug == slug }), state.rolloutEnabled, server.publiclyVisible else {
                throw PublicSettingsError.notFound
            }
            let channels = server.channels.filter(\.guestVisible).sorted { $0.name < $1.name }
            return PublicDirectoryCardResponse(
                serverId: server.id, serverName: server.name, slug: server.slug,
                translationEnabled: server.translationEnabled, channelIds: channels.map(\.id),
                canJoinAsGuest: server.publicGuestJoinEnabled && state.guestRolloutEnabled,
                translationAvailable: state.translationAvailable
            )
        }
    }

    public func publicIds(serverId: String) -> [String] {
        return state.withLock { state in
            guard let server = state.servers.first(where: { $0.id == serverId }) else { return [] }
            return server.channels.flatMap { channel -> [String] in
                var ids = channel.publicId.map { [$0] } ?? []
                ids.append(contentsOf: channel.threads.compactMap(\.publicId))
                return ids
            }
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
        return state.withLock { state in
            let now = Self.bumpLocked(state: &state)
            switch edit {
            case .renameChannel(let id, let name):
                Self.mutateChannel(state: &state, id) { channel in
                    channel.name = name
                    if channel.guestVisible { channel.publicChangedAtMs = now }
                }
            case .editChannelDescription(let id, let description):
                Self.mutateChannel(state: &state, id) { channel in
                    channel.description = description
                    if channel.guestVisible { channel.publicChangedAtMs = now }
                }
            case .editParent(let channelId, let content):
                Self.mutateChannel(state: &state, channelId) { channel in
                    if !channel.threads.isEmpty { channel.threads[0].parentContent = content; channel.threads[0].parentUpdatedAtMs = now }
                }
            case .editReply(let threadId, let content):
                Self.mutateThread(state: &state, threadId) { thread in
                    if !thread.replies.isEmpty { thread.replies[0].content = content; thread.replies[0].updatedAtMs = now }
                }
            case .addReply(let threadId, let content):
                Self.mutateThread(state: &state, threadId) { thread in
                    thread.replies.append(Reply(content: content, createdAtMs: now, updatedAtMs: now, senderName: thread.senderName))
                }
            case .renameServer(let id, let name):
                if let index = state.servers.firstIndex(where: { $0.id == id }) {
                    state.servers[index].name = name
                    state.servers[index].publicChangedAtMs = now
                }
            case .renamePrivateChannel(let id, let name):
                Self.mutateChannel(state: &state, id) { channel in
                    channel.name = name
                }
            case .setServerPublic(let id, let visible):
                if let index = state.servers.firstIndex(where: { $0.id == id }) {
                    state.servers[index].publiclyVisible = visible
                    state.servers[index].publicChangedAtMs = now
                }
            case .setServerSearch(let id, let enabled):
                if let index = state.servers.firstIndex(where: { $0.id == id }) {
                    state.servers[index].publicSearchEnabled = enabled
                    state.servers[index].publicChangedAtMs = now
                }
            case .setServerDeleted(let id, let deleted):
                if let index = state.servers.firstIndex(where: { $0.id == id }) { state.servers[index].deleted = deleted }
            case .setChannelGuestVisible(let id, let visible):
                Self.mutateChannel(state: &state, id) { channel in
                    channel.guestVisible = visible
                    if visible { channel.publicChangedAtMs = now }
                }
            case .setChannelArchived(let id, let archived):
                Self.mutateChannel(state: &state, id) { channel in
                    channel.archived = archived
                    channel.publicChangedAtMs = now
                }
            case .setChannelDeleted(let id, let deleted):
                Self.mutateChannel(state: &state, id) { channel in
                    channel.deleted = deleted
                    channel.publicChangedAtMs = now
                }
            case .setChannelPrivate(let id, let privateChannel):
                Self.mutateChannel(state: &state, id) { channel in
                    channel.isPrivate = privateChannel
                    channel.publicChangedAtMs = now
                }
            }
        }
    }

    public func projectedCatalog() -> PublicSearchCatalog {
        return state.withLock { state in
            let projected = state.servers.compactMap { server -> PublicSearchServer? in
                guard state.rolloutEnabled, server.publiclyVisible, !server.deleted, let publicId = server.publicId else { return nil }
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
    }

    private func userId(_ authorization: String?) -> String? {
        guard let header = authorization, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return state.withLock { state in
            return state.tokens[token]
        }
    }

    private static func backfillLocked(state: inout State, _ index: Int) {
        if state.servers[index].publicId == nil {
            let publicId = Self.hexId(state: &state)
            state.servers[index].publicId = publicId
        }
        for channelIndex in state.servers[index].channels.indices {
            if state.servers[index].channels[channelIndex].publicId == nil {
                let publicId = Self.hexId(state: &state)
                state.servers[index].channels[channelIndex].publicId = publicId
            }
            for threadIndex in state.servers[index].channels[channelIndex].threads.indices {
                if state.servers[index].channels[channelIndex].threads[threadIndex].publicId == nil {
                    let publicId = Self.hexId(state: &state)
                    state.servers[index].channels[channelIndex].threads[threadIndex].publicId = publicId
                }
            }
        }
    }

    private static func bumpLocked(state: inout State) -> Int {
        state.clock += 1
        return state.clock
    }

    private static func hexId(state: inout State) -> String {
        state.nextPublicId += 1
        return String(format: "%032x", state.nextPublicId)
    }

    private static func mutateChannel(state: inout State, _ id: String, _ body: (inout Channel) -> Void) {
        for serverIndex in state.servers.indices {
            if let channelIndex = state.servers[serverIndex].channels.firstIndex(where: { $0.id == id }) {
                body(&state.servers[serverIndex].channels[channelIndex])
                return
            }
        }
    }

    private static func mutateThread(state: inout State, _ id: String, _ body: (inout Thread) -> Void) {
        for serverIndex in state.servers.indices {
            for channelIndex in state.servers[serverIndex].channels.indices {
                if let threadIndex = state.servers[serverIndex].channels[channelIndex].threads.firstIndex(where: { $0.id == id }) {
                    body(&state.servers[serverIndex].channels[channelIndex].threads[threadIndex])
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

    private func jsonStringValue(_ body: String, key: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct EmailInvite: Sendable {
        var serverId: String
        var email: String
        var role: String
        var expiresAt: Date
        var status: String
    }

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

    struct Reply: Sendable {
        var content: String
        var createdAtMs: Int
        var updatedAtMs: Int
        var senderName: String
    }

    struct Thread: Sendable {
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

    struct Channel: Sendable {
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

    struct Server: Sendable {
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
