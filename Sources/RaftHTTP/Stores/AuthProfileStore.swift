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
final class AuthProfileStore: @unchecked Sendable {
    /// Profile surface rows that used to be stored inline on
    /// `EmailLoginDirectory`: timezone history and the
    /// mobile-app lifecycle email audience.
    struct ProfileState {
        var timezoneObservations: [String: EmailLoginDirectory.TimezoneObservation] = [:]
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
        lock.lock()
        defer { lock.unlock() }
        guard let account = accountSurface.accounts[EmailLoginDirectory.normalize(email)] else {
            return false
        }
        passwordResetTokens[tokenHash] = (account.id, now.addingTimeInterval(ttl))
        return true
    }

    /// Spends one reset token and writes the new password in one critical
    /// section. A missing or expired token writes nothing; two concurrent
    /// resets therefore cannot both consume the row.
    func consumeResetToken(
        tokenHash: String,
        passwordHash: String,
        now: Date
    ) -> ResetPasswordOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let reset = passwordResetTokens[tokenHash], reset.expiresAt > now,
              let email = accountSurface.accounts.first(where: { $0.value.id == reset.userId })?.key
        else {
            return .invalidOrExpiredToken
        }
        passwordResetTokens.removeValue(forKey: tokenHash)
        accountSurface.accounts[email]?.passwordHash = passwordHash
        accountSurface.accounts[email]?.passwordCredentialEstablishedAt = now
        return .reset
    }

    /// Cancels one pending social link. Unknown, already-cancelled and expired
    /// tokens are the same no-op; the route answers 204 either way.
    func markPendingSocialLinkCancelled(token: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var pending = accountSurface.pendingSocialLinks[token] else { return }
        pending.cancelled = true
        accountSurface.pendingSocialLinks[token] = pending
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

    /// One locked lookup by account id. The submission and onboarding paths
    /// read verification, the published handle and the usage-data opt-out from
    /// the same row.
    func account(userId: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.accounts.values.first { $0.id == userId }
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

    /// Records one timezone observation and returns the committed pair. The
    /// read and the write are one critical section, so concurrent observations
    /// share one first value and every response matches a committed row.
    func recordTimezoneObservation(
        userId: String,
        timezone: String,
        now: Date
    ) -> EmailLoginDirectory.TimezoneObservation {
        lock.lock()
        defer { lock.unlock() }
        let existing = profile.timezoneObservations[userId]
        let observation = EmailLoginDirectory.TimezoneObservation(
            firstTimezone: existing?.firstTimezone ?? timezone,
            firstAt: existing?.firstAt ?? now,
            lastTimezone: timezone,
            lastAt: now
        )
        profile.timezoneObservations[userId] = observation
        return observation
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

    // MARK: - Join-link / agent-profile account reads

    /// Accounts whose public handle matches one already-lowercased name, in the
    /// ledger's dictionary order. The caller still filters by server
    /// membership, exactly like the retired extension did.
    func accountsMatching(name loweredName: String) -> [Account] {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.accounts.values.filter { $0.name.lowercased() == loweredName }
    }

    func accountEmail(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // The account table is keyed by normalized email, not user id.
        return accountSurface.accounts.values.first { $0.id == id }?.email
    }

    /// The first account whose public handle matches `exactName` exactly, in
    /// the account ledger's dictionary order. The action-card DM target
    /// resolver keeps the legacy case-sensitive `values.first` contract.
    func firstAccount(exactName: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.accounts.values.first { $0.name == exactName }
    }
}

// MARK: - Session identity, app login and profile writes
//
// Each method below is one critical section over the account surface (and, for
// the identity list, the identity rows). They return plain values and decision
// enums; the `AuthIdentitiesService` maps them to its DTOs and typed errors.

/// A user's linked sign-in identities and the password flag, read together.
struct AuthIdentitySnapshot {
    var rows: [(provider: String, providerEmail: String)]
    var passwordConfigured: Bool
}

/// The access/refresh pair one opened session family issued.
struct IssuedSessionTokens: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
}

/// Result of the locked unlink-and-guard decision.
enum UnlinkIdentityOutcome {
    case notLinked(AuthIdentitySnapshot)
    case passwordCredentialRequired
    case unlinked(AuthIdentitySnapshot)
}

/// Result of the locked password login (pending-link check, password check,
/// session open and link consume).
enum AuthenticateOutcome {
    case authenticated(userId: String, email: String, tokens: IssuedSessionTokens, linkedProvider: String?)
    case pendingLinkExpired
    case pendingLinkAccountMismatch
    case rejected
}

/// What the signed-in user decided for a pending app-login request.
enum AppLoginDecision {
    case approve(userId: String, code: String)
    case deny
}

enum AppLoginDecisionOutcome {
    case decided(AppLoginRequest)
    case notFound
    case expired(AppLoginRequest)
    case notPending
}

/// Result of the locked one-time-code completion.
enum CompleteAppLoginOutcome {
    case completed(Account, IssuedSessionTokens)
    case codeNotFound
    case codeConsumed
    case codeExpired
    case pkceMismatch
    case notApproved
    case accountMissing
}

enum ChangePasswordOutcome: Equatable, Sendable {
    case changed
    case accountMissing
    case wrongPassword
}

/// The validated `PATCH /api/auth/me` profile fields. A double optional is
/// "leave alone" (outer `nil`), "clear" (`.some(nil)`) or "set".
struct AccountProfileUpdate: Sendable {
    var referralSource: String?? = nil
    var referralSourceOther: String?? = nil
    var referralSourceSkipped = false
    var preferredLanguage: String?? = nil
    var preferredTimezone: String?? = nil
    var preferredTranslationMode: String? = nil
    var autoTranslationEnabled: Bool? = nil
    var preferredTranslationDisplay: String? = nil
    var preferredTimeFormat: String?? = nil
    var preferredMessageBodyFontSize: String?? = nil
    var displayLanguage: String?? = nil
    var shareUsageData: Bool?? = nil
}

extension AuthProfileStore {
    /// The identity rows and the password flag in one critical section.
    func identitySnapshot(userId: String) -> AuthIdentitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return identitySnapshotLocked(userId: userId, rows: identityRows[userId] ?? [])
    }

    private func identitySnapshotLocked(
        userId: String,
        rows: [(provider: String, providerEmail: String)]
    ) -> AuthIdentitySnapshot {
        let passwordConfigured = accountSurface.accounts.values
            .first { $0.id == userId }?.passwordCredentialEstablishedAt != nil
        return AuthIdentitySnapshot(rows: rows, passwordConfigured: passwordConfigured)
    }

    /// Unlinks the first row for `provider`. The row lookup, the
    /// final-credential guard and the row write are one critical section, so
    /// two concurrent unlinks of a passwordless user's last two identities
    /// cannot both pass the guard.
    func unlinkIdentity(userId: String, provider: String) -> UnlinkIdentityOutcome {
        lock.lock()
        defer { lock.unlock() }
        var rows = identityRows[userId] ?? []
        let before = identitySnapshotLocked(userId: userId, rows: rows)
        guard let index = rows.firstIndex(where: { $0.provider == provider }) else {
            return .notLinked(before)
        }
        if rows.count == 1, !before.passwordConfigured {
            return .passwordCredentialRequired
        }
        rows.remove(at: index)
        identityRows[userId] = rows
        return .unlinked(identitySnapshotLocked(userId: userId, rows: rows))
    }

    /// The account behind a bearer token, without the revoked-family check the
    /// session decisions apply (`requireAuth` for the OAuth routes).
    func account(forAnyAccessToken token: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accountSurface.accessTokens[token] else { return nil }
        return accountSurface.accounts.values.first { $0.id == userId }
    }

    /// Opens one session family. The caller holds `lock`.
    private func openSessionLocked(userId: String) -> IssuedSessionTokens {
        let familyId = UUID().uuidString.lowercased()
        accountSurface.sessionFamilies[familyId] = SessionFamily(userId: userId, revokedAt: nil)
        let accessToken = EmailLoginDirectory.token()
        let refreshToken = EmailLoginDirectory.token()
        accountSurface.sessions[refreshToken] = LiveSession(userId: userId, familyId: familyId)
        accountSurface.accessTokens[accessToken] = userId
        accountSurface.accessTokenFamilies[accessToken] = familyId
        return IssuedSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Password login. The pending-link validation, the credential check, the
    /// first-password stamp, the session open and the link consume are one
    /// critical section, so a pending link cannot be spent twice.
    func authenticate(
        email: String,
        passwordHash: String,
        pendingLinkToken: String?,
        now: Date
    ) -> AuthenticateOutcome {
        lock.lock()
        defer { lock.unlock() }
        var pendingLink: PendingSocialLink?
        if let token = pendingLinkToken, !token.isEmpty {
            guard let pending = accountSurface.pendingSocialLinks[token], !pending.consumed,
                  !pending.cancelled, pending.expiresAt > now
            else { return .pendingLinkExpired }
            guard pending.email == email else { return .pendingLinkAccountMismatch }
            pendingLink = pending
        }
        guard var account = accountSurface.accounts[email],
              account.passwordHash == passwordHash,
              account.retiredAt == nil
        else { return .rejected }
        if account.passwordCredentialEstablishedAt == nil {
            account.passwordCredentialEstablishedAt = now
            accountSurface.accounts[email] = account
        }
        let tokens = openSessionLocked(userId: account.id)
        var linkedProvider: String?
        if var pending = pendingLink {
            pending.consumed = true
            accountSurface.pendingSocialLinks[pending.token] = pending
            if !accountSurface.linkedIdentities.contains(where: {
                $0.userId == account.id && $0.provider == pending.provider
                    && $0.providerUserId == pending.providerUserId
            }) {
                accountSurface.linkedIdentities.append(LinkedIdentity(
                    userId: account.id,
                    provider: pending.provider,
                    providerUserId: pending.providerUserId,
                    providerEmail: pending.email
                ))
            }
            linkedProvider = pending.provider
        }
        return .authenticated(userId: account.id, email: account.email, tokens: tokens, linkedProvider: linkedProvider)
    }

    // MARK: App login

    func insertAppLoginRequest(_ request: AppLoginRequest) {
        lock.lock()
        accountSurface.appLoginRequests[request.id] = request
        lock.unlock()
    }

    func appLoginRequest(id: String) -> AppLoginRequest? {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.appLoginRequests[id]
    }

    /// Approves or denies one request. The expiry check, the pending check and
    /// the status write are one critical section, so a request cannot be both
    /// approved and denied.
    func decideAppLogin(
        requestId: String,
        decision: AppLoginDecision,
        now: Date
    ) -> AppLoginDecisionOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var request = accountSurface.appLoginRequests[requestId] else { return .notFound }
        if request.expiresAt <= now { return .expired(request) }
        guard request.status == "pending" else { return .notPending }
        switch decision {
        case .approve(let userId, let code):
            request.status = "approved"
            request.code = code
            request.userId = userId
        case .deny:
            request.status = "denied"
        }
        accountSurface.appLoginRequests[requestId] = request
        return .decided(request)
    }

    /// Spends one approved request's code. The code lookup, the consumed/expiry
    /// checks, the PKCE comparison, the consumed stamp and the session open are
    /// one critical section: a wrong verifier burns nothing, and two concurrent
    /// completions of one code cannot both open a session.
    func completeAppLogin(
        code: String,
        verifierChallenge: String,
        now: Date
    ) -> CompleteAppLoginOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let request = accountSurface.appLoginRequests.values.first(where: { $0.code == code }) else {
            return .codeNotFound
        }
        if request.consumedAt != nil { return .codeConsumed }
        if request.expiresAt <= now { return .codeExpired }
        guard verifierChallenge == request.codeChallenge else { return .pkceMismatch }
        guard let userId = request.userId else { return .notApproved }
        var approved = request
        approved.consumedAt = now
        accountSurface.appLoginRequests[approved.id] = approved
        guard let account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return .accountMissing
        }
        return .completed(account, openSessionLocked(userId: userId))
    }

    // MARK: Profile writes

    /// Replaces the password when the current one matches. The compare and the
    /// write are one critical section.
    func changePassword(userId: String, currentHash: String, newHash: String) -> ChangePasswordOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return .accountMissing
        }
        guard account.passwordHash == currentHash else { return .wrongPassword }
        account.passwordHash = newHash
        accountSurface.accounts[account.email] = account
        return .changed
    }

    /// Applies every validated profile field and the analytics-id mapping the
    /// usage opt-in controls in one critical section and returns the stored
    /// row. `nil` means the account no longer exists and nothing was written.
    func applyProfileUpdate(
        userId: String,
        update: AccountProfileUpdate,
        now: Date,
        newAnalyticsId: String
    ) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        guard var account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return nil
        }
        var changed = false
        if let value = update.referralSource {
            account.referralSource = value
            account.referralSourceSkippedAt = nil
            changed = true
        }
        if let value = update.referralSourceOther {
            account.referralSourceOther = value
            changed = true
        }
        if update.referralSourceSkipped {
            account.referralSourceSkippedAt = now
            changed = true
        }
        if let value = update.preferredLanguage { account.preferredLanguage = value; changed = true }
        if let value = update.preferredTimezone { account.preferredTimezone = value; changed = true }
        if let value = update.preferredTranslationMode { account.preferredTranslationMode = value; changed = true }
        if let value = update.autoTranslationEnabled { account.autoTranslationEnabled = value; changed = true }
        if let value = update.preferredTranslationDisplay { account.preferredTranslationDisplay = value; changed = true }
        if let value = update.preferredTimeFormat { account.preferredTimeFormat = value; changed = true }
        if let value = update.preferredMessageBodyFontSize { account.preferredMessageBodyFontSize = value; changed = true }
        if let language = update.displayLanguage {
            account.displayLanguage = language
            changed = true
        }
        if let share = update.shareUsageData {
            account.shareUsageData = share
            if share == true {
                if accountSurface.analyticsIds[account.id] == nil {
                    accountSurface.analyticsIds[account.id] = newAnalyticsId
                }
            } else if share == false {
                accountSurface.analyticsIds.removeValue(forKey: account.id)
            }
            changed = true
        }
        if changed {
            accountSurface.accounts[account.email] = account
        }
        return account
    }

    /// Stores a new avatar path and returns the stored row, or `nil` when the
    /// account no longer exists.
    func setAvatarURL(userId: String, url: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        guard var account = accountSurface.accounts.values.first(where: { $0.id == userId }) else {
            return nil
        }
        account.avatarUrl = url
        accountSurface.accounts[account.email] = account
        return account
    }

    /// The first/last timezone pair `me` appends once a user reported one.
    func timezoneObservation(userId: String) -> EmailLoginDirectory.TimezoneObservation? {
        lock.lock()
        defer { lock.unlock() }
        return profile.timezoneObservations[userId]
    }
}

