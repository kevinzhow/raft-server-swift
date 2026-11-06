import Foundation

// MARK: - Request bodies
//
// The retired handlers read these bodies with raw object casts plus per-field
// `as?` casts. The decoders below keep that tolerance: a member of the wrong
// JSON type reads as the legacy `nil` (so the domain's published 400 is
// unchanged) and a missing member stays distinguishable from a present-but-wrong
// one where the legacy handler chose a different refusal for each.

/// One request member whose legacy reader distinguished absent from a present
/// value of the wrong JSON type.
///
/// `PATCH /api/servers/:id/sidebar-order` keeps the stored value for an absent
/// member but answers `400` for a wrong one, so the difference is observable.
public enum SidebarField<Value: Sendable & Equatable>: Sendable, Equatable {
    case absent
    case value(Value)
    case invalid
}

extension SidebarField: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .absent, .invalid:
            try container.encodeNil()
        case .value(let value):
            try container.encode(value)
        }
    }
}

/// One `customSections` entry.
///
/// The legacy reader refused a non-object entry, an entry without a non-empty
/// string `id`, and an entry without a string `name`. `emoji` publishes `null`
/// for an absent key or JSON `null` and is a `400` for any other type;
/// `sortMode` falls back to `manual` for an absent or non-string value.
public struct SidebarSectionPatchEntry: Sendable, Equatable, Codable {
    public var id: String?
    public var name: String?
    public var emoji: String?
    public var emojiInvalid: Bool
    public var sortMode: String?

    public init(
        id: String? = nil,
        name: String? = nil,
        emoji: String? = nil,
        emojiInvalid: Bool = false,
        sortMode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.emojiInvalid = emojiInvalid
        self.sortMode = sortMode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case emoji
        case sortMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        if !container.contains(.emoji) {
            emoji = nil
            emojiInvalid = false
        } else if (try? container.decodeNil(forKey: .emoji)) == true {
            emoji = nil
            emojiInvalid = false
        } else if let value = try? container.decode(String.self, forKey: .emoji) {
            emoji = value
            emojiInvalid = false
        } else {
            emoji = nil
            emojiInvalid = true
        }
        sortMode = try? container.decode(String.self, forKey: .sortMode)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(emoji, forKey: .emoji)
        try container.encodeIfPresent(sortMode, forKey: .sortMode)
    }
}

/// One `sectionPlacements` entry. Every member must be a string; a wrong type
/// or a non-object entry keeps the legacy `Invalid section placements` 400.
public struct SidebarPlacementPatchEntry: Sendable, Equatable, Codable {
    public var kind: String?
    public var id: String?
    public var sectionId: String?

    public init(kind: String? = nil, id: String? = nil, sectionId: String? = nil) {
        self.kind = kind
        self.id = id
        self.sectionId = sectionId
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case sectionId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? container.decode(String.self, forKey: .kind)
        id = try? container.decode(String.self, forKey: .id)
        sectionId = try? container.decode(String.self, forKey: .sectionId)
    }
}

/// One `pinned` reference entry. `kind` is one of `channel`, `agent`, `human`
/// and `id` must be a non-empty string; both rules are applied by the service so
/// the published 400 is unchanged.
public struct SidebarPinPatchEntry: Sendable, Equatable, Codable {
    public var kind: String?
    public var id: String?

    public init(kind: String? = nil, id: String? = nil) {
        self.kind = kind
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? container.decode(String.self, forKey: .kind)
        id = try? container.decode(String.self, forKey: .id)
    }
}

/// `PATCH /api/servers/:id/sidebar-order` request body.
///
/// The body is entirely optional: an absent body was read as `{}` by the
/// retired handler and still is. Each member is tri-state so an absent member
/// keeps the stored value while a wrong one keeps the member-specific 400.
public struct SidebarOrderPatchRequest: Sendable, Equatable, Codable {
    public var channelSortMode: SidebarField<String>
    public var jointChannelSortMode: SidebarField<String>
    public var dmSortMode: SidebarField<String>
    public var pinnedSortMode: SidebarField<String>
    public var channelPanelTabOrder: SidebarField<[String]>
    public var agentPanelTabOrder: SidebarField<[String]>
    public var customSections: SidebarField<[SidebarSectionPatchEntry]>
    public var sectionOrder: SidebarField<[String]>
    public var sectionPlacements: SidebarField<[SidebarPlacementPatchEntry]>
    public var sectionsVersion: SidebarField<Int>
    public var pinned: SidebarField<[SidebarPinPatchEntry]>
    public var pinnedChannelIds: SidebarField<[String]>
    public var pinnedAgentIds: SidebarField<[String]>
    public var pinnedOrder: SidebarField<[String]>

