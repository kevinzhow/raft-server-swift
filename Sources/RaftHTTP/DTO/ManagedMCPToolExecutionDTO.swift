import Foundation

// MARK: - Request bodies
//
// Each type decodes the way the retired dictionary handlers read their keys: a
// member that is missing, `null` or of another type reads as absent, and only a
// body that is not a JSON object fails to decode. See
// `ManagedMCPAssignmentsDTO.swift` for the shared `lenient` helpers.

/// `POST /api/channels/saved/check`. `messageIds` is `nil` unless it is an
/// array made only of strings.
public struct SavedCheckRequest: Decodable, Sendable, Equatable {
    public var messageIds: [String]?

    public init(messageIds: [String]? = nil) {
        self.messageIds = messageIds
    }

    private enum CodingKeys: String, CodingKey { case messageIds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageIds = container.lenient([String].self, forKey: .messageIds)
    }
}

/// `POST /api/channels/dm`: the peer is an agent (`agentId`) or a human
/// (`userId`).
public struct DirectChannelRequest: Decodable, Sendable, Equatable {
    public var agentId: String?
    public var userId: String?

    public init(agentId: String? = nil, userId: String? = nil) {
        self.agentId = agentId
        self.userId = userId
    }

    private enum CodingKeys: String, CodingKey { case agentId, userId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = container.lenient(String.self, forKey: .agentId)
        userId = container.lenient(String.self, forKey: .userId)
    }
}

/// `PATCH /api/channels/:channelId/message-display-settings`.
public struct ChannelDisplayPatchRequest: Decodable, Sendable, Equatable {
    public var collapseLongMessages: Bool?

    public init(collapseLongMessages: Bool? = nil) {
        self.collapseLongMessages = collapseLongMessages
    }

    private enum CodingKeys: String, CodingKey { case collapseLongMessages }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collapseLongMessages = container.lenient(Bool.self, forKey: .collapseLongMessages)
    }
}

/// `POST /api/channels/:channelId/read`.
public struct ChannelReadRequest: Decodable, Sendable, Equatable {
    public var seq: Int?

    public init(seq: Int? = nil) {
        self.seq = seq
    }

    private enum CodingKeys: String, CodingKey { case seq }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = container.lenient(Int.self, forKey: .seq)
    }
}

/// `POST /api/channels/:channelId/resume-all-agents`.
public struct ResumeAllAgentsRequest: Decodable, Sendable, Equatable {
    /// The `agentIds` member: absent or `null` resumes every agent, an array of
    /// strings selects a subset, anything else is refused.
    public enum AgentIds: Sendable, Equatable {
        case absent
        case ids([String])
        case invalid
    }

    public var prompt: String?
    public var agentIds: AgentIds

    public init(prompt: String? = nil, agentIds: AgentIds = .absent) {
        self.prompt = prompt
        self.agentIds = agentIds
    }

    private enum CodingKeys: String, CodingKey { case prompt, agentIds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = container.lenient(String.self, forKey: .prompt)
        if !container.contains(.agentIds) || ((try? container.decodeNil(forKey: .agentIds)) ?? false) {
            agentIds = .absent
        } else if let ids = container.lenient([String].self, forKey: .agentIds) {
            agentIds = .ids(ids)
        } else {
            agentIds = .invalid
        }
    }
}

/// `POST /api/channels/:channelId/read-all`: an optional agent receiver.
public struct ChannelReadAllRequest: Decodable, Sendable, Equatable {
    public struct Receiver: Decodable, Sendable, Equatable {
        public var kind: String
        public var id: String
    }

    /// Present only when `receiver` is an object with a string `kind` and `id`.
    public var receiver: Receiver?

    public init(receiver: Receiver? = nil) {
        self.receiver = receiver
    }

    private enum CodingKeys: String, CodingKey { case receiver }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receiver = container.lenient(Receiver.self, forKey: .receiver)
    }
}

/// `POST /internal/agent-api/channels/archive|unarchive`.
public struct AgentChannelArchiveRequest: Decodable, Sendable, Equatable {
    public var target: String?

    public init(target: String? = nil) {
        self.target = target
    }

    private enum CodingKeys: String, CodingKey { case target }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = container.lenient(String.self, forKey: .target)
    }
}

