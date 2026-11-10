import Foundation

extension ServersAndChannelsStore {
    /// Capture under the owner borrow; construct and encode the private DTO outside it.
    /// Call under the coordinator's exclusive gate for a multi-owner consistent cut.
    func exportPersistenceData() throws -> Data {
        let captured = mutex.withLock { $0 }
        return try CollaborationPersistenceCoding.encode(CPServersSnapshot(captured), format: "raft.servers-and-channels")
    }

    /// Fully decode and validate before the short business-field replacement borrow.
    /// Preserves this owner instance and does not publish any callbacks or frames.
    func restorePersistenceData(_ data: Data) throws {
        let decoded = try CollaborationPersistenceCoding.decode(CPServersSnapshot.self, from: data, format: "raft.servers-and-channels")
        let restored = decoded.restored()
        mutex.withLock { current in
            current.postableChannels = restored.postableChannels
            current.threadOrder = restored.threadOrder
            current.serverMemberRoles = restored.serverMemberRoles
            current.hideHumansFromMembers = restored.hideHumansFromMembers
            current.serverMemberStatuses = restored.serverMemberStatuses
            current.membershipAgreementAudits = restored.membershipAgreementAudits
            current.jointProjections = restored.jointProjections
            current.serverMemberEvents = restored.serverMemberEvents
            current.deletedServerIds = restored.deletedServerIds
            current.removedServerMembers = restored.removedServerMembers
            current.serverPlans = restored.serverPlans
            current.serverLabsState = restored.serverLabsState
            current.serverInvites = restored.serverInvites
            current.serverSwitcherOrders = restored.serverSwitcherOrders
            current.serverOnboardingSettings = restored.serverOnboardingSettings
            current.userOnboardingSettings = restored.userOnboardingSettings
            current.setupPhases = restored.setupPhases
            current.setupHandoffs = restored.setupHandoffs
            current.setupCompletionReasons = restored.setupCompletionReasons
            current.setupHandoffReceipts = restored.setupHandoffReceipts
            current.ownerOpenerLedgers = restored.ownerOpenerLedgers
            current.guestRoleServers = restored.guestRoleServers
            current.proSeats = restored.proSeats
            current.joinLinks = restored.joinLinks
            current.usageLimitAttentionServers = restored.usageLimitAttentionServers
            current.guestVisibleChannels = restored.guestVisibleChannels
            current.guestJoinableChannels = restored.guestJoinableChannels
            current.readReceiptsServers = restored.readReceiptsServers
            current.channelHumanRoles = restored.channelHumanRoles
            current.channelAuthorityRevisions = restored.channelAuthorityRevisions
            current.sidebarModes = restored.sidebarModes
            current.sidebarSections = restored.sidebarSections
            current.sidebarPinnedRefs = restored.sidebarPinnedRefs
            current.sidebarReadAllEnabled = restored.sidebarReadAllEnabled
            current.jointInvites = restored.jointInvites
            current.composerResourceServers = restored.composerResourceServers
            current.installedServerApps = restored.installedServerApps
        }
    }
}

