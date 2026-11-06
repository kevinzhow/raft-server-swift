import Foundation
import Synchronization

/// One issued email-verification token.
///
/// `rawToken` is retained so the in-process acceptance seam can hand the token
/// back without an email transport; no HTTP handler ever exposes it.
struct EmailVerificationRecord: Sendable, Equatable {
    public let userId: String
    public let tokenHash: String
    public let rawToken: String
    public let createdAt: Date
    public let expiresAt: Date
}

/// Result of the locked resend policy. The store decides; the service maps a
/// refusal to its published `AuthVerificationError`.
enum IssueOutcome: Equatable, Sendable {
    case issued
    case tooManyRequests
    case cooldown
}

/// Result of the locked reset-token consume-and-write. The store decides; the
/// service maps a refusal to its published `AuthProfileError`.
enum ResetPasswordOutcome: Equatable, Sendable {
    case reset
    case invalidOrExpiredToken
}

/// Owns account-profile ledgers: linked identities, password-reset tokens,
/// email-verification tokens and legal acceptances. HTTP/session/account
/// decisions stay in `EmailLoginDirectory`; this store serializes only its own
/// rows and returns strong Swift values, never JSON or `HTTPReply`.
final class AuthProfileStore: Sendable {
    /// Profile surface rows that used to be stored inline on
    /// `EmailLoginDirectory`: timezone history and the
    /// mobile-app lifecycle email audience.
    struct ProfileState: Sendable {
        var timezoneObservations: [String: TimezoneObservation] = [:]
        var mobileAppEmailContactsByKey: [String: MobileAppEmailContact] = [:]
        var storedMobileAppEmailJourneys: [MobileAppEmailJourney] = []
    }

    /// All mutable rows share one Mutex so cross-ledger decisions remain atomic.
    struct State: Sendable {
        var profile = ProfileState()
        var identityRows: [String: [(provider: String, providerEmail: String)]] = [:]
        var passwordResetTokens: [String: (userId: String, expiresAt: Date)] = [:]
        var legalAcceptances: [String: EmailLegalAcceptance] = [:]
        /// Replacing a live token does not erase the hourly issue history.
        var emailVerificationTokens: [String: [EmailVerificationRecord]] = [:]
        var emailVerificationIssueDates: [String: [Date]] = [:]
        var accountSurface = AccountState()
        var seamSurface = SeamState()
        var configSurface = ConfigState()
    }

    /// Shared by the store's file extensions; every access borrows state via withLock.
    let state = Mutex(State())

    func appendIdentity(userId: String, provider: String, providerEmail: String) {
        state.withLock { state in
            state.identityRows[userId, default: []].append((provider, providerEmail))
        }
    }

    func identityCount(userId: String) -> Int {
        return state.withLock { state in
            return state.identityRows[userId]?.count ?? 0
        }
    }

    func resetToken(hash: String) -> (userId: String, expiresAt: Date)? {
        return state.withLock { state in
            return state.passwordResetTokens[hash]
        }
    }

    func removeResetToken(hash: String) {
        state.withLock { state in
            _ = state.passwordResetTokens.removeValue(forKey: hash)
        }
    }

    func setResetToken(hash: String, userId: String, expiresAt: Date) {
        state.withLock { state in
            state.passwordResetTokens[hash] = (userId, expiresAt)
        }
    }

    /// Mints a password-reset token for a known address. The normalized
    /// account lookup and the insert are one critical section, so the token
    /// always names a row that existed when it was written. An unknown
    /// address stays a silent no-op and returns `false`.
    @discardableResult
    func insertResetTokenIfAccountExists(
        email: String,
        tokenHash: String,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        return state.withLock { state in
            guard let account = state.accountSurface.accounts[AccountNaming.normalize(email)] else {
                return false
            }
            state.passwordResetTokens[tokenHash] = (account.id, now.addingTimeInterval(ttl))
            return true
        }
    }