// MARK: - Response bodies
//
// Every body that prints members in a non-alphabetical order is a
// `JSONBodyConvertible` tree rendered once by `Respond.swift`.

private func stringArray(_ values: [String]) -> OrderedJSON {
    .array(values.map(OrderedJSON.string))
}

/// `200` body of `POST /api/channels/saved/check`.
public struct SavedCheckResponse: Codable, Sendable, Equatable {
    public var savedIds: [String]

    public init(savedIds: [String]) {
        self.savedIds = savedIds
    }
}

/// One saved-message row.
///
/// Published order: `messageId`, `channelId`, `channelType`, `content`,
/// `parentChannelId`, `parentMessageId`, `parentMessagePreview` (each `null`
/// when absent), `replyCount`.
public struct SavedMessageRowDTO: Sendable, Equatable {
    public var messageId: String
    public var channelId: String
    public var channelType: String
    public var content: String
    public var parentChannelId: String?
    public var parentMessageId: String?
    public var parentMessagePreview: String?
    public var replyCount: Int

    public init(
        messageId: String,
        channelId: String,
        channelType: String,
        content: String,
        parentChannelId: String?,
        parentMessageId: String?,
        parentMessagePreview: String?,
        replyCount: Int
    ) {
        self.messageId = messageId
        self.channelId = channelId
        self.channelType = channelType
        self.content = content
        self.parentChannelId = parentChannelId
        self.parentMessageId = parentMessageId
        self.parentMessagePreview = parentMessagePreview
        self.replyCount = replyCount
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("messageId", messageId),
            OrderedJSONField("channelId", channelId),
            OrderedJSONField("channelType", channelType),
            OrderedJSONField("content", content),
            OrderedJSONField("parentChannelId", optional: parentChannelId),
            OrderedJSONField("parentMessageId", optional: parentMessageId),
            OrderedJSONField("parentMessagePreview", optional: parentMessagePreview),
            OrderedJSONField("replyCount", replyCount),
        ])
    }
}

/// `200` body of `GET /api/channels/saved`: `saved`, `total`, `hasMore`.
public struct SavedMessagesResponse: JSONBodyConvertible, Sendable, Equatable {
    public var saved: [SavedMessageRowDTO]
    public var total: Int
    public var hasMore: Bool

    public init(saved: [SavedMessageRowDTO], total: Int, hasMore: Bool) {
        self.saved = saved
        self.total = total
        self.hasMore = hasMore
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("saved", .array(saved.map(\.json))),
            OrderedJSONField("total", total),
            OrderedJSONField("hasMore", hasMore),
        ])
    }
}

/// `200` body of `POST /api/channels/system/all/hide|restore`: `id`, `visible`.
public struct AllChannelVisibilityResponse: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var visible: Bool

    public init(id: String, visible: Bool) {
        self.id = id
        self.visible = visible
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("visible", visible),
        ])
    }
}

/// The read-state union published on channel rows.
///
/// Upstream carries `InboxScopeReadFrontier`: `{"kind":"absent"}` when no
/// cursor row exists, otherwise `{kind, readStateVersion, maxReadSeq,
/// latestActivity}` with `maxReadSeq` as a canonical decimal string. The port
/// retains cursor presence/value/version; `latestActivity` is always `null`
/// because the cursor's same-source message/seq pair is not retained, and
/// upstream itself publishes `null` for a missing/invalid pair.
public enum ChannelReadStateFrontier: Sendable, Equatable {
    case absent
    case present(readStateVersion: Int, maxReadSeq: Int)

    /// The legacy scalar fields published next to the union. Upstream keeps
    /// `0` / `0` for an absent cursor row.
    var maxReadSeq: Int {
        if case .present(_, let maxReadSeq) = self { return maxReadSeq }
        return 0
    }

    var readStateVersion: Int {
        if case .present(let version, _) = self { return version }
        return 0
    }

    var json: OrderedJSON {
        switch self {
        case .absent:
            return .object([OrderedJSONField("kind", "absent")])
        case .present(let readStateVersion, let maxReadSeq):
            return .object([
                OrderedJSONField("kind", "present"),
                OrderedJSONField("readStateVersion", readStateVersion),
                OrderedJSONField("maxReadSeq", String(maxReadSeq)),
                OrderedJSONField("latestActivity", .null),
            ])
        }
    }
}

