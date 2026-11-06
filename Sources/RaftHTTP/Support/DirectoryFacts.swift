import Foundation

/// One stored agent runtime profile row: the machine it runs on plus any
/// pending migration release state. The delete-machine path treats these as
/// the authority on which Computers may still be removed.
public struct AgentRuntimeProfileFact: Sendable, Equatable {
    public var agentId: String
    public var machineId: String
    public var baselineMachineId: String?
    public var pendingBeforeMachineId: String?
    public var pendingAfterMachineId: String?
    public var migrationStatus: String?
    public var pendingKind: String?
    public var pendingReleaseNotesUrl: String?

    public init(
        agentId: String,
        machineId: String,
        baselineMachineId: String? = nil,
        pendingBeforeMachineId: String? = nil,
        pendingAfterMachineId: String? = nil,
        migrationStatus: String? = nil,
        pendingKind: String? = nil,
        pendingReleaseNotesUrl: String? = nil
    ) {
        self.agentId = agentId
        self.machineId = machineId
        self.baselineMachineId = baselineMachineId
        self.pendingBeforeMachineId = pendingBeforeMachineId
        self.pendingAfterMachineId = pendingAfterMachineId
        self.migrationStatus = migrationStatus
        self.pendingKind = pendingKind
        self.pendingReleaseNotesUrl = pendingReleaseNotesUrl
    }
}

/// Outcome of a target-side agent start attempt during migration arrival.
public enum MachineMigrationAgentStartOutcome: Sendable, Equatable {
    /// The daemon accepted the launch; the migration completes.
    case dispatched
    /// A gate (for example a held wake lock) suppressed the launch; the
    /// migration stays in `starting` so the arrival callback can retry.
    case skipped(String)
}

/// Outcome of an agent start dispatch (for example a resume-all prompt).
public enum AgentStartDispatchOutcome: Sendable, Equatable {
    /// The daemon accepted the start and will run the agent.
    case dispatched
    /// A gate (for example a held wake lock) suppressed the start.
    case skipped(String)
}

/// Outcome of the Built-in model catalog check for a target Computer.
public enum BuiltinModelCatalogResult: Sendable, Equatable {
    case supported
    case modelAbsent
    case catalogUnavailable
}

/// Result of one machine-backed agent surface read.
public enum AgentSurfaceResult: Sendable, Equatable {
    case ok(String)
    case machineUnassigned
    case machineOffline
    case machineTimeout
}

/// A code-shaped source-archive failure reported by the source Computer.
public struct MachineMigrationArchiveFailure: Error, Sendable, Equatable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// Test-observable mirror of the in-memory machine migration row.
public struct MachineMigrationStateSnapshot: Sendable, Equatable {
    public var state: String
    public var revision: Int
    public var agentId: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var transportGeneration: String
    public var flippedAt: Date?
    public var arrivedAt: Date?
    public var completedAt: Date?
    public var updatedAt: Date
    public var failureReason: String?
    public var transportErrorCode: String?
    public var transportErrorMessage: String?
    public var autoStartFailureStage: String?
    public var autoStartFailureCode: String?
    public var sourceWorkspaceArchivedAt: Date?
    public var sourceWorkspaceArchiveAttempts: Int
    public var sourceWorkspaceArchiveLastError: String?
    public var sourceWorkspaceArchiveRetryAt: Date?
    public var sourceWorkspaceArchiveAbandonedAt: Date?
    public var cancelDisposition: String?
    public var cancelSourceAck: String?
    public var cancelTargetAck: String?
    public var cancelSourceAckAt: Date?
    public var cancelTargetAckAt: Date?
    public var canceledAt: Date?
    public var transportTeardownAt: Date?
}

/// One agent migration row. Terminal rows stay behind as history after the
/// source Computer is deleted.
public struct AgentMigrationFact: Sendable, Equatable {
    public var agentId: String
    public var sourceMachineId: String
    public var targetMachineId: String
    public var state: String

    public init(agentId: String, sourceMachineId: String, targetMachineId: String, state: String) {
        self.agentId = agentId
        self.sourceMachineId = sourceMachineId
        self.targetMachineId = targetMachineId
        self.state = state
    }
}

