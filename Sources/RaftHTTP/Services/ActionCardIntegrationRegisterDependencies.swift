import Foundation

/// The closure dependencies of the action-card integration-register domain
/// that still live in not-yet-migrated domains.
///
/// Everything else is a store or the OAuth ledger: the marketplace target
/// resolver, the integration-card preparer and the card projections are owned
/// by this service (`ActionCardMetadataProjection`). `appendHumanMessage` is the directory-lock message append (sequence stamp +
/// OAuth mirror); `emitRealtime` is the realtime relay; `sessionUserId` is the
/// human session ledger; `agentCredential` is the agent credential lookup that
/// records `lastUsedAt`.
struct ActionCardIntegrationRegisterDependencies: Sendable {
    var sessionUserId: @Sendable (String?) -> String?
    var agentCredential: @Sendable (String?) -> (agentId: String, scopes: [String])?
    var identityResolution: @Sendable (String?, String) -> FeedbackLocatorService.IdentityResolution
    var appendHumanMessage: @Sendable (StoredHumanMessage) -> Int
    var addPostableChannel: @Sendable (
        _ serverId: String,
        _ channelId: String,
        _ memberId: String,
        _ kind: String,
        _ parentChannelId: String?,
        _ parentMessageId: String?,
        _ name: String?
    ) -> Void
    var emitRealtime: @Sendable (String, String, String?) -> Void
    /// The action-card `message:updated` projection slot. The carrier row's
    /// executed state lives in this service's store, so the closure receives the
    /// message id and the post-write metadata JSON.
    var publishMessageUpdated: @Sendable (String, String) -> Void = { _, _ in }
    var marketplaceInstallableClient: @Sendable (String) -> MarketplaceClientIdentity?
    var publicIntegrationClient: @Sendable (String) -> MarketplaceClientIdentity?
}
