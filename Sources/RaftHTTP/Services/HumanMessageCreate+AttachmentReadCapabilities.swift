import Foundation

/// The two small attachment capability reads use the existing human-message
/// service's actual profile, server-authority and runtime-flag owners. No new
/// state, network probe or upload-session owner is introduced.
extension HumanMessageCreateService {
    /// Pinned config/attachmentPreviewUnified.ts: an absent flag defaults on;
    /// an existing flag uses its actual caller/server decision, including denial
    /// and kill switch. This is configuration, not a preview-format guarantee.
    public func attachmentPreviewAvailability(
        authorization: String?, serverId: String?
    ) throws -> AttachmentPreviewAvailabilityResponse {
        let scope = try attachmentReadScope(authorization: authorization, serverId: serverId)
        let evaluation = agents.evaluateFeatureFlag(
            key: "attachment_preview_unified_v0", userId: scope.userId,
            serverId: scope.serverId, platform: nil,
            client: FeatureFlagClientFacts(os: nil, buildNumber: nil, buildType: nil)
        )
        return .init(enabled: evaluation.reason == "missing_flag" ? true : evaluation.enabled)
    }

    /// Exact pinned attachmentUploadSessions router branch when service is nil.
    /// Auth -> verified profile -> server membership -> channel UUID syntax ->
    /// empty recovery list. It intentionally does not query resource ACLs or
    /// invent records: this source has no durable direct-upload service/writer.
    public func absentAttachmentUploadRecovery(
        channelId: String, authorization: String?, serverId: String?
    ) throws -> AbsentAttachmentUploadRecoveryResponse {
        _ = try attachmentReadScope(authorization: authorization, serverId: serverId)
        // Shared Node contract uses z.uuid(): RFC UUID versions 1-8 plus the
        // RFC nil/max UUIDs, not just a five-part hexadecimal shape.
        let value = channelId.lowercased()
        let special = value == "00000000-0000-0000-0000-000000000000"
            || value == "ffffffff-ffff-ffff-ffff-ffffffffffff"
        guard special || value.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil else {
            throw AttachmentReadCapabilitiesError.invalidChannelId
        }
        return AbsentAttachmentUploadRecoveryResponse()
    }

    private func attachmentReadScope(
        authorization: String?, serverId: String?
    ) throws -> (userId: String, serverId: String) {
        // Reuse the pinned human admission policy against the retained profile
        // owner; direct service calls keep the same order as HTTP admission.
        let identity = try AuthCoreService(store: profiles).admitHuman(authorization: authorization)
        guard let serverId, !serverId.isEmpty else {
            throw AttachmentReadCapabilitiesError.missingServerIdHeader
        }
        guard oauth.activeRegularServerMember(serverId: serverId, userId: identity.userId) else {
            throw AttachmentReadCapabilitiesError.notAServerMember
        }
        return (identity.userId, serverId)
    }
}
