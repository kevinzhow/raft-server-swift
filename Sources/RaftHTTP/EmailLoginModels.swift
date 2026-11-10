import Foundation
import CoreFoundation

// Extracted from EmailLogin.swift (data models only; behavior unchanged).

struct AppleIdentityClaims {
        var subject: String
        var nonce: String
        var email: String?
    }

enum NativeAppleRequestToken {
        case valid(NativeAppleRequestClaims)
        case expired
        case invalid
    }

struct NativeAppleRequestClaims {
        var requestId: String
        var mode: String
        var codeChallenge: String
        var userId: String?
    }

enum FeedbackRouteFailure: Error {
        case invalidSource
        case sourceUnavailable(source: String, reason: String)
        case configuration
        case routeBinding(reason: String)
    }

struct FeedbackRouteConfig {
        var baseURL: String
        var appId: String
        var appToken: String
        var credentialRevision: String
        var reporterIntegrationId: String
        var keyId: String
        var root: String
        var commitmentLabel: String
        var reporterIdSecret: String
    }

struct FeedbackRouteEnvironment {
        var baseURL: String
        var appSlug: String
        var appId: String
        var clientKey: String
        var appToken: String
        var conversationToken: String
        var credentialRevision: String
        var reporterIntegrationId: String
        var reporterIdSecret: String
        var routeSubjectKeyId: String
        var routeSubjectRoot: String
        var routeCommitmentScope: String
        var cursorSecret: String
        var conversationSessionEnabled: Bool
        var isMultiApp: Bool
    }

struct FeedbackSourceEntry {
        var appSlug: String
        var appId: String
        var reporterIntegrationId: String
        var credentialRevision: String
        var clientKey: String
        var token: String
    }

struct ProviderConnection: Sendable {
        var id: String
        var serverId: String
        var name: String
        var providerId: String
        var endpointUrl: String?
        var supportsImageInput: Bool
        var status: String
        var configVersion: Int
        var credentialVersion: Int
        var hasCredential: Bool
        var createdAt: Date
        var updatedAt: Date
    }

struct ProviderAssignment: Sendable {
        var connectionId: String
        var serverId: String
        var agentId: String
        var computerName: String?
    }

struct WebPushSubscription: Sendable {
        var userId: String
        var endpoint: String
    }

struct ExternalAvatarAsset: Sendable {
        var id: String
        var contentType: String
        var bytes: Data
        var sourceDigest: String
        var active: Bool
    }

struct ReminderEvent: Sendable {
        var reminderId: String
        var serverId: String
        var ownerAgentId: String
        var type: String
        var version: Int
        var actorType: String
        var actorId: String?
        var createdAt: Date
        var fireAt: Date?
    }

struct ReminderRecord: Sendable {
        var id: String
        var serverId: String
        var ownerAgentId: String
        var title: String
        var fireAt: Date
        var status: String = "scheduled"
        var version: Int = 1
        var notes: String? = nil
        var recurrenceJSON: String? = nil
        var channelId: String? = nil
        var threadId: String? = nil
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
    }

struct AgentApiIdempotencyRecord: Sendable {
        var agentId: String
        var route: String
        var key: String
        var fingerprint: String
        var status: Int
        var responseBody: String
        var createdAt: Date
    }

struct TaskRecord: Sendable {
        var id: String
        var channelId: String
        var title: String
        var description: String?
        var status: String
        var taskNumber: Int
        var messageId: String
        var createdAt: Date
        var completedAt: Date? = nil
        var updatedAt: Date? = nil
        var creatorId: String? = nil
        var assigneeId: String? = nil
        var assigneeType: String? = nil
        var claimedAt: Date? = nil
        var revision: Int = 0
        var closedAt: Date? = nil
        /// False for a pre-thread v0 orphan: the row has no host message, so the
        /// agent surface cannot address it.
        var hasHostMessage: Bool = true
        var amendedAt: Date? = nil
        var amendedByType: String? = nil
        var amendedByName: String? = nil
        var superseded: Bool = false
        var requiresResourceReceipt: Bool = false
        var resourceReceiptJSON: String? = nil
    }

struct AgentInboxRow {
        var target: String
        var kind: String
        var lastReadSeq: Int
        var unread: Int
        var mentions: Int
        var latestSeq: Int
        var activitySeq: Int
        var latestSenderName: String
        var latestAt: Date?
        var joinedAt: Date
    }

