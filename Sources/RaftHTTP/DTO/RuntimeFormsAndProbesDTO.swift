import Foundation

// Request and response shapes for the runtime-form, runtime-probe, runtime
// account usage, onboarding/notification settings and machine registration
// routes.
//
// Every response below owns its published member order as an `OrderedJSON`
// tree (`JSONBodyConvertible`); the strings the retired handlers concatenated
// by hand are reproduced byte for byte. A value the domain stores or ships as
// pre-rendered JSON (the runtime-form catalog, a Computer's usage snapshot)
// enters as `OrderedJSON.raw`, the canonical escape hatch for an already
// rendered fragment.

// MARK: - Legacy scalar reads

extension JSONScalarValue {
    /// The legacy `value as? Bool` / `value is Bool` rule: a JSON boolean, and
    /// also the numbers `0` and `1` (they bridged to `NSNumber`).
    var legacyBool: Bool? {
        switch self {
        case .bool(let value):
            value
        case .integer(let value):
            value == 0 ? false : (value == 1 ? true : nil)
        case .number(let value):
            value == 0 ? false : (value == 1 ? true : nil)
        case .null, .string, .other:
            nil
        }
    }

    /// The legacy `value as? String`: JSON strings only.
    var legacyString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The legacy `value is NSNull`.
    var isJSONNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Request bodies

/// A top-level JSON object whose members are read leniently, one by one.
///
/// The retired handlers parsed the body with a raw object cast and then read
/// each member with `as?`, so a member of the wrong type read as absent while a
/// present member stayed distinguishable from a missing one. `members` keeps
/// that: a key is present exactly when the request carried it (explicit `null`
/// included), and `JSONScalarValue` preserves the legacy type reads. A body
/// that is not a JSON object does not decode.
public struct LenientJSONObjectRequest: Decodable, Sendable, Equatable {
    public let members: [String: JSONScalarValue]

    public init(members: [String: JSONScalarValue] = [:]) {
        self.members = members
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeUsageCodingKey.self)
        var members: [String: JSONScalarValue] = [:]
        for key in container.allKeys {
            members[key.stringValue] = try container.decode(JSONScalarValue.self, forKey: key)
        }
        self.members = members
    }

    public subscript(key: String) -> JSONScalarValue? {
        members[key]
    }
}

/// `PATCH /api/servers/:id/onboarding-settings`.
public typealias ServerOnboardingPatchRequest = LenientJSONObjectRequest
/// `PATCH /api/servers/:id/notification-settings`.
public typealias ServerNotificationPatchRequest = LenientJSONObjectRequest
/// `POST /api/servers/:id/machines`.
public typealias ServerMachineRegistrationRequest = LenientJSONObjectRequest
/// `POST /api/servers/:id/machines/:machineId/runtime-account-usage/:provider/refresh`.
public typealias RuntimeAccountUsageRefreshRequest = LenientJSONObjectRequest

/// The slice of a stored agent runtime config the runtime form projects.
///
/// Every member reads like the retired `as?` casts: a member of the wrong type
/// is absent, and `envVars` is all-or-nothing (one non-string value drops the
/// whole map).
struct AgentRuntimeConfigProjection: Decodable {
    struct Model: Decodable {
        var id: String?
        var name: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            name = try? container.decode(String.self, forKey: .name)
        }
    }

    struct Provider: Decodable {
        var kind: String?
        var apiUrl: String?

        private enum CodingKeys: String, CodingKey {
            case kind
            case apiUrl
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? container.decode(String.self, forKey: .kind)
            apiUrl = try? container.decode(String.self, forKey: .apiUrl)
        }
    }

    var model: Model?
    var provider: Provider?
    var reasoningEffort: String?
    var fastMode: Bool?
    var command: String?
    var envVars: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case model
        case provider
        case reasoningEffort
        case fastMode
        case command
        case envVars
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try? container.decode(Model.self, forKey: .model)
        provider = try? container.decode(Provider.self, forKey: .provider)
        reasoningEffort = try? container.decode(String.self, forKey: .reasoningEffort)
        fastMode = (try? container.decode(JSONScalarValue.self, forKey: .fastMode))?.legacyBool
        command = try? container.decode(String.self, forKey: .command)
        envVars = try? container.decode([String: String].self, forKey: .envVars)
    }

    /// The projection of a stored config string; anything that is not a JSON
    /// object projects as an empty config.
    static func parse(_ text: String?) -> AgentRuntimeConfigProjection {
        guard let data = text.flatMap({ $0.data(using: .utf8) }),
              let parsed = try? JSONDecoder().decode(AgentRuntimeConfigProjection.self, from: data)
        else { return AgentRuntimeConfigProjection() }
        return parsed
    }
}

