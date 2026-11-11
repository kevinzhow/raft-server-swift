import Foundation

/// Version 1 of the auth/account business ledger. This is not deployment config.
///
/// State coverage:
/// - profile: all three timezone/contact/journey ledgers.
/// - passwordResetTokens, legalAcceptances, emailVerificationTokens (including
///   rawToken) and emailVerificationIssueDates.
/// - accountSurface: accounts (all 30 fields), analyticsIds, sessions,
///   rotationReceipts (successor and ciphertext), predecessorFamilies,
///   revokedFamilies, sessionFamilies (nonce, revocation and retention),
///   retirementReceipts, accessTokens, accessTokenFamilies, appLoginRequests,
///   socialCompletions, pendingSocialLinks, mobileRequests, consumedHandoffs,
///   deviceGrants, deviceUserCodes and the unified userAuthIdentities list.
///   The same writer also emits the retired identityRows/linkedIdentities
///   projections derived from that list so the pre-unification binary can still
///   decode (and start from) a snapshot written here.
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

    /// One row of the retired `identityRows` list. The pre-unification decoder
    /// required both fields; `providerEmail` was never nullable in this shape,
    /// so a unified row without one has no representation here.
    struct ProviderIdentityRow: Codable, Equatable, Sendable {
        let provider: String
        let providerEmail: String

        init(provider: String, providerEmail: String) {
            self.provider = provider
            self.providerEmail = providerEmail
        }
    }

    /// One row of the retired `linkedIdentities` array. The pre-unification
    /// decoder required `providerUserId`; a unified row without a subject is
    /// projected with the empty-string placeholder the previous writer itself
    /// used for a completion that carried none, and the unified list keeps the
    /// canonical nil.
    struct LegacyLinkedIdentityRow: Codable, Equatable, Sendable {
        let userId: String
        let provider: String
        let providerUserId: String
        let providerEmail: String?

        init(userId: String, provider: String, providerUserId: String, providerEmail: String?) {
            self.userId = userId
            self.provider = provider
            self.providerUserId = providerUserId
            self.providerEmail = providerEmail
        }

        private enum CodingKeys: String, CodingKey {
            case userId
            case provider
            case providerUserId
            case providerEmail
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userId = try values.decode(String.self, forKey: .userId)
            provider = try values.decode(String.self, forKey: .provider)
            providerUserId = try values.decode(String.self, forKey: .providerUserId)
            providerEmail = try values.decode(String?.self, forKey: .providerEmail)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userId, forKey: .userId)
            try values.encode(provider, forKey: .provider)
            try values.encode(providerUserId, forKey: .providerUserId)
            try values.encode(providerEmail, forKey: .providerEmail)
        }

        var identityRow: LinkedIdentityRow {
            LinkedIdentityRow(
                userId: userId,
                provider: provider,
                providerUserId: providerUserId,
                providerEmail: providerEmail
            )
        }
    }

    /// The retired `identityRows` projection of the one owner. Per-user arrays
    /// keep the unified order (the old list route and unlink read that order),
    /// and a row without a provider email is left to `linkedIdentities` because
    /// the retired row shape cannot represent it.
    static func legacyIdentityRows(from identities: [LinkedIdentityRow]) -> [String: [ProviderIdentityRow]] {
        var rows: [String: [ProviderIdentityRow]] = [:]
        for identity in identities {
            guard let providerEmail = identity.providerEmail else { continue }
            rows[identity.userId, default: []].append(
                ProviderIdentityRow(provider: identity.provider, providerEmail: providerEmail)
            )
        }
        return rows
    }

    /// The retired `linkedIdentities` projection of the one owner. Every unified
    /// row is emitted in unified order, so the old first-row
    /// `profileSetupProvider` is the same account row. A nil provider subject
    /// becomes the old empty-string placeholder; a nil email is encoded as JSON
    /// null exactly as the old writer did.
    static func legacyLinkedIdentities(from identities: [LinkedIdentityRow]) -> [LegacyLinkedIdentityRow] {
        identities.map { identity in
            LegacyLinkedIdentityRow(
                userId: identity.userId,
                provider: identity.provider,
                providerUserId: identity.providerUserId ?? "",
                providerEmail: identity.providerEmail
            )
        }
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

    /// Every pre-existing property here is mandatory in the current version-1
    /// payload. Linked identities are one owner: the `userAuthIdentities` list
    /// is authoritative whenever it is present. The writer additionally emits
    /// the retired `identityRows`/`linkedIdentities` pair (derived from the same
    /// list) so the pre-unification binary can still decode the snapshot. A
    /// snapshot that omits the unified list is the old shape and must carry that
    /// pair; a partly present pair rejects the whole snapshot.
    fileprivate struct Payload: Codable, Sendable {
        let timezoneObservations: [String: TimezoneObservationRow]
        let mobileAppEmailContactsByKey: [String: MobileEmailContactRow]
        let storedMobileAppEmailJourneys: [MobileEmailJourneyRow]
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
        let userAuthIdentities: [LinkedIdentityRow]

        private enum CodingKeys: String, CodingKey {
            case timezoneObservations
            case mobileAppEmailContactsByKey
            case storedMobileAppEmailJourneys
            case passwordResetTokens
            case legalAcceptances
            case emailVerificationTokens
            case emailVerificationIssueDates
            case accounts
            case analyticsIds
            case sessions
            case rotationReceipts
            case predecessorFamilies
            case revokedFamilies
            case sessionFamilies
            case retirementReceipts
            case accessTokens
            case accessTokenFamilies
            case appLoginRequests
            case socialCompletions
            case pendingSocialLinks
            case mobileRequests
            case consumedHandoffs
            case deviceGrants
            case deviceUserCodes
            case userAuthIdentities
            // Retired fields: required by the pre-unification shape and emitted
            // here as derived projections alongside the unified list.
            case identityRows
            case linkedIdentities
        }

        init(state: AuthProfileStore.State) {
            timezoneObservations = state.profile.timezoneObservations.mapValues(TimezoneObservationRow.init)
            mobileAppEmailContactsByKey = state.profile.mobileAppEmailContactsByKey.mapValues(MobileEmailContactRow.init)
            storedMobileAppEmailJourneys = state.profile.storedMobileAppEmailJourneys.map(MobileEmailJourneyRow.init)
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
            userAuthIdentities = account.linkedIdentities.map(LinkedIdentityRow.init)
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            timezoneObservations = try values.decode(
                [String: TimezoneObservationRow].self, forKey: .timezoneObservations
            )
            mobileAppEmailContactsByKey = try values.decode(
                [String: MobileEmailContactRow].self, forKey: .mobileAppEmailContactsByKey
            )
            storedMobileAppEmailJourneys = try values.decode(
                [MobileEmailJourneyRow].self, forKey: .storedMobileAppEmailJourneys
            )
            passwordResetTokens = try values.decode([String: PasswordResetRow].self, forKey: .passwordResetTokens)
            legalAcceptances = try values.decode([String: LegalAcceptanceRow].self, forKey: .legalAcceptances)
            emailVerificationTokens = try values.decode(
                [String: [EmailVerificationRow]].self, forKey: .emailVerificationTokens
            )
            emailVerificationIssueDates = try values.decode(
                [String: [Date]].self, forKey: .emailVerificationIssueDates
            )
            accounts = try values.decode([String: AccountRow].self, forKey: .accounts)
            analyticsIds = try values.decode([String: String].self, forKey: .analyticsIds)
            sessions = try values.decode([String: LiveSessionRow].self, forKey: .sessions)
            rotationReceipts = try values.decode([String: RotationReceiptRow].self, forKey: .rotationReceipts)
            predecessorFamilies = try values.decode([String: String].self, forKey: .predecessorFamilies)
            revokedFamilies = try values.decode(Set<String>.self, forKey: .revokedFamilies)
            sessionFamilies = try values.decode([String: SessionFamilyRow].self, forKey: .sessionFamilies)
            retirementReceipts = try values.decode([String: RetirementReceiptRow].self, forKey: .retirementReceipts)
            accessTokens = try values.decode([String: String].self, forKey: .accessTokens)
            accessTokenFamilies = try values.decode([String: String].self, forKey: .accessTokenFamilies)
            appLoginRequests = try values.decode([String: AppLoginRequestRow].self, forKey: .appLoginRequests)
            socialCompletions = try values.decode([SocialCompletionRow].self, forKey: .socialCompletions)
            pendingSocialLinks = try values.decode([String: PendingSocialLinkRow].self, forKey: .pendingSocialLinks)
            mobileRequests = try values.decode([String: MobileOAuthRequestRow].self, forKey: .mobileRequests)
            consumedHandoffs = try values.decode(Set<String>.self, forKey: .consumedHandoffs)
            deviceGrants = try values.decode([String: DeviceGrantRow].self, forKey: .deviceGrants)
            deviceUserCodes = try values.decode([String: String].self, forKey: .deviceUserCodes)

            let hasUnified = values.contains(.userAuthIdentities)
            let hasLegacyRows = values.contains(.identityRows)
            let hasLegacyLinked = values.contains(.linkedIdentities)
            if hasUnified {
                // The unified list is authoritative. The retired projections are
                // writable rollback baggage: decode them so a malformed or
                // half-written pair still rejects the snapshot, then ignore
                // their rows. They are never merged into the unified rows, so a
                // stale or duplicated projection cannot create extra identities.
                if hasLegacyRows || hasLegacyLinked {
                    guard hasLegacyRows, hasLegacyLinked else {
                        throw DecodingError.dataCorrupted(.init(
                            codingPath: values.codingPath,
                            debugDescription: "Retired linked identity fields are only partly present"
                        ))
                    }
                    _ = try values.decode([String: [ProviderIdentityRow]].self, forKey: .identityRows)
                    _ = try values.decode([LegacyLinkedIdentityRow].self, forKey: .linkedIdentities)
                }
                userAuthIdentities = try values.decode([LinkedIdentityRow].self, forKey: .userAuthIdentities)
            } else {
                guard hasLegacyRows, hasLegacyLinked else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: values.codingPath,
                        debugDescription: "Linked identity fields are only partly present"
                    ))
                }
                userAuthIdentities = Self.mergeLegacyIdentities(
                    linked: try values.decode([LegacyLinkedIdentityRow].self, forKey: .linkedIdentities),
                    legacyRows: try values.decode(
                        [String: [ProviderIdentityRow]].self, forKey: .identityRows
                    )
                )
            }
        }

        /// The pre-unification binary wrote the same upstream
        /// `(userId, provider)` owner row twice: once in `linkedIdentities`
        /// (which owned `profileSetupProvider` and the social link replies) and
        /// once in `identityRows` (which owned the identity list and unlink).
        /// The retired `linkedIdentities` order leads because that was the old
        /// `profileSetupProvider` order; list-only rows follow per user in their
        /// stored order. Both fields describe one row per account/provider, so a
        /// list row that matches an already restored identity fills its missing
        /// email instead of appending a duplicate. An empty subject on the
        /// linked representation is the old placeholder for "unknown subject";
        /// when the list row supplies the same identity it restores as nil.
        private static func mergeLegacyIdentities(
            linked: [LegacyLinkedIdentityRow],
            legacyRows: [String: [ProviderIdentityRow]]
        ) -> [LinkedIdentityRow] {
            var merged: [LinkedIdentityRow] = []
            var indexByOwner: [LegacyIdentityKey: Int] = [:]
            for row in linked {
                let key = LegacyIdentityKey(userId: row.userId, provider: row.provider)
                if let index = indexByOwner[key] {
                    if merged[index].providerEmail == nil {
                        merged[index] = row.identityRow
                    }
                    continue
                }
                indexByOwner[key] = merged.count
                merged.append(row.identityRow)
            }
            // The snapshot dictionary has no stable order; each user's array does.
            for userId in legacyRows.keys.sorted() {
                for row in legacyRows[userId] ?? [] {
                    let key = LegacyIdentityKey(userId: userId, provider: row.provider)
                    if let index = indexByOwner[key] {
                        let current = merged[index]
                        merged[index] = LinkedIdentityRow(
                            userId: current.userId,
                            provider: current.provider,
                            providerUserId: current.providerUserId == "" ? nil : current.providerUserId,
                            providerEmail: current.providerEmail ?? row.providerEmail
                        )
                        continue
                    }
                    indexByOwner[key] = merged.count
                    merged.append(LinkedIdentityRow(
                        userId: userId,
                        provider: row.provider,
                        providerUserId: nil,
                        providerEmail: row.providerEmail
                    ))
                }
            }
            return merged
        }

        private struct LegacyIdentityKey: Hashable {
            let userId: String
            let provider: String
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(timezoneObservations, forKey: .timezoneObservations)
            try values.encode(mobileAppEmailContactsByKey, forKey: .mobileAppEmailContactsByKey)
            try values.encode(storedMobileAppEmailJourneys, forKey: .storedMobileAppEmailJourneys)
            try values.encode(passwordResetTokens, forKey: .passwordResetTokens)
            try values.encode(legalAcceptances, forKey: .legalAcceptances)
            try values.encode(emailVerificationTokens, forKey: .emailVerificationTokens)
            try values.encode(emailVerificationIssueDates, forKey: .emailVerificationIssueDates)
            try values.encode(accounts, forKey: .accounts)
            try values.encode(analyticsIds, forKey: .analyticsIds)
            try values.encode(sessions, forKey: .sessions)
            try values.encode(rotationReceipts, forKey: .rotationReceipts)
            try values.encode(predecessorFamilies, forKey: .predecessorFamilies)
            try values.encode(revokedFamilies, forKey: .revokedFamilies)
            try values.encode(sessionFamilies, forKey: .sessionFamilies)
            try values.encode(retirementReceipts, forKey: .retirementReceipts)
            try values.encode(accessTokens, forKey: .accessTokens)
            try values.encode(accessTokenFamilies, forKey: .accessTokenFamilies)
            try values.encode(appLoginRequests, forKey: .appLoginRequests)
            try values.encode(socialCompletions, forKey: .socialCompletions)
            try values.encode(pendingSocialLinks, forKey: .pendingSocialLinks)
            try values.encode(mobileRequests, forKey: .mobileRequests)
            try values.encode(consumedHandoffs, forKey: .consumedHandoffs)
            try values.encode(deviceGrants, forKey: .deviceGrants)
            try values.encode(deviceUserCodes, forKey: .deviceUserCodes)
            try values.encode(userAuthIdentities, forKey: .userAuthIdentities)
            // Expand step: keep the retired binary able to decode this snapshot.
            // Both projections are derived from the same ordered list; the
            // decoder above treats `userAuthIdentities` as authoritative.
            try values.encode(
                AuthProfilePersistence.legacyIdentityRows(from: userAuthIdentities), forKey: .identityRows
            )
            try values.encode(
                AuthProfilePersistence.legacyLinkedIdentities(from: userAuthIdentities), forKey: .linkedIdentities
            )
        }

        /// No decoding or throwing work remains once the owner lock is held.
        /// Assign only durable fields; preserve the receiving process's config,
        /// callbacks, overrides and diagnostic counter even during rollback.
        func install(into state: inout AuthProfileStore.State) {
            state.profile.timezoneObservations = timezoneObservations.mapValues(\.record)
            state.profile.mobileAppEmailContactsByKey = mobileAppEmailContactsByKey.mapValues(\.record)
            state.profile.storedMobileAppEmailJourneys = storedMobileAppEmailJourneys.map(\.record)
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
            state.accountSurface.linkedIdentities = userAuthIdentities.map(\.record)
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