struct AgentChannelCardSnapshot {
        let id: String
        let name: String
        let type: String
        let description: String?
        let archived: Bool

        var json: String {
            let descriptionJSON = description.map(jsonString) ?? "null"
            return "{\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),\"type\":\(jsonString(type)),\"description\":\(descriptionJSON),\"archived\":\(archived)}"
        }

        var rev: String {
            Self.rev(name: name, type: type, archived: archived, description: description)
        }

        /// `channelCardRev` from the shared projector: `v1:` plus two FNV-1a
        /// 32-bit hashes over the fixed-order JSON tuple of what the card
        /// shows, with the description whitespace-collapsed.
        static func rev(name: String, type: String?, archived: Bool, description: String?) -> String {
            let visibility: String
            let trimmedType = type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedType == "joint" {
                visibility = "joint"
            } else if trimmedType == "private" || trimmedType == "dm" {
                visibility = "private"
            } else {
                visibility = "public"
            }
            let displayed = (description ?? "")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let text = "[" + jsonString(name) + "," + jsonString(visibility) + ","
                + (archived ? "true" : "false") + "," + jsonString(displayed) + "]"
            let first = fnv1a32(text, seed: 0x811c_9dc5)
            let second = fnv1a32(text, seed: 0x050c_5d1f)
            return String(format: "v1:%08x%08x", first, second)
        }

        /// JS `charCodeAt` hashes UTF-16 code units, not UTF-8 bytes.
        private static func fnv1a32(_ text: String, seed: UInt32) -> UInt32 {
            var hash = seed
            for unit in text.utf16 {
                hash ^= UInt32(unit)
                hash = hash &* 0x0100_0193
            }
            return hash
        }
    }

enum DMPeerResolution {
        case resolved(peerId: String, peerKind: String, name: String)
        case ambiguous(String)
        case invalidKind(String, String)
        case notFound
    }

struct ServerLabsState: Sendable, Equatable {
        var accessEnabled = false
        var version = 0
        var enrolled: Set<String> = []
        var updatedAt: [String: Date] = [:]
    }

enum TaskChannelAccess {
        case readOnly
        case write
        case missing
    }

enum SidebarPinnedChannelResolution {
        case missing
        case channel((kind: String, id: String))
        case dm((kind: String, id: String), legacyId: String)
    }

struct MachineRecord: Sendable {
        var id: String
        var serverId: String
        var userId: String
        var name: String
        var description: String?
        var apiKey: String?
        var apiKeyFingerprint: String? = nil
        var legacyKeyMigratedAt: Date? = nil
        var hostname: String? = nil
        var lastSeenAt: Date? = nil
        var runtimes: [String] = []
        var runtimeVersions: [String: String] = [:]
        var runtimeDetection: MachineRuntimeDetectionFact? = nil
    }

struct UserOnboarding: Sendable {
        var reminderOptOut = false
        var dismissed: [String: Date] = [:]
        var currentStep: String?
    }

/// How one member's setup row reached `complete`, copied from the upstream
/// `ServerSetupCompletionReason` (services/serverSetupStateService.ts:48-52).
/// `normal` is the only reason a NEW completion writes; `complete_after_defer`
/// is read for compatibility, and `grandfathered`/`admin_override` stay
/// terminal facts that never owe the personal post-setup screens.
enum ServerSetupCompletionReason: String, Sendable, Equatable {
    case normal
    case grandfathered
    case completeAfterDefer = "complete_after_defer"
    case adminOverride = "admin_override"

    /// The two reasons that mean the owner actually walked the real flow
    /// (`projectServerSetup`'s `flowCompleted`).
    var isFreshFlowCompletion: Bool {
        self == .normal || self == .completeAfterDefer
    }
}

/// The real "Let's Go" acknowledgment: the first time the server's primary
/// owner accepted the handoff (upstream `serverMembers.setup_handoff_acknowledged_at`,
/// services/serverService.ts:1530-1571). The pair
/// `(serverId, originalOwnerId)` is the identity; `acknowledgedAt` is the
/// FIRST time and never moves on a retry.
struct SetupHandoffReceipt: Sendable, Equatable {
    var serverId: String
    var originalOwnerId: String
    var acknowledgedAt: Date
}

struct HostedConnectionStatusRecord {
        var connected: Bool
        var account: String?
        var connectedAt: String?
        var connectedBy: String?
        var scopes: [String]
        var connectorId: String?
        var connectors: [HostedConnectionConnectorRecord]
    }