/// The two Foundation `NSDictionary` facts the stored-value block keeps: a
/// string prints `/` as `\/`.
private func slashEscapedString(_ value: String) -> String {
    jsonString(value).replacingOccurrences(of: "/", with: "\\/")
}

// MARK: - Agent runtime form

/// The stored values an agent's runtime form echoes back.
///
/// The retired handler printed these through the Foundation object encoder, which escapes
/// `/` and orders keys by hash. The members print here sorted by key (the
/// deterministic reading of an unordered object) and keep the escaped slash.
public struct AgentRuntimeFormValues: Sendable, Equatable {
    public var apiUrl: String?
    public var command: String?
    public var envVars: [String: String]
    public var fastMode: Bool?
    public var model: String?
    public var provider: String?
    public var reasoningEffort: String?

    public init(
        apiUrl: String? = nil,
        command: String? = nil,
        envVars: [String: String] = [:],
        fastMode: Bool? = nil,
        model: String? = nil,
        provider: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.apiUrl = apiUrl
        self.command = command
        self.envVars = envVars
        self.fastMode = fastMode
        self.model = model
        self.provider = provider
        self.reasoningEffort = reasoningEffort
    }

    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        if let apiUrl { body.append("apiUrl", .raw(slashEscapedString(apiUrl))) }
        if let command { body.append("command", .raw(slashEscapedString(command))) }
        let env = envVars.sorted { $0.key < $1.key }
            .map { "\(slashEscapedString($0.key)):\(slashEscapedString($0.value))" }
            .joined(separator: ",")
        body.append("envVars", .raw("{\(env)}"))
        if let fastMode { body.append("fastMode", fastMode) }
        if let model { body.append("model", .raw(slashEscapedString(model))) }
        if let provider { body.append("provider", .raw(slashEscapedString(provider))) }
        if let reasoningEffort { body.append("reasoningEffort", .raw(slashEscapedString(reasoningEffort))) }
        return body.json
    }
}

/// `GET /api/agents/:id/runtime-form`.
public struct AgentRuntimeFormResponse: JSONBodyConvertible, Equatable {
    public var runtimeId: String
    public var schemaVersion: String
    public var modelLabel: String
    public var values: AgentRuntimeFormValues
    public var writeOnlyPointers: [String]

    public init(
        runtimeId: String,
        schemaVersion: String,
        modelLabel: String,
        values: AgentRuntimeFormValues,
        writeOnlyPointers: [String]
    ) {
        self.runtimeId = runtimeId
        self.schemaVersion = schemaVersion
        self.modelLabel = modelLabel
        self.values = values
        self.writeOnlyPointers = writeOnlyPointers
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("protocolVersion", 2),
            OrderedJSONField("runtimeId", runtimeId),
            OrderedJSONField("schemaVersion", schemaVersion),
            OrderedJSONField("fields", OrderedJSON.array([
                .object([
                    OrderedJSONField("key", "model"),
                    OrderedJSONField("kind", "select"),
                    OrderedJSONField("label", modelLabel),
                    OrderedJSONField("required", true),
                ]),
            ])),
            OrderedJSONField("values", values.jsonBody),
            OrderedJSONField("capabilities", RuntimeFormCapabilities.body(writeOnlyPointers: writeOnlyPointers)),
        ])
    }
}