/// The unified DM peer block: an agent peer or a human/self peer.
public struct DirectChannelPeerFacts: Sendable, Equatable {
    public var peerId: String
    public var peerName: String
    public var peerDisplayName: String?
    public var peerDescription: String?
    public var peerGravatarHash: String?
    public var peerAvatarUrl: String?
    /// `agent` or `user` (self DMs are `user` peers upstream).
    public var peerType: String

    public init(
        peerId: String,
        peerName: String,
        peerDisplayName: String?,
        peerDescription: String?,
        peerGravatarHash: String?,
        peerAvatarUrl: String?,
        peerType: String
    ) {
        self.peerId = peerId
        self.peerName = peerName
        self.peerDisplayName = peerDisplayName
        self.peerDescription = peerDescription
        self.peerGravatarHash = peerGravatarHash
        self.peerAvatarUrl = peerAvatarUrl
        self.peerType = peerType
    }
}

/// `200` body of `POST /api/channels/dm`: the created or existing DM channel
/// row that upstream `findOrCreateDM`/`findOrCreateUserDM` return.
///
/// The agent-peer select orders the block `peerId, peerName, peerDisplayName,
/// peerDescription, peerGravatarHash, peerAvatarUrl, peerType`; the user-peer
/// select orders it `peerType, peerId, peerName, peerDisplayName,
/// peerDescription, peerAvatarUrl, peerGravatarHash`. The two published orders
/// are reproduced per peer kind.
public struct DirectChannelResponse: JSONBodyConvertible, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public var createdAt: String?
    public var peer: DirectChannelPeerFacts

    public init(
        id: String,
        name: String,
        description: String?,
        createdAt: String?,
        peer: DirectChannelPeerFacts
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.peer = peer
    }

    public var jsonBody: OrderedJSON {
        var fields: [OrderedJSONField] = [
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("type", "dm"),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("createdAt", optional: createdAt),
        ]
        if peer.peerType == "agent" {
            fields.append(OrderedJSONField("peerId", peer.peerId))
            fields.append(OrderedJSONField("peerName", peer.peerName))
            fields.append(OrderedJSONField("peerDisplayName", optional: peer.peerDisplayName))
            fields.append(OrderedJSONField("peerDescription", optional: peer.peerDescription))
            fields.append(OrderedJSONField("peerGravatarHash", optional: peer.peerGravatarHash))
            fields.append(OrderedJSONField("peerAvatarUrl", optional: peer.peerAvatarUrl))
            fields.append(OrderedJSONField("peerType", peer.peerType))
        } else {
            fields.append(OrderedJSONField("peerType", peer.peerType))
            fields.append(OrderedJSONField("peerId", peer.peerId))
            fields.append(OrderedJSONField("peerName", peer.peerName))
            fields.append(OrderedJSONField("peerDisplayName", optional: peer.peerDisplayName))
            fields.append(OrderedJSONField("peerDescription", optional: peer.peerDescription))
            fields.append(OrderedJSONField("peerAvatarUrl", optional: peer.peerAvatarUrl))
            fields.append(OrderedJSONField("peerGravatarHash", optional: peer.peerGravatarHash))
        }
        return .object(fields)
    }
}

