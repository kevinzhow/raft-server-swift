import Foundation

/// A principal admitted by Node's whole attachment flex mount. A preview
/// capability is not promoted to an access token or a human write credential.
public enum AttachmentFlexActor: Sendable, Equatable {
    case user(userId: String)
    case machine(machineId: String)
}

public enum AttachmentFlexCredentialSource: Sendable, Equatable {
    case authorizationJWT
    case queryJWT
    case machine
    case computer
    case previewToken
}

/// Immutable, request-local result. Only this module's store-backed admission
/// service constructs it; the HTTP feature cannot manufacture an admission.
public struct AttachmentFlexAdmission: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let actor: AttachmentFlexActor
    public let serverId: String
    public let credentialSource: AttachmentFlexCredentialSource
    public let previewProof: AttachmentPreviewTokens.Payload?
    // Request-local credential for existing pre/post-I/O revocation guards.
    // Never published, serialized, logged, or exposed to the HTTP module.
    let credential: String?
    public var description: String { "AttachmentFlexAdmission(redacted)" }
    public var debugDescription: String { description }

    init(actor: AttachmentFlexActor, serverId: String,
         credentialSource: AttachmentFlexCredentialSource,
         previewProof: AttachmentPreviewTokens.Payload? = nil, credential: String? = nil) {
        self.actor = actor
        self.serverId = serverId
        self.credentialSource = credentialSource
        self.previewProof = previewProof
        self.credential = credential
    }
}

/// Transport scalars, before authentication. The path remains case-preserving:
/// auth.ts's preview-path check is case-sensitive even though Express routes
/// are case-insensitive. Query arrays are represented as absent scalars.
public struct AttachmentFlexRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let authorization: String?
    public let queryToken: String?
    public let previewToken: String?
    public let headerServerId: String?
    public let queryServerId: String?
    public let relativePath: String
    public var description: String { "AttachmentFlexRequest(redacted)" }
    public var debugDescription: String { description }

    public init(authorization: String?, queryToken: String?, previewToken: String?,
                headerServerId: String?, queryServerId: String?, relativePath: String) {
        self.authorization = authorization
        self.queryToken = queryToken
        self.previewToken = previewToken
        self.headerServerId = headerServerId
        self.queryServerId = queryServerId
        self.relativePath = relativePath
    }
}

public enum AttachmentFlexAdmissionError: DomainError, Equatable {
    case authenticationRequired
    case missingServerId
    case missingServerIdHeader
    case notAMember
    case invalidMachineAPIKey
    case invalidComputerCredential
    case linkedMachineNotFound
    case serverNoLongerExists
    case legacyMachineKeyMigrated

    public var status: UInt {
        switch self {
        case .missingServerId, .missingServerIdHeader: 400
        case .notAMember: 403
        default: 401
        }
    }

    public var errorMessage: String {
        switch self {
        case .authenticationRequired: "Authentication required"
        case .missingServerId: "Missing X-Server-Id"
        case .missingServerIdHeader: "Missing X-Server-Id header"
        case .notAMember: "Not a member of this server"
        case .invalidMachineAPIKey: "Invalid machine API key"
        case .invalidComputerCredential: "Invalid computer credential"
        case .linkedMachineNotFound: "Machine linked to computer credential not found"
        case .serverNoLongerExists: "Server no longer exists"
        case .legacyMachineKeyMigrated: "Legacy machine key has been migrated to a Computer attachment"
        }
    }

    public var errorCode: String? {
        self == .legacyMachineKeyMigrated ? "legacy_machine_key_migrated" : nil
    }
    public var errorBody: OrderedJSON? { nil }
}