// MARK: - Managed MCP lifecycle: profile completion and push capability sections

/// Result of the locked profile completion. The store decides; the service
/// maps a refusal to its published `ManagedMCPLifecycleError`.
enum ProfileCompletionOutcome: Equatable {
    case unknownAccount
    /// The same name pair was already completed; the stored row is replayed.
    case replay(Account)
    case alreadyCompleted
    case nameTaken
    case completed(Account)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unknownAccount, .unknownAccount), (.alreadyCompleted, .alreadyCompleted),
             (.nameTaken, .nameTaken):
            true
        case (.replay(let left), .replay(let right)), (.completed(let left), .completed(let right)):
            left.id == right.id && left.name == right.name
        default:
            false
        }
    }
}

/// Result of the locked push-family revocation.
enum PushFamilyRevocation: Equatable, Sendable {
    /// No family owns the capability nonce, or its retention window ended.
    case invalid
    /// The family was revoked earlier and the capability is still retained.
    case alreadyRevoked
    case revoked
}

extension AuthProfileStore {
    /// Completes the profile in one critical section: the unknown-account
    /// check, the completed-replay check, the taken-name check and the write
    /// cannot interleave with another account write.
    func completeProfile(userId: String, name: String, displayName: String, now: Date) -> ProfileCompletionOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let key = accountSurface.accounts.first(where: { $0.value.id == userId })?.key,
              var account = accountSurface.accounts[key]
        else { return .unknownAccount }
        if account.profileSetupCompletedAt != nil {
            let replay = account.name == name && (account.displayName ?? account.name) == displayName
            return replay ? .replay(account) : .alreadyCompleted
        }
        let lowered = name.lowercased()
        let taken = Set(accountSurface.accounts.values.filter { $0.id != userId }.map { $0.name.lowercased() })
        guard !taken.contains(lowered) else { return .nameTaken }
        account.name = name
        account.displayName = displayName
        account.profileSetupCompletedAt = now
        accountSurface.accounts[key] = account
        return .completed(account)
    }

    /// The user and session family behind an access token for the push routes.
    /// Unlike `userId(forAccessToken:)` it does not consult the revoked-family
    /// set: the push routes only ever checked the token table.
    func pushPrincipal(accessToken token: String) -> (userId: String, familyId: String?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let userId = accountSurface.accessTokens[token] else { return nil }
        return (userId, accountSurface.accessTokenFamilies[token])
    }

    /// Ensures the principal's session family exists and carries a revoke
    /// capability nonce, and answers `<familyId>.<nonce>`, in one critical
    /// section so two registrations cannot mint different nonces.
    func ensurePushRevokeCapability(userId: String, familyId existingFamilyId: String?) -> (familyId: String, capability: String) {
        lock.lock()
        defer { lock.unlock() }
        let familyId = existingFamilyId ?? UUID().uuidString.lowercased()
        if accountSurface.sessionFamilies[familyId] == nil {
            accountSurface.sessionFamilies[familyId] = SessionFamily(userId: userId)
        }
        var nonce = accountSurface.sessionFamilies[familyId]?.revokeCapabilityNonce
        if nonce == nil {
            let minted = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            accountSurface.sessionFamilies[familyId]?.revokeCapabilityNonce = minted
            nonce = minted
        }
        return (familyId, "\(familyId).\(nonce ?? "")")
    }

    /// Revokes the session family that owns the capability nonce and drops its
    /// refresh sessions and access tokens, in one critical section.
    func revokePushFamily(nonce: String, now: Date) -> PushFamilyRevocation {
        lock.lock()
        defer { lock.unlock() }
        guard let familyId = accountSurface.sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == nonce })?.key,
              var family = accountSurface.sessionFamilies[familyId]
        else { return .invalid }
        if family.revokedAt != nil {
            if let retain = family.capabilityRetainUntil, retain > now { return .alreadyRevoked }
            return .invalid
        }
        family.revokedAt = now
        family.revokedReason = "push_family"
        family.capabilityRetainUntil = now.addingTimeInterval(30 * 24 * 60 * 60)
        accountSurface.sessionFamilies[familyId] = family
        for (token, _) in accountSurface.sessions.filter({ $0.value.familyId == familyId }) {
            accountSurface.sessions.removeValue(forKey: token)
        }
        for token in accountSurface.accessTokenFamilies.filter({ $0.value == familyId }).map(\.key) {
            accountSurface.accessTokens.removeValue(forKey: token)
            accountSurface.accessTokenFamilies.removeValue(forKey: token)
        }
        return .revoked
    }
}

