import Foundation

/// The `/api/billing` surface as the Web consumes it.
///
/// This deployment has no Stripe credentials. The mutating routes therefore
/// publish the upstream unconfigured refusal (`routes/billing.ts` returns 503
/// `{"error":"Billing is not configured"}` before any role or body check), while
/// `GET /subscription` keeps returning the real retained server plan and usage
/// with `stripeConfigured: false` and `subscription: null`. No plan, price or
/// subscription fact is invented: the summary is projected from the OAuth
/// ledger's server plan and live member/agent rows.
public struct BillingService: Sendable {
    private static let freeMonthlyUploadLimitBytes = 100 * 1024 * 1024
    private static let trialStart = Date(timeIntervalSince1970: 1_776_470_400) // 2026-04-18T00:00:00Z
    private static let trialEnd = Date(timeIntervalSince1970: 1_782_216_000)   // 2026-06-23T12:00:00Z

    private let profiles: AuthProfileStore
    private let oauth: OAuthLedger
    private let now: @Sendable () -> Date

    init(
        profiles: AuthProfileStore,
        oauth: OAuthLedger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profiles = profiles
        self.oauth = oauth
        self.now = now
    }

    // MARK: - Provider state

    /// `isStripeConfigured` (`services/billingService.ts:76-91`) requires the
    /// explicit flag plus all four credentials.
    public static func stripeConfigured(environment: [String: String]) -> Bool {
        func present(_ key: String) -> Bool {
            !(environment[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard environment["STRIPE_BILLING_ENABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" else { return false }
        return ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET",
                "STRIPE_PRO_SEAT_MONTHLY_PRICE_ID", "STRIPE_PRO_SEAT_ANNUAL_PRICE_ID"].allSatisfy(present)
    }

    /// Checkout, cancel, portal and seat-quantity all begin with the upstream
    /// `isStripeConfigured` gate. This deployment has no provider integration,
    /// so the disabled contract is the published refusal even if the
    /// environment is populated (documented in docs/DEVIATIONS).
    public func requireConfiguredProvider() throws -> Never {
        throw BillingError.notConfigured
    }

    // MARK: - GET /api/billing/subscription

    public func summary(
        authorization: String?,
        serverId: String,
        stripeConfigured: Bool
    ) throws -> BillingSummaryResponse {
        let member = try self.member(authorization: authorization, serverId: serverId)
        guard member.role == "owner" || member.role == "admin" else {
            throw BillingError.summaryForbidden
        }
        guard let server = oauth.serverProfile(id: serverId) else { throw BillingError.notAMember }

        let roleRows = oauth.memberRoles(serverId: serverId).filter { $0.role != "guest" }
        let agentCount = oauth.serverAgents(serverId: serverId).count
        let usage = BillingUsageDTO.from(humans: roleRows.count, agents: agentCount)
        let plan = server.plan
        let moment = now()
        let quota = Self.fileUploadQuota(plan: plan, now: moment)
        return BillingSummaryResponse(
            plan: plan,
            displayName: Self.displayName(plan),
            serverPlan: plan,
            source: "server",
            capacity: Self.capacity(plan: plan, proPackQuantity: 0),
            usage: usage,
            fileUploadQuota: quota,
            provisioned: BillingProvisionedDTO(
                humans: usage.humans,
                agents: usage.agents,
                proPackQuantity: 0,
                trialFreePackQuantity: 0
            ),
            price: nil,
            subscription: nil,
            stripeConfigured: stripeConfigured,
            permissions: BillingPermissionsDTO(
                canReadBillingSummary: true,
                canManageBilling: member.role == "owner"
            )
        )
    }

    // MARK: - GET /api/billing/hosted-runtime-usage

    /// The route is not Stripe-gated. The kill switch / hosted-provision facts
    /// are absent in this deployment, so a reader gets the published 404 that
    /// hides the Plan card; a non-reader keeps the typed 403.
    public func hostedRuntimeUsage(authorization: String?, serverId: String) throws -> Never {
        let member = try self.member(authorization: authorization, serverId: serverId)
        guard member.role == "owner" || member.role == "admin" else {
            throw BillingError.hostedSpendForbidden
        }
        throw BillingError.hostedSpendNotEnabled
    }

    // MARK: - Shared request scope

    private func member(authorization: String?, serverId: String) throws -> (userId: String, role: String) {
        guard let authorization, authorization.hasPrefix("Bearer "),
              let userId = profiles.userId(forAccessToken: String(authorization.dropFirst("Bearer ".count)))
        else { throw BillingError.unauthenticated }
        guard !serverId.isEmpty else { throw BillingError.missingServerHeader }
        guard let role = oauth.memberRole(serverId: serverId, userId: userId),
              oauth.serverProfile(id: serverId) != nil else { throw BillingError.notAMember }
        return (userId, role)
    }

    // MARK: - Projections

    static func displayName(_ plan: String) -> String {
        switch plan {
        case "founder": "Founder"
        case "partner": "Partner"
        case "pro": "Pro"
        default: "Free"
        }
    }

    static func capacity(plan: String, proPackQuantity: Int) -> BillingCapacityDTO {
        switch plan {
        case "founder", "partner":
            return BillingCapacityDTO(maxHumans: -1, maxAgents: -1, maxUniversalSeats: -1)
        case "pro":
            return BillingCapacityDTO(maxHumans: -1, maxAgents: -1, maxUniversalSeats: max(1, proPackQuantity))
        default:
            // PLAN_CONFIG.free.limits: unlimited humans and agents.
            return BillingCapacityDTO(maxHumans: -1, maxAgents: -1, maxUniversalSeats: -1)
        }
    }

    static func fileUploadQuota(plan: String, now: Date) -> BillingFileUploadQuotaDTO {
        let limited = plan == "free"
        let trialActive = now >= trialStart && now < trialEnd
        let limitBytes = limited ? freeMonthlyUploadLimitBytes : -1
        return BillingFileUploadQuotaDTO(
            month: usageMonth(now),
            plan: plan,
            limited: limited,
            enforced: limited && !trialActive,
            limitBytes: limitBytes,
            usedBytes: 0,
            reservedBytes: 0,
            remainingBytes: limited ? limitBytes : -1
        )
    }

    static func usageMonth(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d", parts.year ?? 1970, parts.month ?? 1)
    }
}
