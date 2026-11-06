import Foundation

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

/// Owns account-profile ledgers: linked identities, password-reset tokens,
/// email-verification tokens and legal acceptances. HTTP/session/account
/// decisions stay in `EmailLoginDirectory`; this store serializes only its own
/// rows and returns strong Swift values, never JSON or `HTTPReply`.
final class AuthProfileStore: @unchecked Sendable {
    /// Profile surface rows that used to be stored inline on
    /// `EmailLoginDirectory`: timezone history, onboarding progress and the
    /// mobile-app lifecycle email audience.
    struct ProfileState {
        var timezoneObservations: [String: EmailLoginDirectory.TimezoneObservation] = [:]
        var userOnboardingSettings: [String: UserOnboarding] = [:]
        var mobileAppEmailContactsByKey: [String: EmailLoginDirectory.MobileAppEmailContact] = [:]
        var storedMobileAppEmailJourneys: [EmailLoginDirectory.MobileAppEmailJourney] = []
    }

    private let lock = NSLock()
    private var profile = ProfileState()
    private var identityRows: [String: [(provider: String, providerEmail: String)]] = [:]
    private var passwordResetTokens: [String: (userId: String, expiresAt: Date)] = [:]
    private var legalAcceptances: [String: EmailLegalAcceptance] = [:]
    /// Live tokens keyed by user id. `issueVerificationToken` replaces the
    /// user's set, which is the upstream insert-after-delete behavior.
    private var emailVerificationTokens: [String: [EmailVerificationRecord]] = [:]
    /// Issue history per user. It survives token replacement so the resend
    /// rate limit can count sends from the last hour even after old rows go.
    private var emailVerificationIssueDates: [String: [Date]] = [:]

    func identities(userId: String) -> [(provider: String, providerEmail: String)] {
        lock.lock()
        defer { lock.unlock() }
        return identityRows[userId] ?? []
    }

    func replaceIdentities(userId: String, rows: [(provider: String, providerEmail: String)]) {
        lock.lock()
        identityRows[userId] = rows
        lock.unlock()
    }

    func appendIdentity(userId: String, provider: String, providerEmail: String) {
        lock.lock()
        identityRows[userId, default: []].append((provider, providerEmail))
        lock.unlock()
    }

    func identityCount(userId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return identityRows[userId]?.count ?? 0
    }

    func resetToken(hash: String) -> (userId: String, expiresAt: Date)? {
        lock.lock()
        defer { lock.unlock() }
        return passwordResetTokens[hash]
    }

    func removeResetToken(hash: String) {
        lock.lock()
        passwordResetTokens.removeValue(forKey: hash)
        lock.unlock()
    }

    func setResetToken(hash: String, userId: String, expiresAt: Date) {
        lock.lock()
        passwordResetTokens[hash] = (userId, expiresAt)
        lock.unlock()
    }