extension AuthProfileStore {
    /// The first account whose handle equals `name` ignoring case, in the
    /// ledger's dictionary order (the joint-channel invitee lookup).
    func firstAccount(caseInsensitiveName name: String) -> Account? {
        lock.lock()
        defer { lock.unlock() }
        return accountSurface.accounts.values.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Session issue, refresh rotation and analytics identity

extension AuthProfileStore {
    /// Opens one session family and issues its token pair, in one critical
    /// section (the refresh table, the family row and both token tables change
    /// together).
    func openSession(userId: String) -> IssuedSessionTokens {
        lock.lock()
        defer { lock.unlock() }
        return openSessionLocked(userId: userId)
    }

    /// One refresh-token rotation. With an attempt and an installation id the
    /// rotation is durable (a receipt lets the same attempt replay the
    /// successor); otherwise it is the plain one-time rotation that keeps the
    /// predecessor hash resolvable to its family. The whole decision and every
    /// write is one critical section, so two concurrent refreshes of the same
    /// token cannot both rotate it.
    func rotateRefresh(refreshToken: String, attemptId: String?, installationId: String?) -> RefreshOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let attemptId, let installationId {
            return durableRefreshLocked(
                refreshToken: refreshToken,
                attemptId: attemptId,
                installationId: installationId
            )
        }
        guard let live = accountSurface.sessions[refreshToken],
              !accountSurface.revokedFamilies.contains(live.familyId)
        else {
            return .rejected
        }
        accountSurface.sessions.removeValue(forKey: refreshToken)
        accountSurface.predecessorFamilies[EmailLoginDirectory.sha256(refreshToken)] = live.familyId
        let successor = EmailLoginDirectory.token()
        accountSurface.sessions[successor] = live
        let accessToken = EmailLoginDirectory.token()
        accountSurface.accessTokens[accessToken] = live.userId
        accountSurface.accessTokenFamilies[accessToken] = live.familyId
        return .rotated(IssuedRefresh(accessToken: accessToken, userId: live.userId), successor)
    }

    private func durableRefreshLocked(
        refreshToken: String,
        attemptId: String,
        installationId: String
    ) -> RefreshOutcome {
        let hash = EmailLoginDirectory.sha256(refreshToken)
        if let live = accountSurface.sessions.removeValue(forKey: refreshToken) {
            if accountSurface.revokedFamilies.contains(live.familyId) {
                return .rejected
            }
            let successor = EmailLoginDirectory.token()
            accountSurface.sessions[successor] = live
            let ciphertext = EmailLoginDirectory.sealSuccessor(successor)
            accountSurface.rotationReceipts[hash] = RotationReceipt(
                attemptId: attemptId,
                installationId: installationId,
                userId: live.userId,
                familyId: live.familyId,
                successor: successor,
                ciphertext: ciphertext,
                expiresAt: Date(timeIntervalSinceNow: 15 * 60)
            )
            let accessToken = EmailLoginDirectory.token()
            accountSurface.accessTokens[accessToken] = live.userId
            accountSurface.accessTokenFamilies[accessToken] = live.familyId
            return .rotated(IssuedRefresh(accessToken: accessToken, userId: live.userId), successor)
        }
        guard let receipt = accountSurface.rotationReceipts[hash] else { return .rejected }
        if receipt.attemptId != attemptId || receipt.installationId != installationId { return .rejected }
        if receipt.expiresAt <= Date() || accountSurface.revokedFamilies.contains(receipt.familyId) {
            return .rejected
        }
        let accessToken = EmailLoginDirectory.token()
        accountSurface.accessTokens[accessToken] = receipt.userId
        accountSurface.accessTokenFamilies[accessToken] = receipt.familyId
        return .rotated(IssuedRefresh(accessToken: accessToken, userId: receipt.userId), receipt.successor)
    }

    /// The user's analytics id, minted on first use. Lookup and mint are one
    /// critical section, so two concurrent first events share one id.
    func analyticsId(userId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = accountSurface.analyticsIds[userId] { return existing }
        let minted = UUID().uuidString.lowercased()
        accountSurface.analyticsIds[userId] = minted
        return minted
    }

    /// Resolves a `push/family-revoke` capability (`<familyId>.<nonce>`)
    /// without consuming it.
    func familyRevokeTarget(capability: String) -> (userId: String, familyId: String)? {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let familyId = accountSurface.sessionFamilies.first(where: { $0.value.revokeCapabilityNonce == parts[1] })?.key,
              let family = accountSurface.sessionFamilies[familyId]
        else { return nil }
        return (family.userId, familyId)
    }
}