private struct CPServersSnapshot: Codable {
    var postableChannels: [String: CPPostableChannel]
    var threadOrder: [String]
    var serverMemberRoles: [String: String]
    var hideHumansFromMembers: [String: Bool]
    var serverMemberStatuses: [String: String]
    var membershipAgreementAudits: [CPMembershipAudit]
    var jointProjections: [CPJointLink]
    var serverMemberEvents: [CPServerMemberEvent]
    var deletedServerIds: Set<String>
    var removedServerMembers: Set<String>
    var serverPlans: [String: String]
    var serverLabsState: [String: CPServerLabs]
    var serverInvites: [CPServerInvite]
    var serverSwitcherOrders: [String: CPSwitcher]
    var serverOnboardingSettings: [String: CPServerOnboarding]
    var userOnboardingSettings: [String: CPUserOnboarding]
    var setupPhases: [String: String]
    var setupHandoffs: Set<String>
    /// The post-setup fact group (completion reason + owner handoff receipts).
    ///
    /// `nil` means the snapshot is the clearly identified OLD v1 shape, written
    /// before this group existed; it decodes as unknown reasons and no receipts.
    /// A present group must be complete and well-typed: absence of one member,
    /// a wrong type or a malformed date rejects the whole snapshot instead of
    /// restoring a partial group.
    var setupCompletion: CPSetupCompletion?
    /// Owner onboarding-briefing ledgers keyed `serverId\nownerId`. An absent
    /// group is the clearly identified older snapshot shape and restores as
    /// "never briefed, never claimed"; a present group is strict.
    var ownerOpenerLedgers: [String: CPOwnerOpenerLedger]?
    var guestRoleServers: Set<String>
    var proSeats: [String: Int]
    var joinLinks: [String: CPJoinLink]
    var usageLimitAttentionServers: Set<String>
    var guestVisibleChannels: [String: Bool]
    var guestJoinableChannels: [String: Bool]
    var readReceiptsServers: Set<String>
    var channelHumanRoles: [String: String]
    var channelAuthorityRevisions: [String: Int]
    var sidebarModes: [String: CPSidebarMode]
    var sidebarSections: [String: CPSidebarSections]
    var sidebarPinnedRefs: [String: CPSidebarPinned]
    var sidebarReadAllEnabled: Bool
    var jointInvites: [CPJointInvite]
    var composerResourceServers: Set<String>
    var installedServerApps: [String: Set<String>]

    init(_ value: ServersAndChannelsStore.State) {
        postableChannels = value.postableChannels.mapValues(CPPostableChannel.init)
        threadOrder = value.threadOrder
        serverMemberRoles = value.serverMemberRoles
        hideHumansFromMembers = value.hideHumansFromMembers
        serverMemberStatuses = value.serverMemberStatuses
        membershipAgreementAudits = value.membershipAgreementAudits.map(CPMembershipAudit.init)
        jointProjections = value.jointProjections.map(CPJointLink.init)
        serverMemberEvents = value.serverMemberEvents.map(CPServerMemberEvent.init)
        deletedServerIds = value.deletedServerIds
        removedServerMembers = value.removedServerMembers
        serverPlans = value.serverPlans
        serverLabsState = value.serverLabsState.mapValues(CPServerLabs.init)
        serverInvites = value.serverInvites.map(CPServerInvite.init)
        serverSwitcherOrders = value.serverSwitcherOrders.mapValues(CPSwitcher.init)
        serverOnboardingSettings = value.serverOnboardingSettings.mapValues(CPServerOnboarding.init)
        userOnboardingSettings = value.userOnboardingSettings.mapValues(CPUserOnboarding.init)
        setupPhases = value.setupPhases
        setupHandoffs = value.setupHandoffs
        setupCompletion = CPSetupCompletion(
            completionReasons: value.setupCompletionReasons,
            handoffReceipts: value.setupHandoffReceipts.mapValues(CPHandoffReceipt.init)
        )
        ownerOpenerLedgers = value.ownerOpenerLedgers.mapValues(CPOwnerOpenerLedger.init)
        guestRoleServers = value.guestRoleServers
        proSeats = value.proSeats
        joinLinks = value.joinLinks.mapValues(CPJoinLink.init)
        usageLimitAttentionServers = value.usageLimitAttentionServers
        guestVisibleChannels = value.guestVisibleChannels
        guestJoinableChannels = value.guestJoinableChannels
        readReceiptsServers = value.readReceiptsServers
        channelHumanRoles = value.channelHumanRoles
        channelAuthorityRevisions = value.channelAuthorityRevisions
        sidebarModes = value.sidebarModes.mapValues(CPSidebarMode.init)
        sidebarSections = value.sidebarSections.mapValues(CPSidebarSections.init)
        sidebarPinnedRefs = value.sidebarPinnedRefs.mapValues(CPSidebarPinned.init)
        sidebarReadAllEnabled = value.sidebarReadAllEnabled
        jointInvites = value.jointInvites.map(CPJointInvite.init)
        composerResourceServers = value.composerResourceServers
        installedServerApps = value.installedServerApps
    }

