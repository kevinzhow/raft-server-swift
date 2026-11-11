import Foundation

/// Published refusals of the `/api/raftbench` surface.
public enum RaftBenchError: DomainError, Equatable {
    case unauthenticated
    case missingServerHeader
    case notAMember
    case serverNotAllowed
    case disabled
    case invalidPage
    case invalidSettings
    case invalidAgentSettings
    case invalidAssignment

    public var status: UInt {
        switch self {
        case .unauthenticated: 401
        case .serverNotAllowed, .notAMember, .disabled: 403
        case .missingServerHeader, .invalidPage, .invalidSettings,
             .invalidAgentSettings, .invalidAssignment: 400
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthenticated: "Unauthorized"
        case .missingServerHeader: "Missing X-Server-Id header"
        case .notAMember: "Not a member of this server"
        case .serverNotAllowed: "RaftBench is unavailable on this server or deployment."
        case .disabled: "RaftBench is unavailable on this server."
        case .invalidPage: "Invalid result page"
        case .invalidSettings: "Invalid RaftBench settings"
        case .invalidAgentSettings: "Invalid RaftBench agent settings"
        case .invalidAssignment: "Invalid RaftBench assignment"
        }
    }

    public var errorCode: String? {
        switch self {
        case .serverNotAllowed: "raftbench_server_not_allowed"
        case .disabled: "raftbench_disabled"
        default: nil
        }
    }
}

/// `/api/raftbench` request authority and validation.
///
/// Upstream registers the routes in every deployment
/// (`app.ts:741`, `routes/raftbench.ts`) and refuses them inside the handler:
/// `requirePilot` answers 403 `raftbench_server_not_allowed` unless
/// `DEPLOYMENT_ENV=staging` and the server is in the fixed pilot set. This
/// deployment is not staging, so every authenticated, member-scoped call takes
/// that published refusal. The request validators run in the same order as
/// upstream: after the auth/server middleware, before the pilot gate.
///
/// D19 keeps the synthetic-analysis engine out of the port. An enrolled
/// staging server would still answer 403 `raftbench_disabled` here rather than
/// fabricate a dashboard.
public struct RaftBenchService: Sendable {
    /// `raftbench/contract.ts:5-9` (canary enrollment is additive).
    static let pilotServerIds: Set<String> = [
        "4fc662e7-6626-4f59-a16d-3a224cd54acf",
        "95f993fa-2a68-4797-b8ae-7beb7d984ada",
        "90623df1-20ed-4321-88a1-e4e2b411a252",
    ]

    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let environment: [String: String]

    init(
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        environment: [String: String] = [:]
    ) {
        self.profiles = profiles
        self.oauth = oauth
        self.environment = environment
    }

