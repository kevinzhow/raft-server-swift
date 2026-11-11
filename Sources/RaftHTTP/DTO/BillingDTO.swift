import Foundation

/// `GET /api/billing/subscription` capacity projection
/// (`packages/shared/src/index.ts:3976-3980`, `4245-4263`).
public struct BillingCapacityDTO: Codable, Sendable, Equatable {
    public var maxHumans: Int
    public var maxAgents: Int
    public var maxUniversalSeats: Int

    public init(maxHumans: Int, maxAgents: Int, maxUniversalSeats: Int) {
        self.maxHumans = maxHumans
        self.maxAgents = maxAgents
        self.maxUniversalSeats = maxUniversalSeats
    }
}

/// `getBillingUsage` (`packages/shared/src/index.ts:4265-4273`). The universal
/// seat total is a real number because one agent seat is 1/10 of a seat.
public struct BillingUsageDTO: Codable, Sendable, Equatable {
    public var humans: Int
    public var agents: Int
    public var universalSeats: Double

    public init(humans: Int, agents: Int, universalSeats: Double) {
        self.humans = humans
        self.agents = agents
        self.universalSeats = universalSeats
    }

    public static func from(humans: Int, agents: Int) -> BillingUsageDTO {
        BillingUsageDTO(
            humans: humans,
            agents: agents,
            universalSeats: Double(humans) + Double(agents) / 10
        )
    }
}

/// `fileUploadQuota` in the billing summary
/// (`services/fileUploadQuotaService.ts:9-20,86-102`).
public struct BillingFileUploadQuotaDTO: Codable, Sendable, Equatable {
    public var month: String
    public var plan: String
    public var limited: Bool
    public var enforced: Bool
    public var limitBytes: Int
    public var usedBytes: Int
    public var reservedBytes: Int
    public var remainingBytes: Int

    public init(
        month: String, plan: String, limited: Bool, enforced: Bool, limitBytes: Int,
        usedBytes: Int, reservedBytes: Int, remainingBytes: Int
    ) {
        self.month = month
        self.plan = plan
        self.limited = limited
        self.enforced = enforced
        self.limitBytes = limitBytes
        self.usedBytes = usedBytes
        self.reservedBytes = reservedBytes
        self.remainingBytes = remainingBytes
    }
}

/// `provisioned` in the billing summary. `firstPackTrialEndsAt` is published
/// as `null` when absent, so the encoder writes the key explicitly.
public struct BillingProvisionedDTO: Codable, Sendable, Equatable {
    public var humans: Int
    public var agents: Int
    public var proPackQuantity: Int
    public var trialFreePackQuantity: Int
    public var firstPackTrialEndsAt: String?

    public init(
        humans: Int, agents: Int, proPackQuantity: Int,
        trialFreePackQuantity: Int, firstPackTrialEndsAt: String? = nil
    ) {
        self.humans = humans
        self.agents = agents
        self.proPackQuantity = proPackQuantity
        self.trialFreePackQuantity = trialFreePackQuantity
        self.firstPackTrialEndsAt = firstPackTrialEndsAt
    }

    private enum CodingKeys: String, CodingKey {
        case humans, agents, proPackQuantity, trialFreePackQuantity, firstPackTrialEndsAt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(humans, forKey: .humans)
        try container.encode(agents, forKey: .agents)
        try container.encode(proPackQuantity, forKey: .proPackQuantity)
        try container.encode(trialFreePackQuantity, forKey: .trialFreePackQuantity)
        if let firstPackTrialEndsAt {
            try container.encode(firstPackTrialEndsAt, forKey: .firstPackTrialEndsAt)
        } else {
            try container.encodeNil(forKey: .firstPackTrialEndsAt)
        }
    }
}

public struct BillingPermissionsDTO: Codable, Sendable, Equatable {
    public var canReadBillingSummary: Bool
    public var canManageBilling: Bool

    public init(canReadBillingSummary: Bool, canManageBilling: Bool) {
        self.canReadBillingSummary = canReadBillingSummary
        self.canManageBilling = canManageBilling
    }
}