    /// Strict decode of every existing key plus the NEW post-setup group.
    ///
    /// A snapshot written before the group existed omits the whole key and
    /// decodes as unknown reasons / no receipts (the clearly identified old v1
    /// shape). Everything else stays required, and the group is decoded as one
    /// unit: a present group missing either member, holding the wrong type or a
    /// malformed date fails the whole snapshot before anything is restored.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        postableChannels = try container.decode([String: CPPostableChannel].self, forKey: .postableChannels)
        threadOrder = try container.decode([String].self, forKey: .threadOrder)
        serverMemberRoles = try container.decode([String: String].self, forKey: .serverMemberRoles)
        hideHumansFromMembers = try container.decode([String: Bool].self, forKey: .hideHumansFromMembers)
        serverMemberStatuses = try container.decode([String: String].self, forKey: .serverMemberStatuses)
        membershipAgreementAudits = try container.decode([CPMembershipAudit].self, forKey: .membershipAgreementAudits)
        jointProjections = try container.decode([CPJointLink].self, forKey: .jointProjections)
        serverMemberEvents = try container.decode([CPServerMemberEvent].self, forKey: .serverMemberEvents)
        deletedServerIds = try container.decode(Set<String>.self, forKey: .deletedServerIds)
        removedServerMembers = try container.decode(Set<String>.self, forKey: .removedServerMembers)
        serverPlans = try container.decode([String: String].self, forKey: .serverPlans)
        serverLabsState = try container.decode([String: CPServerLabs].self, forKey: .serverLabsState)
        serverInvites = try container.decode([CPServerInvite].self, forKey: .serverInvites)
        serverSwitcherOrders = try container.decode([String: CPSwitcher].self, forKey: .serverSwitcherOrders)
        serverOnboardingSettings = try container.decode([String: CPServerOnboarding].self, forKey: .serverOnboardingSettings)
        userOnboardingSettings = try container.decode([String: CPUserOnboarding].self, forKey: .userOnboardingSettings)
        setupPhases = try container.decode([String: String].self, forKey: .setupPhases)
        setupHandoffs = try container.decode(Set<String>.self, forKey: .setupHandoffs)
        if container.contains(.setupCompletion) {
            setupCompletion = try container.decode(CPSetupCompletion.self, forKey: .setupCompletion)
        } else {
            setupCompletion = nil
        }
        if container.contains(.ownerOpenerLedgers) {
            ownerOpenerLedgers = try container.decode([String: CPOwnerOpenerLedger].self, forKey: .ownerOpenerLedgers)
        } else {
            ownerOpenerLedgers = nil
        }
        guestRoleServers = try container.decode(Set<String>.self, forKey: .guestRoleServers)
        proSeats = try container.decode([String: Int].self, forKey: .proSeats)
        joinLinks = try container.decode([String: CPJoinLink].self, forKey: .joinLinks)
        usageLimitAttentionServers = try container.decode(Set<String>.self, forKey: .usageLimitAttentionServers)
        guestVisibleChannels = try container.decode([String: Bool].self, forKey: .guestVisibleChannels)
        guestJoinableChannels = try container.decode([String: Bool].self, forKey: .guestJoinableChannels)
        readReceiptsServers = try container.decode(Set<String>.self, forKey: .readReceiptsServers)
        channelHumanRoles = try container.decode([String: String].self, forKey: .channelHumanRoles)
        channelAuthorityRevisions = try container.decode([String: Int].self, forKey: .channelAuthorityRevisions)
        sidebarModes = try container.decode([String: CPSidebarMode].self, forKey: .sidebarModes)
        sidebarSections = try container.decode([String: CPSidebarSections].self, forKey: .sidebarSections)
        sidebarPinnedRefs = try container.decode([String: CPSidebarPinned].self, forKey: .sidebarPinnedRefs)
        sidebarReadAllEnabled = try container.decode(Bool.self, forKey: .sidebarReadAllEnabled)
        jointInvites = try container.decode([CPJointInvite].self, forKey: .jointInvites)
        composerResourceServers = try container.decode(Set<String>.self, forKey: .composerResourceServers)
        installedServerApps = try container.decode([String: Set<String>].self, forKey: .installedServerApps)
    }

    func restored() -> ServersAndChannelsStore.State {
        var value = ServersAndChannelsStore.State()
        value.postableChannels = postableChannels.mapValues { $0.restored() }
        value.threadOrder = threadOrder
        value.serverMemberRoles = serverMemberRoles
        value.hideHumansFromMembers = hideHumansFromMembers
        value.serverMemberStatuses = serverMemberStatuses
        value.membershipAgreementAudits = membershipAgreementAudits.map { $0.restored() }
        value.jointProjections = jointProjections.map { $0.restored() }
        value.serverMemberEvents = serverMemberEvents.map { $0.restored() }
        value.deletedServerIds = deletedServerIds
        value.removedServerMembers = removedServerMembers
        value.serverPlans = serverPlans
        value.serverLabsState = serverLabsState.mapValues { $0.restored() }
        value.serverInvites = serverInvites.map { $0.restored() }
        value.serverSwitcherOrders = serverSwitcherOrders.mapValues { $0.restored() }
        value.serverOnboardingSettings = serverOnboardingSettings.mapValues { $0.restored() }
        value.userOnboardingSettings = userOnboardingSettings.mapValues { $0.restored() }
        value.setupPhases = setupPhases
        value.setupHandoffs = setupHandoffs
        let completion = setupCompletion ?? .empty
        value.setupCompletionReasons = completion.completionReasons
        value.setupHandoffReceipts = completion.handoffReceipts.mapValues { $0.restored() }
        value.ownerOpenerLedgers = (ownerOpenerLedgers ?? [:]).mapValues { $0.restored() }
        value.guestRoleServers = guestRoleServers
        value.proSeats = proSeats
        value.joinLinks = joinLinks.mapValues { $0.restored() }
        value.usageLimitAttentionServers = usageLimitAttentionServers
        value.guestVisibleChannels = guestVisibleChannels
        value.guestJoinableChannels = guestJoinableChannels
        value.readReceiptsServers = readReceiptsServers
        value.channelHumanRoles = channelHumanRoles
        value.channelAuthorityRevisions = channelAuthorityRevisions
        value.sidebarModes = sidebarModes.mapValues { $0.restored() }
        value.sidebarSections = sidebarSections.mapValues { $0.restored() }
        value.sidebarPinnedRefs = sidebarPinnedRefs.mapValues { $0.restored() }
        value.sidebarReadAllEnabled = sidebarReadAllEnabled
        value.jointInvites = jointInvites.map { $0.restored() }
        value.composerResourceServers = composerResourceServers
        value.installedServerApps = installedServerApps
        return value
    }
}