    var legalAcceptanceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return legalAcceptances.count
    }

    func legalAcceptance(userId: String) -> EmailLegalAcceptance? {
        lock.lock()
        defer { lock.unlock() }
        return legalAcceptances[userId]
    }

    func setLegalAcceptance(_ acceptance: EmailLegalAcceptance, userId: String) {
        lock.lock()
        legalAcceptances[userId] = acceptance
        lock.unlock()
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
        let record = EmailVerificationRecord(
            userId: userId,
            tokenHash: tokenHash,
            rawToken: token,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        lock.lock()
        emailVerificationTokens[userId] = [record]
        emailVerificationIssueDates[userId, default: []].append(now)
        lock.unlock()
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
        lock.lock()
        defer { lock.unlock() }
        let recentIssued = emailVerificationIssueDates[userId]?.filter {
            $0 >= now.addingTimeInterval(-60 * 60)
        }.count ?? 0
        if recentIssued >= hourlyLimit { return .tooManyRequests }
        if recentIssued > 0,
           let latest = emailVerificationTokens[userId]?.max(by: { $0.createdAt < $1.createdAt }),
           now.timeIntervalSince(latest.createdAt) < cooldown {
            return .cooldown
        }
        emailVerificationTokens[userId] = [EmailVerificationRecord(
            userId: userId,
            tokenHash: tokenHash,
            rawToken: token,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )]
        emailVerificationIssueDates[userId, default: []].append(now)
        accountSurface.emailVerifications += 1
        return .issued
    }

    /// Spends one token. An unknown hash returns `nil`. An expired token is
    /// removed and returns `nil`. A valid token removes every verification
    /// token for its owner and returns the owner id.
    func consumeVerificationToken(tokenHash: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = emailVerificationTokens.first(where: { _, records in
            records.contains { $0.tokenHash == tokenHash }
        })?.key,
            let record = emailVerificationTokens[userId]?.first(where: { $0.tokenHash == tokenHash })
        else { return nil }
        guard record.expiresAt >= now else {
            emailVerificationTokens[userId]?.removeAll { $0.tokenHash == tokenHash }
            if emailVerificationTokens[userId]?.isEmpty == true {
                emailVerificationTokens.removeValue(forKey: userId)
            }
            return nil
        }
        emailVerificationTokens.removeValue(forKey: userId)
        return userId
    }

    /// The most recently issued live token, for inspection and the acceptance
    /// seam. The resend cooldown reads it inside `issueVerificationTokenIfAllowed`.
    func latestVerificationToken(userId: String) -> EmailVerificationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return emailVerificationTokens[userId]?.max { $0.createdAt < $1.createdAt }
    }

    // MARK: - Verification policy lookups

    /// Whether an account row still exists for `userId`.
    func accountExists(userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.accounts.values.contains { $0.id == userId }
    }

    func isEmailVerified(userId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.accounts.values.first { $0.id == userId }?.emailVerified ?? false
    }

    /// The Node fixture marks a row verified without an HTTP call. Retirement
    /// refuses an unverified account.
    func markEmailVerified(userId: String) {
        lock.lock()
        if let key = accountSurface.accounts.first(where: { $0.value.id == userId })?.key {
            accountSurface.accounts[key]?.emailVerified = true
        }
        lock.unlock()
    }

    /// The account id behind a bearer access token, or `nil` when the token is
    /// unknown or its session family was revoked.
    func userId(forAccessToken token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accountSurface.accessTokens[token] else { return nil }
        if let family = accountSurface.accessTokenFamilies[token],
           accountSurface.revokedFamilies.contains(family) {
            return nil
        }
        return userId
    }

    // MARK: - Profile surface

    /// The whole profile surface. One read or one write is one locked critical
    /// section, so `EmailLoginDirectory`'s forwarding accessors stay atomic.
    var profileState: ProfileState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return profile
        }
        set {
            lock.lock()
            profile = newValue
            lock.unlock()
        }
    }

    var timezoneObservations: [String: EmailLoginDirectory.TimezoneObservation] {
        get { profileState.timezoneObservations }
        set { profileState.timezoneObservations = newValue }
    }

    var userOnboardingSettings: [String: UserOnboarding] {
        get { profileState.userOnboardingSettings }
        set { profileState.userOnboardingSettings = newValue }
    }

    var mobileAppEmailContactsByKey: [String: EmailLoginDirectory.MobileAppEmailContact] {
        get { profileState.mobileAppEmailContactsByKey }
        set { profileState.mobileAppEmailContactsByKey = newValue }
    }

    var storedMobileAppEmailJourneys: [EmailLoginDirectory.MobileAppEmailJourney] {
        get { profileState.storedMobileAppEmailJourneys }
        set { profileState.storedMobileAppEmailJourneys = newValue }
    }

    // MARK: - Account and session surface

    /// Rows that used to be stored inline on `EmailLoginDirectory`: the account
    /// table, the refresh-session families they mint, the one-time social and
    /// device handoffs, and the login-platform gates.
    struct AccountState {
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
    struct SeamState {
        var handsConversationSessionEnabled: Bool? = nil
        var handsFeedbackWarningSink: ((String) -> Void)? = nil
    }

    /// Injected sign-in configuration that used to live inline on
    /// `EmailLoginDirectory`: social/Apple providers, OAuth return URIs and the
    /// deployment switches read by the auth extensions.
    struct ConfigState {
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

    private var accountSurface = AccountState()
    private var seamSurface = SeamState()
    private var configSurface = ConfigState()

    /// The whole account/session surface. One read or one write is one locked
    /// critical section, so `EmailLoginDirectory`'s forwarding accessors stay
    /// atomic.
    var accountState: AccountState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return accountSurface
        }
        set {
            lock.lock()
            accountSurface = newValue
            lock.unlock()
        }
    }

    var seamState: SeamState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return seamSurface
        }
        set {
            lock.lock()
            seamSurface = newValue
            lock.unlock()
        }
    }

    /// The whole injected sign-in configuration. One read or one write is one
    /// locked critical section.
    var configState: ConfigState {
        get {
            lock.lock()
            defer { lock.unlock() }
            return configSurface
        }
        set {
            lock.lock()
            configSurface = newValue
            lock.unlock()
        }
    }

    var accounts: [String: Account] {
        get { accountState.accounts }
        set { accountState.accounts = newValue }
    }

    var analyticsIds: [String: String] {
        get { accountState.analyticsIds }
        set { accountState.analyticsIds = newValue }
    }

    var sessions: [String: LiveSession] {
        get { accountState.sessions }
        set { accountState.sessions = newValue }
    }

    var rotationReceipts: [String: RotationReceipt] {
        get { accountState.rotationReceipts }
        set { accountState.rotationReceipts = newValue }
    }

    var predecessorFamilies: [String: String] {
        get { accountState.predecessorFamilies }
        set { accountState.predecessorFamilies = newValue }
    }

    var revokedFamilies: Set<String> {
        get { accountState.revokedFamilies }
        set { accountState.revokedFamilies = newValue }
    }

    var sessionFamilies: [String: SessionFamily] {
        get { accountState.sessionFamilies }
        set { accountState.sessionFamilies = newValue }
    }

    var retirementReceipts: [String: RetirementReceipt] {
        get { accountState.retirementReceipts }
        set { accountState.retirementReceipts = newValue }
    }

    var accessTokens: [String: String] {
        get { accountState.accessTokens }
        set { accountState.accessTokens = newValue }
    }

    var accessTokenFamilies: [String: String] {
        get { accountState.accessTokenFamilies }
        set { accountState.accessTokenFamilies = newValue }
    }

    var emailVerifications: Int {
        get { accountState.emailVerifications }
        set { accountState.emailVerifications = newValue }
    }

    var appLoginRequests: [String: AppLoginRequest] {
        get { accountState.appLoginRequests }
        set { accountState.appLoginRequests = newValue }
    }

    var socialCompletions: [SocialCompletion] {
        get { accountState.socialCompletions }
        set { accountState.socialCompletions = newValue }
    }

    var pendingSocialLinks: [String: PendingSocialLink] {
        get { accountState.pendingSocialLinks }
        set { accountState.pendingSocialLinks = newValue }
    }

    var mobileRequests: [String: MobileOAuthRequest] {
        get { accountState.mobileRequests }
        set { accountState.mobileRequests = newValue }
    }

    var providerExchanges: Int {
        get { accountState.providerExchanges }
        set { accountState.providerExchanges = newValue }
    }

    var consumedHandoffs: Set<String> {
        get { accountState.consumedHandoffs }
        set { accountState.consumedHandoffs = newValue }
    }

    var deviceGrants: [String: DeviceGrant] {
        get { accountState.deviceGrants }
        set { accountState.deviceGrants = newValue }
    }

    var deviceUserCodes: [String: String] {
        get { accountState.deviceUserCodes }
        set { accountState.deviceUserCodes = newValue }
    }

    var appleLoginPlatforms: Set<String> {
        get { accountState.appleLoginPlatforms }
        set { accountState.appleLoginPlatforms = newValue }
    }

    var linkedIdentities: [LinkedIdentity] {
        get { accountState.linkedIdentities }
        set { accountState.linkedIdentities = newValue }
    }

    var experimentalSurfacesDisabledOverride: Bool? {
        get { accountState.experimentalSurfacesDisabledOverride }
        set { accountState.experimentalSurfacesDisabledOverride = newValue }
    }

    var handsConversationSessionEnabled: Bool? {
        get { seamState.handsConversationSessionEnabled }
        set { seamState.handsConversationSessionEnabled = newValue }
    }

    var handsFeedbackWarningSink: ((String) -> Void)? {
        get { seamState.handsFeedbackWarningSink }
        set { seamState.handsFeedbackWarningSink = newValue }
    }

    // MARK: - Injected sign-in configuration

    var mobileProviderProfile: MobileProviderProfile? {
        get { configState.mobileProviderProfile }
        set { configState.mobileProviderProfile = newValue }
    }

    var webProviderProfile: MobileProviderProfile? {
        get { configState.webProviderProfile }
        set { configState.webProviderProfile = newValue }
    }

    var configuredSocialAuthProviders: Set<String> {
        get { configState.configuredSocialAuthProviders }
        set { configState.configuredSocialAuthProviders = newValue }
    }

    var appleClientId: String {
        get { configState.appleClientId }
        set { configState.appleClientId = newValue }
    }

    var nativeAppleClientId: String {
        get { configState.nativeAppleClientId }
        set { configState.nativeAppleClientId = newValue }
    }

    var nativeAppleClientSecret: String {
        get { configState.nativeAppleClientSecret }
        set { configState.nativeAppleClientSecret = newValue }
    }

    var nativeAppleStateSecret: String {
        get { configState.nativeAppleStateSecret }
        set { configState.nativeAppleStateSecret = newValue }
    }

    var exchangeNativeAppleCode: (@Sendable (NativeAppleCodeExchange) async -> String?)? {
        get { configState.exchangeNativeAppleCode }
        set { configState.exchangeNativeAppleCode = newValue }
    }

    var serverURL: String {
        get { configState.serverURL }
        set { configState.serverURL = newValue }
    }

    var appURL: String {
        get { configState.appURL }
        set { configState.appURL = newValue }
    }

    var mobileOAuthReturnURI: String? {
        get { configState.mobileOAuthReturnURI }
        set { configState.mobileOAuthReturnURI = newValue }
    }

    var mobileOAuthAllowedReturnURIs: String? {
        get { configState.mobileOAuthAllowedReturnURIs }
        set { configState.mobileOAuthAllowedReturnURIs = newValue }
    }

    var releaseBranch: String? {
        get { configState.releaseBranch }
        set { configState.releaseBranch = newValue }
    }

    var deviceLoginGate: String? {
        get { configState.deviceLoginGate }
        set { configState.deviceLoginGate = newValue }
    }

    var scopeAttestationSecretOverride: String?? {
        get { configState.scopeAttestationSecretOverride }
        set { configState.scopeAttestationSecretOverride = newValue }
    }

    var deploymentEnvironmentOverride: String?? {
        get { configState.deploymentEnvironmentOverride }
        set { configState.deploymentEnvironmentOverride = newValue }
    }
}
