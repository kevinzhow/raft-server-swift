/// Shared header precondition of pinned middleware/auth.ts:734-742. A human
/// session error is not the missing-credential response of an Agent surface.
public enum AgentCredentialAuthError: DomainError, Equatable {
    case missingCredential

    public var status: UInt { 401 }
    public var errorMessage: String { "Missing agent credential" }
}