/// The `capabilities` object every runtime form publishes.
enum RuntimeFormCapabilities {
    static func body(writeOnlyPointers: [String] = ["/apiKey"]) -> OrderedJSON {
        .object([
            OrderedJSONField("providerKinds", OrderedJSON.array([.string("preset")])),
            OrderedJSONField("writeOnlyPointers", OrderedJSON.array(writeOnlyPointers.map(OrderedJSON.string))),
            OrderedJSONField("forbiddenPointers", OrderedJSON.array([.string("/hostUserState")])),
        ])
    }
}

// MARK: - Runtime form definitions

/// A machine's runtime form definition (v1 data-schema or v2 field list).
public enum RuntimeFormDefinitionResponse: JSONBodyConvertible, Equatable {
    /// A definition the form catalog already ships as rendered JSON.
    case catalog(String)
    case builtinV2(schemaVersion: String, chinese: Bool)
    case selectV2(runtimeId: String, schemaVersion: String, chinese: Bool)
    case selectV1(runtimeId: String, schemaVersion: String)

    public var jsonBody: OrderedJSON {
        switch self {
        case .catalog(let json):
            return .raw(json)
        case .builtinV2(let schemaVersion, let chinese):
            func source(_ id: String) -> OrderedJSON {
                .object([
                    OrderedJSONField("protocolVersion", 1),
                    OrderedJSONField("runtimeId", "builtin"),
                    OrderedJSONField("schemaVersion", schemaVersion),
                    OrderedJSONField("sourceId", id),
                ])
            }
            func field(_ key: String, _ kind: String, _ label: String, required: Bool, extra: [OrderedJSONField]) -> OrderedJSON {
                .object([
                    OrderedJSONField("key", key),
                    OrderedJSONField("kind", kind),
                    OrderedJSONField("label", label),
                    OrderedJSONField("required", required),
                ] + extra)
            }
            return .object([
                OrderedJSONField("protocolVersion", 2),
                OrderedJSONField("runtimeId", "builtin"),
                OrderedJSONField("schemaVersion", schemaVersion),
                OrderedJSONField("requiredClientCapabilities", OrderedJSON.array([.string("option_source.status")])),
                OrderedJSONField("fields", OrderedJSON.array([
                    field("providerId", "select", chinese ? "提供方" : "Provider", required: true, extra: []),
                    field("apiKey", "password", chinese ? "API 密钥" : "API Key", required: true, extra: [
                        OrderedJSONField("writeOnly", true),
                    ]),
                    field("model", "dependent_select", chinese ? "模型" : "Model", required: true, extra: [
                        OrderedJSONField("dependsOn", "providerId"),
                    ]),
                    field("supportsImageInput", "boolean", chinese ? "图片输入" : "Image input", required: false, extra: []),
                ])),
                OrderedJSONField("capabilities", RuntimeFormCapabilities.body()),
                OrderedJSONField("optionSources", OrderedJSON.object([
                    OrderedJSONField("provider", source("provider")),
                    OrderedJSONField("model", source("model")),
                ])),
            ])
        case .selectV2(let runtimeId, let schemaVersion, let chinese):
            return .object([
                OrderedJSONField("protocolVersion", 2),
                OrderedJSONField("runtimeId", runtimeId),
                OrderedJSONField("schemaVersion", schemaVersion),
                OrderedJSONField("requiredClientCapabilities", OrderedJSON.array([.string("option_source.status")])),
                OrderedJSONField("fields", OrderedJSON.array([
                    .object([
                        OrderedJSONField("key", "model"),
                        OrderedJSONField("kind", "select"),
                        OrderedJSONField("label", chinese ? "模型" : "Model"),
                        OrderedJSONField("required", true),
                    ]),
                ])),
                OrderedJSONField("capabilities", RuntimeFormCapabilities.body()),
            ])
        case .selectV1(let runtimeId, let schemaVersion):
            return .object([
                OrderedJSONField("protocolVersion", 1),
                OrderedJSONField("runtimeId", runtimeId),
                OrderedJSONField("schemaVersion", schemaVersion),
                OrderedJSONField("dataSchema", OrderedJSON.object([
                    OrderedJSONField("type", "object"),
                    OrderedJSONField("properties", OrderedJSON.object([
                        OrderedJSONField("model", OrderedJSON.object([OrderedJSONField("type", "string")])),
                    ])),
                    OrderedJSONField("required", OrderedJSON.array([.string("model")])),
                ])),
                OrderedJSONField("uiSchema", OrderedJSON.object([])),
                OrderedJSONField("capabilities", RuntimeFormCapabilities.body()),
                OrderedJSONField("optionSources", OrderedJSON.object([
                    OrderedJSONField("model", OrderedJSON.object([
                        OrderedJSONField("protocolVersion", 1),
                        OrderedJSONField("runtimeId", runtimeId),
                        OrderedJSONField("schemaVersion", schemaVersion),
                        OrderedJSONField("sourceId", "model"),
                    ])),
                ])),
            ])
        }
    }
}