private struct CPPostableChannel: Codable {
    var serverId: String
    var memberIds: Set<String>
    var kind: String
    var agentId: String?
    var parentChannelId: String?
    var parentMessageId: String?
    var archived: Bool
    var deletedAt: Date?
    var name: String

    init(_ value: PostableChannel) {
        serverId = value.serverId
        memberIds = value.memberIds
        kind = value.kind
        agentId = value.agentId
        parentChannelId = value.parentChannelId
        parentMessageId = value.parentMessageId
        archived = value.archived
        deletedAt = value.deletedAt
        name = value.name
    }

    func restored() -> PostableChannel {
        PostableChannel(serverId: serverId, memberIds: memberIds, kind: kind, agentId: agentId, parentChannelId: parentChannelId, parentMessageId: parentMessageId, archived: archived, deletedAt: deletedAt, name: name)
    }
}

private struct CPMembershipAudit: Codable {
    var serverId: String
    var subjectId: String
    var actorUserId: String
    var source: String
    var agreementId: String?
    var agreementVersion: Int?

    init(_ value: (serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)) {
        serverId = value.serverId
        subjectId = value.subjectId
        actorUserId = value.actorUserId
        source = value.source
        agreementId = value.agreementId
        agreementVersion = value.agreementVersion
    }