    public init(
        channelSortMode: SidebarField<String> = .absent,
        jointChannelSortMode: SidebarField<String> = .absent,
        dmSortMode: SidebarField<String> = .absent,
        pinnedSortMode: SidebarField<String> = .absent,
        channelPanelTabOrder: SidebarField<[String]> = .absent,
        agentPanelTabOrder: SidebarField<[String]> = .absent,
        customSections: SidebarField<[SidebarSectionPatchEntry]> = .absent,
        sectionOrder: SidebarField<[String]> = .absent,
        sectionPlacements: SidebarField<[SidebarPlacementPatchEntry]> = .absent,
        sectionsVersion: SidebarField<Int> = .absent,
        pinned: SidebarField<[SidebarPinPatchEntry]> = .absent,
        pinnedChannelIds: SidebarField<[String]> = .absent,
        pinnedAgentIds: SidebarField<[String]> = .absent,
        pinnedOrder: SidebarField<[String]> = .absent
    ) {
        self.channelSortMode = channelSortMode
        self.jointChannelSortMode = jointChannelSortMode
        self.dmSortMode = dmSortMode
        self.pinnedSortMode = pinnedSortMode
        self.channelPanelTabOrder = channelPanelTabOrder
        self.agentPanelTabOrder = agentPanelTabOrder
        self.customSections = customSections
        self.sectionOrder = sectionOrder
        self.sectionPlacements = sectionPlacements
        self.sectionsVersion = sectionsVersion
        self.pinned = pinned
        self.pinnedChannelIds = pinnedChannelIds
        self.pinnedAgentIds = pinnedAgentIds
        self.pinnedOrder = pinnedOrder
    }

    private enum CodingKeys: String, CodingKey {
        case channelSortMode
        case jointChannelSortMode
        case dmSortMode
        case pinnedSortMode
        case channelPanelTabOrder
        case agentPanelTabOrder
        case customSections
        case sectionOrder
        case sectionPlacements
        case sectionsVersion
        case pinned
        case pinnedChannelIds
        case pinnedAgentIds
        case pinnedOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelSortMode = Self.read(.channelSortMode, container)
        jointChannelSortMode = Self.read(.jointChannelSortMode, container)
        dmSortMode = Self.read(.dmSortMode, container)
        pinnedSortMode = Self.read(.pinnedSortMode, container)
        channelPanelTabOrder = Self.read(.channelPanelTabOrder, container)
        agentPanelTabOrder = Self.read(.agentPanelTabOrder, container)
        customSections = Self.read(.customSections, container)
        sectionOrder = Self.read(.sectionOrder, container)
        sectionPlacements = Self.read(.sectionPlacements, container)
        sectionsVersion = Self.read(.sectionsVersion, container)
        pinned = Self.read(.pinned, container)
        pinnedChannelIds = Self.read(.pinnedChannelIds, container)
        pinnedAgentIds = Self.read(.pinnedAgentIds, container)
        pinnedOrder = Self.read(.pinnedOrder, container)
    }

    private static func read<Value: Decodable>(
        _ key: CodingKeys,
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> SidebarField<Value> {
        guard container.contains(key) else { return .absent }
        if (try? container.decodeNil(forKey: key)) == true { return .invalid }
        guard let value = try? container.decode(Value.self, forKey: key) else { return .invalid }
        return .value(value)
    }

    /// The retired `object[key] != nil` test the section-field branch used.
    public var hasSectionFields: Bool {
        customSections != .absent || sectionOrder != .absent || sectionPlacements != .absent
    }
}

/// `PATCH /api/servers/:id/members/:memberId` request body.
///
/// `role` must be one of `owner`, `admin`, `member`, `guest`; every other shape
/// (wrong type, absent key, non-object body) keeps the published
/// `Invalid member role` 400.
public struct ServerMemberRolePatchRequest: Sendable, Equatable, Codable {
    public var role: String?