// MARK: - Runtime form option sources

/// One selectable model of a `select` option source.
public struct RuntimeProbeOption: Sendable, Equatable {
    public var value: String
    public var label: String
    public var supportedReasoningEfforts: [String]
    public var defaultReasoningEffort: String?

    /// `reasoning` publishes the effort metadata the probe reported; a model
    /// without efforts prints only `value` and `label`.
    public init(_ model: RuntimeModelProbeModel, reasoning: Bool) {
        value = model.id
        label = model.label
        if reasoning, let efforts = model.supportedReasoningEfforts, !efforts.isEmpty {
            supportedReasoningEfforts = efforts
            defaultReasoningEffort = model.defaultReasoningEffort
        } else {
            supportedReasoningEfforts = []
            defaultReasoningEffort = nil
        }
    }

    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("value", value)
        body.append("label", label)
        if !supportedReasoningEfforts.isEmpty {
            body.append("supportedReasoningEfforts", .array(supportedReasoningEfforts.map(OrderedJSON.string)))
            body.append("defaultReasoningEffort", ifPresent: defaultReasoningEffort)
        }
        return body.json
    }
}

/// One `{value,label}` choice (cached models and the builtin catalog).
public struct RuntimeModelChoice: Sendable, Equatable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }

    var jsonBody: OrderedJSON {
        .object([OrderedJSONField("value", value), OrderedJSONField("label", label)])
    }
}

/// The v1-envelope `select` source for a runtime's models.
///
/// `customValueAllowed`, `status`, `reason` and `retryable` are members only
/// when the runtime publishes them, always in this order after `defaultValue`.
public struct RuntimeModelSourceBody: Sendable, Equatable {
    public var runtimeId: String
    public var schemaVersion: String
    public var options: [RuntimeProbeOption]
    public var defaultValue: String
    public var customValueAllowed: Bool?
    public var status: String?
    public var reason: String?
    public var retryable: Bool?

    public init(
        runtimeId: String,
        schemaVersion: String,
        options: [RuntimeProbeOption],
        defaultValue: String,
        customValueAllowed: Bool? = nil,
        status: String? = nil,
        reason: String? = nil,
        retryable: Bool? = nil
    ) {
        self.runtimeId = runtimeId
        self.schemaVersion = schemaVersion
        self.options = options
        self.defaultValue = defaultValue
        self.customValueAllowed = customValueAllowed
        self.status = status
        self.reason = reason
        self.retryable = retryable
    }

    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("protocolVersion", 1)
        body.append("runtimeId", runtimeId)
        body.append("schemaVersion", schemaVersion)
        body.append("sourceId", "model")
        body.append("kind", "select")
        body.append("pointer", "/model")
        body.append("options", .array(options.map(\.jsonBody)))
        body.append("defaultValue", defaultValue)
        body.append("customValueAllowed", ifPresent: customValueAllowed)
        body.append("status", ifPresent: status)
        body.append("reason", ifPresent: reason)
        body.append("retryable", ifPresent: retryable)
        return body.json
    }
}

