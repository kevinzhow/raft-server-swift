import Foundation

// Explicit witnesses are required because these records are declared in other files.
extension OAuthLedger.SavedMessageRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case userId
        case messageId
        case savedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.userId = try values.decode(String.self, forKey: .userId)
        self.messageId = try values.decode(String.self, forKey: .messageId)
        self.savedAt = try values.decode(Int.self, forKey: .savedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(userId, forKey: .userId)
        try values.encode(messageId, forKey: .messageId)
        try values.encode(savedAt, forKey: .savedAt)
    }
}

extension OAuthLedger.ChannelRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case name
        case type
        case description
        case parentChannelId
        case parentMessageId
        case archived
        case archivedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.name = try values.decode(String.self, forKey: .name)
        self.type = try values.decode(String.self, forKey: .type)
        self.description = try values.decode(String?.self, forKey: .description)
        self.parentChannelId = try values.decode(String?.self, forKey: .parentChannelId)
        self.parentMessageId = try values.decode(String?.self, forKey: .parentMessageId)
        self.archived = try values.decode(Bool.self, forKey: .archived)
        self.archivedAt = try values.decode(Date?.self, forKey: .archivedAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(name, forKey: .name)
        try values.encode(type, forKey: .type)
        try values.encode(description, forKey: .description)
        try values.encode(parentChannelId, forKey: .parentChannelId)
        try values.encode(parentMessageId, forKey: .parentMessageId)
        try values.encode(archived, forKey: .archived)
        try values.encode(archivedAt, forKey: .archivedAt)
    }
}

extension OAuthLedger.ChannelMessageRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case channelId
        case content
        case createdAt
        case senderId
        case seq
        case senderTimezone
        case senderType
        case messageType
        case systemSubtype
        case causalActorType
        case causalActorId
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.channelId = try values.decode(String.self, forKey: .channelId)
        self.content = try values.decode(String.self, forKey: .content)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.senderId = try values.decode(String.self, forKey: .senderId)
        self.seq = try values.decode(Int.self, forKey: .seq)
        self.senderTimezone = try values.decode(String?.self, forKey: .senderTimezone)
        self.senderType = try values.decode(String?.self, forKey: .senderType)
        self.messageType = try values.decode(String?.self, forKey: .messageType)
        self.systemSubtype = try values.decode(String?.self, forKey: .systemSubtype)
        self.causalActorType = try values.decode(String?.self, forKey: .causalActorType)
        self.causalActorId = try values.decode(String?.self, forKey: .causalActorId)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(channelId, forKey: .channelId)
        try values.encode(content, forKey: .content)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(senderId, forKey: .senderId)
        try values.encode(seq, forKey: .seq)
        try values.encode(senderTimezone, forKey: .senderTimezone)
        try values.encode(senderType, forKey: .senderType)
        try values.encode(messageType, forKey: .messageType)
        try values.encode(systemSubtype, forKey: .systemSubtype)
        try values.encode(causalActorType, forKey: .causalActorType)
        try values.encode(causalActorId, forKey: .causalActorId)
    }
}

extension OAuthLedger.ChannelSystemMessageRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case channelId
        case content
        case seq
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.channelId = try values.decode(String.self, forKey: .channelId)
        self.content = try values.decode(String.self, forKey: .content)
        self.seq = try values.decode(Int.self, forKey: .seq)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(channelId, forKey: .channelId)
        try values.encode(content, forKey: .content)
        try values.encode(seq, forKey: .seq)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

extension OAuthLedger.ChannelNotificationPrefs: Codable {
    private enum CodingKeys: String, CodingKey {
        case activityMuted
        case muteFromSeq
        case prefsVersion
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.activityMuted = try values.decode(Bool.self, forKey: .activityMuted)
        self.muteFromSeq = try values.decode(Int?.self, forKey: .muteFromSeq)
        self.prefsVersion = try values.decode(Int.self, forKey: .prefsVersion)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(activityMuted, forKey: .activityMuted)
        try values.encode(muteFromSeq, forKey: .muteFromSeq)
        try values.encode(prefsVersion, forKey: .prefsVersion)
    }
}

extension OAuthLedger.ChannelDisplayPrefs: Codable {
    private enum CodingKeys: String, CodingKey {
        case collapseLongMessages
        case prefsVersion
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.collapseLongMessages = try values.decode(Bool.self, forKey: .collapseLongMessages)
        self.prefsVersion = try values.decode(Int.self, forKey: .prefsVersion)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(collapseLongMessages, forKey: .collapseLongMessages)
        try values.encode(prefsVersion, forKey: .prefsVersion)
    }
}

extension OAuthLedger.SidebarOrder: Codable {
    private enum CodingKeys: String, CodingKey {
        case channelOrder
        case agentOrder
        case dmOrder
        case pinnedOrder
        case hiddenDmIds
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.channelOrder = try values.decode([String].self, forKey: .channelOrder)
        self.agentOrder = try values.decode([String].self, forKey: .agentOrder)
        self.dmOrder = try values.decode([String].self, forKey: .dmOrder)
        self.pinnedOrder = try values.decode([String].self, forKey: .pinnedOrder)
        self.hiddenDmIds = try values.decode([String].self, forKey: .hiddenDmIds)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(channelOrder, forKey: .channelOrder)
        try values.encode(agentOrder, forKey: .agentOrder)
        try values.encode(dmOrder, forKey: .dmOrder)
        try values.encode(pinnedOrder, forKey: .pinnedOrder)
        try values.encode(hiddenDmIds, forKey: .hiddenDmIds)
    }
}

extension OAuthLedger.ServerAgreementInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case serverId
        case version
        case title
        case bodyMarkdown
        case enabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.serverId = try values.decode(String.self, forKey: .serverId)
        self.version = try values.decode(Int.self, forKey: .version)
        self.title = try values.decode(String.self, forKey: .title)
        self.bodyMarkdown = try values.decode(String.self, forKey: .bodyMarkdown)
        self.enabled = try values.decode(Bool.self, forKey: .enabled)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(serverId, forKey: .serverId)
        try values.encode(version, forKey: .version)
        try values.encode(title, forKey: .title)
        try values.encode(bodyMarkdown, forKey: .bodyMarkdown)
        try values.encode(enabled, forKey: .enabled)
    }
}