    public init(role: String? = nil) {
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case role
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try? container.decode(String.self, forKey: .role)
    }
}

/// `PATCH /api/servers/:id/labs/access` and `PUT /api/servers/:id/labs/:labKey`
/// request body. Both members are required by the handler; a body that does not
/// carry them keeps the operation's legacy 400.
public struct ServerLabsToggleRequest: Sendable, Equatable, Codable {
    public var enabled: Bool?
    public var expectedVersion: Int?

    public init(enabled: Bool? = nil, expectedVersion: Int? = nil) {
        self.enabled = enabled
        self.expectedVersion = expectedVersion
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case expectedVersion
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? container.decode(Bool.self, forKey: .enabled)
        expectedVersion = try? container.decode(Int.self, forKey: .expectedVersion)
    }
}

// MARK: - Responses

/// `PATCH /api/servers/:id/members/:memberId` success body.
public struct ServerMemberRolePatchResponse: Sendable, Equatable, Codable, JSONBodyConvertible {
    public init() {}

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("ok", true),
            OrderedJSONField("changed", true),
        ])
    }
}

/// One sidebar pin reference.
public struct SidebarPinDTO: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var kind: String
    public var id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("kind", kind),
            OrderedJSONField("id", id),
        ])
    }
}

/// One custom sidebar section.
public struct SidebarSectionDTO: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var id: String
    public var name: String
    public var emoji: String?
    public var sortMode: String

    public init(id: String, name: String, emoji: String?, sortMode: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.sortMode = sortMode
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("id", id),
            OrderedJSONField("name", name),
            OrderedJSONField("emoji", optional: emoji),
            OrderedJSONField("sortMode", sortMode),
        ])
    }
}

/// One channel/agent placement in a custom sidebar section.
public struct SidebarPlacementDTO: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var kind: String
    public var id: String
    public var sectionId: String
    public var position: Int

    public init(kind: String, id: String, sectionId: String, position: Int) {
        self.kind = kind
        self.id = id
        self.sectionId = sectionId
        self.position = position
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("kind", kind),
            OrderedJSONField("id", id),
            OrderedJSONField("sectionId", sectionId),
            OrderedJSONField("position", position),
        ])
    }
}

