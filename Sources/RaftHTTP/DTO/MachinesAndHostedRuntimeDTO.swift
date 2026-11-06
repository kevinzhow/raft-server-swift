import Foundation

// Response shapes for the onboarding identity adoption, the hosted runtime and
// the provider account connections.
//
// Every response owns its published member order as an `OrderedJSON` tree
// (`JSONBodyConvertible`); the strings the retired handlers concatenated by hand
// are reproduced byte for byte.

/// One field the onboarding adoption would change, or changed.
public struct OnboardingAdoptionChangeDTO: Sendable, Equatable {
    public var field: String
    public var before: String?
    public var after: String?

    public init(field: String, before: String?, after: String?) {
        self.field = field
        self.before = before
        self.after = after
    }

    var json: OrderedJSON {
        .object([
            OrderedJSONField("field", field),
            OrderedJSONField("before", optional: before),
            OrderedJSONField("after", optional: after),
        ])
    }
}

/// `GET`/`POST /api/agents/:id/onboarding-identity-adoption`.
public struct OnboardingAdoptionResponse: JSONBodyConvertible, Equatable {
    public struct AgentSummary: Sendable, Equatable {
        public var id: String
        public var name: String
        public var displayName: String
        public var description: String?
        public var avatarUrl: String?
        public var serverRole: String

        public init(
            id: String,
            name: String,
            displayName: String,
            description: String?,
            avatarUrl: String?,
            serverRole: String
        ) {
            self.id = id
            self.name = name
            self.displayName = displayName
            self.description = description
            self.avatarUrl = avatarUrl
            self.serverRole = serverRole
        }
    }

    public var canAdopt: Bool
    public var changes: [OnboardingAdoptionChangeDTO]
    public var appliedChanges: [OnboardingAdoptionChangeDTO]?
    public var agent: AgentSummary?

    public init(
        canAdopt: Bool,
        changes: [OnboardingAdoptionChangeDTO],
        appliedChanges: [OnboardingAdoptionChangeDTO]? = nil,
        agent: AgentSummary? = nil
    ) {
        self.canAdopt = canAdopt
        self.changes = changes
        self.appliedChanges = appliedChanges
        self.agent = agent
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("canAdopt", canAdopt)
        body.append("changes", .array(changes.map(\.json)))
        if let appliedChanges {
            body.append("appliedChanges", .array(appliedChanges.map(\.json)))
        }
        if let agent {
            body.append("agent", .object([
                OrderedJSONField("id", agent.id),
                OrderedJSONField("name", agent.name),
                OrderedJSONField("displayName", agent.displayName),
                OrderedJSONField("description", optional: agent.description),
                OrderedJSONField("avatarUrl", optional: agent.avatarUrl),
                OrderedJSONField("serverRole", agent.serverRole),
            ]))
        }
        return body.json
    }
}

/// `GET /api/agents/:id/hosted-runtime` and the retry acknowledgement.
public struct HostedRuntimeStatusResponse: JSONBodyConvertible, Equatable {
    public var agentId: String
    public var provider: String
    public var model: String?
    public var state: String
    public var retryNeedsModel: Bool
    public var createdAt: String
    /// The status read also publishes a `null` onboarding setup; the retry
    /// acknowledgement does not.
    public var includesOnboardingSetup: Bool

    public init(
        agentId: String,
        provider: String,
        model: String?,
        state: String,
        retryNeedsModel: Bool,
        createdAt: String,
        includesOnboardingSetup: Bool
    ) {
        self.agentId = agentId
        self.provider = provider
        self.model = model
        self.state = state
        self.retryNeedsModel = retryNeedsModel
        self.createdAt = createdAt
        self.includesOnboardingSetup = includesOnboardingSetup
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("hostedRuntime", .object([
            OrderedJSONField("agentId", agentId),
            OrderedJSONField("provider", provider),
            OrderedJSONField("model", optional: model),
            OrderedJSONField("state", state),
            OrderedJSONField("retryNeedsModel", retryNeedsModel),
            OrderedJSONField("createdAt", createdAt),
        ]))
        if includesOnboardingSetup {
            body.append("onboardingSetup", .null)
        }
        return body.json
    }
}

/// `GET /api/agents/:id/hosted-runtime/usage`: the provider's stored usage
/// document, published as received.
public struct HostedUsageResponse: JSONBodyConvertible, Equatable {
    public var rawJSON: String

    public init(rawJSON: String) {
        self.rawJSON = rawJSON
    }

    public var jsonBody: OrderedJSON { .raw(rawJSON) }
}

/// `GET`/`PUT /api/agents/:id/hosted-runtime/model`.
public struct HostedModelViewResponse: JSONBodyConvertible, Equatable {
    public struct Option: Sendable, Equatable {
        public var id: String
        public var label: String
        public var provider: String

        public init(id: String, label: String, provider: String) {
            self.id = id
            self.label = label
            self.provider = provider
        }
    }

