import Foundation
import Synchronization
import RaftShared

/// Owns the server-membership, sidebar and channel-authority rows that used to be stored inline on
/// `EmailLoginDirectory`.
///
/// HTTP decisions stay in the directory extensions; this store serializes only
/// its own rows in a Mutex-protected State and hands back Swift values.
/// `EmailLoginDirectory` keeps computed accessors that forward here so the
/// existing extension files and tests keep their property names while the
/// directory body stays a composition root.
final class ServersAndChannelsStore: Sendable {
    /// All mutable rows share one Mutex. Snapshot accessors return values;
    /// transaction methods read and mutate this state in one critical section.
    struct State: Sendable {
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
        /// Per-member onboarding progress, keyed `serverId\nuserId`. It lives
        /// beside the per-server rows so one patch updates both in a single
        /// critical section.
        var userOnboardingSettings: [String: UserOnboarding] = [:]
        /// Per-member setup phase, keyed `serverId\nuserId`.
        var setupPhases: [String: String] = [:]
        /// Legacy subjectless handoff markers. Retained for snapshot compatibility
        /// only: an old marker must never become a new owner/time receipt.
        var setupHandoffs: Set<String> = []
        /// Per-member completion provenance, keyed `serverId\nuserId`. Absent means
        /// unknown (a legacy `complete` written before a reason was recorded); an
        /// unknown reason never grows a personal survey/handoff task.
        var setupCompletionReasons: [String: String] = [:]
        /// Real owner handoff receipts keyed `serverId\noriginalOwnerId`. Written
        /// once by `POST .../setup-handoff` and retained on retry.
        var setupHandoffReceipts: [String: SetupHandoffReceipt] = [:]
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

    let mutex = TransactionalState(State())

    /// A value snapshot; transaction methods hold the Mutex for their whole decision.
    var state: State {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }

    var postableChannels: [String: PostableChannel] {
        get { mutex.withLock { $0.postableChannels } }
        set { mutex.withLock { $0.postableChannels = newValue } }
    }

    var threadOrder: [String] {
        get { mutex.withLock { $0.threadOrder } }
        set { mutex.withLock { $0.threadOrder = newValue } }
    }

    var serverMemberRoles: [String: String] {
        get { mutex.withLock { $0.serverMemberRoles } }
        set { mutex.withLock { $0.serverMemberRoles = newValue } }
    }

    var hideHumansFromMembers: [String: Bool] {
        get { mutex.withLock { $0.hideHumansFromMembers } }
        set { mutex.withLock { $0.hideHumansFromMembers = newValue } }
    }

    var serverMemberStatuses: [String: String] {
        get { mutex.withLock { $0.serverMemberStatuses } }
        set { mutex.withLock { $0.serverMemberStatuses = newValue } }
    }

    var membershipAgreementAudits: [(serverId: String, subjectId: String, actorUserId: String, source: String, agreementId: String?, agreementVersion: Int?)] {
        get { mutex.withLock { $0.membershipAgreementAudits } }
        set { mutex.withLock { $0.membershipAgreementAudits = newValue } }
    }

    var jointProjections: [JointChannelLink] {
        get { mutex.withLock { $0.jointProjections } }
        set { mutex.withLock { $0.jointProjections = newValue } }
    }

    var serverMemberEvents: [ServerMemberEvent] {
        get { mutex.withLock { $0.serverMemberEvents } }
        set { mutex.withLock { $0.serverMemberEvents = newValue } }
    }

    var deletedServerIds: Set<String> {
        get { mutex.withLock { $0.deletedServerIds } }
        set { mutex.withLock { $0.deletedServerIds = newValue } }
    }

    var removedServerMembers: Set<String> {
        get { mutex.withLock { $0.removedServerMembers } }
        set { mutex.withLock { $0.removedServerMembers = newValue } }
    }

    var serverPlans: [String: String] {
        get { mutex.withLock { $0.serverPlans } }
        set { mutex.withLock { $0.serverPlans = newValue } }
    }

    var serverLabsState: [String: ServerLabsState] {
        get { mutex.withLock { $0.serverLabsState } }
        set { mutex.withLock { $0.serverLabsState = newValue } }
    }

    var serverInvites: [(id: String, serverId: String, email: String, role: String, tokenHash: String?)] {
        get { mutex.withLock { $0.serverInvites } }
        set { mutex.withLock { $0.serverInvites = newValue } }
    }

