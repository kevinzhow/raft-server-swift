import Foundation

// Separate persistence DTOs avoid changing the domain records or their conformances.
// Every pre-existing key is required, including nullable fields; nil is encoded
// as JSON null. The one new field group (signup survey + first onboarding) is
// all-or-none so the previous version-1 row keeps restoring.
extension AuthProfilePersistence {
    struct AccountRow: Codable, Sendable {
        let id: String
        let email: String
        let passwordHash: String
        let passwordCredentialEstablishedAt: Date?
        let displayLanguage: String?
        let name: String
        let displayName: String?
        let profileSetupSuggestedHandle: String?
        let profileSetupProvider: String?
        let profileSetupCompletedAt: Date?
        let avatarUrl: String?
        let description: String?
        let shareUsageData: Bool?
        let emailVerified: Bool
        let stagingSelfAccountCapabilityHash: String?
        let retiredAt: Date?
        let preferredLanguage: String?
        let preferredTimezone: String?
        let preferredTranslationMode: String
        let autoTranslationEnabled: Bool
        let preferredTranslationDisplay: String
        let preferredTimeFormat: String?
        let preferredMessageBodyFontSize: String?
        let referralSource: String?
        let referralSourceOther: String?
        let referralSourceSkippedAt: Date?
        /// The signup survey and the account-global first-onboarding pair. These
        /// four keys are one field group: the pre-batch version-1 writer did not
        /// know them at all, so a row without any of them is the old shape and
        /// decodes them as nil. A row with only some of them is corrupt.
        let signupRole: String?
        let signupSurveyCompletedAt: Date?
        let firstOnboardingCompletedAt: Date?
        let firstOnboardingCompletedSessionFamilyId: String?