/// `GET`/`PATCH /api/servers/:id/sidebar-order` success body.
public struct SidebarOrderResponse: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var channelOrder: [String]
    public var agentOrder: [String]
    public var dmOrder: [String]
    public var pinned: [SidebarPinDTO]
    public var pinnedChannelIds: [String]
    public var pinnedAgentIds: [String]
    public var pinnedOrder: [String]
    public var pinnedVersion: Int
    public var hiddenDmIds: [String]
    public var channelSortMode: String
    public var jointChannelSortMode: String
    public var dmSortMode: String
    public var pinnedSortMode: String
    public var channelPanelTabOrder: [String]
    public var agentPanelTabOrder: [String]
    public var customSections: [SidebarSectionDTO]
    public var sectionOrder: [String]
    public var sectionPlacements: [SidebarPlacementDTO]
    public var sectionsVersion: Int

    public init(
        channelOrder: [String],
        agentOrder: [String],
        dmOrder: [String],
        pinned: [SidebarPinDTO],
        pinnedChannelIds: [String],
        pinnedAgentIds: [String],
        pinnedOrder: [String],
        pinnedVersion: Int,
        hiddenDmIds: [String],
        channelSortMode: String,
        jointChannelSortMode: String,
        dmSortMode: String,
        pinnedSortMode: String,
        channelPanelTabOrder: [String],
        agentPanelTabOrder: [String],
        customSections: [SidebarSectionDTO],
        sectionOrder: [String],
        sectionPlacements: [SidebarPlacementDTO],
        sectionsVersion: Int
    ) {
        self.channelOrder = channelOrder
        self.agentOrder = agentOrder
        self.dmOrder = dmOrder
        self.pinned = pinned
        self.pinnedChannelIds = pinnedChannelIds
        self.pinnedAgentIds = pinnedAgentIds
        self.pinnedOrder = pinnedOrder
        self.pinnedVersion = pinnedVersion
        self.hiddenDmIds = hiddenDmIds
        self.channelSortMode = channelSortMode
        self.jointChannelSortMode = jointChannelSortMode
        self.dmSortMode = dmSortMode
        self.pinnedSortMode = pinnedSortMode
        self.channelPanelTabOrder = channelPanelTabOrder
        self.agentPanelTabOrder = agentPanelTabOrder
        self.customSections = customSections
        self.sectionOrder = sectionOrder
        self.sectionPlacements = sectionPlacements
        self.sectionsVersion = sectionsVersion
    }

    public var jsonBody: OrderedJSON {
        func strings(_ values: [String]) -> OrderedJSON {
            .array(values.map(OrderedJSON.string))
        }
        return .object([
            OrderedJSONField("channelOrder", strings(channelOrder)),
            OrderedJSONField("agentOrder", strings(agentOrder)),
            OrderedJSONField("dmOrder", strings(dmOrder)),
            OrderedJSONField("pinned", .array(pinned.map(\.jsonBody))),
            OrderedJSONField("pinnedChannelIds", strings(pinnedChannelIds)),
            OrderedJSONField("pinnedAgentIds", strings(pinnedAgentIds)),
            OrderedJSONField("pinnedOrder", strings(pinnedOrder)),
            OrderedJSONField("pinnedVersion", pinnedVersion),
            OrderedJSONField("hiddenDmIds", strings(hiddenDmIds)),
            OrderedJSONField("channelSortMode", channelSortMode),
            OrderedJSONField("jointChannelSortMode", jointChannelSortMode),
            OrderedJSONField("dmSortMode", dmSortMode),
            OrderedJSONField("pinnedSortMode", pinnedSortMode),
            OrderedJSONField("channelPanelTabOrder", strings(channelPanelTabOrder)),
            OrderedJSONField("agentPanelTabOrder", strings(agentPanelTabOrder)),
            OrderedJSONField("customSections", .array(customSections.map(\.jsonBody))),
            OrderedJSONField("sectionOrder", strings(sectionOrder)),
            OrderedJSONField("sectionPlacements", .array(sectionPlacements.map(\.jsonBody))),
            OrderedJSONField("sectionsVersion", sectionsVersion),
        ])
    }
}

/// One server lab row. `updatedAt` is the legacy ISO-8601 text (fractional
/// seconds) or JSON `null`; the service formats it, the DTO only publishes it.
public struct ServerLabDTO: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var labKey: String
    public var name: String
    public var description: String
    public var state: String
    public var enrolled: Bool
    public var effective: Bool
    public var updatedAt: String?

    public init(
        labKey: String,
        name: String,
        description: String,
        state: String,
        enrolled: Bool,
        effective: Bool,
        updatedAt: String?
    ) {
        self.labKey = labKey
        self.name = name
        self.description = description
        self.state = state
        self.enrolled = enrolled
        self.effective = effective
        self.updatedAt = updatedAt
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("labKey", labKey),
            OrderedJSONField("name", name),
            OrderedJSONField("description", description),
            OrderedJSONField("state", state),
            OrderedJSONField("enrolled", enrolled),
            OrderedJSONField("effective", effective),
            OrderedJSONField("updatedAt", optional: updatedAt),
        ])
    }
}

/// `GET /api/servers/:id/labs` success body.
public struct ServerLabsResponse: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var accessEnabled: Bool
    public var version: Int
    public var canManageAccess: Bool
    public var canManageEnrollments: Bool
    public var labs: [ServerLabDTO]

    public init(
        accessEnabled: Bool,
        version: Int,
        canManageAccess: Bool,
        canManageEnrollments: Bool,
        labs: [ServerLabDTO]
    ) {
        self.accessEnabled = accessEnabled
        self.version = version
        self.canManageAccess = canManageAccess
        self.canManageEnrollments = canManageEnrollments
        self.labs = labs
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("accessEnabled", accessEnabled),
            OrderedJSONField("version", version),
            OrderedJSONField("canManageAccess", canManageAccess),
            OrderedJSONField("canManageEnrollments", canManageEnrollments),
            OrderedJSONField("labs", .array(labs.map(\.jsonBody))),
        ])
    }
}