    func restored() -> (serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?) {
        (serverId: serverId, subjectId: subjectId, actorUserId: actorUserId, source: source, agreementId: agreementId, agreementVersion: agreementVersion)
    }
}

private struct CPJointLink: Codable {
    var localChannelId: String
    var canonicalChannelId: String
    var serverId: String
    var status: String

    init(_ value: JointChannelLink) {
        localChannelId = value.localChannelId
        canonicalChannelId = value.canonicalChannelId
        serverId = value.serverId
        status = value.status
    }

    func restored() -> JointChannelLink {
        JointChannelLink(localChannelId: localChannelId, canonicalChannelId: canonicalChannelId, serverId: serverId, status: status)
    }
}

private struct CPServerMemberEvent: Codable {
    var serverId: String
    var eventType: String
    var subjectType: String
    var subjectId: String
    var provenanceJSON: String
    var deliveryQueued: Bool

    init(_ value: ServerMemberEvent) {
        serverId = value.serverId
        eventType = value.eventType
        subjectType = value.subjectType
        subjectId = value.subjectId
        provenanceJSON = value.provenanceJSON
        deliveryQueued = value.deliveryQueued
    }

    func restored() -> ServerMemberEvent {
        ServerMemberEvent(serverId: serverId, eventType: eventType, subjectType: subjectType, subjectId: subjectId, provenanceJSON: provenanceJSON, deliveryQueued: deliveryQueued)
    }
}

private struct CPServerLabs: Codable {
    var accessEnabled: Bool
    var version: Int
    var enrolled: Set<String>
    var updatedAt: [String: Date]
    init(_ value: ServerLabsState) {
        accessEnabled = value.accessEnabled; version = value.version
        enrolled = value.enrolled; updatedAt = value.updatedAt
    }
    func restored() -> ServerLabsState {
        var value = ServerLabsState()
        value.accessEnabled = accessEnabled; value.version = version
        value.enrolled = enrolled; value.updatedAt = updatedAt
        return value
    }
}

private struct CPServerInvite: Codable {
    var id: String
    var serverId: String
    var email: String
    var role: String
    var tokenHash: String?

    init(_ value: (id: String, serverId: String, email: String, role: String, tokenHash: String?)) {
        id = value.id
        serverId = value.serverId
        email = value.email
        role = value.role
        tokenHash = value.tokenHash
    }

    func restored() -> (id: String, serverId: String, email: String, role: String, tokenHash: String?) {
        (id: id, serverId: serverId, email: email, role: role, tokenHash: tokenHash)
    }
}

private struct CPSwitcher: Codable {
    var ids: [String]
    var version: Int

    init(_ value: (ids: [String], version: Int)) {
        ids = value.ids
        version = value.version
    }

    func restored() -> (ids: [String], version: Int) {
        (ids: ids, version: version)
    }
}

private struct CPServerOnboarding: Codable {
    var agentId: String?
    var greeting: Bool

    init(_ value: (agentId: String?, greeting: Bool)) {
        agentId = value.agentId
        greeting = value.greeting
    }

    func restored() -> (agentId: String?, greeting: Bool) {
        (agentId: agentId, greeting: greeting)
    }
}

private struct CPUserOnboarding: Codable {
    var reminderOptOut: Bool
    var dismissed: [String: Date]
    var currentStep: String?
    init(_ value: UserOnboarding) {
        reminderOptOut = value.reminderOptOut; dismissed = value.dismissed; currentStep = value.currentStep
    }
    func restored() -> UserOnboarding {
        var value = UserOnboarding()
        value.reminderOptOut = reminderOptOut; value.dismissed = dismissed; value.currentStep = currentStep
        return value
    }
}