/// One row of `GET /api/channels/dm`, mirroring upstream `listDMChannels`.
///
/// Published order: `id`, `name`, `type`, `description`, `createdAt`, peer
/// fields (`peerId`, `peerName`, `peerDisplayName`, `peerDescription`,
/// `peerAvatarUrl`, `peerGravatarHash`, `peerType`), `activityMuted`,
/// `muteFromSeq`, `prefsVersion`, `activityMuteSupported`,
/// `collapseLongMessages`, `displayPrefsVersion`, `maxReadSeq`,
/// `readStateVersion`, `readState`, `lastMessageAt`, `lastMessagePreview`,
/// `lastMessageSenderName`.
public struct DirectChannelListRowDTO: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public var createdAt: String?
    public var peer: DirectChannelPeerFacts
    public var activityMuted: Bool
    public var muteFromSeq: Int?
    public var prefsVersion: Int
    public var collapseLongMessages: Bool
    public var displayPrefsVersion: Int
    public var maxReadSeq: Int
    public var readStateVersion: Int
    public var readState: ChannelReadStateFrontier
    public var lastMessageAt: String?
    public var lastMessagePreview: String?
    public var lastMessageSenderName: String?

    public init(
        id: String,
        name: String,
        description: String?,
        createdAt: String?,
        peer: DirectChannelPeerFacts,
        activityMuted: Bool,
        muteFromSeq: Int?,
        prefsVersion: Int,
        collapseLongMessages: Bool,
        displayPrefsVersion: Int,
        maxReadSeq: Int,
        readStateVersion: Int,
        readState: ChannelReadStateFrontier,
        lastMessageAt: String?,
        lastMessagePreview: String?,
        lastMessageSenderName: String?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.peer = peer
        self.activityMuted = activityMuted
        self.muteFromSeq = muteFromSeq
        self.prefsVersion = prefsVersion
        self.collapseLongMessages = collapseLongMessages
        self.displayPrefsVersion = displayPrefsVersion
        self.maxReadSeq = maxReadSeq
        self.readStateVersion = readStateVersion
        self.readState = readState
        self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageSenderName = lastMessageSenderName
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("type", "dm"),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("createdAt", optional: createdAt),
            OrderedJSONField("peerId", peer.peerId),
            OrderedJSONField("peerName", peer.peerName),
            OrderedJSONField("peerDisplayName", optional: peer.peerDisplayName),
            OrderedJSONField("peerDescription", optional: peer.peerDescription),
            OrderedJSONField("peerAvatarUrl", optional: peer.peerAvatarUrl),
            OrderedJSONField("peerGravatarHash", optional: peer.peerGravatarHash),
            OrderedJSONField("peerType", peer.peerType),
            OrderedJSONField("activityMuted", activityMuted),
            OrderedJSONField("muteFromSeq", optional: muteFromSeq),
            OrderedJSONField("prefsVersion", prefsVersion),
            OrderedJSONField("activityMuteSupported", false),
            OrderedJSONField("collapseLongMessages", collapseLongMessages),
            OrderedJSONField("displayPrefsVersion", displayPrefsVersion),
            OrderedJSONField("maxReadSeq", maxReadSeq),
            OrderedJSONField("readStateVersion", readStateVersion),
            OrderedJSONField("readState", readState.json),
            OrderedJSONField("lastMessageAt", optional: lastMessageAt),
            OrderedJSONField("lastMessagePreview", optional: lastMessagePreview),
            OrderedJSONField("lastMessageSenderName", optional: lastMessageSenderName),
        ])
    }
}

/// `200` body of `GET /api/channels/dm`: a bare array of rows.
public struct DirectChannelListResponse: JSONBodyConvertible, Sendable, Equatable {
    public var rows: [DirectChannelListRowDTO]

    public init(rows: [DirectChannelListRowDTO]) {
        self.rows = rows
    }

    public var jsonBody: OrderedJSON {
        .array(rows.map(\.json))
    }
}

/// `200` body of `GET /api/channels/:channelId`.
///
/// Published channel-row order: `id`, `serverId`, `name`, `description`,
/// `type`, `createdAt`, then the DM peer block, `joined`, the display prefs,
/// the read state, `activityMuteSupported`, the channel authorization block and
/// finally the peer read state. The agent DM peer block is
/// `peerId, peerName, peerDisplayName, peerDescription, peerGravatarHash,
/// peerAvatarUrl, peerType`; the user/self block is `peerType, peerId,
/// peerName, peerDisplayName, peerDescription, peerAvatarUrl,
/// peerGravatarHash` — the two upstream selects' orders.
public struct ChannelDetailResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Capabilities: Sendable, Equatable {
        public var editChannelMetadata: Bool
        public var archiveChannels: Bool
        public var addChannelMembers: Bool
        public var removeChannelMembers: Bool
        public var changeChannelMemberRoles: Bool
        public var manageGuestAccess: Bool
        public var deleteChannels: Bool
        public var changeChannelVisibility: Bool
        public var federateChannels: Bool