    /// Spends one reset token and writes the new password in one critical
    /// section. A missing or expired token writes nothing; two concurrent
    /// resets therefore cannot both consume the row.
    func consumeResetToken(
        tokenHash: String,
        passwordHash: String,
        now: Date
    ) -> ResetPasswordOutcome {
        return state.withLock { state in
            guard let reset = state.passwordResetTokens[tokenHash], reset.expiresAt > now,
                  let email = state.accountSurface.accounts.first(where: { $0.value.id == reset.userId })?.key
            else {
                return .invalidOrExpiredToken
            }
            state.passwordResetTokens.removeValue(forKey: tokenHash)
            state.accountSurface.accounts[email]?.passwordHash = passwordHash
            state.accountSurface.accounts[email]?.passwordCredentialEstablishedAt = now
            return .reset
        }
    }

    /// Cancels one pending social link. Unknown, already-cancelled and expired
    /// tokens are the same no-op; the route answers 204 either way.
    func markPendingSocialLinkCancelled(token: String) {
        return state.withLock { state in
            guard var pending = state.accountSurface.pendingSocialLinks[token] else { return }
            pending.cancelled = true
            state.accountSurface.pendingSocialLinks[token] = pending
        }
    }

    var legalAcceptanceCount: Int {
        return state.withLock { state in
            return state.legalAcceptances.count
        }
    }

