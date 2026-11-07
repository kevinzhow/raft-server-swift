/// A fully parsed installation mint attempt. HTTP spelling and authentication
/// header precedence belong to the integration service, before the transaction.
struct InstallationMintAttempt: Sendable {
    let clientId: String
    let clientSecret: String
    let installationId: String
}

/// The live-state decisions and receipt from one OAuth owner transaction.
/// No HTTP error, header policy or response DTO crosses this boundary.
enum InstallationMintOutcome: Sendable {
    case invalidClient
    case installationUnavailable
    case noEffectiveGroups
    case issued(InstallationMintReceipt)
}

struct InstallationMintReceipt: Sendable {
    let accessToken: String
    let installationId: String
    let serverId: String
    let grantRevision: Int
    let groups: [String]
}

/// A copy of the credential facts verified under the OAuth owner lock. Query
/// authority is selected by the service after that lock has been released.
struct InstallationCredentialFacts: Sendable {
    let installationId: String
    let clientId: String
    let serverId: String
    let groups: [String]
}

struct InstallationServerFacts: Sendable {
    let id: String
    let name: String
    let slug: String
}