/// The builtin runtime's provider-grouped model source.
public struct BuiltinModelSourceBody: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public var provider: String
        public var models: [RuntimeModelChoice]

        public init(provider: String, models: [RuntimeModelChoice]) {
            self.provider = provider
            self.models = models
        }
    }

    public var schemaVersion: String
    public var groups: [Group]
    public var status: String?
    public var reason: String?
    public var retryable: Bool?

    public init(
        schemaVersion: String,
        groups: [Group],
        status: String? = nil,
        reason: String? = nil,
        retryable: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.status = status
        self.reason = reason
        self.retryable = retryable
    }

    /// The catalog the Computer falls back to without a live answer.
    public static func bundledGroups() -> [Group] {
        [
            Group(provider: "deepseek", models: [RuntimeModelChoice(value: "deepseek-chat", label: "DeepSeek Chat")]),
            Group(provider: "moonshotai", models: [RuntimeModelChoice(value: "kimi-k2", label: "Kimi K2")]),
        ]
    }

    var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("protocolVersion", 1)
        body.append("runtimeId", "builtin")
        body.append("schemaVersion", schemaVersion)
        body.append("sourceId", "model")
        body.append("kind", "dependent_select")
        body.append("pointer", "/model")
        body.append("optionsByValue", .object(groups.map {
            OrderedJSONField($0.provider, OrderedJSON.array($0.models.map(\.jsonBody)))
        }))
        body.append("status", ifPresent: status)
        body.append("reason", ifPresent: reason)
        body.append("retryable", ifPresent: retryable)
        return body.json
    }
}

/// A machine's runtime form option source.
public enum RuntimeOptionSourceResponse: JSONBodyConvertible, Equatable {
    /// A source the form catalog already ships as rendered JSON (possibly with
    /// the probe `reason`/`retryable` members substituted).
    case catalog(String)
    case model(RuntimeModelSourceBody)
    case builtinModel(BuiltinModelSourceBody)
    case builtinProvider(schemaVersion: String, chinese: Bool)
    case cachedModels(schemaVersion: String, models: [RuntimeModelChoice])

    public var jsonBody: OrderedJSON {
        switch self {
        case .catalog(let json):
            return .raw(json)
        case .model(let body):
            return body.jsonBody
        case .builtinModel(let body):
            return body.jsonBody
        case .builtinProvider(let schemaVersion, let chinese):
            func option(_ value: String, _ label: String) -> OrderedJSON {
                .object([
                    OrderedJSONField("value", value),
                    OrderedJSONField("label", label),
                    OrderedJSONField("providerKind", "preset"),
                ])
            }
            return .object([
                OrderedJSONField("sourceId", "provider"),
                OrderedJSONField("schemaVersion", schemaVersion),
                OrderedJSONField("kind", "select"),
                OrderedJSONField("options", OrderedJSON.array([
                    option("deepseek", "DeepSeek"),
                    option("moonshotai", chinese ? "月之暗面" : "Moonshot AI"),
                ])),
            ])
        case .cachedModels(let schemaVersion, let models):
            return .object([
                OrderedJSONField("sourceId", "model"),
                OrderedJSONField("schemaVersion", schemaVersion),
                OrderedJSONField("kind", "select"),
                OrderedJSONField("options", OrderedJSON.array(models.map(\.jsonBody))),
            ])
        }
    }
}

// MARK: - Runtime options and models

/// `GET /api/servers/:id/machines/:machineId/runtime-options`.
public struct MachineRuntimeOptionsResponse: JSONBodyConvertible, Equatable {
    public struct Option: Sendable, Equatable {
        public var runtimeId: String
        public var capabilityStatus: String
        public var canSelectInThisContext: Bool
        public var runtimeFormV2: Bool
        /// The v1 form reference's schema version, when the option publishes one.
        public var formDefinitionSchemaVersion: String?

        public init(
            runtimeId: String,
            capabilityStatus: String,
            canSelectInThisContext: Bool,
            runtimeFormV2: Bool,
            formDefinitionSchemaVersion: String?
        ) {
            self.runtimeId = runtimeId
            self.capabilityStatus = capabilityStatus
            self.canSelectInThisContext = canSelectInThisContext
            self.runtimeFormV2 = runtimeFormV2
            self.formDefinitionSchemaVersion = formDefinitionSchemaVersion
        }

