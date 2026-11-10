import Foundation

/// Version 1 of the auth/account business ledger. This is not deployment config.
///
/// State coverage:
/// - profile: all three timezone/contact/journey ledgers.
/// - identityRows, passwordResetTokens, legalAcceptances,
///   emailVerificationTokens (including rawToken), emailVerificationIssueDates.
/// - accountSurface: accounts (all 26 fields), analyticsIds, sessions,
///   rotationReceipts (successor and ciphertext), predecessorFamilies,
///   revokedFamilies, sessionFamilies (nonce, revocation and retention),
///   retirementReceipts, accessTokens, accessTokenFamilies, appLoginRequests,
///   socialCompletions, pendingSocialLinks, mobileRequests, consumedHandoffs,
///   deviceGrants, deviceUserCodes and linkedIdentities.
///
/// Excluded and left unchanged by restore:
/// - accountSurface.providerExchanges: diagnostic exchange counter; no business
///   decision reads it. appleLoginPlatforms: live provider platform gate.
///   experimentalSurfacesDisabledOverride: live deployment policy override.
/// - seamSurface.handsConversationSessionEnabled / handsFeedbackWarningSink.
/// - configSurface.oauthDeployment / authCoreDeployment / mobileProviderProfile /
///   webProviderProfile / exchangeNativeAppleCode / scopeAttestationSecretOverride /
///   deploymentEnvironmentOverride. This preserves both levels of each String??.
///   OAuth deployment includes the configured native Apple signing secrets.
/// - Service clocks, verifiers and network clients are not owned by this State.
///
/// OAuthLedger owns its independent JWT signing secret. Its persistence codec,
/// not this account snapshot, must capture that secret. AuthTokenCodec's social
/// and refresh-receipt keys are deterministic constants, not mutable owner rows.
///
/// DTOs do not expose State or add global Codable conformances to shared records.
/// The opaque data contains credentials and tokens; callers must not log it.
/// Cross-owner commit/rollback ordering and serialization belong to the caller.
enum AuthProfilePersistence {
    enum Failure: Error, Sendable, Equatable {
        case invalidSnapshot
        case unsupportedVersion(Int)
        case unsupportedDateEncoding
        case invalidDate
    }

    private static let domain = "raft.auth-profile"
    private static let version = 1
    private static let dateEncoding = "reference-seconds-ieee754-hex"

    private struct Header: Decodable {
        let domain: String
        let version: Int
        let dateEncoding: String
    }

    private struct Envelope: Codable, Sendable {
        let domain: String
        let version: Int
        let dateEncoding: String
        let payload: Payload
    }

