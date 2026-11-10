import Foundation

// Separate persistence DTOs avoid changing the domain records or their conformances.
// Every key is required, including nullable fields; nil is encoded as JSON null.
extension AuthProfilePersistence {
    struct EmailVerificationRow: Codable, Sendable {
        let userId: String
        let tokenHash: String
        let rawToken: String
        let createdAt: Date
        let expiresAt: Date

        init(_ record: EmailVerificationRecord) {
            userId = record.userId
            tokenHash = record.tokenHash
            rawToken = record.rawToken
            createdAt = record.createdAt
            expiresAt = record.expiresAt
        }

        private enum CodingKeys: String, CodingKey {
            case userId
            case tokenHash
            case rawToken
            case createdAt
            case expiresAt
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userId = try values.decode(String.self, forKey: .userId)
            tokenHash = try values.decode(String.self, forKey: .tokenHash)
            rawToken = try values.decode(String.self, forKey: .rawToken)
            createdAt = try values.decode(Date.self, forKey: .createdAt)
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userId, forKey: .userId)
            try values.encode(tokenHash, forKey: .tokenHash)
            try values.encode(rawToken, forKey: .rawToken)
            try values.encode(createdAt, forKey: .createdAt)
            try values.encode(expiresAt, forKey: .expiresAt)
        }

        var record: EmailVerificationRecord {
            EmailVerificationRecord(
                userId: userId,
                tokenHash: tokenHash,
                rawToken: rawToken,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
        }
    }

    struct LegalAcceptanceRow: Codable, Sendable {
        let termsVersion: String
        let privacyVersion: String
        let termsUrl: String
        let privacyUrl: String
        let source: String
        let userAgentHash: String?
        let locale: String?

        init(_ record: EmailLegalAcceptance) {
            termsVersion = record.termsVersion
            privacyVersion = record.privacyVersion
            termsUrl = record.termsUrl
            privacyUrl = record.privacyUrl
            source = record.source
            userAgentHash = record.userAgentHash
            locale = record.locale
        }

        private enum CodingKeys: String, CodingKey {
            case termsVersion
            case privacyVersion
            case termsUrl
            case privacyUrl
            case source
            case userAgentHash
            case locale
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            termsVersion = try values.decode(String.self, forKey: .termsVersion)
            privacyVersion = try values.decode(String.self, forKey: .privacyVersion)
            termsUrl = try values.decode(String.self, forKey: .termsUrl)
            privacyUrl = try values.decode(String.self, forKey: .privacyUrl)
            source = try values.decode(String.self, forKey: .source)
            userAgentHash = try values.decode(String?.self, forKey: .userAgentHash)
            locale = try values.decode(String?.self, forKey: .locale)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(termsVersion, forKey: .termsVersion)
            try values.encode(privacyVersion, forKey: .privacyVersion)
            try values.encode(termsUrl, forKey: .termsUrl)
            try values.encode(privacyUrl, forKey: .privacyUrl)
            try values.encode(source, forKey: .source)
            try values.encode(userAgentHash, forKey: .userAgentHash)
            try values.encode(locale, forKey: .locale)
        }

        var record: EmailLegalAcceptance {
            EmailLegalAcceptance(
                termsVersion: termsVersion,
                privacyVersion: privacyVersion,
                termsUrl: termsUrl,
                privacyUrl: privacyUrl,
                source: source,
                userAgentHash: userAgentHash,
                locale: locale
            )
        }
    }

    struct TimezoneObservationRow: Codable, Sendable {
        let firstTimezone: String
        let firstAt: Date
        let lastTimezone: String
        let lastAt: Date

        init(_ record: TimezoneObservation) {
            firstTimezone = record.firstTimezone
            firstAt = record.firstAt
            lastTimezone = record.lastTimezone
            lastAt = record.lastAt
        }