    func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        return state.withLock { state in
            return state.legalAcceptances[userId]
        }
    }

    func setLegalAcceptance(_ acceptance: EmailLegalAcceptance, userId: String) {
        state.withLock { state in
            state.legalAcceptances[userId] = acceptance
        }
    }

    // MARK: - Email verification

    /// Replaces every live verification token for `userId` with one fresh
    /// record and records the issue time for the hourly rate limit.
    func issueVerificationToken(
        userId: String,
        token: String,
        tokenHash: String,
        now: Date = Date(),
        ttl: TimeInterval = 24 * 60 * 60
    ) {
        state.withLock { state in
            Self.issueVerificationTokenLocked(state: &state, userId: userId, token: token, tokenHash: tokenHash, now: now, ttl: ttl)
        }
    }

    /// The token replacement and issue-date append. The caller passes its already-borrowed state.
    static func issueVerificationTokenLocked(
        state: inout State,
        userId: String,
        token: String,
        tokenHash: String,
        now: Date,
        ttl: TimeInterval
    ) {
        let record = EmailVerificationRecord(
            userId: userId,
            tokenHash: tokenHash,
            rawToken: token,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        state.emailVerificationTokens[userId] = [record]
        state.emailVerificationIssueDates[userId, default: []].append(now)
    }

    /// The resend policy and its write in one critical section: hourly-cap
    /// check, cooldown check, token replacement and issue-count increment all
    /// observe and mutate the same rows under the same lock. Two concurrent
    /// resends therefore cannot both pass the cap or the cooldown.
    func issueVerificationTokenIfAllowed(
        userId: String,
        token: String,
        tokenHash: String,
        now: Date,
        ttl: TimeInterval,
        hourlyLimit: Int,
        cooldown: TimeInterval
    ) -> IssueOutcome {
        return state.withLock { state in
            let recentIssued = state.emailVerificationIssueDates[userId]?.filter {
                $0 >= now.addingTimeInterval(-60 * 60)
            }.count ?? 0
            if recentIssued >= hourlyLimit { return .tooManyRequests }
            if recentIssued > 0,
               let latest = state.emailVerificationTokens[userId]?.max(by: { $0.createdAt < $1.createdAt }),
               now.timeIntervalSince(latest.createdAt) < cooldown {
                return .cooldown
            }
            state.emailVerificationTokens[userId] = [EmailVerificationRecord(
                userId: userId,
                tokenHash: tokenHash,
                rawToken: token,
                createdAt: now,
                expiresAt: now.addingTimeInterval(ttl)
            )]
            state.emailVerificationIssueDates[userId, default: []].append(now)
            state.accountSurface.emailVerifications += 1
            return .issued
        }
    }

    /// Spends one token. An unknown hash returns `nil`. An expired token is
    /// removed and returns `nil`. A valid token removes every verification
    /// token for its owner and returns the owner id.
    func consumeVerificationToken(tokenHash: String, now: Date = Date()) -> String? {
        return state.withLock { state in
            guard let userId = state.emailVerificationTokens.first(where: { _, records in
                records.contains { $0.tokenHash == tokenHash }
            })?.key,
                let record = state.emailVerificationTokens[userId]?.first(where: { $0.tokenHash == tokenHash })
            else { return nil }
            guard record.expiresAt >= now else {
                state.emailVerificationTokens[userId]?.removeAll { $0.tokenHash == tokenHash }
                if state.emailVerificationTokens[userId]?.isEmpty == true {
                    state.emailVerificationTokens.removeValue(forKey: userId)
                }
                return nil
            }
            state.emailVerificationTokens.removeValue(forKey: userId)
            return userId
        }
    }

    /// The most recently issued live token, for inspection and the acceptance
    /// seam. The resend cooldown reads it inside `issueVerificationTokenIfAllowed`.
    func latestVerificationToken(userId: String) -> EmailVerificationRecord? {
        return state.withLock { state in
            return state.emailVerificationTokens[userId]?.max { $0.createdAt < $1.createdAt }
        }
    }

    // MARK: - Verification policy lookups

    /// Whether an account row still exists for `userId`.
    func accountExists(userId: String) -> Bool {
        return state.withLock { state in
            return state.accountSurface.accounts.values.contains { $0.id == userId }
        }
    }

    func isEmailVerified(userId: String) -> Bool {
        return state.withLock { state in
            return state.accountSurface.accounts.values.first { $0.id == userId }?.emailVerified ?? false
        }
    }

    /// One locked lookup by account id. The submission and onboarding paths
    /// read verification, the published handle and the usage-data opt-out from
    /// the same row.
    func account(userId: String) -> Account? {
        return state.withLock { state in
            return state.accountSurface.accounts.values.first { $0.id == userId }
        }
    }

    /// The Node fixture marks a row verified without an HTTP call. Retirement
    /// refuses an unverified account.
    func markEmailVerified(userId: String) {
        state.withLock { state in
            if let key = state.accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
                state.accountSurface.accounts[key]?.emailVerified = true
            }
        }
    }

    /// The account id behind a bearer access token, or `nil` when the token is
    /// unknown or its session family was revoked.
    func userId(forAccessToken token: String) -> String? {
        return state.withLock { state in
            guard let userId = state.accountSurface.accessTokens[token] else { return nil }
            if let family = state.accountSurface.accessTokenFamilies[token],
               state.accountSurface.revokedFamilies.contains(family) {
                return nil
            }
            return userId
        }
    }

    // MARK: - Profile surface

    /// The whole profile surface. One read or one write is one locked critical
    /// section, so `EmailLoginDirectory`'s forwarding accessors stay atomic.
    var profileState: ProfileState {
        get {
            return state.withLock { state in
                return state.profile
            }
        }
        set {
            state.withLock { state in
                state.profile = newValue
            }
        }
    }

    var timezoneObservations: [String: TimezoneObservation] {
        get { state.withLock { $0.profile.timezoneObservations } }
        set { state.withLock { $0.profile.timezoneObservations = newValue } }
    }

    /// Records one timezone observation and returns the committed pair. The
    /// read and the write are one critical section, so concurrent observations
    /// share one first value and every response matches a committed row.
    func recordTimezoneObservation(
        userId: String,
        timezone: String,
        now: Date
    ) -> TimezoneObservation {
        return state.withLock { state in
            let existing = state.profile.timezoneObservations[userId]
            let observation = TimezoneObservation(
                firstTimezone: existing?.firstTimezone ?? timezone,
                firstAt: existing?.firstAt ?? now,
                lastTimezone: timezone,
                lastAt: now
            )
            state.profile.timezoneObservations[userId] = observation
            return observation
        }
    }

    var mobileAppEmailContactsByKey: [String: MobileAppEmailContact] {
        get { state.withLock { $0.profile.mobileAppEmailContactsByKey } }
        set { state.withLock { $0.profile.mobileAppEmailContactsByKey = newValue } }
    }

    var storedMobileAppEmailJourneys: [MobileAppEmailJourney] {
        get { state.withLock { $0.profile.storedMobileAppEmailJourneys } }
        set { state.withLock { $0.profile.storedMobileAppEmailJourneys = newValue } }
    }

    // MARK: - Account and session surface

    /// Rows that used to be stored inline on `EmailLoginDirectory`: the account
    /// table, the refresh-session families they mint, the one-time social and
    /// device handoffs, and the login-platform gates.
    struct AccountState: Sendable {
        var accounts: [String: Account] = [:]
        var analyticsIds: [String: String] = [:]
        var sessions: [String: LiveSession] = [:]
        var rotationReceipts: [String: RotationReceipt] = [:]
        /// Plain refresh tokens are one-time; the predecessor hash still resolves
        /// to its family so a legacy logout can revoke the successor.
        var predecessorFamilies: [String: String] = [:]
        var revokedFamilies: Set<String> = []
        var sessionFamilies: [String: SessionFamily] = [:]
        var retirementReceipts: [String: RetirementReceipt] = [:]
        var accessTokens: [String: String] = [:]
        var accessTokenFamilies: [String: String] = [:]
        var emailVerifications: Int = 0
        var appLoginRequests: [String: AppLoginRequest] = [:]
        var socialCompletions: [SocialCompletion] = []
        var pendingSocialLinks: [String: PendingSocialLink] = [:]
        var mobileRequests: [String: MobileOAuthRequest] = [:]
        var providerExchanges: Int = 0
        var consumedHandoffs: Set<String> = []
        var deviceGrants: [String: DeviceGrant] = [:]
        var deviceUserCodes: [String: String] = [:]
        var appleLoginPlatforms: Set<String> = []
        var linkedIdentities: [LinkedIdentity] = []
        /// Forces every experimental surface off when set.
        var experimentalSurfacesDisabledOverride: Bool? = nil
    }

    /// Injected hands-feedback switches (conversation session flag and the
    /// warning sink); the directory body keeps no storage of its own.
    struct SeamState: Sendable {
        var handsConversationSessionEnabled: Bool? = nil
        var handsFeedbackWarningSink: (@Sendable (String) -> Void)? = nil
    }

    /// Injected sign-in configuration that used to live inline on
    /// `EmailLoginDirectory`: social/Apple providers, OAuth return URIs and the
    /// deployment switches read by the auth extensions.
    struct ConfigState: Sendable {
        var mobileProviderProfile: MobileProviderProfile? = nil
        var webProviderProfile: MobileProviderProfile? = nil
        var configuredSocialAuthProviders: Set<String> = []
        var appleClientId: String = ""
        var nativeAppleClientId: String = ""
        var nativeAppleClientSecret: String = ""
        var nativeAppleStateSecret: String = ""
        var exchangeNativeAppleCode: (@Sendable (NativeAppleCodeExchange) async -> String?)? = nil
        var serverURL: String = "http://localhost:3001"
        var appURL: String = "http://localhost:3000"
        var mobileOAuthReturnURI: String? = nil
        var mobileOAuthAllowedReturnURIs: String? = nil
        var releaseBranch: String? = nil
        var deviceLoginGate: String? = nil
        var scopeAttestationSecretOverride: String?? = nil
        var deploymentEnvironmentOverride: String?? = nil
    }


    /// The whole account/session surface. One read or one write is one locked
    /// critical section, so `EmailLoginDirectory`'s forwarding accessors stay
    /// atomic.
    var accountState: AccountState {
        get {
            return state.withLock { state in
                return state.accountSurface
            }
        }
        set {
            state.withLock { state in
                state.accountSurface = newValue
            }
        }
    }

    var seamState: SeamState {
        get {
            return state.withLock { state in
                return state.seamSurface
            }
        }
        set {
            state.withLock { state in
                state.seamSurface = newValue
            }
        }
    }

    /// The whole injected sign-in configuration. One read or one write is one
    /// locked critical section.
    var configState: ConfigState {
        get {
            return state.withLock { state in
                return state.configSurface
            }
        }
        set {
            state.withLock { state in
                state.configSurface = newValue
            }
        }
    }

    var accounts: [String: Account] {
        get { state.withLock { $0.accountSurface.accounts } }
        set { state.withLock { $0.accountSurface.accounts = newValue } }
    }

    var analyticsIds: [String: String] {
        get { state.withLock { $0.accountSurface.analyticsIds } }
        set { state.withLock { $0.accountSurface.analyticsIds = newValue } }
    }

    var sessions: [String: LiveSession] {
        get { state.withLock { $0.accountSurface.sessions } }
        set { state.withLock { $0.accountSurface.sessions = newValue } }
    }

    var rotationReceipts: [String: RotationReceipt] {
        get { state.withLock { $0.accountSurface.rotationReceipts } }
        set { state.withLock { $0.accountSurface.rotationReceipts = newValue } }
    }

    var predecessorFamilies: [String: String] {
        get { state.withLock { $0.accountSurface.predecessorFamilies } }
        set { state.withLock { $0.accountSurface.predecessorFamilies = newValue } }
    }

    var revokedFamilies: Set<String> {
        get { state.withLock { $0.accountSurface.revokedFamilies } }
        set { state.withLock { $0.accountSurface.revokedFamilies = newValue } }
    }

    var sessionFamilies: [String: SessionFamily] {
        get { state.withLock { $0.accountSurface.sessionFamilies } }
        set { state.withLock { $0.accountSurface.sessionFamilies = newValue } }
    }

    var retirementReceipts: [String: RetirementReceipt] {
        get { state.withLock { $0.accountSurface.retirementReceipts } }
        set { state.withLock { $0.accountSurface.retirementReceipts = newValue } }
    }

    var accessTokens: [String: String] {
        get { state.withLock { $0.accountSurface.accessTokens } }
        set { state.withLock { $0.accountSurface.accessTokens = newValue } }
    }

    var accessTokenFamilies: [String: String] {
        get { state.withLock { $0.accountSurface.accessTokenFamilies } }
        set { state.withLock { $0.accountSurface.accessTokenFamilies = newValue } }
    }

    var emailVerifications: Int {
        get { state.withLock { $0.accountSurface.emailVerifications } }
        set { state.withLock { $0.accountSurface.emailVerifications = newValue } }
    }

    var socialCompletions: [SocialCompletion] {
        get { state.withLock { $0.accountSurface.socialCompletions } }
        set { state.withLock { $0.accountSurface.socialCompletions = newValue } }
    }

    var pendingSocialLinks: [String: PendingSocialLink] {
        get { state.withLock { $0.accountSurface.pendingSocialLinks } }
        set { state.withLock { $0.accountSurface.pendingSocialLinks = newValue } }
    }

    var mobileRequests: [String: MobileOAuthRequest] {
        get { state.withLock { $0.accountSurface.mobileRequests } }
        set { state.withLock { $0.accountSurface.mobileRequests = newValue } }
    }

    var providerExchanges: Int {
        get { state.withLock { $0.accountSurface.providerExchanges } }
        set { state.withLock { $0.accountSurface.providerExchanges = newValue } }
    }

    var consumedHandoffs: Set<String> {
        get { state.withLock { $0.accountSurface.consumedHandoffs } }
        set { state.withLock { $0.accountSurface.consumedHandoffs = newValue } }
    }

    var deviceGrants: [String: DeviceGrant] {
        get { state.withLock { $0.accountSurface.deviceGrants } }
        set { state.withLock { $0.accountSurface.deviceGrants = newValue } }
    }

    var deviceUserCodes: [String: String] {
        get { state.withLock { $0.accountSurface.deviceUserCodes } }
        set { state.withLock { $0.accountSurface.deviceUserCodes = newValue } }
    }

    var appleLoginPlatforms: Set<String> {
        get { state.withLock { $0.accountSurface.appleLoginPlatforms } }
        set { state.withLock { $0.accountSurface.appleLoginPlatforms = newValue } }
    }

    var linkedIdentities: [LinkedIdentity] {
        get { state.withLock { $0.accountSurface.linkedIdentities } }
        set { state.withLock { $0.accountSurface.linkedIdentities = newValue } }
    }

    var experimentalSurfacesDisabledOverride: Bool? {
        get { state.withLock { $0.accountSurface.experimentalSurfacesDisabledOverride } }
        set { state.withLock { $0.accountSurface.experimentalSurfacesDisabledOverride = newValue } }
    }

    var handsConversationSessionEnabled: Bool? {
        get { state.withLock { $0.seamSurface.handsConversationSessionEnabled } }
        set { state.withLock { $0.seamSurface.handsConversationSessionEnabled = newValue } }
    }

    var handsFeedbackWarningSink: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.seamSurface.handsFeedbackWarningSink } }
        set { state.withLock { $0.seamSurface.handsFeedbackWarningSink = newValue } }
    }

    // MARK: - Injected sign-in configuration

    var mobileProviderProfile: MobileProviderProfile? {
        get { state.withLock { $0.configSurface.mobileProviderProfile } }
        set { state.withLock { $0.configSurface.mobileProviderProfile = newValue } }
    }

    var webProviderProfile: MobileProviderProfile? {
        get { state.withLock { $0.configSurface.webProviderProfile } }
        set { state.withLock { $0.configSurface.webProviderProfile = newValue } }
    }

    var configuredSocialAuthProviders: Set<String> {
        get { state.withLock { $0.configSurface.configuredSocialAuthProviders } }
        set { state.withLock { $0.configSurface.configuredSocialAuthProviders = newValue } }
    }

    var appleClientId: String {
        get { state.withLock { $0.configSurface.appleClientId } }
        set { state.withLock { $0.configSurface.appleClientId = newValue } }
    }

    var nativeAppleClientId: String {
        get { state.withLock { $0.configSurface.nativeAppleClientId } }
        set { state.withLock { $0.configSurface.nativeAppleClientId = newValue } }
    }

    var nativeAppleClientSecret: String {
        get { state.withLock { $0.configSurface.nativeAppleClientSecret } }
        set { state.withLock { $0.configSurface.nativeAppleClientSecret = newValue } }
    }

    var nativeAppleStateSecret: String {
        get { state.withLock { $0.configSurface.nativeAppleStateSecret } }
        set { state.withLock { $0.configSurface.nativeAppleStateSecret = newValue } }
    }

    var exchangeNativeAppleCode: (@Sendable (NativeAppleCodeExchange) async -> String?)? {
        get { state.withLock { $0.configSurface.exchangeNativeAppleCode } }
        set { state.withLock { $0.configSurface.exchangeNativeAppleCode = newValue } }
    }

    var serverURL: String {
        get { state.withLock { $0.configSurface.serverURL } }
        set { state.withLock { $0.configSurface.serverURL = newValue } }
    }

    var appURL: String {
        get { state.withLock { $0.configSurface.appURL } }
        set { state.withLock { $0.configSurface.appURL = newValue } }
    }

    var mobileOAuthReturnURI: String? {
        get { state.withLock { $0.configSurface.mobileOAuthReturnURI } }
        set { state.withLock { $0.configSurface.mobileOAuthReturnURI = newValue } }
    }

    var mobileOAuthAllowedReturnURIs: String? {
        get { state.withLock { $0.configSurface.mobileOAuthAllowedReturnURIs } }
        set { state.withLock { $0.configSurface.mobileOAuthAllowedReturnURIs = newValue } }
    }

    var releaseBranch: String? {
        get { state.withLock { $0.configSurface.releaseBranch } }
        set { state.withLock { $0.configSurface.releaseBranch = newValue } }
    }

    var deviceLoginGate: String? {
        get { state.withLock { $0.configSurface.deviceLoginGate } }
        set { state.withLock { $0.configSurface.deviceLoginGate = newValue } }
    }

    var scopeAttestationSecretOverride: String?? {
        get { state.withLock { $0.configSurface.scopeAttestationSecretOverride } }
        set { state.withLock { $0.configSurface.scopeAttestationSecretOverride = newValue } }
    }

    var deploymentEnvironmentOverride: String?? {
        get { state.withLock { $0.configSurface.deploymentEnvironmentOverride } }
        set { state.withLock { $0.configSurface.deploymentEnvironmentOverride = newValue } }
    }

    // MARK: - Join-link / agent-profile account reads

    /// Accounts whose public handle matches one already-lowercased name, in the
    /// ledger's dictionary order. The caller still filters by server
    /// membership, exactly like the retired extension did.
    func accountsMatching(name loweredName: String) -> [Account] {
        return state.withLock { state in
            return state.accountSurface.accounts.values.filter { $0.name.lowercased() == loweredName }
        }
    }

    func accountEmail(id: String) -> String? {
        return state.withLock { state in
            // The account table is keyed by normalized email, not user id.
            return state.accountSurface.accounts.values.first { $0.id == id }?.email
        }
    }

    /// The first account whose public handle matches `exactName` exactly, in
    /// the account ledger's dictionary order. The action-card DM target
    /// resolver keeps the legacy case-sensitive `values.first` contract.
    func firstAccount(exactName: String) -> Account? {
        return state.withLock { state in
            return state.accountSurface.accounts.values.first { $0.name == exactName }
        }
    }
}