struct HostedConnectionConnectorRecord {
        var id: String
        var account: String
        var creatorRaftUserId: String?
        var createdAt: String?
        var current: Bool
    }

struct AttachedComputer: Sendable {
        let id: String
        let serverId: String
        let userId: String
        let name: String
        let apiKey: String
    }

struct ChannelAttachment: Sendable {
        var id: String
        var channelId: String
        var uploaderId: String
        var filename: String
        var messageId: String?
        var messagePosition: Int?
        var mimeType: String? = nil
        var sizeBytes: Int? = nil
        var width: Int? = nil
        var height: Int? = nil
        var uploaderType: String = "user"
        var createdAt: Date = Date()
        var thumbnailKey: String? = nil
        var storageKey: String? = nil
    }

enum ChannelProbeAccess {
        case allowed
        case residue
        case hidden
    }

struct StoredHumanMessage: Sendable {
        var id: String
        var channelId: String
        var senderId: String
        var content: String
        /// Server-wide message sequence. Assigned when the row is appended.
        var seq: Int = 0
        var randomId: String?
        var attachmentIds: [String] = []
        var messageType: String = "chat"
        var senderType: String = "user"
        var createdAt: Date = Date()
        var actionKind: String? = nil
        var taskStatus: String? = nil
        var taskNumber: Int? = nil
        var taskAssigneeType: String? = nil
        var taskAssigneeId: String? = nil
        var taskClaimedAt: String? = nil
        var taskCompletedAt: String? = nil
        var senderTimezone: String? = nil
        var externalMessageId: String? = nil
        var externalProvider: String? = nil
        var externalSenderName: String? = nil
        var systemSubtype: String? = nil
        var causalActorType: String? = nil
        var causalActorId: String? = nil
        var mentions: [StoredMessageMention] = []
    }

struct StoredMessageMention: Equatable, Sendable {
        var type: String
        var id: String
        var name: String
    }

struct StoredReaction: Sendable {
        var messageId: String
        var emoji: String
        var reactorId: String
        var reactorType: String
    }

struct SystemAttentionReceipt: Sendable {
        var seenAt: Date?
        var dismissedAt: Date?
    }

struct SystemAttentionIncident: Sendable {
        var id: String
        var serverId: String
        var machineId: String
        var provider: String
        var windowKey: String
        var activationGeneration: Int
        var affectedAgentIds: [String]
        var activatedAt: Date
        var lastObservedAt: Date
        var resetsAt: Date?
        var state: String
    }

struct JoinLinkRecord: Sendable {
        var id: String
        var token: String
        var serverId: String
        var role: String
        var createdAt: Date
        var expiresAt: Date?
        var maxUses: Int?
        var useCount: Int
        var revokedAt: Date?
    }

struct ServerAgent: Sendable {
        var id: String
        var serverId: String
        var name: String
        var avatarUrl: String?
        var status: String = "inactive"
    }

struct MentionInput {
        var type: String
        var id: String
        var name: String
    }

struct AgentCredential: Sendable {
        var id: String = UUID().uuidString.lowercased()
        var agentId: String
        var scopes: Set<String>
        var name: String
        var createdAt: Date = Date()
        var lastUsedAt: Date?
        var revokedAt: Date?
    }

struct StoredMention: Sendable {
        var id: String
        var messageId: String
        var channelId: String
        var senderId: String
        var targetType: String
        var targetId: String
        var handle: String
        var notifiableAtSend: Bool
        var createdAt: Date = Date()
        var notifiedAt: Date?
        var notifiedByType: String?
        var notifiedById: String?
        var notifiedAction: String?
        var terminalCode: String? = nil
    }

struct PostableChannel: Sendable {
        var serverId: String
        var memberIds: Set<String>
        var kind: String = "channel"
        var agentId: String? = nil
        var parentChannelId: String? = nil
        var parentMessageId: String? = nil
        var archived: Bool = false
        var deletedAt: Date? = nil
        var name: String = ""
    }

struct JointChannelLink: Sendable {
        var localChannelId: String
        var canonicalChannelId: String
        var serverId: String
        var status: String = "active"
    }

struct Issue {
        var path: String
        var message: String
    }