        public init(
            editChannelMetadata: Bool,
            archiveChannels: Bool,
            addChannelMembers: Bool,
            removeChannelMembers: Bool,
            changeChannelMemberRoles: Bool,
            manageGuestAccess: Bool,
            deleteChannels: Bool,
            changeChannelVisibility: Bool,
            federateChannels: Bool
        ) {
            self.editChannelMetadata = editChannelMetadata
            self.archiveChannels = archiveChannels
            self.addChannelMembers = addChannelMembers
            self.removeChannelMembers = removeChannelMembers
            self.changeChannelMemberRoles = changeChannelMemberRoles
            self.manageGuestAccess = manageGuestAccess
            self.deleteChannels = deleteChannels
            self.changeChannelVisibility = changeChannelVisibility
            self.federateChannels = federateChannels
        }

        var json: OrderedJSON {
            .object([
                OrderedJSONField("editChannelMetadata", editChannelMetadata),
                OrderedJSONField("archiveChannels", archiveChannels),
                OrderedJSONField("addChannelMembers", addChannelMembers),
                OrderedJSONField("removeChannelMembers", removeChannelMembers),
                OrderedJSONField("changeChannelMemberRoles", changeChannelMemberRoles),
                OrderedJSONField("manageGuestAccess", manageGuestAccess),
                OrderedJSONField("deleteChannels", deleteChannels),
                OrderedJSONField("changeChannelVisibility", changeChannelVisibility),
                OrderedJSONField("federateChannels", federateChannels),
            ])
        }
    }

    /// The peer read state published when read receipts are enabled.
    public enum PeerReadState: Sendable, Equatable {
        /// More than 50 peers: `peerReadSummary{peerCount,readCountAtSeq}`.
        case summary(peerCount: Int, readCountAtSeq: [(seq: Int, count: Int)])
        /// `peerReadStates[{peerKind,peerId,maxReadSeq}]`.
        case states([(peerId: String, maxReadSeq: Int)])

        public static func == (lhs: PeerReadState, rhs: PeerReadState) -> Bool {
            switch (lhs, rhs) {
            case (.summary(let lc, let lb), .summary(let rc, let rb)):
                return lc == rc && lb.count == rb.count
                    && zip(lb, rb).allSatisfy { $0.0.seq == $0.1.seq && $0.0.count == $0.1.count }
            case (.states(let l), .states(let r)):
                return l.count == r.count
                    && zip(l, r).allSatisfy { $0.0.peerId == $0.1.peerId && $0.0.maxReadSeq == $0.1.maxReadSeq }
            default:
                return false
            }
        }
    }

    public var id: String
    public var serverId: String
    public var name: String
    public var description: String?
    public var type: String
    public var createdAt: String?
    public var directPeer: DirectChannelPeerFacts?
    public var joined: Bool
    public var collapseLongMessages: Bool
    public var displayPrefsVersion: Int
    public var maxReadSeq: Int
    public var readStateVersion: Int
    public var readState: ChannelReadStateFrontier
    public var activityMuteSupported: Bool
    public var channelRole: String
    public var channelAdminBasis: String?
    public var capabilities: Capabilities
    public var channelAuthorityRevision: Int
    public var peerReadState: PeerReadState?

    public init(
        id: String,
        serverId: String,
        name: String,
        description: String?,
        type: String,
        createdAt: String?,
        directPeer: DirectChannelPeerFacts?,
        joined: Bool,
        collapseLongMessages: Bool,
        displayPrefsVersion: Int,
        maxReadSeq: Int,
        readStateVersion: Int,
        readState: ChannelReadStateFrontier,
        activityMuteSupported: Bool,
        channelRole: String,
        channelAdminBasis: String?,
        capabilities: Capabilities,
        channelAuthorityRevision: Int,
        peerReadState: PeerReadState?
    ) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.description = description
        self.type = type
        self.createdAt = createdAt
        self.directPeer = directPeer
        self.joined = joined
        self.collapseLongMessages = collapseLongMessages
        self.displayPrefsVersion = displayPrefsVersion
        self.maxReadSeq = maxReadSeq
        self.readStateVersion = readStateVersion
        self.readState = readState
        self.activityMuteSupported = activityMuteSupported
        self.channelRole = channelRole
        self.channelAdminBasis = channelAdminBasis
        self.capabilities = capabilities
        self.channelAuthorityRevision = channelAuthorityRevision
        self.peerReadState = peerReadState
    }

    public var jsonBody: OrderedJSON {
        var fields = [
            OrderedJSONField("id", id),
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("name", name),
            OrderedJSONField("description", optional: description),
            OrderedJSONField("type", type),
            OrderedJSONField("createdAt", optional: createdAt),
        ]
        if let directPeer {
            if directPeer.peerType == "agent" {
                fields.append(OrderedJSONField("peerId", directPeer.peerId))
                fields.append(OrderedJSONField("peerName", directPeer.peerName))
                fields.append(OrderedJSONField("peerDisplayName", optional: directPeer.peerDisplayName))
                fields.append(OrderedJSONField("peerDescription", optional: directPeer.peerDescription))
                fields.append(OrderedJSONField("peerGravatarHash", optional: directPeer.peerGravatarHash))
                fields.append(OrderedJSONField("peerAvatarUrl", optional: directPeer.peerAvatarUrl))
                fields.append(OrderedJSONField("peerType", directPeer.peerType))
            } else {
                fields.append(OrderedJSONField("peerType", directPeer.peerType))
                fields.append(OrderedJSONField("peerId", directPeer.peerId))
                fields.append(OrderedJSONField("peerName", directPeer.peerName))
                fields.append(OrderedJSONField("peerDisplayName", optional: directPeer.peerDisplayName))
                fields.append(OrderedJSONField("peerDescription", optional: directPeer.peerDescription))
                fields.append(OrderedJSONField("peerAvatarUrl", optional: directPeer.peerAvatarUrl))
                fields.append(OrderedJSONField("peerGravatarHash", optional: directPeer.peerGravatarHash))
            }
        }
        fields.append(OrderedJSONField("joined", joined))
        fields.append(OrderedJSONField("collapseLongMessages", collapseLongMessages))
        fields.append(OrderedJSONField("displayPrefsVersion", displayPrefsVersion))
        fields.append(OrderedJSONField("maxReadSeq", maxReadSeq))
        fields.append(OrderedJSONField("readStateVersion", readStateVersion))
        fields.append(OrderedJSONField("readState", readState.json))
        switch peerReadState {
        case .summary(let peerCount, let buckets)?:
            fields.append(OrderedJSONField("peerReadSummary", .object([
                OrderedJSONField("peerCount", peerCount),
                OrderedJSONField("readCountAtSeq", .array(buckets.map {
                    .object([OrderedJSONField("seq", $0.seq), OrderedJSONField("count", $0.count)])
                })),
            ])))
        case .states(let peers)?:
            fields.append(OrderedJSONField("peerReadStates", .array(peers.map {
                .object([
                    OrderedJSONField("peerKind", "agent"),
                    OrderedJSONField("peerId", $0.peerId),
                    OrderedJSONField("maxReadSeq", $0.maxReadSeq),
                ])
            })))
        case nil:
            break
        }
        fields.append(OrderedJSONField("activityMuteSupported", activityMuteSupported))
        fields.append(OrderedJSONField("channelRole", channelRole))
        fields.append(OrderedJSONField("channelAdminBasis", optional: channelAdminBasis))
        fields.append(OrderedJSONField("channelCapabilities", capabilities.json))
        fields.append(OrderedJSONField("channelAuthorityRevision", channelAuthorityRevision))
        return .object(fields)
    }
}

