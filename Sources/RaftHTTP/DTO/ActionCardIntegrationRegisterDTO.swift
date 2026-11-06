import Foundation
import RaftShared

// MARK: - Request bodies
//
// The retired handlers read untyped JSON dictionaries with `as?` casts,
// so a wrong-typed or missing member never failed the whole body; it fell
// through to the published 400. These decoders keep that leniency: the root
// value is read as a `JSONValue` tree and each member is projected with the
// legacy cast rules, so a body the legacy parser accepted decodes to the
// same fields.

extension JSONValue {
    /// Foundation `as? String`.
    var legacyString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Foundation `as? Bool` over the legacy `NSNumber` bridge: a
    /// JSON boolean is itself, and any nonzero number is `true`.
    var legacyBool: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .integer(let value):
            return value != 0
        case .number(let value):
            return value != 0
        default:
            return nil
        }
    }

    /// Foundation `(value as? [Any])?.compactMap { $0 as? String }`.
    var legacyStringArray: [String] {
        guard case .array(let elements) = self else { return [] }
        return elements.compactMap(\.legacyString)
    }

    /// Foundation `as? Dictionary`, as an ordered-preserving member map.
    var legacyObject: [String: JSONValue]? {
        guard case .object(let members) = self else { return nil }
        return members
    }
}

/// `POST /internal/agent-api/integrations/app/prepare` request body.
///
/// The legacy handler required `mode == "register"`, a non-empty trimmed
/// `name`, and a non-empty trimmed `returnUrl`; it treated a wrong-typed member
/// as absent. A missing or malformed body decodes to the empty value and
/// publishes the same `Invalid app registration request` 400.
public struct IntegrationAppPrepareRequest: Sendable, Equatable {
    public var mode: String?
    public var name: String?
    public var returnUrl: String?
    public var target: String?
    public var clientKey: String?
    public var homepageUrl: String?
    public var agentManifestUrl: String?
    public var scopes: [String]
    public var category: String?
    public var unsafeDemoUrlOverride: Bool

    public init(
        mode: String? = nil,
        name: String? = nil,
        returnUrl: String? = nil,
        target: String? = nil,
        clientKey: String? = nil,
        homepageUrl: String? = nil,
        agentManifestUrl: String? = nil,
        scopes: [String] = [],
        category: String? = nil,
        unsafeDemoUrlOverride: Bool = false
    ) {
        self.mode = mode
        self.name = name
        self.returnUrl = returnUrl
        self.target = target
        self.clientKey = clientKey
        self.homepageUrl = homepageUrl
        self.agentManifestUrl = agentManifestUrl
        self.scopes = scopes
        self.category = category
        self.unsafeDemoUrlOverride = unsafeDemoUrlOverride
    }
}

extension IntegrationAppPrepareRequest: Decodable {
    public init(from decoder: any Decoder) throws {
        let value = (try? JSONValue(from: decoder)) ?? .null
        let members = value.legacyObject ?? [:]
        mode = members["mode"]?.legacyString
        name = members["name"]?.legacyString
        returnUrl = members["returnUrl"]?.legacyString
        target = members["target"]?.legacyString
        clientKey = members["clientKey"]?.legacyString
        homepageUrl = members["homepageUrl"]?.legacyString
        agentManifestUrl = members["agentManifestUrl"]?.legacyString
        scopes = members["scopes"]?.legacyStringArray ?? []
        category = members["category"]?.legacyString
        unsafeDemoUrlOverride = members["unsafeDemoUrlOverride"]?.legacyBool == true
    }
}

/// `POST /internal/agent-api/prepare-action` request body.
///
/// `target` and `action` are the two members the legacy handler required;
/// everything else is read from `action` by the service. `raw` keeps the whole
/// decoded root so the idempotency fingerprint covers the same bytes the
/// legacy untyped object did.
public struct ActionCardPrepareRequest: Sendable, Equatable {
    public var target: String?
    public var action: [String: JSONValue]?
    public var raw: JSONValue?

    public init(
        target: String? = nil,
        action: [String: JSONValue]? = nil,
        raw: JSONValue? = nil
    ) {
        self.target = target
        self.action = action
        self.raw = raw
    }
}

extension ActionCardPrepareRequest: Decodable {
    public init(from decoder: any Decoder) throws {
        let value = (try? JSONValue(from: decoder)) ?? .null
        raw = value
        let members = value.legacyObject ?? [:]
        target = members["target"]?.legacyString
        action = members["action"]?.legacyObject
    }
}

