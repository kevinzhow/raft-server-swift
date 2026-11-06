import Foundation
import RaftShared

/// An agent's free-form runtime config document, with the legacy normalization,
/// redaction and serialization rules.
///
/// The config is a client-supplied JSON object that the server stores and echoes
/// as text. Its stored form is the output of `JSONSerialization` with sorted keys
/// (which orders keys with its own collation and escapes `/`), so the bytes can
/// only be reproduced by the same serializer. This type keeps that boundary in
/// one place: the agent service reads and writes typed members and never touches
/// the untyped tree. The rules below moved here unchanged from the directory
/// statics.
struct AgentRuntimeConfigDocument {
    /// A refusal the config structure check can publish.
    enum StructureError {
        case modelNameRequired
        case providerNotSupportedForCursor
        case providerAPIKeyRequired
    }

    private var storage: [String: Any]

    init() {
        storage = [:]
    }

    /// The `runtimeConfig` request member: the document when the member is a
    /// JSON object, `nil` for anything else (absent, `null`, a scalar).
    init?(request value: JSONValue?) {
        guard case .object(let members)? = value else { return nil }
        storage = members.mapValues(Self.foundationValue)
    }

    /// The stored config text; an unparseable or non-object text reads as empty.
    init(storedJSON: String?) {
        storage = storedJSON.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8))
        } as? [String: Any] ?? [:]
    }

    /// The config an external agent always stores.
    static var external: AgentRuntimeConfigDocument {
        var document = AgentRuntimeConfigDocument()
        document.storage = [
            "version": 1,
            "runtime": "external",
            "model": ["kind": "preset", "id": "external"],
            "mode": ["kind": "default"],
            "reasoningEffort": NSNull(),
            "envVars": NSNull(),
        ]
        return document
    }

    /// `NSNumber` carries the numeric and boolean casts (`as? Int`, `as? Bool`)
    /// the legacy member reads relied on.
    private static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .object(let members):
            return members.mapValues(foundationValue)
        case .array(let elements):
            return elements.map(foundationValue)
        case .string(let text):
            return text
        case .number(let number):
            return NSNumber(value: number)
        case .integer(let integer):
            return NSNumber(value: integer)
        case .bool(let flag):
            return NSNumber(value: flag)
        case .null:
            return NSNull()
        }
    }

    /// Stored client JSON keeps Foundation's numeric representation, including
    /// unsigned integers beyond Int64.max and decimal NSNumber values.
    private static func serializedStoredObject(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Reads

    /// `config["runtime"] as? String`.
    var runtime: String? { storage["runtime"] as? String }

    /// `config["reasoningEffort"] as? String`.
    var reasoningEffort: String? { storage["reasoningEffort"] as? String }

    /// The reasoning effort a reply publishes: `nil` for a missing or `null`
    /// value, the string, and an empty string for any other type.
    var publishedReasoningEffort: String? {
        guard let value = storage["reasoningEffort"], !(value is NSNull) else { return nil }
        return value as? String ?? ""
    }

    /// `config["envVars"] as? [String: String] ?? [:]`.
    var userEnv: [String: String] { storage["envVars"] as? [String: String] ?? [:] }

    /// The legacy structure check: a custom model needs a name, a custom provider
    /// is not available for the cursor runtime and needs an API key.
    var structureError: StructureError? {
        if let model = storage["model"] as? [String: Any],
           model["kind"] as? String == "custom",
           (model["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .modelNameRequired
        }
        guard let provider = storage["provider"] as? [String: Any],
              provider["kind"] as? String == "custom"
        else { return nil }
        if (storage["runtime"] as? String ?? "") == "cursor" {
            return .providerNotSupportedForCursor
        }
        if (provider["apiKey"] as? String ?? "").isEmpty {
            return .providerAPIKeyRequired
        }
        return nil
    }

    /// The runtime named by a non-empty `command` when that runtime is not
    /// `claude` (only `claude` accepts a command).
    var unsupportedCommandRuntime: String? {
        guard let command = storage["command"] as? String, !command.isEmpty,
              let runtime = storage["runtime"] as? String, runtime != "claude"
        else { return nil }
        return runtime
    }

    /// The Built-in model id when the runtime is `builtin`.
    var builtinModelId: String? {
        guard (storage["runtime"] as? String) == "builtin",
              let model = storage["model"] as? [String: Any]
        else { return nil }
        return model["id"] as? String
    }

    /// Whether a provider block carries a non-empty `apiKey` in this document.
    var providerAPIKey: String? {
        (storage["provider"] as? [String: Any])?["apiKey"] as? String
    }

    // MARK: Writes

    /// `version`, `mode`, `reasoningEffort` and the sanitized `envVars`
    /// (`ANTHROPIC_` keys are dropped from user input).
    func normalized() -> AgentRuntimeConfigDocument {
        var config = storage
        if config["version"] == nil { config["version"] = 1 }
        if config["mode"] == nil { config["mode"] = ["kind": "default"] }
        if config["reasoningEffort"] == nil { config["reasoningEffort"] = NSNull() }
        var userEnv: [String: String] = [:]
        if let env = config["envVars"] as? [String: String] {
            for (key, value) in env where !key.hasPrefix("ANTHROPIC_") {
                userEnv[key] = value
            }
        }
        config["envVars"] = userEnv
        var document = AgentRuntimeConfigDocument()
        document.storage = config
        return document
    }

    /// Keeps the stored provider key when an update leaves it empty.
    mutating func preserveProviderAPIKey(from previous: AgentRuntimeConfigDocument) {
        guard var provider = storage["provider"] as? [String: Any] else { return }
        let incomingKey = provider["apiKey"] as? String ?? ""
        if incomingKey.isEmpty, let previousKey = previous.providerAPIKey, !previousKey.isEmpty {
            provider["apiKey"] = previousKey
            storage["provider"] = provider
        }
    }

    mutating func setEnv(_ env: [String: String]) {
        storage["envVars"] = env
    }

    mutating func setRuntime(_ runtime: String) {
        storage["runtime"] = runtime
    }

    mutating func setPresetModel(id: String) {
        storage["model"] = ["kind": "preset", "id": id]
    }

    /// `effort is NSNull ? NSNull : (effort as? String ?? NSNull)`.
    mutating func setReasoningEffort(_ value: JSONValue) {
        if case .string(let text) = value {
            storage["reasoningEffort"] = text
        } else {
            storage["reasoningEffort"] = NSNull()
        }
    }

    /// The defaults a changed config is stored with.
    mutating func fillDefaults() {
        if storage["version"] == nil { storage["version"] = 1 }
        if storage["mode"] == nil { storage["mode"] = ["kind": "default"] }
        if storage["reasoningEffort"] == nil { storage["reasoningEffort"] = NSNull() }
        if storage["envVars"] == nil { storage["envVars"] = [String: String]() }
    }

    /// The env the runner receives: the user env plus the Anthropic variables a
    /// custom Claude provider or model needs.
    func derivedEnvVars(userEnv: [String: String]) -> [String: String] {
        var env = userEnv
        if storage["runtime"] as? String == "claude" {
            if let provider = storage["provider"] as? [String: Any], provider["kind"] as? String == "custom" {
                if let apiUrl = provider["apiUrl"] as? String { env["ANTHROPIC_BASE_URL"] = apiUrl }
                if let apiKey = provider["apiKey"] as? String { env["ANTHROPIC_API_KEY"] = apiKey }
            }
            if let model = storage["model"] as? [String: Any], model["kind"] as? String == "custom",
               let name = model["name"] as? String {
                env["ANTHROPIC_CUSTOM_MODEL_OPTION"] = name
            }
        }
        return env
    }

    // MARK: Serialization

    /// The stored text: sorted keys, `JSONSerialization` escaping.
    func serialized() -> String {
        Self.serializedStoredObject(storage) ?? "{}"
    }

    /// The text of an env map in the same stored form.
    static func serializedEnv(_ env: [String: String]) -> String {
        Self.serializedStoredObject(env) ?? "{}"
    }

    /// The `envVars` request member: `nil` env and `nil` error for an absent or
    /// `null` value, an error for a non-object, a key outside
    /// `[A-Za-z_][A-Za-z0-9_]*`, a non-string value or a NUL byte.
    static func validatedEnvVars(_ value: JSONValue?) -> (env: [String: String]?, error: String?) {
        guard let present = value else { return (nil, nil) }
        if case .null = present { return (nil, nil) }
        guard case .object(let object) = present else {
            return (nil, "envVars must be an object")
        }
        var env: [String: String] = [:]
        for (key, raw) in object {
            guard case .string(let text) = raw else {
                return (nil, "envVars keys and values must be strings")
            }
            guard key.wholeMatch(of: /^[A-Za-z_][A-Za-z0-9_]*$/) != nil else {
                return (nil, "Invalid env var key \"\(key)\": must match [A-Za-z_][A-Za-z0-9_]*")
            }
            guard !key.contains("\0"), !text.contains("\0") else {
                return (nil, "envVars keys and values must not contain null bytes")
            }
            env[key] = text
        }
        return (env, nil)
    }

    /// The config text with a custom provider's `apiKey` blanked; the text itself
    /// when it cannot be parsed.
    static func redactedConfigJSON(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return raw }
        if var provider = object["provider"] as? [String: Any], provider["apiKey"] != nil {
            provider["apiKey"] = ""
            object["provider"] = provider
        }
        return Self.serializedStoredObject(object) ?? raw
    }

    /// The model name or id a stored config selects; `external` for an external
    /// agent and empty when none is set.
    static func agentModel(from runtimeConfigJSON: String?, external: Bool) -> String {
        if external { return "external" }
        guard let runtimeConfigJSON,
              let config = (try? JSONSerialization.jsonObject(with: Data(runtimeConfigJSON.utf8))) as? [String: Any],
              let model = config["model"] as? [String: Any]
        else { return "" }
        return (model["name"] as? String) ?? (model["id"] as? String) ?? ""
    }
}