struct Account: Sendable {
        var id: String
        var email: String
        var passwordHash: String
        var passwordCredentialEstablishedAt: Date? = Date()
        var displayLanguage: String?
        var name: String
        var displayName: String? = nil
        var profileSetupSuggestedHandle: String?
        var profileSetupProvider: String? = nil
        var profileSetupCompletedAt: Date? = nil
        var avatarUrl: String? = nil
        var description: String? = nil
        var shareUsageData: Bool? = nil
        var emailVerified: Bool = false
        var stagingSelfAccountCapabilityHash: String? = nil
        var retiredAt: Date? = nil
        var preferredLanguage: String? = nil
        var preferredTimezone: String? = nil
        var preferredTranslationMode: String = "off"
        var autoTranslationEnabled: Bool = false
        var preferredTranslationDisplay: String = "translated"
        var preferredTimeFormat: String? = nil
        var preferredMessageBodyFontSize: String? = nil
        var referralSource: String? = nil
        var referralSourceOther: String? = nil
        var referralSourceSkippedAt: Date? = nil
    }

struct LinkedIdentity: Sendable {
        var userId: String
        var provider: String
        var providerUserId: String
        var providerEmail: String? = nil
    }

struct SocialCompletion: Sendable {
        var provider: String
        var code: String
        var mode: String
        var intendedAction: String
        var email: String
        var returnTo: String
        var userId: String?
        var providerUserId: String?
        var linkOnConflict: Bool = false
    }

struct RotationReceipt: Sendable {
        var attemptId: String
        var installationId: String
        var userId: String
        var familyId: String
        var successor: String
        var ciphertext: String
        var expiresAt: Date
    }

struct DeviceGrant: Sendable {
        var deviceCode: String
        var userCode: String
        var status: String
        var approvedByUserId: String?
        var expiresAt: Date
        var clientName: String?
    }

struct RetirementReceipt: Sendable {
        var userId: String
        var actorUserId: String
        var environment: String
        var terminalState: String
        var sessionsRevoked: Int
    }

struct SessionFamily: Sendable {
        var userId: String
        var revokedAt: Date?
        var revokedReason: String?
        var revokeCapabilityNonce: String?
        var capabilityRetainUntil: Date?
    }

struct LiveSession: Sendable {
        var userId: String
        var familyId: String
    }

struct MobileOAuthRequest: Sendable {
        var id: String
        var provider: String
        var mode: String
        var status: String
        var codeChallenge: String
        var returnUri: String
        var nonce: String
        var expiresAt: Date
        var handoffCode: String? = nil
        var codeHash: String? = nil
        var profileEmail: String? = nil
        var profileUserId: String? = nil
        var profileName: String? = nil
        var userId: String? = nil
        var linkOnConflict: Bool = false
        var intendedAction: String = "login"
    }

struct ActorCursor {
        var principalId: String
        var serverId: String
        var messageId: String
        var emoji: String
        var discussionVersion: Int
        var visibilityHash: String
        var actorKind: String
        var actorId: String
    }

enum ReactionTarget {
        case message(StoredHumanMessage, PostableChannel, String)
        case ambiguous
        case missing
    }

enum PageCursor: Equatable {
        case absent
        case value(Int)
        case invalid