/// `POST /api/actions/:messageId/execute` request body.
///
/// Only `expectedState` is policy input. The legacy handler parsed the body
/// with `as? String`, so a wrong-typed member behaved like an absent one.
public struct ActionCardExecuteRequest: Sendable, Equatable {
    public var expectedState: String?

    public init(expectedState: String? = nil) {
        self.expectedState = expectedState
    }
}

extension ActionCardExecuteRequest: Decodable {
    public init(from decoder: any Decoder) throws {
        let value = (try? JSONValue(from: decoder)) ?? .null
        expectedState = value.legacyObject?["expectedState"]?.legacyString
    }
}

/// The three members a legacy Marketplace client dictionary contributed to a
/// prepared card, projected out of `OAuthLedger`'s untyped dictionary so the
/// service never handles an untyped dictionary.
public struct MarketplaceClientIdentity: Sendable, Equatable {
    public var recordId: String
    public var clientKey: String
    public var name: String

    public init(recordId: String, clientKey: String, name: String) {
        self.recordId = recordId
        self.clientKey = clientKey
        self.name = name
    }
}

// MARK: - `POST /internal/agent-api/integrations/app/prepare`

/// The published `201` body of the app-prepare route.
///
/// Order: `status`, `actionCardMessageId`, `action`.
public struct IntegrationAppPrepareResponse: JSONBodyConvertible, Sendable, Equatable {
    public var actionCardMessageId: String
    public var action: IntegrationAppPrepareAction

    public init(actionCardMessageId: String, action: IntegrationAppPrepareAction) {
        self.actionCardMessageId = actionCardMessageId
        self.action = action
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("status", "prepared")
        body.append("actionCardMessageId", actionCardMessageId)
        body.append("action", action.jsonBody)
        return body.json
    }
}

/// The `action` member of the prepare reply. The legacy handler appended
/// `clientKey` and `homepageUrl` only when present, in that order.
public struct IntegrationAppPrepareAction: JSONBodyConvertible, Sendable, Equatable {
    public var name: String
    public var clientKey: String?
    public var homepageUrl: String?
    public var returnUrl: String
    public var scopes: [String]

    public init(
        name: String,
        clientKey: String? = nil,
        homepageUrl: String? = nil,
        returnUrl: String,
        scopes: [String]
    ) {
        self.name = name
        self.clientKey = clientKey
        self.homepageUrl = homepageUrl
        self.returnUrl = returnUrl
        self.scopes = scopes
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("type", "integration:register_app")
        body.append("name", name)
        body.append("clientKey", ifPresent: clientKey)
        body.append("homepageUrl", ifPresent: homepageUrl)
        body.append("returnUrl", returnUrl)
        body.append("scopes", .array(scopes.map { .string($0) }))
        return body.json
    }
}

// MARK: - `POST /internal/agent-api/prepare-action`

/// The published `201` body of the prepare-action route.
///
/// `metadata` is the action-card projection of the prepared row. Its member
/// order belongs to the card projection (`ActionCardMarketplaceService`), so it
/// enters as a rendered fragment; a prepared reply is `messageId` then
/// `metadata`, and an idempotent replay publishes the first reply's bytes
/// unchanged.
public struct ActionCardPrepareResponse: Encodable, JSONBodyConvertible, Sendable, Equatable {
    public var messageId: String
    public var metadataJSON: String
    /// The stored body of the first reply when this response is an idempotent
    /// replay. The route then publishes the legacy no-store header set.
    public var idempotentReplayBody: String?

    public init(
        messageId: String,
        metadataJSON: String,
        idempotentReplayBody: String? = nil
    ) {
        self.messageId = messageId
        self.metadataJSON = metadataJSON
        self.idempotentReplayBody = idempotentReplayBody
    }

    public var isIdempotentReplay: Bool { idempotentReplayBody != nil }

    public var jsonBody: OrderedJSON {
        if let idempotentReplayBody { return .raw(idempotentReplayBody) }
        var body = OrderedJSONObject()
        body.append("messageId", messageId)
        body.append("metadata", .raw(metadataJSON))
        return body.json
    }
}

// MARK: - `POST /api/actions/:messageId/execute`

/// The published `200` body of every action-card execute branch: `messageId`
/// then the card projection's `metadata` fragment.
public struct ActionCardExecuteResponse: JSONBodyConvertible, Sendable, Equatable {
    public var messageId: String
    public var metadataJSON: String

    public init(messageId: String, metadataJSON: String) {
        self.messageId = messageId
        self.metadataJSON = metadataJSON
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("messageId", messageId)
        body.append("metadata", .raw(metadataJSON))
        return body.json
    }
}