        var jsonBody: OrderedJSON {
            var body = OrderedJSONObject()
            body.append("runtimeId", runtimeId)
            body.append("capabilityStatus", capabilityStatus)
            body.append("admissionStatus", "available_for_new")
            body.append("admissionReason", optional: nil as String?)
            body.append("current", false)
            body.append("availableForNew", true)
            body.append("manageableForCurrentAgent", false)
            body.append("canSelectInThisContext", canSelectInThisContext)
            if runtimeFormV2 {
                body.append("runtimeFormV2", .object([OrderedJSONField("protocolVersion", 2)]))
            }
            if let formDefinitionSchemaVersion {
                body.append("formDefinitionRef", .object([
                    OrderedJSONField("protocolVersion", 1),
                    OrderedJSONField("runtimeId", runtimeId),
                    OrderedJSONField("schemaVersion", formDefinitionSchemaVersion),
                ]))
            }
            return body.json
        }
    }

    public var machineId: String
    public var options: [Option]

    public init(machineId: String, options: [Option]) {
        self.machineId = machineId
        self.options = options
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("context", "new_agent"),
            OrderedJSONField("machineId", machineId),
            OrderedJSONField("options", OrderedJSON.array(options.map(\.jsonBody))),
        ])
    }
}

/// `GET /api/servers/:id/machines/:machineId/runtime-models/:runtime`.
public enum MachineRuntimeModelsResponse: JSONBodyConvertible, Equatable {
    case computerOffline
    case live(models: [RuntimeModelChoice], defaultModel: String?)
    /// The probe's legacy `models` answer: no `kind` envelope.
    case plainModels(models: [RuntimeModelChoice], defaultModel: String?)
    case missingConfig
    case noModels
    case unsupported
    /// A probe error; an empty `code` publishes no `code` member.
    case error(code: String)

    public var jsonBody: OrderedJSON {
        switch self {
        case .computerOffline:
            return .object([
                OrderedJSONField("kind", "error"),
                OrderedJSONField("retryable", true),
                OrderedJSONField("code", "computer_offline"),
            ])
        case .live(let models, let defaultModel):
            let list = OrderedJSON.array(models.map(Self.modelBody))
            let defaultJSON = OrderedJSON.stringOrNull(defaultModel)
            return .object([
                OrderedJSONField("kind", "live"),
                OrderedJSONField("value", OrderedJSON.object([
                    OrderedJSONField("models", list),
                    OrderedJSONField("default", defaultJSON),
                ])),
                OrderedJSONField("models", list),
                OrderedJSONField("default", defaultJSON),
            ])
        case .plainModels(let models, let defaultModel):
            return .object([
                OrderedJSONField("models", OrderedJSON.array(models.map(Self.modelBody))),
                OrderedJSONField("default", OrderedJSON.stringOrNull(defaultModel)),
            ])
        case .missingConfig:
            return .object([
                OrderedJSONField("kind", "missing_config"),
                OrderedJSONField("recovery", "kimi_login"),
            ])
        case .noModels:
            return .object([OrderedJSONField("kind", "no_models")])
        case .unsupported:
            return .object([OrderedJSONField("kind", "unsupported")])
        case .error(let code):
            var body = OrderedJSONObject()
            body.append("kind", "error")
            body.append("retryable", true)
            if !code.isEmpty { body.append("code", code) }
            return body.json
        }
    }

    private static func modelBody(_ model: RuntimeModelChoice) -> OrderedJSON {
        .object([OrderedJSONField("id", model.value), OrderedJSONField("label", model.label)])
    }
}

/// `GET /api/servers/:id/machines/:machineId/workspaces`.
public struct MachineWorkspacesResponse: JSONBodyConvertible, Equatable {
    public struct Row: Sendable, Equatable {
        public var directoryName: String
        public var lastModified: String
        public var status: String
        public var agentName: String
        public var agentStatus: String

