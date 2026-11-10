import Foundation
import RaftShared

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
        var providerId: String?
        var baseUrl: String?
        var supportsImageInput: Bool?

        private enum CodingKeys: String, CodingKey {
            case kind
            case apiUrl
            case providerId, baseUrl, supportsImageInput
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? container.decode(String.self, forKey: .kind)
            apiUrl = try? container.decode(String.self, forKey: .apiUrl)
            providerId = try? container.decode(String.self, forKey: .providerId)
            baseUrl = try? container.decode(String.self, forKey: .baseUrl)
            supportsImageInput = try? container.decode(Bool.self, forKey: .supportsImageInput)
        }
    }

    var model: Model?
    var provider: Provider?
    var reasoningEffort: String?
    var fastMode: Bool?
    var loadLocalPlugins: Bool?
    var command: String?
    var envVars: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case model
        case provider
        case reasoningEffort
        case fastMode, loadLocalPlugins
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
        loadLocalPlugins = try? container.decode(Bool.self, forKey: .loadLocalPlugins)
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
    public var providerId: String?
    public var baseUrl: String?
    public var supportsImageInput: Bool?
    public var loadLocalPlugins: Bool?
    public var command: String?
    public var envVars: [String: String]
    public var fastMode: Bool?
    public var model: String?
    public var provider: String?
    public var reasoningEffort: String?

    public init(
        apiUrl: String? = nil,
        providerId: String? = nil,
        baseUrl: String? = nil,
        supportsImageInput: Bool? = nil,
        loadLocalPlugins: Bool? = nil,
        command: String? = nil,
        envVars: [String: String] = [:],
        fastMode: Bool? = nil,
        model: String? = nil,
        provider: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.apiUrl = apiUrl
        self.providerId = providerId
        self.baseUrl = baseUrl
        self.supportsImageInput = supportsImageInput
        self.loadLocalPlugins = loadLocalPlugins
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
        if runtimeId == "builtin" {
            var fields: [String: JSONValue] = [
                "providerId": .string(values.providerId ?? ""), "model": .string(values.model ?? ""),
                "loadLocalPlugins": .bool(values.loadLocalPlugins == true),
                "envVars": .object(values.envVars.mapValues(JSONValue.string)),
            ]
            if let baseUrl = values.baseUrl { fields["baseUrl"] = .string(baseUrl) }
            if let supportsImageInput = values.supportsImageInput { fields["supportsImageInput"] = .bool(supportsImageInput) }
            return RuntimeFormCatalog.builtinV2Definition(schemaVersion: schemaVersion, chinese: modelLabel == "模型", values: .object(fields))
        }
        return .object([
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

/// A machine's runtime form definition (released data-schema on v1 or v2).
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
            return RuntimeFormCatalog.builtinV2Definition(schemaVersion: schemaVersion, chinese: chinese)
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
    /// Declared metadata retained when an unavailable source has no options.
    public var metadataGroups: [Group]?
    public var includeGatewayOptions: Bool
    public var status: String?
    public var reason: String?
    public var retryable: Bool?

    public init(
        schemaVersion: String,
        groups: [Group],
        status: String? = nil,
        reason: String? = nil,
        retryable: Bool? = nil,
        metadataGroups: [Group]? = nil,
        includeGatewayOptions: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.metadataGroups = metadataGroups
        self.includeGatewayOptions = includeGatewayOptions
        self.status = status
        self.reason = reason
        self.retryable = retryable
    }

    /// The catalog the Computer falls back to without a live answer.
    public static func bundledGroups() -> [Group] {
        [
            // Pinned piBuiltinModels.generated.ts:96-97,124-128. Declared UI only;
            // this bounded two-provider subset is not a full Built-in catalog.
            Group(provider: "deepseek", models: [
                RuntimeModelChoice(value: "deepseek/deepseek-v4-pro", label: "DeepSeek V4 Pro"),
                RuntimeModelChoice(value: "deepseek/deepseek-flash", label: "DeepSeek V4.1 Flash"),
            ]),
            Group(provider: "moonshotai", models: [
                RuntimeModelChoice(value: "moonshotai/kimi-k2.7-code", label: "Kimi K2.7 Code"),
                RuntimeModelChoice(value: "moonshotai/kimi-k2.7-code-highspeed", label: "Kimi K2.7 Code HighSpeed"),
                RuntimeModelChoice(value: "moonshotai/kimi-k3", label: "Kimi K3"),
                RuntimeModelChoice(value: "moonshotai/kimi-k2.6", label: "Kimi K2.6"),
            ]),
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
        body.append("dependsOn", "/providerId")
        var optionGroups = groups.map { OrderedJSONField($0.provider, OrderedJSON.array($0.models.map(\.jsonBody))) }
        if includeGatewayOptions, status != "unavailable" {
            optionGroups += RuntimeFormCatalog.builtinGatewayIDs.map { OrderedJSONField($0, .array([])) }
        }
        body.append("optionsByValue", .object(optionGroups))
        let defaults = includeGatewayOptions ? RuntimeFormCatalog.builtinV2DefaultModels
            : ["deepseek": "deepseek/deepseek-v4-pro", "moonshotai": "moonshotai/kimi-k2.6"]
        let metadata = metadataGroups ?? groups
        body.append("defaultValueByValue", .object(metadata.compactMap { group in
            guard let first = group.models.first else { return nil }
            let preferred = defaults[group.provider] ?? first.value
            return OrderedJSONField(group.provider, group.models.contains { $0.value == preferred } ? preferred : first.value)
        }))
        var custom = metadata.map { OrderedJSONField($0.provider, false) }
        if includeGatewayOptions { custom += RuntimeFormCatalog.builtinGatewayIDs.map { OrderedJSONField($0, true) } }
        body.append("customValueAllowedByValue", .object(custom))
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
    case builtinProviderV2(schemaVersion: String, supportedModelIDs: Set<String>?)
    case cachedModels(schemaVersion: String, models: [RuntimeModelChoice])

    public var jsonBody: OrderedJSON {
        switch self {
        case .catalog(let json):
            return .raw(json)
        case .model(let body):
            return body.jsonBody
        case .builtinModel(let body):
            return body.jsonBody
        case .builtinProviderV2(let schemaVersion, let supportedModelIDs):
            return RuntimeFormCatalog.builtinV2ProviderSource(schemaVersion: schemaVersion, supportedModelIDs: supportedModelIDs)
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
        public var current: Bool
        public var admissionReason: String?
        /// The v1 form reference's schema version, when the option publishes one.
        public var formDefinitionSchemaVersion: String?

        public init(
            runtimeId: String,
            capabilityStatus: String,
            canSelectInThisContext: Bool,
            runtimeFormV2: Bool,
            formDefinitionSchemaVersion: String?,
            current: Bool = false,
            admissionReason: String? = nil
        ) {
            self.runtimeId = runtimeId
            self.capabilityStatus = capabilityStatus
            self.canSelectInThisContext = canSelectInThisContext
            self.runtimeFormV2 = runtimeFormV2
            self.formDefinitionSchemaVersion = formDefinitionSchemaVersion
            self.current = current
            self.admissionReason = admissionReason
        }

        var jsonBody: OrderedJSON {
            var body = OrderedJSONObject()
            body.append("runtimeId", runtimeId)
            body.append("capabilityStatus", capabilityStatus)
            body.append("admissionStatus", admissionReason == nil ? "available_for_new" : "grandfathered_current")
            body.append("admissionReason", optional: admissionReason)
            body.append("current", current)
            body.append("availableForNew", admissionReason == nil)
            body.append("manageableForCurrentAgent", current && capabilityStatus == "available")
            body.append("canSelectInThisContext", canSelectInThisContext)
            if let formDefinitionSchemaVersion {
                body.append("formDefinitionRef", .object([
                    OrderedJSONField("protocolVersion", 1),
                    OrderedJSONField("runtimeId", runtimeId),
                    OrderedJSONField("schemaVersion", formDefinitionSchemaVersion),
                ]))
            }
            if runtimeFormV2 {
                body.append("runtimeFormV2", .object([OrderedJSONField("protocolVersion", 2)]))
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
public struct MachineWorkspacesResponse: JSONBodyConvertible, Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public var directoryName: String
        public var totalSizeBytes: Int
        public var lastModified: String
        public var fileCount: Int
        public var displayPath: String?
        public var status: String
        public var agentName: String?
        public var agentStatus: String

        public init(directoryName: String, totalSizeBytes: Int, lastModified: String,
                    fileCount: Int, displayPath: String? = nil, status: String,
                    agentName: String?, agentStatus: String) {
            self.directoryName = directoryName
            self.totalSizeBytes = totalSizeBytes
            self.lastModified = lastModified
            self.fileCount = fileCount
            self.displayPath = displayPath
            self.status = status
            self.agentName = agentName
            self.agentStatus = agentStatus
        }

        var jsonBody: OrderedJSON {
            var body = OrderedJSONObject()
            body.append("directoryName", directoryName)
            body.append("totalSizeBytes", totalSizeBytes)
            body.append("lastModified", lastModified)
            body.append("fileCount", fileCount)
            body.append("displayPath", ifPresent: displayPath)
            body.append("status", status)
            body.append("agentName", optional: agentName)
            body.append("agentStatus", agentStatus)
            return body.json
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

/// Sanitized Node scan failure; the real error correlation links header/body.
struct MachineWorkspaceScanFailure: DomainError {
    let correlationId = UUID().uuidString.lowercased()
    var status: UInt { 500 }
    var errorMessage: String { "Failed to scan workspaces" }
    var responseHeaders: [String: String] { ["X-Slock-Error-Id": correlationId] }
    var errorBody: OrderedJSON? {
        .object([.init("error", errorMessage), .init("code", "machine_workspace_scan_failed"),
                 .init("correlationId", correlationId)])
    }
}

/// Native cleanup is unimplemented. A cache marker is not physical deletion.
struct MachineWorkspaceDeleteUnavailable: DomainError {
    var status: UInt { 503 }
    var errorMessage: String { "Machine workspace deletion is unavailable" }
    var errorBody: OrderedJSON? {
        .object([.init("error", errorMessage), .init("code", "machine_workspace_delete_unavailable"),
                 .init("retryable", false)])
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