    /// `requireAuth` + `requireServer` ([`routes/raftbench.ts`] runs under
    /// `requireAuth, requireVerified, requireServer`).
    public func authorize(authorization: String?, serverId: String) throws {
        guard let authorization, authorization.hasPrefix("Bearer "),
              profiles.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count))) != nil
        else { throw RaftBenchError.unauthenticated }
        guard !serverId.isEmpty else { throw RaftBenchError.missingServerHeader }
        guard oauth.memberRole(serverId: serverId, userId: signedInUser(authorization)) != nil,
              oauth.serverProfile(id: serverId) != nil else { throw RaftBenchError.notAMember }
    }

    private func signedInUser(_ authorization: String) -> String {
        profiles.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count))) ?? ""
    }

    /// `requirePilot` (`raftbench/service.ts:31-33`) plus the D19 engine gap.
    public func refuseUnlessEnrolled(serverId: String) throws -> Never {
        let staging = environment["DEPLOYMENT_ENV"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "staging"
        let canary = environment["RAFTBENCH_CANARY_SERVER_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pilot = staging && (Self.pilotServerIds.contains(serverId.lowercased()) || canary == serverId.lowercased())
        if pilot { throw RaftBenchError.disabled }
        throw RaftBenchError.serverNotAllowed
    }

    // MARK: - Request validation

    public func validateDashboardPage(_ raw: String?) throws {
        let page = raw ?? "1"
        guard page.wholeMatch(of: /^[1-9][0-9]{0,3}$/) != nil else { throw RaftBenchError.invalidPage }
    }

    public func validateConfigure(_ body: String?) throws {
        try Self.decode(Self.ConfigureBody.self, from: body, error: .invalidSettings)
    }

    public func validateAgentSettings(_ body: String?) throws {
        // `req.body ?? {}` upstream: an absent body is the empty settings object.
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        try Self.decode(Self.AgentSettingsBody.self, from: trimmed, error: .invalidAgentSettings)
    }

    public func validateAssignment(_ body: String?) throws {
        try Self.decode(Self.AssignmentBody.self, from: body, error: .invalidAssignment)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from body: String?, error: RaftBenchError) throws {
        guard let body, let data = body.data(using: .utf8),
              (try? JSONDecoder().decode(type, from: data)) != nil else { throw error }
    }

    // MARK: - Pinned shapes

    private struct CodingKeyBox: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func key(_ name: String) -> CodingKeyBox { CodingKeyBox(name) }

    private static func isUUID(_ value: String) -> Bool {
        value.wholeMatch(of: /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) != nil
    }

    /// `z.string().datetime()` default: RFC 3339 with a `Z` suffix.
    private static func isDateTime(_ value: String) -> Bool {
        guard value.hasSuffix("Z") else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    /// `configureSchema` (`raftbench/contract.ts:18-24`), `.strict()`.
    private struct ConfigureBody: Decodable {
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeyBox.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            let allowed: Set<String> = ["enabled", "channelIds", "expectedRevision", "historyFrom", "providerTarget"]
            guard keys.isSubset(of: allowed),
                  keys.contains("enabled"), keys.contains("channelIds"), keys.contains("expectedRevision")
            else { throw RaftBenchError.invalidSettings }
            _ = try container.decode(Bool.self, forKey: RaftBenchService.key("enabled"))
            let revision = try container.decode(Int.self, forKey: RaftBenchService.key("expectedRevision"))
            guard revision >= 0 else { throw RaftBenchError.invalidSettings }
            let channelIds = try container.decode([String].self, forKey: RaftBenchService.key("channelIds"))
            guard (1...50).contains(channelIds.count),
                  channelIds.allSatisfy(RaftBenchService.isUUID) else { throw RaftBenchError.invalidSettings }
            if keys.contains("historyFrom") {
                let raw = try container.decode(String.self, forKey: RaftBenchService.key("historyFrom"))
                guard RaftBenchService.isDateTime(raw) else { throw RaftBenchError.invalidSettings }
            }
            if keys.contains("providerTarget") {
                let raw = try container.decode(String.self, forKey: RaftBenchService.key("providerTarget"))
                guard raw == "default" || raw == "canary" else { throw RaftBenchError.invalidSettings }
            }
        }
    }

    /// `z.object({ providerTarget: z.enum(["default","canary"]).optional() }).strict()`.
    private struct AgentSettingsBody: Decodable {
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeyBox.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            guard keys.isSubset(of: ["providerTarget"]) else { throw RaftBenchError.invalidAgentSettings }
            if keys.contains("providerTarget") {
                let raw = try container.decode(String.self, forKey: RaftBenchService.key("providerTarget"))
                guard raw == "default" || raw == "canary" else { throw RaftBenchError.invalidAgentSettings }
            }
        }
    }

    /// `PUT /api/raftbench/assignment` body (`routes/raftbench.ts:17`), `.strict()`.
    private struct AssignmentBody: Decodable {
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeyBox.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            let allowed: Set<String> = ["agentId", "expectedRevision", "channelIds", "historyFrom"]
            guard keys.isSubset(of: allowed), keys.contains("agentId"), keys.contains("expectedRevision")
            else { throw RaftBenchError.invalidAssignment }
            let agentId = try container.decode(String.self, forKey: RaftBenchService.key("agentId"))
            guard RaftBenchService.isUUID(agentId) else { throw RaftBenchError.invalidAssignment }
            let revision = try container.decode(Int.self, forKey: RaftBenchService.key("expectedRevision"))
            guard revision >= 0 else { throw RaftBenchError.invalidAssignment }
            if keys.contains("channelIds") {
                let ids = try container.decode([String].self, forKey: RaftBenchService.key("channelIds"))
                guard (1...50).contains(ids.count),
                      ids.allSatisfy(RaftBenchService.isUUID) else { throw RaftBenchError.invalidAssignment }
            }
            if keys.contains("historyFrom") {
                let raw = try container.decode(String.self, forKey: RaftBenchService.key("historyFrom"))
                guard RaftBenchService.isDateTime(raw) else { throw RaftBenchError.invalidAssignment }
            }
        }
    }
}
