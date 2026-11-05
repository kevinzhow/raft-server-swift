import Foundation

/// Owns the server-membership, sidebar and channel-authority rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows behind a private lock and hands back strong Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class ServersAndChannelsStore: @unchecked Sendable {
    /// Every row this store owns. Grouping them lets one locked value be the
    /// whole store snapshot; each accessor below copies it, which is cheap
    /// because the collections are copy-on-write.
    struct State {
        var postableChannels: [String: PostableChannel] = [:]
        var threadOrder: [String] = []
        var serverMemberRoles: [String: String] = [:]
        var hideHumansFromMembers: [String: Bool] = [:]
        var serverMemberStatuses: [String: String] = [:]
        var membershipAgreementAudits: [(serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)] = []
        var jointProjections: [JointChannelLink] = []
        var serverMemberEvents: [ServerMemberEvent] = []
        var deletedServerIds: Set<String> = []
        var removedServerMembers: Set<String> = []
        var serverPlans: [String: String] = [:]
        var serverLabsState: [String: ServerLabsState] = [:]
        var serverInvites: [(id: String, serverId: String, email: String, role: String, tokenHash: String?)] = []
        var serverSwitcherOrders: [String: (ids: [String], version: Int)] = [:]
        var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] = [:]
        var setupPhases: [String: String] = [:]
        var setupHandoffs: Set<String> = []
        var guestRoleServers: Set<String> = []
        var proSeats: [String: Int] = [:]
        var joinLinks: [String: JoinLinkRecord] = [:]
        var usageLimitAttentionServers: Set<String> = []
        var guestVisibleChannels: [String: Bool] = [:]
        var guestJoinableChannels: [String: Bool] = [:]
        var readReceiptsServers: Set<String> = []
        var channelHumanRoles: [String: String] = [:]
        var channelAuthorityRevisions: [String: Int] = [:]
        var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] = [:]
        var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] = [:]
        var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] = [:]
        var sidebarReadAllEnabled: Bool = false
        var jointInvites: [(id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String)] = []
        var composerResourceServers: Set<String> = []
        var installedServerApps: [String: Set<String>] = [:]
    }

    private let lock = NSLock()
    private var storage = State()

    /// The whole owned state. A read or a write is one locked critical section.
    var state: State {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    var postableChannels: [String: PostableChannel] {
        get { state.postableChannels }
        set { state.postableChannels = newValue }
    }

    var threadOrder: [String] {
        get { state.threadOrder }
        set { state.threadOrder = newValue }
    }

    var serverMemberRoles: [String: String] {
        get { state.serverMemberRoles }
        set { state.serverMemberRoles = newValue }
    }

    var hideHumansFromMembers: [String: Bool] {
        get { state.hideHumansFromMembers }
        set { state.hideHumansFromMembers = newValue }
    }

    var serverMemberStatuses: [String: String] {
        get { state.serverMemberStatuses }
        set { state.serverMemberStatuses = newValue }
    }

    var membershipAgreementAudits: [(serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)] {
        get { state.membershipAgreementAudits }
        set { state.membershipAgreementAudits = newValue }
    }

    var jointProjections: [JointChannelLink] {
        get { state.jointProjections }
        set { state.jointProjections = newValue }
    }

    var serverMemberEvents: [ServerMemberEvent] {
        get { state.serverMemberEvents }
        set { state.serverMemberEvents = newValue }
    }

    var deletedServerIds: Set<String> {
        get { state.deletedServerIds }
        set { state.deletedServerIds = newValue }
    }

    var removedServerMembers: Set<String> {
        get { state.removedServerMembers }
        set { state.removedServerMembers = newValue }
    }

    var serverPlans: [String: String] {
        get { state.serverPlans }
        set { state.serverPlans = newValue }
    }

    var serverLabsState: [String: ServerLabsState] {
        get { state.serverLabsState }
        set { state.serverLabsState = newValue }
    }

    var serverInvites: [(id: String, serverId: String, email: String, role: String, tokenHash: String?)] {
        get { state.serverInvites }
        set { state.serverInvites = newValue }
    }

    var serverSwitcherOrders: [String: (ids: [String], version: Int)] {
        get { state.serverSwitcherOrders }
        set { state.serverSwitcherOrders = newValue }
    }

    var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] {
        get { state.serverOnboardingSettings }
        set { state.serverOnboardingSettings = newValue }
    }

    var setupPhases: [String: String] {
        get { state.setupPhases }
        set { state.setupPhases = newValue }
    }

    var setupHandoffs: Set<String> {
        get { state.setupHandoffs }
        set { state.setupHandoffs = newValue }
    }

    var guestRoleServers: Set<String> {
        get { state.guestRoleServers }
        set { state.guestRoleServers = newValue }
    }

    var proSeats: [String: Int] {
        get { state.proSeats }
        set { state.proSeats = newValue }
    }

    var joinLinks: [String: JoinLinkRecord] {
        get { state.joinLinks }
        set { state.joinLinks = newValue }
    }

    var usageLimitAttentionServers: Set<String> {
        get { state.usageLimitAttentionServers }
        set { state.usageLimitAttentionServers = newValue }
    }

    var guestVisibleChannels: [String: Bool] {
        get { state.guestVisibleChannels }
        set { state.guestVisibleChannels = newValue }
    }

    var guestJoinableChannels: [String: Bool] {
        get { state.guestJoinableChannels }
        set { state.guestJoinableChannels = newValue }
    }

    var readReceiptsServers: Set<String> {
        get { state.readReceiptsServers }
        set { state.readReceiptsServers = newValue }
    }

    var channelHumanRoles: [String: String] {
        get { state.channelHumanRoles }
        set { state.channelHumanRoles = newValue }
    }

    var channelAuthorityRevisions: [String: Int] {
        get { state.channelAuthorityRevisions }
        set { state.channelAuthorityRevisions = newValue }
    }

    var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] {
        get { state.sidebarModes }
        set { state.sidebarModes = newValue }
    }

    var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] {
        get { state.sidebarSections }
        set { state.sidebarSections = newValue }
    }

    var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] {
        get { state.sidebarPinnedRefs }
        set { state.sidebarPinnedRefs = newValue }
    }

    var sidebarReadAllEnabled: Bool {
        get { state.sidebarReadAllEnabled }
        set { state.sidebarReadAllEnabled = newValue }
    }

    var jointInvites: [(id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String)] {
        get { state.jointInvites }
        set { state.jointInvites = newValue }
    }

    var composerResourceServers: Set<String> {
        get { state.composerResourceServers }
        set { state.composerResourceServers = newValue }
    }

    var installedServerApps: [String: Set<String>] {
        get { state.installedServerApps }
        set { state.installedServerApps = newValue }
    }
}