/// The one post-setup fact group. Both members are required once the group is
/// present, so a half-written group cannot restore a partial truth.
private struct CPSetupCompletion: Codable {
    var completionReasons: [String: String]
    var handoffReceipts: [String: CPHandoffReceipt]

    static let empty = CPSetupCompletion(completionReasons: [:], handoffReceipts: [:])

    init(completionReasons: [String: String], handoffReceipts: [String: CPHandoffReceipt]) {
        self.completionReasons = completionReasons
        self.handoffReceipts = handoffReceipts
    }

    /// Rejects a receipt whose retained key and stored identity disagree: the
    /// key is what the projection reads, and one snapshot must not carry two
    /// answers to the same `(serverId, originalOwnerId)`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completionReasons = try container.decode([String: String].self, forKey: .completionReasons)
        handoffReceipts = try container.decode([String: CPHandoffReceipt].self, forKey: .handoffReceipts)
        for (key, receipt) in handoffReceipts where key != receipt.retainedKey {
            throw DecodingError.dataCorruptedError(
                forKey: .handoffReceipts,
                in: container,
                debugDescription: "Handoff receipt key does not match its retained identity"
            )
        }
    }
}

private struct CPHandoffReceipt: Codable {
    var serverId: String
    var originalOwnerId: String
    var acknowledgedAt: Date

    var retainedKey: String { "\(serverId)\n\(originalOwnerId)" }

    init(_ value: SetupHandoffReceipt) {
        serverId = value.serverId
        originalOwnerId = value.originalOwnerId
        acknowledgedAt = value.acknowledgedAt
    }

    func restored() -> SetupHandoffReceipt {
        SetupHandoffReceipt(
            serverId: serverId,
            originalOwnerId: originalOwnerId,
            acknowledgedAt: acknowledgedAt
        )
    }
}

private struct CPJoinLink: Codable {
    var id: String
    var token: String
    var serverId: String
    var role: String
    var createdAt: Date
    var expiresAt: Date?
    var maxUses: Int?
    var useCount: Int
    var revokedAt: Date?

    init(_ value: JoinLinkRecord) {
        id = value.id
        token = value.token
        serverId = value.serverId
        role = value.role
        createdAt = value.createdAt
        expiresAt = value.expiresAt
        maxUses = value.maxUses
        useCount = value.useCount
        revokedAt = value.revokedAt
    }

    func restored() -> JoinLinkRecord {
        JoinLinkRecord(id: id, token: token, serverId: serverId, role: role, createdAt: createdAt, expiresAt: expiresAt, maxUses: maxUses, useCount: useCount, revokedAt: revokedAt)
    }
}

private struct CPSidebarMode: Codable {
    var channel: String
    var joint: String
    var dm: String
    var pinned: String
    var channelTabs: [String]
    var agentTabs: [String]

    init(_ value: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])) {
        channel = value.channel
        joint = value.joint
        dm = value.dm
        pinned = value.pinned
        channelTabs = value.channelTabs
        agentTabs = value.agentTabs
    }

    func restored() -> (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String]) {
        (channel: channel, joint: joint, dm: dm, pinned: pinned, channelTabs: channelTabs, agentTabs: agentTabs)
    }
}

private struct CPSidebarSections: Codable {
    var sections: [CPSidebarSection]
    var order: [String]
    var placements: [CPSidebarPlacement]
    var version: Int
    init(_ value: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)) {
        sections = value.sections.map(CPSidebarSection.init); order = value.order
        placements = value.placements.map(CPSidebarPlacement.init); version = value.version
    }
    func restored() -> (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int) {
        (sections: sections.map { $0.restored() }, order: order, placements: placements.map { $0.restored() }, version: version)
    }
}