        public init(
            directoryName: String,
            lastModified: String,
            status: String,
            agentName: String,
            agentStatus: String
        ) {
            self.directoryName = directoryName
            self.lastModified = lastModified
            self.status = status
            self.agentName = agentName
            self.agentStatus = agentStatus
        }

        var jsonBody: OrderedJSON {
            .object([
                OrderedJSONField("directoryName", directoryName),
                OrderedJSONField("totalSizeBytes", 0),
                OrderedJSONField("lastModified", lastModified),
                OrderedJSONField("fileCount", 0),
                OrderedJSONField("status", status),
                OrderedJSONField("agentName", agentName),
                OrderedJSONField("agentStatus", agentStatus),
            ])
        }
    }

    public var rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// A bare JSON array.
    public var jsonBody: OrderedJSON {
        .array(rows.map(\.jsonBody))
    }
}

// MARK: - Runtime account usage

/// `GET .../runtime-account-usage/:provider`.
public struct RuntimeAccountUsageResponse: JSONBodyConvertible, Equatable {
    public var state: String
    /// The Computer's stored snapshot, already rendered JSON; `nil` is `null`.
    public var snapshotJSON: String?

    public init(state: String, snapshotJSON: String?) {
        self.state = state
        self.snapshotJSON = snapshotJSON
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("state", state),
            OrderedJSONField("snapshot", snapshotJSON.map(OrderedJSON.raw) ?? .null),
        ])
    }
}

/// The `200` answers of `POST .../runtime-account-usage/:provider/refresh`.
public struct RuntimeAccountUsageRefreshResponse: JSONBodyConvertible, Equatable {
    public var state: String
    public var snapshotJSON: String?

    public init(state: String, snapshotJSON: String? = nil) {
        self.state = state
        self.snapshotJSON = snapshotJSON
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("accepted", true)
        body.append("state", state)
        body.append("snapshot", ifPresent: snapshotJSON.map(OrderedJSON.raw))
        return body.json
    }
}

/// The `staleAfter` member of a Computer's usage snapshot, read leniently.
struct RuntimeUsageSnapshotFreshness: Decodable {
    var staleAfter: String?

    private enum CodingKeys: String, CodingKey {
        case staleAfter
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        staleAfter = try? container.decode(String.self, forKey: .staleAfter)
    }
}

// MARK: - Server settings

/// The per-user and per-server onboarding projection.
public struct OnboardingSettingsResponse: JSONBodyConvertible, Equatable {
    public var onboardingAgentId: String?
    public var agentAllChannelGreetingEnabled: Bool
    public var onboardingWizardEnabled: Bool
    public var setupModalReminderOptOut: Bool
    public var dismissedAddComputerStepAt: String?
    public var dismissedCreateAgentStepAt: String?
    public var dismissedInviteStepAt: String?
    public var dismissedCommunityStepAt: String?
    public var dismissedNotificationStepAt: String?
    public var onboardingWizardCurrentStep: String?

    public init(
        onboardingAgentId: String?,
        agentAllChannelGreetingEnabled: Bool,
        onboardingWizardEnabled: Bool,
        setupModalReminderOptOut: Bool,
        dismissedAddComputerStepAt: String?,
        dismissedCreateAgentStepAt: String?,
        dismissedInviteStepAt: String?,
        dismissedCommunityStepAt: String?,
        dismissedNotificationStepAt: String?,
        onboardingWizardCurrentStep: String?
    ) {
        self.onboardingAgentId = onboardingAgentId
        self.agentAllChannelGreetingEnabled = agentAllChannelGreetingEnabled
        self.onboardingWizardEnabled = onboardingWizardEnabled
        self.setupModalReminderOptOut = setupModalReminderOptOut
        self.dismissedAddComputerStepAt = dismissedAddComputerStepAt
        self.dismissedCreateAgentStepAt = dismissedCreateAgentStepAt
        self.dismissedInviteStepAt = dismissedInviteStepAt
        self.dismissedCommunityStepAt = dismissedCommunityStepAt
        self.dismissedNotificationStepAt = dismissedNotificationStepAt
        self.onboardingWizardCurrentStep = onboardingWizardCurrentStep
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("onboardingAgentId", optional: onboardingAgentId),
            OrderedJSONField("agentAllChannelGreetingEnabled", agentAllChannelGreetingEnabled),
            OrderedJSONField("onboardingWizardEnabled", onboardingWizardEnabled),
            OrderedJSONField("setupModalReminderOptOut", setupModalReminderOptOut),
            OrderedJSONField("dismissedAddComputerStepAt", optional: dismissedAddComputerStepAt),
            OrderedJSONField("dismissedCreateAgentStepAt", optional: dismissedCreateAgentStepAt),
            OrderedJSONField("dismissedInviteStepAt", optional: dismissedInviteStepAt),
            OrderedJSONField("dismissedCommunityStepAt", optional: dismissedCommunityStepAt),
            OrderedJSONField("dismissedNotificationStepAt", optional: dismissedNotificationStepAt),
            OrderedJSONField("onboardingWizardCurrentStep", optional: onboardingWizardCurrentStep),
        ])
    }
}