/// `200` body of the message-display-settings read and patch.
public struct ChannelDisplaySettingsResponse: Codable, Sendable, Equatable {
    public var collapseLongMessages: Bool
    public var prefsVersion: Int

    public init(collapseLongMessages: Bool, prefsVersion: Int) {
        self.collapseLongMessages = collapseLongMessages
        self.prefsVersion = prefsVersion
    }
}

/// `200` body of `POST /api/channels/:channelId/read`.
///
/// Published order: `ok`, `maxReadSeq`, `readStateVersion`.
public struct ChannelReadStateResponse: JSONBodyConvertible, Sendable, Equatable {
    public var maxReadSeq: Int
    public var readStateVersion: Int

    public init(maxReadSeq: Int, readStateVersion: Int) {
        self.maxReadSeq = maxReadSeq
        self.readStateVersion = readStateVersion
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("maxReadSeq", maxReadSeq),
            OrderedJSONField("readStateVersion", readStateVersion),
        ])
    }
}

/// `200` body of `POST /api/channels/:channelId/read-all`.
///
/// Published order: `ok`, `seq`, `readStateVersion`.
public struct ChannelReadAllResponse: JSONBodyConvertible, Sendable, Equatable {
    public var seq: Int
    public var readStateVersion: Int

    public init(seq: Int, readStateVersion: Int) {
        self.seq = seq
        self.readStateVersion = readStateVersion
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("seq", seq),
            OrderedJSONField("readStateVersion", readStateVersion),
        ])
    }
}