        var value: Int? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

struct PendingForwardSource {
        var messageId: String
        var content: String
        var createdAt: Date
        var channelId: String
        var channelKind: String
        var channelName: String
        var parentChannelId: String?
        var senderId: String
        var attachments: [ChannelAttachment]
    }

struct StoredForwardRecord: Sendable {
        var sourceIds: [String]
        var items: [ForwardItemRecord]
        var destinationTargetId: String
    }

struct ForwardItemRecord: Sendable {
        var sourceMessageId: String
        var exposesPointers: Bool
        var sourceAuthorUniqueName: String
        var sourceIsThreadParent: Bool
        var contentSnapshot: String
        var sourceTargetId: String?
        var sourceThreadId: String?
        var parentChannelId: String?
        var snapshotId: String?
        var snapshotType: String
        var snapshotLabel: String
        var snapshotLabelVisibility: String
        var provenanceState: String
        var attachments: [ForwardAttachmentSnapshot]
        var attachmentPolicy: String
    }

struct ForwardSourceContext {
        var bundleSourceId: String
        var sourceTargetId: String?
        var sourceThreadId: String?
        var parentChannelId: String?
        var sourceIsThreadParent: Bool
        var snapshotId: String?
        var snapshotType: String
        var snapshotLabel: String
        var snapshotLabelVisibility: String
    }

struct ForwardAttachmentSnapshot: Sendable {
        var id: String
        var filename: String
        var mimeType: String
        var sizeBytes: Int
        var width: Int?
        var height: Int?
    }

enum SearchViewer {
        case user(String)
        case agent(String)
    }

struct FeatureFlagClientFacts {
        var os: String?
        var buildNumber: Int?
        var buildType: String?
    }

enum NativeAppleClaim {
        case missing
        case authRequired
        case userMismatch
        case expired
        case consumed
        case claimed(String)
    }

struct PendingSocialLink: Sendable {
        var token: String
        var provider: String
        var providerUserId: String
        var email: String
        var returnTo: String?
        var returnUri: String?
        var expiresAt: Date
        var consumed: Bool = false
        var cancelled: Bool = false
    }

struct StoredNativeNotificationEvent {
        var eventId: String
        var streamSeq: Int
        var recipientUserId: String
        var eventKey: String
        var serverId: String
        var channelId: String
        var messageId: String
        var title: String
        var body: String
        var targetUri: String
        var createdAt: Date
        var expiresAt: Date
    }

struct StoredNotificationCredential {
        var id: String
        var deviceId: String
        var userId: String
        var sessionFamilyId: String
        var secretHash: String
        var scope: String
        var expiresAt: Date
        var revokedAt: Date? = nil
    }

struct StoredNotificationDevice {
        var id: String
        var userId: String
        var appId: String
        var appVersion: String
        var releaseChannel: String
        var appInstanceId: String
        var publicKey: String = ""
        var revokedAt: Date? = nil
    }

struct StoredEnrollmentGrant {
        var id: String
        var userId: String
        var sessionFamilyId: String
        var secretHash: String
        var appId: String
        var protocolVersion: Int
        var appVersion: String
        var releaseChannel: String
        var appInstanceId: String
        var publicKey: String
        var nonce: String
        var attestationState: String
        var expiresAt: Date
        var createdAt: Date
        var consumedAt: Date?
    }

struct FeatureFlagRuleRecord: Sendable {
        var key: String
        var stage: String
        var decision: String
        var values: [String]
        var clientOs: [String]?
        var minClientBuild: Int?
        var clientBuildTypes: [String]?
        var priority = 0
        var createdAt = Date()
    }

struct FeatureFlagRecord: Sendable {
        var key: String
        var enabled = true
        var killSwitch = false
        var defaultEnabled = false
    }

struct FeedbackLocatorRecord: Sendable {
        var serverId: String
        var producerAgentId: String
        var reportId: String
        var receiptId: String
        var capturedAt: Date
        var runtime: String
        var nativeStatus: String
        var nativeLookupMethod: String
        var nativeLocatorKind: String
        var hasServedExact: Bool
        var servedExactSha256: [String]
        var routeBasis: String?
        var routeTarget: String?
        var payloadSha256: String
        var createdAt: Date
    }

struct ManagedMCPServerRecord: Sendable {
        var id: String
        var serverId: String
        var name: String
        var provider: String?
        var authMode: String?
        var oauthStatus: String?
        var endpointUrl: String
        var toolCatalogJSON: String
        var catalogVersion: Int
        var credentialHeaderNames: [String] = []
        var credentialHeaders: [String: String] = [:]
    }

struct AgentApiSendReceipt: Sendable {
        var messageId: String
        var messageSeq: Int
        var target: String
        var content: String
        var attachmentIds: [String]
    }

struct IntegrationRegisterCard: Sendable {
        var messageId: String
        var serverId: String
        var agentId: String
        var agentName: String
        var storageChannelId: String
        var localCarrierChannelId: String
        var name: String
        var clientKey: String?
        var homepageUrl: String?
        var returnUrl: String
        var agentManifestUrl: String?
        var setupUrl: String?
        var setupDescription: String?
        var scopes: [String]
        var state: String
        var executedByUserId: String?
        var resultJSON: String?
    }

struct MarketplaceInstallCard: Sendable {
        var messageId: String
        var serverId: String
        var clientRecordId: String
        var clientKey: String
        var clientName: String
        var clientNameSha256: String
        var agentId: String
        var agentName: String
        var scopes: [String]
        var storageChannelId: String
        var localCarrierChannelId: String
        var state: String
        var executedByUserId: String?
        var resultJSON: String?
        var setupUrl: String? = nil
        var setupRevision: Int = 1
    }

struct ActionCardRecord: Sendable {
        var messageId: String
        var serverId: String
        var requesterAgentId: String
        var storageChannelId: String
        var localCarrierChannelId: String
        var actionType: String
        var channelName: String?
        var visibility: String
        var state: String
        var executedByUserId: String?
    }

struct AnnouncementImageAsset: Sendable {
        var id: String
        var announcementId: String
        var contentType: String
        var bytes: Data
    }

struct AttestedSendEventRecord: Sendable {
        var eventType: String
        var agentId: String
        var messageId: String?
        var metadataJSON: String
    }

struct ThreadUnfollowRecord: Sendable {
        var serverId: String
        var userId: String
        var threadChannelId: String
        var parentMessageId: String
        var unfollowedAt: Date
        var latestMessageId: String
        var replyCount: Int
        var frozenMessages: [(id: String, content: String)]
    }

struct ShareArtifactRecord: Sendable {
        var bytes: Data
        var width: Int
        var height: Int
        var serverId: String
        var createdAt: Date
    }

struct ReadMutationRecord: Sendable {
        var mutationId: String
        var serverId: String
        var principalId: String
        var kind: String
        var scopeId: String?
        var fingerprint: String
        var authoritySeq: Int
        var state: String
    }

struct ServerMemberEvent: Sendable {
        var serverId: String
        var eventType: String
        var subjectType: String
        var subjectId: String
        var provenanceJSON: String
        var deliveryQueued: Bool
    }

struct AgentArchiveRecord: Sendable {
        var serverId: String
        var machineId: String?
        var machineName: String
        var archivedAt: Date
        var archivedByUserId: String
        /// `on_computer`, `deleted`, or `unknown` when the agent cannot own a Computer workspace.
        var workspaceState: String
        var pendingOp: String?
        var lastErrorCode: String?
        var lastErrorAt: Date?
    }

struct HostedModelState: Sendable {
        var models: [(id: String, label: String, provider: String)]
        var defaultModel: String?
        var defaultLabel: String?
        var model: String?
        var label: String?
        var source: String
        var locked: Bool
    }

struct MachineMigrationRecord: Sendable {
        var agentId: String
        var serverId: String
        var supportRef: String
        var revision: Int
        var state: String
        var sourceMachineId: String
        var targetMachineId: String
        var transportGeneration: String
        var transportProvider: String = "object_store"
        var transportSessionId: String = ""
        var sourceTokenHash: String = ""
        var targetTokenHash: String = ""
        var manifestJSON: String?
        var manifestChunks: [Int: (sha256: String, sizeBytes: Int)] = [:]
        var chunkReceipts: [Int: String] = [:]
        var failureReason: String?
        var transportErrorCode: String?
        var transportErrorMessage: String?
        var transportLostAt: Date?
        var transportTeardownAt: Date?
        var canceledAt: Date?
        var cancelReason: String?
        var cancelDispatchAttempts: Int = 0
        var cancelLastDispatchAt: Date?
        var cancelErrorCode: String?
        var cancelGeneration: String?
        var cancelTransportGeneration: String?
        var cancelDisposition: String?
        var cancelSourceAck: String?
        var cancelTargetAck: String?
        var cancelSourceAckAt: Date?
        var cancelTargetAckAt: Date?
        var quiesceReceiptJSON: String?
        var progressJSON: String?
        /// Generation consumed by the transition into the current state; lets a
        /// replayed flip/arrive present the generation it was issued with.
        var previousTransportGeneration: String?
        var flippedAt: Date?
        var arrivedAt: Date?
        var completedAt: Date?
        var updatedAt: Date = Date()
        var sourceWorkspaceArchivedAt: Date?
        var sourceWorkspaceArchiveAttempts: Int = 0
        var sourceWorkspaceArchiveLastError: String?
        var sourceWorkspaceArchiveRetryAt: Date?
        var sourceWorkspaceArchiveAbandonedAt: Date?
        var autoStartFailureStage: String?
        var autoStartFailureCode: String?
        var arrivalReportPath: String?
        var arrivalReportSha256: String?
    }

struct HostedMigrationRecord: Sendable {
        var agentId: String
        var serverId: String
        var supportRef: String
        var revision: Int
        var state: String
        var sourceMachineId: String?
        var canceledAt: Date?
        var cancelReason: String?
        var cancelDispatchAttempts: Int = 0
        var cancelLastDispatchAt: Date?
        var cancelErrorCode: String?
    }

struct AppLoginRequest: Sendable {
        var id: String
        var returnUri: String
        var codeChallenge: String
        var status: String
        var code: String?
        var userId: String?
        var expiresAt: Date
        var consumedAt: Date?
    }
