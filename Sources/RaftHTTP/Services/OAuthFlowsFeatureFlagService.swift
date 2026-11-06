import Foundation
import RaftShared

/// `POST /api/feature-flags/evaluate` (pure move out of `OAuthFlowsService`).
/// Admin flag routes are not mounted. The flag rows and rules live in
/// `AgentsRuntimeStore`; the whole key list is evaluated in one critical
/// section there.
extension OAuthFlowsService {
    public func evaluateFeatureFlags(
        _ body: FeatureFlagsEvaluateRequest,
        authorization: String?
    ) throws -> FeatureFlagEvaluations {
        let userId = try authorizedUser(authorization)
        guard store.isEmailVerified(userId: userId) else {
            throw OAuthFlowsError.emailVerificationRequired
        }
        let rawKeys: [JSONValue]
        if let keys = body.keys {
            rawKeys = keys
        } else if let key = body.key {
            rawKeys = [.string(key)]
        } else {
            rawKeys = []
        }
        let parsed = rawKeys.map(Self.featureFlagKey)
        if parsed.isEmpty || parsed.count > 50 || parsed.contains(where: { $0 == nil }) {
            throw OAuthFlowsError.featureFlagKeysInvalid
        }
        var serverId: String?
        switch body.serverId {
        case .absent:
            break
        case .value(let value):
            guard ServerScope.isUUID(value) else { throw OAuthFlowsError.featureFlagServerIdInvalid }
            serverId = value
        case .invalid:
            throw OAuthFlowsError.featureFlagServerIdInvalid
        }
        if let serverId, oauth.memberRole(serverId: serverId, userId: userId) == nil {
            throw OAuthFlowsError.notAServerMember
        }
        var platform: String?
        switch body.platform {
        case .absent:
            break
        case .value(let value):
            guard value == "web" || value == "mobile" else { throw OAuthFlowsError.featureFlagPlatformInvalid }
            platform = value
        case .invalid:
            throw OAuthFlowsError.featureFlagPlatformInvalid
        }
        let unique = parsed.compactMap { $0 }.reduce(into: [String]()) { list, key in
            if !list.contains(key) { list.append(key) }
        }
        let evaluations = flags.evaluateFeatureFlags(
            keys: unique,
            userId: userId,
            serverId: serverId,
            platform: platform,
            client: Self.clientFacts(body)
        )
        return FeatureFlagEvaluations(evaluations: evaluations.map {
            FeatureFlagEvaluation(key: $0.key, enabled: $0.enabled, reason: $0.reason)
        })
    }

    /// A key is a trimmed lowercase slug of 1-128 characters; any other value,
    /// a non-string included, is invalid.
    static func featureFlagKey(_ value: JSONValue) -> String? {
        guard case .string(let string) = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.wholeMatch(of: /^[a-z0-9][a-z0-9_.-]{0,127}$/) != nil else { return nil }
        return trimmed
    }

    /// Client facts only narrow a client rule; an unknown value reads as absent
    /// and never fails the request.
    static func clientFacts(_ body: FeatureFlagsEvaluateRequest) -> FeatureFlagClientFacts {
        let osValues: Set<String> = ["android", "ios", "ohos"]
        let buildTypes: Set<String> = ["release", "alpha", "debug"]
        let os = body.os.flatMap { osValues.contains($0) ? $0 : nil }
        let buildType = body.buildType.flatMap { buildTypes.contains($0) ? $0 : nil }
        var buildNumber: Int?
        switch body.buildNumber {
        case .string(let string):
            if string.wholeMatch(of: /^[0-9]{1,15}$/) != nil { buildNumber = Int(string) }
        case .integer(let number):
            if number >= 0 { buildNumber = Int(exactly: number) }
        case .number(let number):
            if number >= 0, number.rounded() == number { buildNumber = Int(exactly: number) }
        default:
            break
        }
        return FeatureFlagClientFacts(os: os, buildNumber: buildNumber, buildType: buildType)
    }
}