        init(_ record: Account) {
            id = record.id
            email = record.email
            passwordHash = record.passwordHash
            passwordCredentialEstablishedAt = record.passwordCredentialEstablishedAt
            displayLanguage = record.displayLanguage
            name = record.name
            displayName = record.displayName
            profileSetupSuggestedHandle = record.profileSetupSuggestedHandle
            profileSetupProvider = record.profileSetupProvider
            profileSetupCompletedAt = record.profileSetupCompletedAt
            avatarUrl = record.avatarUrl
            description = record.description
            shareUsageData = record.shareUsageData
            emailVerified = record.emailVerified
            stagingSelfAccountCapabilityHash = record.stagingSelfAccountCapabilityHash
            retiredAt = record.retiredAt
            preferredLanguage = record.preferredLanguage
            preferredTimezone = record.preferredTimezone
            preferredTranslationMode = record.preferredTranslationMode
            autoTranslationEnabled = record.autoTranslationEnabled
            preferredTranslationDisplay = record.preferredTranslationDisplay
            preferredTimeFormat = record.preferredTimeFormat
            preferredMessageBodyFontSize = record.preferredMessageBodyFontSize
            referralSource = record.referralSource
            referralSourceOther = record.referralSourceOther
            referralSourceSkippedAt = record.referralSourceSkippedAt
            signupRole = record.signupRole
            signupSurveyCompletedAt = record.signupSurveyCompletedAt
            firstOnboardingCompletedAt = record.firstOnboardingCompletedAt
            firstOnboardingCompletedSessionFamilyId = record.firstOnboardingCompletedSessionFamilyId
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case email
            case passwordHash
            case passwordCredentialEstablishedAt
            case displayLanguage
            case name
            case displayName
            case profileSetupSuggestedHandle
            case profileSetupProvider
            case profileSetupCompletedAt
            case avatarUrl
            case description
            case shareUsageData
            case emailVerified
            case stagingSelfAccountCapabilityHash
            case retiredAt
            case preferredLanguage
            case preferredTimezone
            case preferredTranslationMode
            case autoTranslationEnabled
            case preferredTranslationDisplay
            case preferredTimeFormat
            case preferredMessageBodyFontSize
            case referralSource
            case referralSourceOther
            case referralSourceSkippedAt
            case signupRole
            case signupSurveyCompletedAt
            case firstOnboardingCompletedAt
            case firstOnboardingCompletedSessionFamilyId
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            email = try values.decode(String.self, forKey: .email)
            passwordHash = try values.decode(String.self, forKey: .passwordHash)
            passwordCredentialEstablishedAt = try values.decode(Date?.self, forKey: .passwordCredentialEstablishedAt)
            displayLanguage = try values.decode(String?.self, forKey: .displayLanguage)
            name = try values.decode(String.self, forKey: .name)
            displayName = try values.decode(String?.self, forKey: .displayName)
            profileSetupSuggestedHandle = try values.decode(String?.self, forKey: .profileSetupSuggestedHandle)
            profileSetupProvider = try values.decode(String?.self, forKey: .profileSetupProvider)
            profileSetupCompletedAt = try values.decode(Date?.self, forKey: .profileSetupCompletedAt)
            avatarUrl = try values.decode(String?.self, forKey: .avatarUrl)
            description = try values.decode(String?.self, forKey: .description)
            shareUsageData = try values.decode(Bool?.self, forKey: .shareUsageData)
            emailVerified = try values.decode(Bool.self, forKey: .emailVerified)
            stagingSelfAccountCapabilityHash = try values.decode(String?.self, forKey: .stagingSelfAccountCapabilityHash)
            retiredAt = try values.decode(Date?.self, forKey: .retiredAt)
            preferredLanguage = try values.decode(String?.self, forKey: .preferredLanguage)
            preferredTimezone = try values.decode(String?.self, forKey: .preferredTimezone)
            preferredTranslationMode = try values.decode(String.self, forKey: .preferredTranslationMode)
            autoTranslationEnabled = try values.decode(Bool.self, forKey: .autoTranslationEnabled)
            preferredTranslationDisplay = try values.decode(String.self, forKey: .preferredTranslationDisplay)
            preferredTimeFormat = try values.decode(String?.self, forKey: .preferredTimeFormat)
            preferredMessageBodyFontSize = try values.decode(String?.self, forKey: .preferredMessageBodyFontSize)
            referralSource = try values.decode(String?.self, forKey: .referralSource)
            referralSourceOther = try values.decode(String?.self, forKey: .referralSourceOther)
            referralSourceSkippedAt = try values.decode(Date?.self, forKey: .referralSourceSkippedAt)
            // The new facts are one all-or-none group. None present is the old
            // version-1 row this codec must keep restoring; a partial group is a
            // different row shape and rejects the whole snapshot before install.
            let onboardingKeys: [CodingKeys] = [
                .signupRole, .signupSurveyCompletedAt,
                .firstOnboardingCompletedAt, .firstOnboardingCompletedSessionFamilyId,
            ]
            let present = onboardingKeys.filter { values.contains($0) }
            if present.isEmpty {
                signupRole = nil
                signupSurveyCompletedAt = nil
                firstOnboardingCompletedAt = nil
                firstOnboardingCompletedSessionFamilyId = nil
            } else if present.count == onboardingKeys.count {
                signupRole = try values.decode(String?.self, forKey: .signupRole)
                signupSurveyCompletedAt = try values.decode(Date?.self, forKey: .signupSurveyCompletedAt)
                firstOnboardingCompletedAt = try values.decode(Date?.self, forKey: .firstOnboardingCompletedAt)
                firstOnboardingCompletedSessionFamilyId = try values.decode(
                    String?.self, forKey: .firstOnboardingCompletedSessionFamilyId
                )
            } else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: values.codingPath,
                    debugDescription: "Signup survey and first-onboarding facts are only partly present"
                ))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(email, forKey: .email)
            try values.encode(passwordHash, forKey: .passwordHash)
            try values.encode(passwordCredentialEstablishedAt, forKey: .passwordCredentialEstablishedAt)
            try values.encode(displayLanguage, forKey: .displayLanguage)
            try values.encode(name, forKey: .name)
            try values.encode(displayName, forKey: .displayName)
            try values.encode(profileSetupSuggestedHandle, forKey: .profileSetupSuggestedHandle)
            try values.encode(profileSetupProvider, forKey: .profileSetupProvider)
            try values.encode(profileSetupCompletedAt, forKey: .profileSetupCompletedAt)
            try values.encode(avatarUrl, forKey: .avatarUrl)
            try values.encode(description, forKey: .description)
            try values.encode(shareUsageData, forKey: .shareUsageData)
            try values.encode(emailVerified, forKey: .emailVerified)
            try values.encode(stagingSelfAccountCapabilityHash, forKey: .stagingSelfAccountCapabilityHash)
            try values.encode(retiredAt, forKey: .retiredAt)
            try values.encode(preferredLanguage, forKey: .preferredLanguage)
            try values.encode(preferredTimezone, forKey: .preferredTimezone)
            try values.encode(preferredTranslationMode, forKey: .preferredTranslationMode)
            try values.encode(autoTranslationEnabled, forKey: .autoTranslationEnabled)
            try values.encode(preferredTranslationDisplay, forKey: .preferredTranslationDisplay)
            try values.encode(preferredTimeFormat, forKey: .preferredTimeFormat)
            try values.encode(preferredMessageBodyFontSize, forKey: .preferredMessageBodyFontSize)
            try values.encode(referralSource, forKey: .referralSource)
            try values.encode(referralSourceOther, forKey: .referralSourceOther)
            try values.encode(referralSourceSkippedAt, forKey: .referralSourceSkippedAt)
            try values.encode(signupRole, forKey: .signupRole)
            try values.encode(signupSurveyCompletedAt, forKey: .signupSurveyCompletedAt)
            try values.encode(firstOnboardingCompletedAt, forKey: .firstOnboardingCompletedAt)
            try values.encode(firstOnboardingCompletedSessionFamilyId, forKey: .firstOnboardingCompletedSessionFamilyId)
        }

        var record: Account {
            Account(
                id: id,
                email: email,
                passwordHash: passwordHash,
                passwordCredentialEstablishedAt: passwordCredentialEstablishedAt,
                displayLanguage: displayLanguage,
                name: name,
                displayName: displayName,
                profileSetupSuggestedHandle: profileSetupSuggestedHandle,
                profileSetupProvider: profileSetupProvider,
                profileSetupCompletedAt: profileSetupCompletedAt,
                avatarUrl: avatarUrl,
                description: description,
                shareUsageData: shareUsageData,
                emailVerified: emailVerified,
                stagingSelfAccountCapabilityHash: stagingSelfAccountCapabilityHash,
                retiredAt: retiredAt,
                preferredLanguage: preferredLanguage,
                preferredTimezone: preferredTimezone,
                preferredTranslationMode: preferredTranslationMode,
                autoTranslationEnabled: autoTranslationEnabled,
                preferredTranslationDisplay: preferredTranslationDisplay,
                preferredTimeFormat: preferredTimeFormat,
                preferredMessageBodyFontSize: preferredMessageBodyFontSize,
                referralSource: referralSource,
                referralSourceOther: referralSourceOther,
                referralSourceSkippedAt: referralSourceSkippedAt,
                signupRole: signupRole,
                signupSurveyCompletedAt: signupSurveyCompletedAt,
                firstOnboardingCompletedAt: firstOnboardingCompletedAt,
                firstOnboardingCompletedSessionFamilyId: firstOnboardingCompletedSessionFamilyId
            )
        }
    }

    struct LinkedIdentityRow: Codable, Sendable {
        let userId: String
        let provider: String
        let providerUserId: String
        let providerEmail: String?

        init(_ record: LinkedIdentity) {
            userId = record.userId
            provider = record.provider
            providerUserId = record.providerUserId
            providerEmail = record.providerEmail
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

        var record: LinkedIdentity {
            LinkedIdentity(
                userId: userId,
                provider: provider,
                providerUserId: providerUserId,
                providerEmail: providerEmail
            )
        }
    }

    struct SocialCompletionRow: Codable, Sendable {
        let provider: String
        let code: String
        let mode: String
        let intendedAction: String
        let email: String
        let returnTo: String
        let userId: String?
        let providerUserId: String?
        let linkOnConflict: Bool

        init(_ record: SocialCompletion) {
            provider = record.provider
            code = record.code
            mode = record.mode
            intendedAction = record.intendedAction
            email = record.email
            returnTo = record.returnTo
            userId = record.userId
            providerUserId = record.providerUserId
            linkOnConflict = record.linkOnConflict
        }

        private enum CodingKeys: String, CodingKey {
            case provider
            case code
            case mode
            case intendedAction
            case email
            case returnTo
            case userId
            case providerUserId
            case linkOnConflict
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            provider = try values.decode(String.self, forKey: .provider)
            code = try values.decode(String.self, forKey: .code)
            mode = try values.decode(String.self, forKey: .mode)
            intendedAction = try values.decode(String.self, forKey: .intendedAction)
            email = try values.decode(String.self, forKey: .email)
            returnTo = try values.decode(String.self, forKey: .returnTo)
            userId = try values.decode(String?.self, forKey: .userId)
            providerUserId = try values.decode(String?.self, forKey: .providerUserId)
            linkOnConflict = try values.decode(Bool.self, forKey: .linkOnConflict)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(provider, forKey: .provider)
            try values.encode(code, forKey: .code)
            try values.encode(mode, forKey: .mode)
            try values.encode(intendedAction, forKey: .intendedAction)
            try values.encode(email, forKey: .email)
            try values.encode(returnTo, forKey: .returnTo)
            try values.encode(userId, forKey: .userId)
            try values.encode(providerUserId, forKey: .providerUserId)
            try values.encode(linkOnConflict, forKey: .linkOnConflict)
        }

        var record: SocialCompletion {
            SocialCompletion(
                provider: provider,
                code: code,
                mode: mode,
                intendedAction: intendedAction,
                email: email,
                returnTo: returnTo,
                userId: userId,
                providerUserId: providerUserId,
                linkOnConflict: linkOnConflict
            )
        }
    }

    struct PendingSocialLinkRow: Codable, Sendable {
        let token: String
        let provider: String
        let providerUserId: String
        let email: String
        let returnTo: String?
        let returnUri: String?
        let expiresAt: Date
        let consumed: Bool
        let cancelled: Bool

        init(_ record: PendingSocialLink) {
            token = record.token
            provider = record.provider
            providerUserId = record.providerUserId
            email = record.email
            returnTo = record.returnTo
            returnUri = record.returnUri
            expiresAt = record.expiresAt
            consumed = record.consumed
            cancelled = record.cancelled
        }

        private enum CodingKeys: String, CodingKey {
            case token
            case provider
            case providerUserId
            case email
            case returnTo
            case returnUri
            case expiresAt
            case consumed
            case cancelled
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            token = try values.decode(String.self, forKey: .token)
            provider = try values.decode(String.self, forKey: .provider)
            providerUserId = try values.decode(String.self, forKey: .providerUserId)
            email = try values.decode(String.self, forKey: .email)
            returnTo = try values.decode(String?.self, forKey: .returnTo)
            returnUri = try values.decode(String?.self, forKey: .returnUri)
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
            consumed = try values.decode(Bool.self, forKey: .consumed)
            cancelled = try values.decode(Bool.self, forKey: .cancelled)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(token, forKey: .token)
            try values.encode(provider, forKey: .provider)
            try values.encode(providerUserId, forKey: .providerUserId)
            try values.encode(email, forKey: .email)
            try values.encode(returnTo, forKey: .returnTo)
            try values.encode(returnUri, forKey: .returnUri)
            try values.encode(expiresAt, forKey: .expiresAt)
            try values.encode(consumed, forKey: .consumed)
            try values.encode(cancelled, forKey: .cancelled)
        }

        var record: PendingSocialLink {
            PendingSocialLink(
                token: token,
                provider: provider,
                providerUserId: providerUserId,
                email: email,
                returnTo: returnTo,
                returnUri: returnUri,
                expiresAt: expiresAt,
                consumed: consumed,
                cancelled: cancelled
            )
        }
    }

}
