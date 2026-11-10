/// The admission attached to a pinned Node route. Recovery routes have no
/// requirement; accepting an invite requires a handle but not verified email.
public enum HumanAdmissionRequirement: Sendable, Equatable {
    case verifiedProfile
    /// Legacy attachment writes authenticate and verify email before scope;
    /// their feature checks profile completeness after the scope boundary.
    case verifiedAccount
    case profileOnly
}

/// Current authenticated account identity, after the required account checks.
public struct HumanAdmissionIdentity: Sendable, Equatable {
    public let userId: String
}

/// Exact requireAuth -> current account -> email -> handle refusals.
/// DomainError's default projection keeps error before code.
public enum HumanAdmissionError: DomainError, Equatable {
    case missingAuthorization
    case invalidToken
    case emailVerificationRequired
    case profileSetupRequired

    public var status: UInt {
        switch self {
        case .missingAuthorization, .invalidToken: 401
        case .emailVerificationRequired, .profileSetupRequired: 403
        }
    }

    // app.ts applies this default before the authenticated route mounts.
    // Admission can return before a handler supplies its own cache policy.
    public var responseHeaders: [String: String] {
        ["Cache-Control": "private, no-store"]
    }

    public var errorMessage: String {
        switch self {
        case .missingAuthorization: "Missing or invalid Authorization header"
        case .invalidToken: "Invalid or expired token"
        case .emailVerificationRequired: "Email verification required"
        case .profileSetupRequired: "Profile setup required"
        }
    }

    public var errorCode: String? {
        switch self {
        case .missingAuthorization, .invalidToken: "auth_required"
        case .emailVerificationRequired: nil
        case .profileSetupRequired: "PROFILE_SETUP_REQUIRED"
        }
    }
}