    var serverSwitcherOrders: [String: (ids: [String], version: Int)] {
        get { mutex.withLock { $0.serverSwitcherOrders } }
        set { mutex.withLock { $0.serverSwitcherOrders = newValue } }
    }

    var serverOnboardingSettings: [String: (agentId: String?, greeting: Bool)] {
        get { mutex.withLock { $0.serverOnboardingSettings } }
        set { mutex.withLock { $0.serverOnboardingSettings = newValue } }
    }

    var setupPhases: [String: String] {
        get { mutex.withLock { $0.setupPhases } }
        set { mutex.withLock { $0.setupPhases = newValue } }
    }

    var setupHandoffs: Set<String> {
        get { mutex.withLock { $0.setupHandoffs } }
        set { mutex.withLock { $0.setupHandoffs = newValue } }
    }

    var guestRoleServers: Set<String> {
        get { mutex.withLock { $0.guestRoleServers } }
        set { mutex.withLock { $0.guestRoleServers = newValue } }
    }

    var proSeats: [String: Int] {
        get { mutex.withLock { $0.proSeats } }
        set { mutex.withLock { $0.proSeats = newValue } }
    }

    var joinLinks: [String: JoinLinkRecord] {
        get { mutex.withLock { $0.joinLinks } }
        set { mutex.withLock { $0.joinLinks = newValue } }
    }

    var usageLimitAttentionServers: Set<String> {
        get { mutex.withLock { $0.usageLimitAttentionServers } }
        set { mutex.withLock { $0.usageLimitAttentionServers = newValue } }
    }

    var guestVisibleChannels: [String: Bool] {
        get { mutex.withLock { $0.guestVisibleChannels } }
        set { mutex.withLock { $0.guestVisibleChannels = newValue } }
    }

    var guestJoinableChannels: [String: Bool] {
        get { mutex.withLock { $0.guestJoinableChannels } }
        set { mutex.withLock { $0.guestJoinableChannels = newValue } }
    }

    var readReceiptsServers: Set<String> {
        get { mutex.withLock { $0.readReceiptsServers } }
        set { mutex.withLock { $0.readReceiptsServers = newValue } }
    }

    var channelHumanRoles: [String: String] {
        get { mutex.withLock { $0.channelHumanRoles } }
        set { mutex.withLock { $0.channelHumanRoles = newValue } }
    }

    var channelAuthorityRevisions: [String: Int] {
        get { mutex.withLock { $0.channelAuthorityRevisions } }
        set { mutex.withLock { $0.channelAuthorityRevisions = newValue } }
    }

    var sidebarModes: [String: (channel: String, joint: String, dm: String, pinned: String, channelTabs: [String], agentTabs: [String])] {
        get { mutex.withLock { $0.sidebarModes } }
        set { mutex.withLock { $0.sidebarModes = newValue } }
    }

    var sidebarSections: [String: (sections: [(id: String, name: String, emoji: String?, sortMode: String)], order: [String], placements: [(kind: String, id: String, sectionId: String, position: Int)], version: Int)] {
        get { mutex.withLock { $0.sidebarSections } }
        set { mutex.withLock { $0.sidebarSections = newValue } }
    }

    var sidebarPinnedRefs: [String: (refs: [(kind: String, id: String)], channelIds: [String], agentIds: [String], version: Int)] {
        get { mutex.withLock { $0.sidebarPinnedRefs } }
        set { mutex.withLock { $0.sidebarPinnedRefs = newValue } }
    }

    var sidebarReadAllEnabled: Bool {
        get { mutex.withLock { $0.sidebarReadAllEnabled } }
        set { mutex.withLock { $0.sidebarReadAllEnabled = newValue } }
    }

    var jointInvites: [(id: String, hostServerId: String, hostChannelId: String, targetServerId: String, targetChannelId: String, targetOwnerId: String, status: String)] {
        get { mutex.withLock { $0.jointInvites } }
        set { mutex.withLock { $0.jointInvites = newValue } }
    }

    var composerResourceServers: Set<String> {
        get { mutex.withLock { $0.composerResourceServers } }
        set { mutex.withLock { $0.composerResourceServers = newValue } }
    }

    var installedServerApps: [String: Set<String>] {
        get { mutex.withLock { $0.installedServerApps } }
        set { mutex.withLock { $0.installedServerApps = newValue } }
    }
}