private struct CPSidebarSection: Codable {
    var id: String
    var name: String
    var emoji: String?
    var sortMode: String

    init(_ value: (id: String, name: String, emoji: String?, sortMode: String)) {
        id = value.id
        name = value.name
        emoji = value.emoji
        sortMode = value.sortMode
    }

    func restored() -> (id: String, name: String, emoji: String?, sortMode: String) {
        (id: id, name: name, emoji: emoji, sortMode: sortMode)
    }
}

private struct CPSidebarPlacement: Codable {
    var kind: String
    var id: String
    var sectionId: String
    var position: Int

    init(_ value: (kind: String, id: String, sectionId: String, position: Int)) {
        kind = value.kind
        id = value.id
        sectionId = value.sectionId
        position = value.position
    }

    func restored() -> (kind: String, id: String, sectionId: String, position: Int) {
        (kind: kind, id: id, sectionId: sectionId, position: position)
    }
}

private struct CPSidebarPinned: Codable {
    var refs: [CPSidebarRef]
    var channelIds: [String]
    var agentIds: [String]
    var version: Int
    init(_ value: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)) {
        refs = value.refs.map(CPSidebarRef.init); channelIds = value.channelIds
        agentIds = value.agentIds; version = value.version
    }
    func restored() -> (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int) {
        (refs: refs.map { $0.restored() }, channelIds: channelIds, agentIds: agentIds, version: version)
    }
}

private struct CPSidebarRef: Codable {
    var kind: String
    var id: String

    init(_ value: (kind: String, id: String)) {
        kind = value.kind
        id = value.id
    }

    func restored() -> (kind: String, id: String) {
        (kind: kind, id: id)
    }
}

private struct CPJointInvite: Codable {
    var id: String
    var hostServerId: String
    var hostChannelId: String
    var targetServerId: String
    var targetChannelId: String
    var targetOwnerId: String
    var status: String

    init(_ value: (id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String)) {
        id = value.id
        hostServerId = value.hostServerId
        hostChannelId = value.hostChannelId
        targetServerId = value.targetServerId
        targetChannelId = value.targetChannelId
        targetOwnerId = value.targetOwnerId
        status = value.status
    }

    func restored() -> (id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String) {
        (id: id, hostServerId: hostServerId, hostChannelId: hostChannelId, targetServerId: targetServerId, targetChannelId: targetChannelId, targetOwnerId: targetOwnerId, status: status)
    }
}


/// Owner onboarding-briefing ledger snapshot row. Every field is optional
/// because the opener is unsent before its first successful delivery; a present
/// group keeps exact reference-date bits for both stamps.
private struct CPOwnerOpenerLedger: Codable {
    var dmSentAt: Date?
    var dmSentByAgentId: String?
    var openerV2SentAt: Date?
    var openerV2SentByAgentId: String?
    var openerV2MessageIds: [String]
    var openerV2Version: String?
    var openerV2Topics: [String]
    var openerClaimedAt: Date?

    init(_ value: OwnerOpenerLedger) {
        dmSentAt = value.dmSentAt
        dmSentByAgentId = value.dmSentByAgentId
        openerV2SentAt = value.openerV2SentAt
        openerV2SentByAgentId = value.openerV2SentByAgentId
        openerV2MessageIds = value.openerV2MessageIds
        openerV2Version = value.openerV2Version
        openerV2Topics = value.openerV2Topics
        openerClaimedAt = value.openerClaimedAt
    }

    func restored() -> OwnerOpenerLedger {
        var value = OwnerOpenerLedger()
        value.dmSentAt = dmSentAt
        value.dmSentByAgentId = dmSentByAgentId
        value.openerV2SentAt = openerV2SentAt
        value.openerV2SentByAgentId = openerV2SentByAgentId
        value.openerV2MessageIds = openerV2MessageIds
        value.openerV2Version = openerV2Version
        value.openerV2Topics = openerV2Topics
        value.openerClaimedAt = openerClaimedAt
        return value
    }
}