    public var models: [Option]
    public var defaultModel: String?
    public var defaultLabel: String?
    public var model: String?
    public var label: String?
    public var source: String
    public var locked: Bool
    public var picker: Bool

    public init(
        models: [Option],
        defaultModel: String?,
        defaultLabel: String?,
        model: String?,
        label: String?,
        source: String,
        locked: Bool,
        picker: Bool
    ) {
        self.models = models
        self.defaultModel = defaultModel
        self.defaultLabel = defaultLabel
        self.model = model
        self.label = label
        self.source = source
        self.locked = locked
        self.picker = picker
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("models", .array(models.map { option in
                .object([
                    OrderedJSONField("id", option.id),
                    OrderedJSONField("label", option.label),
                    OrderedJSONField("provider", option.provider),
                ])
            })),
            OrderedJSONField("default", optional: defaultModel),
            OrderedJSONField("defaultLabel", optional: defaultLabel),
            OrderedJSONField("model", optional: model),
            OrderedJSONField("label", optional: label),
            OrderedJSONField("source", source),
            OrderedJSONField("locked", locked),
            OrderedJSONField("picker", picker),
        ])
    }
}

/// `GET /api/agents/:id/connections/:provider` and the confirm/assign replies.
public struct ProviderConnectionStatusResponse: JSONBodyConvertible, Equatable {
    public struct Person: Sendable, Equatable {
        public var id: String
        public var name: String?
        /// The creator form also publishes `displayName`.
        public var displayName: String?
        public var includesDisplayName: Bool

        public init(id: String, name: String?, displayName: String? = nil, includesDisplayName: Bool = false) {
            self.id = id
            self.name = name
            self.displayName = displayName
            self.includesDisplayName = includesDisplayName
        }

        var json: OrderedJSON {
            var fields = [
                OrderedJSONField("id", id),
                OrderedJSONField("name", optional: name),
            ]
            if includesDisplayName {
                fields.append(OrderedJSONField("displayName", optional: displayName))
            }
            return .object(fields)
        }
    }

    public struct Connector: Sendable, Equatable {
        public var id: String
        public var account: String
        public var createdAt: String?
        public var creator: Person?
        public var current: Bool
        public var canManage: Bool

        public init(
            id: String,
            account: String,
            createdAt: String?,
            creator: Person?,
            current: Bool,
            canManage: Bool
        ) {
            self.id = id
            self.account = account
            self.createdAt = createdAt
            self.creator = creator
            self.current = current
            self.canManage = canManage
        }
    }

    public var provider: String
    public var connected: Bool
    public var account: String?
    public var connectedAt: String?
    public var connectedBy: Person?
    public var scopes: [String]
    public var connectorId: String?
    public var connectors: [Connector]

    public init(
        provider: String,
        connected: Bool,
        account: String?,
        connectedAt: String?,
        connectedBy: Person?,
        scopes: [String],
        connectorId: String?,
        connectors: [Connector]
    ) {
        self.provider = provider
        self.connected = connected
        self.account = account
        self.connectedAt = connectedAt
        self.connectedBy = connectedBy
        self.scopes = scopes
        self.connectorId = connectorId
        self.connectors = connectors
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("provider", provider),
            OrderedJSONField("supported", true),
            OrderedJSONField("connected", connected),
            OrderedJSONField("account", optional: account),
            OrderedJSONField("connectedAt", optional: connectedAt),
            OrderedJSONField("connectedBy", connectedBy?.json ?? .null),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
            OrderedJSONField("connectorId", optional: connectorId),
            OrderedJSONField("connectors", .array(connectors.map { connector in
                .object([
                    OrderedJSONField("id", connector.id),
                    OrderedJSONField("account", connector.account),
                    OrderedJSONField("createdAt", optional: connector.createdAt),
                    OrderedJSONField("creator", connector.creator?.json ?? .null),
                    OrderedJSONField("current", connector.current),
                    OrderedJSONField("canManage", connector.canManage),
                ])
            })),
        ])
    }
}

/// `GET /api/agents/:id/connections/:provider`: the connection status, or the
/// `supported: false` answer when the provider has no connections surface.
public enum ProviderConnectionStatusReply: JSONBodyConvertible, Equatable {
    case status(ProviderConnectionStatusResponse)
    case unsupported(provider: String)

    public var jsonBody: OrderedJSON {
        switch self {
        case .status(let response):
            response.jsonBody
        case .unsupported(let provider):
            .object([
                OrderedJSONField("provider", provider),
                OrderedJSONField("supported", false),
            ])
        }
    }
}

/// `POST /api/agents/:id/connections/:provider`: the provider consent link.
public struct ProviderConnectionStartResponse: JSONBodyConvertible, Equatable {
    public var url: String
    public var expiresAt: String
    public var scopes: [String]

    public init(url: String, expiresAt: String, scopes: [String]) {
        self.url = url
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("url", url),
            OrderedJSONField("expiresAt", expiresAt),
            OrderedJSONField("scopes", .array(scopes.map(OrderedJSON.string))),
        ])
    }
}