/// One probed runtime model with its optional reasoning metadata.
public struct RuntimeModelProbeModel: Sendable, Equatable {
    public var id: String
    public var label: String
    public var supportedReasoningEfforts: [String]?
    public var defaultReasoningEffort: String?

    public init(
        id: String,
        label: String,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.label = label
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

/// The Computer's answer to a runtime model probe.
public enum RuntimeModelProbeOutcome: Sendable, Equatable {
    case live(models: [RuntimeModelProbeModel], default: String?)
    case models(models: [RuntimeModelProbeModel], default: String?)
    case missingConfig
    case noModels
    case unsupported
    case error(code: String, retryable: Bool)
    case failed
}

/// One agent (runner) thread follow row.
public struct AgentThreadFollowRecord: Sendable, Equatable {
    public var serverId: String
    public var agentId: String
    public var threadChannelId: String
    public var parentMessageId: String
    public var followedAt: Date
    public var reason: String
    public var doneAt: Date?
    public var unfollowedAt: Date?

    public init(
        serverId: String,
        agentId: String,
        threadChannelId: String,
        parentMessageId: String,
        followedAt: Date,
        reason: String,
        doneAt: Date? = nil,
        unfollowedAt: Date? = nil
    ) {
        self.serverId = serverId
        self.agentId = agentId
        self.threadChannelId = threadChannelId
        self.parentMessageId = parentMessageId
        self.followedAt = followedAt
        self.reason = reason
        self.doneAt = doneAt
        self.unfollowedAt = unfollowedAt
    }
}

/// One agent login into a server integration service.
public struct AgentIntegrationLoginRecord: Sendable, Equatable {
    public var serverId: String
    public var agentId: String
    public var clientId: String
    public var scopes: [String]
    public var loggedInAt: Date

    public init(serverId: String, agentId: String, clientId: String, scopes: [String], loggedInAt: Date) {
        self.serverId = serverId
        self.agentId = agentId
        self.clientId = clientId
        self.scopes = scopes
        self.loggedInAt = loggedInAt
    }
}

/// One attachment comment row.
public struct AttachmentCommentRecord: Sendable, Equatable {
    public var id: String
    public var attachmentId: String
    public var content: String
    public var anchorJSON: String?
    public var senderId: String
    public var senderType: String
    public var createdAt: Date
    public var threadChannelId: String?
    public var hostMessageId: String?
    public var hostChannelId: String?

    public init(
        id: String,
        attachmentId: String,
        content: String,
        anchorJSON: String?,
        senderId: String,
        senderType: String,
        createdAt: Date,
        threadChannelId: String? = nil,
        hostMessageId: String? = nil,
        hostChannelId: String? = nil
    ) {
        self.id = id
        self.attachmentId = attachmentId
        self.content = content
        self.anchorJSON = anchorJSON
        self.senderId = senderId
        self.senderType = senderType
        self.createdAt = createdAt
        self.threadChannelId = threadChannelId
        self.hostMessageId = hostMessageId
        self.hostChannelId = hostChannelId
    }
}

public struct RefreshRotationReceipt: Equatable, Sendable {
    public var attemptId: String
    public var installationId: String
    public var successorTokenCiphertext: String

    public init(attemptId: String, installationId: String, successorTokenCiphertext: String) {
        self.attemptId = attemptId
        self.installationId = installationId
        self.successorTokenCiphertext = successorTokenCiphertext
    }
}

public struct NativeAppleCodeExchange: Equatable, Sendable {
    public var code: String
    public var clientId: String
    public var clientSecret: String
    public var grantType: String
    public var redirectUri: String?

    public init(code: String, clientId: String, clientSecret: String, grantType: String, redirectUri: String?) {
        self.code = code
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.grantType = grantType
        self.redirectUri = redirectUri
    }
}

public struct MobileProviderProfile: Equatable, Sendable {
    public var providerUserId: String
    public var email: String
    public var displayName: String?
    /// Apple rejects a link when this is false. Google and GitHub profiles are already verified.
    public var emailVerified: Bool

    public init(providerUserId: String, email: String, displayName: String?, emailVerified: Bool = true) {
        self.providerUserId = providerUserId
        self.email = email
        self.displayName = displayName
        self.emailVerified = emailVerified
    }
}

public struct SocialAuthState: Equatable, Sendable {
    public var provider: String
    public var mode: String
    public var nonce: String
    public var kind: String
    public var mobileRequestId: String
    public var desktopNonce: String?
    public var returnTo: String?
    public var linkUserId: String?
    public var linkOnConflict: Bool = false

    public init(provider: String, mode: String, nonce: String, kind: String, mobileRequestId: String, desktopNonce: String?, returnTo: String? = nil, linkUserId: String? = nil, linkOnConflict: Bool = false) {
        self.provider = provider
        self.mode = mode
        self.nonce = nonce
        self.kind = kind
        self.mobileRequestId = mobileRequestId
        self.desktopNonce = desktopNonce
        self.returnTo = returnTo
        self.linkUserId = linkUserId
        self.linkOnConflict = linkOnConflict
    }
}

public struct EmailLegalAcceptance: Equatable, Sendable {
    public var termsVersion: String
    public var privacyVersion: String
    public var termsUrl: String
    public var privacyUrl: String
    public var source: String
    public var userAgentHash: String?
    public var locale: String?

    public init(
        termsVersion: String,
        privacyVersion: String,
        termsUrl: String,
        privacyUrl: String,
        source: String,
        userAgentHash: String?,
        locale: String?
    ) {
        self.termsVersion = termsVersion
        self.privacyVersion = privacyVersion
        self.termsUrl = termsUrl
        self.privacyUrl = privacyUrl
        self.source = source
        self.userAgentHash = userAgentHash
        self.locale = locale
    }
}

public struct RecordedProductEvent: Sendable {
    public var subjectType: String
    public var subjectId: String
    public var eventType: String
    public var actorType: String
    public var actorId: String
    public var source: String
    public var idempotencyKey: String?
    public var metadataJSON: String
}

public struct ClientEventRecord: Sendable {
    public var event: String
    public var analyticsId: String
    public var serverId: String
    public var source: String
    public var sessionId: String
    public var appVersion: String?
    public var propertiesJSON: String
}


public struct MobileAppEmailContact: Equatable, Sendable {
    public var userId: String
    public var email: String
    public var audienceId: String
    public var status: String
    public var optedOutAt: Date?
}

public struct MobileAppEmailJourney: Equatable, Sendable {
    public var userId: String
    public var email: String
    public var journeyKey: String
    public var day1Status: String
    public var day1EmailId: String?
    public var suppressedReason: String?
    public var canceledAt: Date?
}

public struct ForwardedSource: Equatable, Sendable {
    public var sourceServerId: String
    public var sourceTargetId: String
    public var sourceMessageId: String
    public var snapshotId: String
    public var snapshotType: String
    public var snapshotLabel: String
    public var snapshotLabelVisibility: String
    public var provenanceState: String

    public init(sourceServerId: String, sourceTargetId: String, sourceMessageId: String, snapshotId: String, snapshotType: String, snapshotLabel: String, snapshotLabelVisibility: String, provenanceState: String) {
        self.sourceServerId = sourceServerId
        self.sourceTargetId = sourceTargetId
        self.sourceMessageId = sourceMessageId
        self.snapshotId = snapshotId
        self.snapshotType = snapshotType
        self.snapshotLabel = snapshotLabel
        self.snapshotLabelVisibility = snapshotLabelVisibility
        self.provenanceState = provenanceState
    }
}

public struct MentionFact: Equatable, Sendable {
    public var targetType: String
    public var targetId: String
    public var notifiableAtSend: Bool
    public var notified: Bool
}

public struct InboxFact: Equatable, Sendable {
    public var receiverType: String
    public var receiverId: String
    public var personalMention: Bool = false
    public var unreadEligible: Bool = true

    public init(receiverType: String, receiverId: String, personalMention: Bool = false, unreadEligible: Bool = true) {
        self.receiverType = receiverType
        self.receiverId = receiverId
        self.personalMention = personalMention
        self.unreadEligible = unreadEligible
    }
}

public struct MentionActionRecord: Equatable, Sendable {
    public var notified: Bool
    public var notifiedByType: String?
    public var notifiedById: String?
    public var notifiedAction: String?
}

public struct TimezoneObservation: Sendable {
    public var firstTimezone: String
    public var firstAt: Date
    public var lastTimezone: String
    public var lastAt: Date
}