    /// Decode and validate before acquiring the store lock. Missing tables or
    /// nullable record keys reject the entire snapshot; no empty-table fallback.
    fileprivate static func decode(_ data: Data) throws -> Payload {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw Failure.invalidSnapshot
        }
        guard header.domain == domain else { throw Failure.invalidSnapshot }
        guard header.version == version else { throw Failure.unsupportedVersion(header.version) }
        guard header.dateEncoding == dateEncoding else { throw Failure.unsupportedDateEncoding }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard !text.isEmpty, text.utf8.count <= 16,
                  let bits = UInt64(text, radix: 16)
            else { throw Failure.invalidDate }
            let seconds = Double(bitPattern: bits)
            guard seconds.isFinite else { throw Failure.invalidDate }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        do {
            return try decoder.decode(Envelope.self, from: data).payload
        } catch {
            // A decoding codingPath can include a token used as a dictionary key.
            // Do not expose that path through the persistence error surface.
            throw Failure.invalidSnapshot
        }
    }

    /// Lets the aggregate persistence boundary validate every owner's bytes
    /// before it starts replacing any owner. This does not touch the store.
    static func validate(_ data: Data) throws {
        _ = try decode(data)
    }

    fileprivate static func encode(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else { throw Failure.invalidDate }
            var container = encoder.singleValueContainer()
            try container.encode(String(seconds.bitPattern, radix: 16))
        }
        return try encoder.encode(Envelope(
            domain: domain, version: version, dateEncoding: dateEncoding, payload: payload
        ))
    }

    /// Tuples use named records; identity array order and duplicates are kept.
    struct ProviderIdentityRow: Codable, Sendable {
        let provider: String
        let providerEmail: String

        init(_ row: (provider: String, providerEmail: String)) {
            provider = row.provider
            providerEmail = row.providerEmail
        }

        var record: (provider: String, providerEmail: String) { (provider, providerEmail) }
    }

    struct PasswordResetRow: Codable, Sendable {
        let userId: String
        let expiresAt: Date

        init(_ row: (userId: String, expiresAt: Date)) {
            userId = row.userId
            expiresAt = row.expiresAt
        }

        var record: (userId: String, expiresAt: Date) { (userId, expiresAt) }
    }

    /// Every stored property here is mandatory in the versioned payload.
    fileprivate struct Payload: Codable, Sendable {
        let timezoneObservations: [String: TimezoneObservationRow]
        let mobileAppEmailContactsByKey: [String: MobileEmailContactRow]
        let storedMobileAppEmailJourneys: [MobileEmailJourneyRow]
        let identityRows: [String: [ProviderIdentityRow]]
        let passwordResetTokens: [String: PasswordResetRow]
        let legalAcceptances: [String: LegalAcceptanceRow]
        let emailVerificationTokens: [String: [EmailVerificationRow]]
        let emailVerificationIssueDates: [String: [Date]]
        let accounts: [String: AccountRow]
        let analyticsIds: [String: String]
        let sessions: [String: LiveSessionRow]
        let rotationReceipts: [String: RotationReceiptRow]
        let predecessorFamilies: [String: String]
        let revokedFamilies: Set<String>
        let sessionFamilies: [String: SessionFamilyRow]
        let retirementReceipts: [String: RetirementReceiptRow]
        let accessTokens: [String: String]
        let accessTokenFamilies: [String: String]
        let appLoginRequests: [String: AppLoginRequestRow]
        let socialCompletions: [SocialCompletionRow]
        let pendingSocialLinks: [String: PendingSocialLinkRow]
        let mobileRequests: [String: MobileOAuthRequestRow]
        let consumedHandoffs: Set<String>
        let deviceGrants: [String: DeviceGrantRow]
        let deviceUserCodes: [String: String]
        let linkedIdentities: [LinkedIdentityRow]

        init(state: AuthProfileStore.State) {
            timezoneObservations = state.profile.timezoneObservations.mapValues(TimezoneObservationRow.init)
            mobileAppEmailContactsByKey = state.profile.mobileAppEmailContactsByKey.mapValues(MobileEmailContactRow.init)
            storedMobileAppEmailJourneys = state.profile.storedMobileAppEmailJourneys.map(MobileEmailJourneyRow.init)
            identityRows = state.identityRows.mapValues { $0.map(ProviderIdentityRow.init) }
            passwordResetTokens = state.passwordResetTokens.mapValues(PasswordResetRow.init)
            legalAcceptances = state.legalAcceptances.mapValues(LegalAcceptanceRow.init)
            emailVerificationTokens = state.emailVerificationTokens.mapValues { $0.map(EmailVerificationRow.init) }
            emailVerificationIssueDates = state.emailVerificationIssueDates
            let account = state.accountSurface
            accounts = account.accounts.mapValues(AccountRow.init)
            analyticsIds = account.analyticsIds
            sessions = account.sessions.mapValues(LiveSessionRow.init)
            rotationReceipts = account.rotationReceipts.mapValues(RotationReceiptRow.init)
            predecessorFamilies = account.predecessorFamilies
            revokedFamilies = account.revokedFamilies
            sessionFamilies = account.sessionFamilies.mapValues(SessionFamilyRow.init)
            retirementReceipts = account.retirementReceipts.mapValues(RetirementReceiptRow.init)
            accessTokens = account.accessTokens
            accessTokenFamilies = account.accessTokenFamilies
            appLoginRequests = account.appLoginRequests.mapValues(AppLoginRequestRow.init)
            socialCompletions = account.socialCompletions.map(SocialCompletionRow.init)
            pendingSocialLinks = account.pendingSocialLinks.mapValues(PendingSocialLinkRow.init)
            mobileRequests = account.mobileRequests.mapValues(MobileOAuthRequestRow.init)
            consumedHandoffs = account.consumedHandoffs
            deviceGrants = account.deviceGrants.mapValues(DeviceGrantRow.init)
            deviceUserCodes = account.deviceUserCodes
            linkedIdentities = account.linkedIdentities.map(LinkedIdentityRow.init)
        }

        /// No decoding or throwing work remains once the owner lock is held.
        /// Assign only durable fields; preserve the receiving process's config,
        /// callbacks, overrides and diagnostic counter even during rollback.
        func install(into state: inout AuthProfileStore.State) {
            state.profile.timezoneObservations = timezoneObservations.mapValues(\.record)
            state.profile.mobileAppEmailContactsByKey = mobileAppEmailContactsByKey.mapValues(\.record)
            state.profile.storedMobileAppEmailJourneys = storedMobileAppEmailJourneys.map(\.record)
            state.identityRows = identityRows.mapValues { $0.map(\.record) }
            state.passwordResetTokens = passwordResetTokens.mapValues(\.record)
            state.legalAcceptances = legalAcceptances.mapValues(\.record)
            state.emailVerificationTokens = emailVerificationTokens.mapValues { $0.map(\.record) }
            state.emailVerificationIssueDates = emailVerificationIssueDates
            state.accountSurface.accounts = accounts.mapValues(\.record)
            state.accountSurface.analyticsIds = analyticsIds
            state.accountSurface.sessions = sessions.mapValues(\.record)
            state.accountSurface.rotationReceipts = rotationReceipts.mapValues(\.record)
            state.accountSurface.predecessorFamilies = predecessorFamilies
            state.accountSurface.revokedFamilies = revokedFamilies
            state.accountSurface.sessionFamilies = sessionFamilies.mapValues(\.record)
            state.accountSurface.retirementReceipts = retirementReceipts.mapValues(\.record)
            state.accountSurface.accessTokens = accessTokens
            state.accountSurface.accessTokenFamilies = accessTokenFamilies
            state.accountSurface.appLoginRequests = appLoginRequests.mapValues(\.record)
            state.accountSurface.socialCompletions = socialCompletions.map(\.record)
            state.accountSurface.pendingSocialLinks = pendingSocialLinks.mapValues(\.record)
            state.accountSurface.mobileRequests = mobileRequests.mapValues(\.record)
            state.accountSurface.consumedHandoffs = consumedHandoffs
            state.accountSurface.deviceGrants = deviceGrants.mapValues(\.record)
            state.accountSurface.deviceUserCodes = deviceUserCodes
            state.accountSurface.linkedIdentities = linkedIdentities.map(\.record)
        }
    }
}

extension AuthProfileStore {
    /// One coherent owner snapshot. Encoding runs after releasing the Mutex.
    /// The returned opaque data includes credential material and must not be logged.
    func exportAuthProfilePersistence() throws -> Data {
        let payload = state.withLock { AuthProfilePersistence.Payload(state: $0) }
        return try AuthProfilePersistence.encode(payload)
    }

    /// Decode completely before changing any live rows, then replace all durable
    /// auth ledgers together. The caller serializes this with its PG transaction
    /// and with other owners; this method alone is not a database transaction.
    func restoreAuthProfilePersistence(from data: Data) throws {
        let payload = try AuthProfilePersistence.decode(data)
        state.withLock { payload.install(into: &$0) }
    }
}