        private enum CodingKeys: String, CodingKey {
            case firstTimezone
            case firstAt
            case lastTimezone
            case lastAt
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            firstTimezone = try values.decode(String.self, forKey: .firstTimezone)
            firstAt = try values.decode(Date.self, forKey: .firstAt)
            lastTimezone = try values.decode(String.self, forKey: .lastTimezone)
            lastAt = try values.decode(Date.self, forKey: .lastAt)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(firstTimezone, forKey: .firstTimezone)
            try values.encode(firstAt, forKey: .firstAt)
            try values.encode(lastTimezone, forKey: .lastTimezone)
            try values.encode(lastAt, forKey: .lastAt)
        }

        var record: TimezoneObservation {
            TimezoneObservation(
                firstTimezone: firstTimezone,
                firstAt: firstAt,
                lastTimezone: lastTimezone,
                lastAt: lastAt
            )
        }
    }

    struct MobileEmailContactRow: Codable, Sendable {
        let userId: String
        let email: String
        let audienceId: String
        let status: String
        let optedOutAt: Date?

        init(_ record: MobileAppEmailContact) {
            userId = record.userId
            email = record.email
            audienceId = record.audienceId
            status = record.status
            optedOutAt = record.optedOutAt
        }

        private enum CodingKeys: String, CodingKey {
            case userId
            case email
            case audienceId
            case status
            case optedOutAt
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userId = try values.decode(String.self, forKey: .userId)
            email = try values.decode(String.self, forKey: .email)
            audienceId = try values.decode(String.self, forKey: .audienceId)
            status = try values.decode(String.self, forKey: .status)
            optedOutAt = try values.decode(Date?.self, forKey: .optedOutAt)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userId, forKey: .userId)
            try values.encode(email, forKey: .email)
            try values.encode(audienceId, forKey: .audienceId)
            try values.encode(status, forKey: .status)
            try values.encode(optedOutAt, forKey: .optedOutAt)
        }

        var record: MobileAppEmailContact {
            MobileAppEmailContact(
                userId: userId,
                email: email,
                audienceId: audienceId,
                status: status,
                optedOutAt: optedOutAt
            )
        }
    }

    struct MobileEmailJourneyRow: Codable, Sendable {
        let userId: String
        let email: String
        let journeyKey: String
        let day1Status: String
        let day1EmailId: String?
        let suppressedReason: String?
        let canceledAt: Date?

        init(_ record: MobileAppEmailJourney) {
            userId = record.userId
            email = record.email
            journeyKey = record.journeyKey
            day1Status = record.day1Status
            day1EmailId = record.day1EmailId
            suppressedReason = record.suppressedReason
            canceledAt = record.canceledAt
        }

        private enum CodingKeys: String, CodingKey {
            case userId
            case email
            case journeyKey
            case day1Status
            case day1EmailId
            case suppressedReason
            case canceledAt
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userId = try values.decode(String.self, forKey: .userId)
            email = try values.decode(String.self, forKey: .email)
            journeyKey = try values.decode(String.self, forKey: .journeyKey)
            day1Status = try values.decode(String.self, forKey: .day1Status)
            day1EmailId = try values.decode(String?.self, forKey: .day1EmailId)
            suppressedReason = try values.decode(String?.self, forKey: .suppressedReason)
            canceledAt = try values.decode(Date?.self, forKey: .canceledAt)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userId, forKey: .userId)
            try values.encode(email, forKey: .email)
            try values.encode(journeyKey, forKey: .journeyKey)
            try values.encode(day1Status, forKey: .day1Status)
            try values.encode(day1EmailId, forKey: .day1EmailId)
            try values.encode(suppressedReason, forKey: .suppressedReason)
            try values.encode(canceledAt, forKey: .canceledAt)
        }

        var record: MobileAppEmailJourney {
            MobileAppEmailJourney(
                userId: userId,
                email: email,
                journeyKey: journeyKey,
                day1Status: day1Status,
                day1EmailId: day1EmailId,
                suppressedReason: suppressedReason,
                canceledAt: canceledAt
            )
        }
    }

}
