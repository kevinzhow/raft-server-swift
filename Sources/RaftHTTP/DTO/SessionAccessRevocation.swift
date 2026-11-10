/// Actual account/session revocation facts returned by the retained auth owner.
/// Consumers publish after commit; this value never decides authorization.
public enum SessionAccessRevocation: Sendable {
    case user(userId: String)
    case family(userId: String, familyId: String)
}
