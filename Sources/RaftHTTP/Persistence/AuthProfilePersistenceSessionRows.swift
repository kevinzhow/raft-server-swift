import Foundation

// Separate persistence DTOs avoid changing the domain records or their conformances.
// Every key is required, including nullable fields; nil is encoded as JSON null.
extension AuthProfilePersistence {
    struct LiveSessionRow: Codable, Sendable {
        let userId: String
        let familyId: String

        init(_ record: LiveSession) {
            userId = record.userId
            familyId = record.familyId
        }

        private enum CodingKeys: String, CodingKey {
            case userId
            case familyId
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userId = try values.decode(String.self, forKey: .userId)
            familyId = try values.decode(String.self, forKey: .familyId)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userId, forKey: .userId)
            try values.encode(familyId, forKey: .familyId)
        }

        var record: LiveSession {
            LiveSession(
                userId: userId,
                familyId: familyId
            )
        }
    }

    struct SessionFamilyRow: Codable, Sendable {
        let userId: String
        let revokedAt: Date?
        let revokedReason: String?
        let revokeCapabilityNonce: String?
        let capabilityRetainUntil: Date?

        init(_ record: SessionFamily) {
            userId = record.userId
            revokedAt = record.revokedAt
            revokedReason = record.revokedReason
            revokeCapabilityNonce = record.revokeCapabilityNonce
            capabilityRetainUntil = record.capabilityRetainUntil
        }

        private enum CodingKeys: String, CodingKey {
            case userId
            case revokedAt
            case revokedReason
            case revokeCapabilityNonce
            case capabilityRetainUntil
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userId = try values.decode(String.self, forKey: .userId)
            revokedAt = try values.decode(Date?.self, forKey: .revokedAt)
            revokedReason = try values.decode(String?.self, forKey: .revokedReason)
            revokeCapabilityNonce = try values.decode(String?.self, forKey: .revokeCapabilityNonce)
            capabilityRetainUntil = try values.decode(Date?.self, forKey: .capabilityRetainUntil)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userId, forKey: .userId)
            try values.encode(revokedAt, forKey: .revokedAt)
            try values.encode(revokedReason, forKey: .revokedReason)
            try values.encode(revokeCapabilityNonce, forKey: .revokeCapabilityNonce)
            try values.encode(capabilityRetainUntil, forKey: .capabilityRetainUntil)
        }

        var record: SessionFamily {
            SessionFamily(
                userId: userId,
                revokedAt: revokedAt,
                revokedReason: revokedReason,
                revokeCapabilityNonce: revokeCapabilityNonce,
                capabilityRetainUntil: capabilityRetainUntil
            )
        }
    }

    struct RotationReceiptRow: Codable, Sendable {
        let attemptId: String
        let installationId: String
        let userId: String
        let familyId: String
        let successor: String
        let ciphertext: String
        let expiresAt: Date

        init(_ record: RotationReceipt) {
            attemptId = record.attemptId
            installationId = record.installationId
            userId = record.userId
            familyId = record.familyId
            successor = record.successor
            ciphertext = record.ciphertext
            expiresAt = record.expiresAt
        }

        private enum CodingKeys: String, CodingKey {
            case attemptId
            case installationId
            case userId
            case familyId
            case successor
            case ciphertext
            case expiresAt
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            attemptId = try values.decode(String.self, forKey: .attemptId)
            installationId = try values.decode(String.self, forKey: .installationId)
            userId = try values.decode(String.self, forKey: .userId)
            familyId = try values.decode(String.self, forKey: .familyId)
            successor = try values.decode(String.self, forKey: .successor)
            ciphertext = try values.decode(String.self, forKey: .ciphertext)
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(attemptId, forKey: .attemptId)
            try values.encode(installationId, forKey: .installationId)
            try values.encode(userId, forKey: .userId)
            try values.encode(familyId, forKey: .familyId)
            try values.encode(successor, forKey: .successor)
            try values.encode(ciphertext, forKey: .ciphertext)
            try values.encode(expiresAt, forKey: .expiresAt)
        }

        var record: RotationReceipt {
            RotationReceipt(
                attemptId: attemptId,
                installationId: installationId,
                userId: userId,
                familyId: familyId,
                successor: successor,
                ciphertext: ciphertext,
                expiresAt: expiresAt
            )
        }
    }

    struct RetirementReceiptRow: Codable, Sendable {
        let userId: String
        let actorUserId: String
        let environment: String
        let terminalState: String
        let sessionsRevoked: Int

        init(_ record: RetirementReceipt) {
            userId = record.userId
            actorUserId = record.actorUserId
            environment = record.environment
            terminalState = record.terminalState
            sessionsRevoked = record.sessionsRevoked
        }

        private enum CodingKeys: String, CodingKey {
            case userId
            case actorUserId
            case environment
            case terminalState
            case sessionsRevoked
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            userId = try values.decode(String.self, forKey: .userId)
            actorUserId = try values.decode(String.self, forKey: .actorUserId)
            environment = try values.decode(String.self, forKey: .environment)
            terminalState = try values.decode(String.self, forKey: .terminalState)
            sessionsRevoked = try values.decode(Int.self, forKey: .sessionsRevoked)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(userId, forKey: .userId)
            try values.encode(actorUserId, forKey: .actorUserId)
            try values.encode(environment, forKey: .environment)
            try values.encode(terminalState, forKey: .terminalState)
            try values.encode(sessionsRevoked, forKey: .sessionsRevoked)
        }

        var record: RetirementReceipt {
            RetirementReceipt(
                userId: userId,
                actorUserId: actorUserId,
                environment: environment,
                terminalState: terminalState,
                sessionsRevoked: sessionsRevoked
            )
        }
    }

    struct DeviceGrantRow: Codable, Sendable {
        let deviceCode: String
        let userCode: String
        let status: String
        let approvedByUserId: String?
        let expiresAt: Date
        let clientName: String?

        init(_ record: DeviceGrant) {
            deviceCode = record.deviceCode
            userCode = record.userCode
            status = record.status
            approvedByUserId = record.approvedByUserId
            expiresAt = record.expiresAt
            clientName = record.clientName
        }

        private enum CodingKeys: String, CodingKey {
            case deviceCode
            case userCode
            case status
            case approvedByUserId
            case expiresAt
            case clientName
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            deviceCode = try values.decode(String.self, forKey: .deviceCode)
            userCode = try values.decode(String.self, forKey: .userCode)
            status = try values.decode(String.self, forKey: .status)
            approvedByUserId = try values.decode(String?.self, forKey: .approvedByUserId)
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
            clientName = try values.decode(String?.self, forKey: .clientName)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(deviceCode, forKey: .deviceCode)
            try values.encode(userCode, forKey: .userCode)
            try values.encode(status, forKey: .status)
            try values.encode(approvedByUserId, forKey: .approvedByUserId)
            try values.encode(expiresAt, forKey: .expiresAt)
            try values.encode(clientName, forKey: .clientName)
        }

        var record: DeviceGrant {
            DeviceGrant(
                deviceCode: deviceCode,
                userCode: userCode,
                status: status,
                approvedByUserId: approvedByUserId,
                expiresAt: expiresAt,
                clientName: clientName
            )
        }
    }

    struct MobileOAuthRequestRow: Codable, Sendable {
        let id: String
        let provider: String
        let mode: String
        let status: String
        let codeChallenge: String
        let returnUri: String
        let nonce: String
        let expiresAt: Date
        let handoffCode: String?
        let codeHash: String?
        let profileEmail: String?
        let profileUserId: String?
        let profileName: String?
        let userId: String?
        let linkOnConflict: Bool
        let intendedAction: String

        init(_ record: MobileOAuthRequest) {
            id = record.id
            provider = record.provider
            mode = record.mode
            status = record.status
            codeChallenge = record.codeChallenge
            returnUri = record.returnUri
            nonce = record.nonce
            expiresAt = record.expiresAt
            handoffCode = record.handoffCode
            codeHash = record.codeHash
            profileEmail = record.profileEmail
            profileUserId = record.profileUserId
            profileName = record.profileName
            userId = record.userId
            linkOnConflict = record.linkOnConflict
            intendedAction = record.intendedAction
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case provider
            case mode
            case status
            case codeChallenge
            case returnUri
            case nonce
            case expiresAt
            case handoffCode
            case codeHash
            case profileEmail
            case profileUserId
            case profileName
            case userId
            case linkOnConflict
            case intendedAction
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            provider = try values.decode(String.self, forKey: .provider)
            mode = try values.decode(String.self, forKey: .mode)
            status = try values.decode(String.self, forKey: .status)
            codeChallenge = try values.decode(String.self, forKey: .codeChallenge)
            returnUri = try values.decode(String.self, forKey: .returnUri)
            nonce = try values.decode(String.self, forKey: .nonce)
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
            handoffCode = try values.decode(String?.self, forKey: .handoffCode)
            codeHash = try values.decode(String?.self, forKey: .codeHash)
            profileEmail = try values.decode(String?.self, forKey: .profileEmail)
            profileUserId = try values.decode(String?.self, forKey: .profileUserId)
            profileName = try values.decode(String?.self, forKey: .profileName)
            userId = try values.decode(String?.self, forKey: .userId)
            linkOnConflict = try values.decode(Bool.self, forKey: .linkOnConflict)
            intendedAction = try values.decode(String.self, forKey: .intendedAction)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(provider, forKey: .provider)
            try values.encode(mode, forKey: .mode)
            try values.encode(status, forKey: .status)
            try values.encode(codeChallenge, forKey: .codeChallenge)
            try values.encode(returnUri, forKey: .returnUri)
            try values.encode(nonce, forKey: .nonce)
            try values.encode(expiresAt, forKey: .expiresAt)
            try values.encode(handoffCode, forKey: .handoffCode)
            try values.encode(codeHash, forKey: .codeHash)
            try values.encode(profileEmail, forKey: .profileEmail)
            try values.encode(profileUserId, forKey: .profileUserId)
            try values.encode(profileName, forKey: .profileName)
            try values.encode(userId, forKey: .userId)
            try values.encode(linkOnConflict, forKey: .linkOnConflict)
            try values.encode(intendedAction, forKey: .intendedAction)
        }

        var record: MobileOAuthRequest {
            MobileOAuthRequest(
                id: id,
                provider: provider,
                mode: mode,
                status: status,
                codeChallenge: codeChallenge,
                returnUri: returnUri,
                nonce: nonce,
                expiresAt: expiresAt,
                handoffCode: handoffCode,
                codeHash: codeHash,
                profileEmail: profileEmail,
                profileUserId: profileUserId,
                profileName: profileName,
                userId: userId,
                linkOnConflict: linkOnConflict,
                intendedAction: intendedAction
            )
        }
    }

    struct AppLoginRequestRow: Codable, Sendable {
        let id: String
        let returnUri: String
        let codeChallenge: String
        let status: String
        let code: String?
        let userId: String?
        let expiresAt: Date
        let consumedAt: Date?

        init(_ record: AppLoginRequest) {
            id = record.id
            returnUri = record.returnUri
            codeChallenge = record.codeChallenge
            status = record.status
            code = record.code
            userId = record.userId
            expiresAt = record.expiresAt
            consumedAt = record.consumedAt
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case returnUri
            case codeChallenge
            case status
            case code
            case userId
            case expiresAt
            case consumedAt
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            returnUri = try values.decode(String.self, forKey: .returnUri)
            codeChallenge = try values.decode(String.self, forKey: .codeChallenge)
            status = try values.decode(String.self, forKey: .status)
            code = try values.decode(String?.self, forKey: .code)
            userId = try values.decode(String?.self, forKey: .userId)
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
            consumedAt = try values.decode(Date?.self, forKey: .consumedAt)
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(returnUri, forKey: .returnUri)
            try values.encode(codeChallenge, forKey: .codeChallenge)
            try values.encode(status, forKey: .status)
            try values.encode(code, forKey: .code)
            try values.encode(userId, forKey: .userId)
            try values.encode(expiresAt, forKey: .expiresAt)
            try values.encode(consumedAt, forKey: .consumedAt)
        }

        var record: AppLoginRequest {
            AppLoginRequest(
                id: id,
                returnUri: returnUri,
                codeChallenge: codeChallenge,
                status: status,
                code: code,
                userId: userId,
                expiresAt: expiresAt,
                consumedAt: consumedAt
            )
        }
    }

}