/// `GET /api/servers/:id/settings`.
public struct ServerSettingsResponse: JSONBodyConvertible, Equatable {
    public var onboarding: OnboardingSettingsResponse

    public init(onboarding: OnboardingSettingsResponse) {
        self.onboarding = onboarding
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("settings", OrderedJSON.object([
                OrderedJSONField("onboardSettings", onboarding.jsonBody),
                OrderedJSONField("feedbackSettings", OrderedJSON.object([OrderedJSONField("enabled", true)])),
            ])),
        ])
    }
}

/// The per-member server notification preferences.
public struct ServerNotificationSettingsResponse: JSONBodyConvertible, Equatable {
    public var serverPushMuted: Bool
    public var serverPushMentionsOnly: Bool
    public var serverPushMode: String
    public var prefsVersion: Int

    public init(serverPushMuted: Bool, serverPushMentionsOnly: Bool, serverPushMode: String, prefsVersion: Int) {
        self.serverPushMuted = serverPushMuted
        self.serverPushMentionsOnly = serverPushMentionsOnly
        self.serverPushMode = serverPushMode
        self.prefsVersion = prefsVersion
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("serverPushMuted", serverPushMuted),
            OrderedJSONField("serverPushMentionsOnly", serverPushMentionsOnly),
            OrderedJSONField("serverPushMode", serverPushMode),
            OrderedJSONField("prefsVersion", prefsVersion),
        ])
    }

    /// The `notification_prefs:updated` frame payload for one changed row.
    func updatedEventPayload(serverId: String) -> String {
        OrderedJSON.object([
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("scopeId", serverId),
            OrderedJSONField("prefs", OrderedJSON.object([
                OrderedJSONField("serverPushMuted", serverPushMuted),
                OrderedJSONField("serverPushMentionsOnly", serverPushMentionsOnly),
                OrderedJSONField("serverPushMode", serverPushMode),
            ])),
            OrderedJSONField("prefsVersion", prefsVersion),
        ]).render()
    }
}

// MARK: - Machine registration

/// `POST /api/servers/:id/machines`.
public struct ServerMachineRegistrationResponse: JSONBodyConvertible, Equatable {
    public var id: String
    public var serverId: String
    public var name: String
    public var userId: String
    public var apiKey: String

    public init(id: String, serverId: String, name: String, userId: String, apiKey: String) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.userId = userId
        self.apiKey = apiKey
    }

    public var jsonBody: OrderedJSON {
        .object([
            OrderedJSONField("machine", OrderedJSON.object([
                OrderedJSONField("id", id),
                OrderedJSONField("serverId", serverId),
                OrderedJSONField("name", name),
                OrderedJSONField("userId", userId),
                OrderedJSONField("description", .null),
            ])),
            OrderedJSONField("apiKey", apiKey),
        ])
    }

    /// The `machine:updated` frame payload.
    func updatedEventPayload() -> String {
        OrderedJSON.object([
            OrderedJSONField("serverId", serverId),
            OrderedJSONField("machineId", id),
        ]).render()
    }
}