/// `200` body of `POST /api/channels/:channelId/resume-all-agents`.
///
/// Published order: `ok`, `started`, `total`, `results` (each `{agentId, ok}`
/// plus `reason` on a skipped agent).
public struct ResumeAllAgentsResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Result: Sendable, Equatable {
        public var agentId: String
        /// `nil` when the agent was dispatched.
        public var skipReason: String?

        public init(agentId: String, skipReason: String?) {
            self.agentId = agentId
            self.skipReason = skipReason
        }

        var json: OrderedJSON {
            var fields = [
                OrderedJSONField("agentId", agentId),
                OrderedJSONField("ok", skipReason == nil),
            ]
            if let skipReason { fields.append(OrderedJSONField("reason", skipReason)) }
            return .object(fields)
        }
    }

    public var started: Int
    public var total: Int
    public var results: [Result]

    public init(started: Int, total: Int, results: [Result]) {
        self.started = started
        self.total = total
        self.results = results
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", started == total),
            OrderedJSONField("started", started),
            OrderedJSONField("total", total),
            OrderedJSONField("results", .array(results.map(\.json))),
        ])
    }
}

/// `200` body of `POST /internal/agent-api/channels/archive|unarchive`:
/// `ok`, `archived`.
public struct AgentChannelArchiveResponse: JSONBodyConvertible, Sendable, Equatable {
    public var archived: Bool

    public init(archived: Bool) {
        self.archived = archived
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("archived", archived),
        ])
    }
}

/// `200` body of `POST /internal/agent-api/channels/:channelId/mute|unmute`.
///
/// Published order: `activityMuted`, `muteFromSeq` (`null` when unmuted),
/// `attention`.
public struct AgentChannelMuteResponse: JSONBodyConvertible, Sendable, Equatable {
    public var muted: Bool
    public var muteFromSeq: Int?
    public var channelId: String
    public var channelName: String

    public init(muted: Bool, muteFromSeq: Int?, channelId: String, channelName: String) {
        self.muted = muted
        self.muteFromSeq = muteFromSeq
        self.channelId = channelId
        self.channelName = channelName
    }

    public var jsonBody: OrderedJSON {
        let attention: OrderedJSON
        if muted {
            attention = .object([
                OrderedJSONField("state", "muted"),
                OrderedJSONField("unmuteCommand", "raft channel unmute #\(channelName)"),
                OrderedJSONField("unmuteApi", "POST /internal/agent-api/channels/\(channelId)/unmute"),
                OrderedJSONField("stillArrives", stringArray([
                    "Personal @mentions still arrive.",
                    "Direct messages still arrive.",
                    "Threads you follow deliver independently.",
                ])),
                OrderedJSONField(
                    "threadBoundary",
                    "Channel mute suppresses ordinary Activity from this channel only. Threads you follow keep delivering independently until you unfollow them."
                ),
                OrderedJSONField(
                    "catchUp",
                    "Run `raft channel history #\(channelName)` or GET /internal/agent-api/history to catch up."
                ),
            ])
        } else {
            attention = .object([
                OrderedJSONField("state", "unmuted"),
                OrderedJSONField("muteCommand", "raft channel mute #\(channelName)"),
            ])
        }
        return .object([
            OrderedJSONField("activityMuted", muted),
            OrderedJSONField("muteFromSeq", optional: muteFromSeq),
            OrderedJSONField("attention", attention),
        ])
    }
}
