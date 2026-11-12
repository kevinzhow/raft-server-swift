/// Shared header/principal preconditions of pinned middleware/auth.ts:734-755.
public enum AgentCredentialAuthError: DomainError, Equatable {
    case missingCredential
    case invalidPrincipal

    public var status: UInt { 401 }
    public var errorMessage: String {
        switch self {
        case .missingCredential: "Missing agent credential"
        case .invalidPrincipal: "Invalid authentication: agent credential required"
        }
    }
    public var errorCode: String? { self == .invalidPrincipal ? "invalid_principal" : nil }
}