/// `PATCH /api/servers/:id/labs/access` success body.
public struct ServerLabsAccessPatchResponse: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var applied: Bool
    public var accessEnabled: Bool
    public var version: Int
    public var labs: [ServerLabDTO]

    public init(applied: Bool, accessEnabled: Bool, version: Int, labs: [ServerLabDTO]) {
        self.applied = applied
        self.accessEnabled = accessEnabled
        self.version = version
        self.labs = labs
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("applied", applied),
            OrderedJSONField("accessEnabled", accessEnabled),
            OrderedJSONField("version", version),
            OrderedJSONField("labs", .array(labs.map(\.jsonBody))),
        ])
    }
}

/// `PUT /api/servers/:id/labs/:labKey` success body.
public struct ServerLabEnrollmentResponse: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var applied: Bool
    public var version: Int
    public var labs: [ServerLabDTO]

    public init(applied: Bool, version: Int, labs: [ServerLabDTO]) {
        self.applied = applied
        self.version = version
        self.labs = labs
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("applied", applied),
            OrderedJSONField("version", version),
            OrderedJSONField("labs", .array(labs.map(\.jsonBody))),
        ])
    }
}

/// `GET /api/tasks/server/snapshot-metrics` success body.
///
/// `medianHours`/`p90Hours` keep the retired `number(_:)` text: an integral
/// value prints without a fractional part, everything else with two decimals.
public struct TaskSnapshotMetricsResponse: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var total: Int
    public var inReview: Int
    public var done: Int
    public var durationSamples: Int
    public var medianHours: String
    public var p90Hours: String
    public var firstCreatedAt: String?
    public var latestUpdatedAt: String?

    public init(
        total: Int,
        inReview: Int,
        done: Int,
        durationSamples: Int,
        medianHours: String,
        p90Hours: String,
        firstCreatedAt: String?,
        latestUpdatedAt: String?
    ) {
        self.total = total
        self.inReview = inReview
        self.done = done
        self.durationSamples = durationSamples
        self.medianHours = medianHours
        self.p90Hours = p90Hours
        self.firstCreatedAt = firstCreatedAt
        self.latestUpdatedAt = latestUpdatedAt
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("total", total),
            OrderedJSONField("inReview", inReview),
            OrderedJSONField("done", done),
            OrderedJSONField("durationSamples", durationSamples),
            OrderedJSONField("medianHours", .raw(medianHours)),
            OrderedJSONField("p90Hours", .raw(p90Hours)),
            OrderedJSONField("firstCreatedAt", optional: firstCreatedAt),
            OrderedJSONField("latestUpdatedAt", optional: latestUpdatedAt),
        ])
    }
}

/// One window of `GET /api/tasks/server/period-metrics`.
public struct TaskPeriodMetricsWindowDTO: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var completed: Int
    public var durationSamples: Int
    public var meanHours: String
    public var medianHours: String

    public init(completed: Int, durationSamples: Int, meanHours: String, medianHours: String) {
        self.completed = completed
        self.durationSamples = durationSamples
        self.meanHours = meanHours
        self.medianHours = medianHours
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("completed", completed),
            OrderedJSONField("durationSamples", durationSamples),
            OrderedJSONField("meanHours", .raw(meanHours)),
            OrderedJSONField("medianHours", .raw(medianHours)),
        ])
    }
}

/// `GET /api/tasks/server/period-metrics` success body: the current window
/// first, then the previous one.
public struct TaskPeriodMetricsResponse: Sendable, Equatable, Codable, JSONBodyConvertible {
    public var current: TaskPeriodMetricsWindowDTO
    public var previous: TaskPeriodMetricsWindowDTO

    public init(current: TaskPeriodMetricsWindowDTO, previous: TaskPeriodMetricsWindowDTO) {
        self.current = current
        self.previous = previous
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("current", current.jsonBody),
            OrderedJSONField("previous", previous.jsonBody),
        ])
    }
}
