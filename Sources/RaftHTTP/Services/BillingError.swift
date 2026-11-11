import Foundation

/// Published refusals of the `/api/billing` surface (`routes/billing.ts`).
public enum BillingError: DomainError, Equatable {
    case unauthenticated
    case missingServerHeader
    case notAMember
    case summaryForbidden
    case hostedSpendForbidden
    case hostedSpendNotEnabled
    case notConfigured

    public var status: UInt {
        switch self {
        case .unauthenticated: 401
        case .missingServerHeader: 400
        case .notAMember, .summaryForbidden, .hostedSpendForbidden: 403
        case .hostedSpendNotEnabled: 404
        case .notConfigured: 503
        }
    }

    public var errorMessage: String {
        switch self {
        case .unauthenticated: "Unauthorized"
        case .missingServerHeader: "Missing X-Server-Id header"
        case .notAMember: "Not a member of this server"
        case .summaryForbidden: "Only server owners and admins can view billing"
        case .hostedSpendForbidden: "Only server owners and admins can view cloud agent spend"
        case .hostedSpendNotEnabled: "This server has no cloud agents"
        case .notConfigured: "Billing is not configured"
        }
    }

    public var errorCode: String? {
        switch self {
        case .hostedSpendForbidden: "hosted_runtime_spend_forbidden"
        case .hostedSpendNotEnabled: "hosted_runtime_spend_not_enabled"
        default: nil
        }
    }
}