/// The price summary `priceForSummary` returns for a paid plan. This port has
/// no Stripe subscription, so the summary publishes `null`; the shape exists
/// so the key is always present.
public struct BillingPriceDTO: Codable, Sendable, Equatable {
    public var billingInterval: String
    public var monthlyUsd: Double
    public var annualUsd: Double?
    public var discountPercent: Double
    public var baseMonthlyUsd: Double
    public var overageMonthlyUsd: Double
    public var seatQuantity: Int
    public var packQuantity: Int
    public var humanSeatQuantity: Int
    public var agentSeatQuantity: Int
    public var agentSeatBlockQuantity: Int

    public init(
        billingInterval: String, monthlyUsd: Double, annualUsd: Double?, discountPercent: Double,
        baseMonthlyUsd: Double, overageMonthlyUsd: Double, seatQuantity: Int, packQuantity: Int,
        humanSeatQuantity: Int, agentSeatQuantity: Int, agentSeatBlockQuantity: Int
    ) {
        self.billingInterval = billingInterval
        self.monthlyUsd = monthlyUsd
        self.annualUsd = annualUsd
        self.discountPercent = discountPercent
        self.baseMonthlyUsd = baseMonthlyUsd
        self.overageMonthlyUsd = overageMonthlyUsd
        self.seatQuantity = seatQuantity
        self.packQuantity = packQuantity
        self.humanSeatQuantity = humanSeatQuantity
        self.agentSeatQuantity = agentSeatQuantity
        self.agentSeatBlockQuantity = agentSeatBlockQuantity
    }
}

public struct BillingSubscriptionDTO: Codable, Sendable, Equatable {
    public var status: String
    public var billingInterval: String
    public var currentPeriodStart: String
    public var currentPeriodEnd: String
    public var cancelAtPeriodEnd: Bool

    public init(
        status: String, billingInterval: String, currentPeriodStart: String,
        currentPeriodEnd: String, cancelAtPeriodEnd: Bool
    ) {
        self.status = status
        self.billingInterval = billingInterval
        self.currentPeriodStart = currentPeriodStart
        self.currentPeriodEnd = currentPeriodEnd
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
    }
}

/// `GET /api/billing/subscription` (`routes/billing.ts:229-248`).
///
/// The body spreads the billing summary and appends `permissions`. `price` and
/// `subscription` are always present and nullable.
public struct BillingSummaryResponse: Codable, Sendable, Equatable {
    public var plan: String
    public var displayName: String
    public var serverPlan: String
    public var source: String
    public var capacity: BillingCapacityDTO
    public var usage: BillingUsageDTO
    public var fileUploadQuota: BillingFileUploadQuotaDTO
    public var provisioned: BillingProvisionedDTO
    public var price: BillingPriceDTO?
    public var subscription: BillingSubscriptionDTO?
    public var stripeConfigured: Bool
    public var permissions: BillingPermissionsDTO

    public init(
        plan: String, displayName: String, serverPlan: String, source: String,
        capacity: BillingCapacityDTO, usage: BillingUsageDTO,
        fileUploadQuota: BillingFileUploadQuotaDTO, provisioned: BillingProvisionedDTO,
        price: BillingPriceDTO? = nil, subscription: BillingSubscriptionDTO? = nil,
        stripeConfigured: Bool, permissions: BillingPermissionsDTO
    ) {
        self.plan = plan
        self.displayName = displayName
        self.serverPlan = serverPlan
        self.source = source
        self.capacity = capacity
        self.usage = usage
        self.fileUploadQuota = fileUploadQuota
        self.provisioned = provisioned
        self.price = price
        self.subscription = subscription
        self.stripeConfigured = stripeConfigured
        self.permissions = permissions
    }

    private enum CodingKeys: String, CodingKey {
        case plan, displayName, serverPlan, source, capacity, usage, fileUploadQuota,
             provisioned, price, subscription, stripeConfigured, permissions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(plan, forKey: .plan)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(serverPlan, forKey: .serverPlan)
        try container.encode(source, forKey: .source)
        try container.encode(capacity, forKey: .capacity)
        try container.encode(usage, forKey: .usage)
        try container.encode(fileUploadQuota, forKey: .fileUploadQuota)
        try container.encode(provisioned, forKey: .provisioned)
        if let price {
            try container.encode(price, forKey: .price)
        } else {
            try container.encodeNil(forKey: .price)
        }
        if let subscription {
            try container.encode(subscription, forKey: .subscription)
        } else {
            try container.encodeNil(forKey: .subscription)
        }
        try container.encode(stripeConfigured, forKey: .stripeConfigured)
        try container.encode(permissions, forKey: .permissions)
    }
}
