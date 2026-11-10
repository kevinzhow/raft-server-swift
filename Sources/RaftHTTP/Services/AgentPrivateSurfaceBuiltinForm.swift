import Foundation
import RaftShared

extension AgentPrivateSurfaceService {
    /// The builtin base protocol maps field values before the existing canonical
    /// parser and writer. It owns no store and never grants runtime availability.
    func adoptingBuiltinForm(_ fields: [String: JSONValue], serverId: String,
                             existingJSON: String? = nil, external: Bool = false, editing: Bool = false) throws -> [String: JSONValue] {
        let ref = fields["formDefinitionRef"]?.legacyObject
        let refRuntime = ref?["runtimeId"]?.legacyString
        let existing = existingJSON.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) }
        let builtin = refRuntime == "builtin" || fields["runtime"]?.legacyString?.trimmingCharacters(in: .whitespacesAndNewlines) == "builtin"
            || existing?["runtime"]?.legacyString == "builtin"
        guard builtin else { return fields }
        func issue(_ code: String, _ pointer: String, status: UInt = 400,
                   message: String = "Runtime form values are invalid") -> AgentPrivateSurfaceError {
            .runtimeFormFailure(status: status, message: message, code: code, pointer: pointer)
        }
        guard fields["formDefinitionRef"] != nil else { return fields }
        if external { throw issue("external_form_definition_forbidden", "/formDefinitionRef", message: "External agents cannot use runtime form definitions") }
        guard let ref else { throw issue("form_definition_ref_required", "/formDefinitionRef", status: 409, message: "Runtime form definition is stale or invalid") }
        // V1 clients continue to build their own runtimeConfig, byte-for-byte.
        if ref["protocolVersion"] == .integer(1) || ref["protocolVersion"] == .number(1) { return fields }
        guard ref["protocolVersion"] == .integer(2) || ref["protocolVersion"] == .number(2) else {
            throw issue("unsupported_form_protocol", "/formDefinitionRef/protocolVersion", status: 409, message: "Runtime form definition is stale or invalid")
        }
        if let refRuntime, refRuntime != "builtin", RuntimeFormCatalog.v2Forms[refRuntime] != nil {
            // Another runtime's assembly contract is outside this builtin layer.
            return fields
        }
        guard refRuntime == "builtin" else {
            throw issue("unknown_form_runtime", "/formDefinitionRef/runtimeId", message: "This runtime has no v2 runtime form")
        }
        guard let values = fields["formValues"]?.legacyObject else { throw issue("form_values_required", "/formValues") }
        func canonicalFailure(_ message: String, code: String, pointer: String) -> AgentPrivateSurfaceError {
            if editing { return .invalidRuntimeConfig(message) }
            return .runtimeFormFailure(status: 400, message: "Runtime configuration is invalid", code: code, pointer: pointer)
        }
        let env: JSONValue
        let envError: String?
        if let rawEnv = values["envVars"], rawEnv != .null {
            guard let rawMembers = rawEnv.legacyObject else { throw issue("invalid_string_map", "/formValues/envVars") }
            let members = rawMembers.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard members.values.allSatisfy({ $0.legacyString != nil }) else { throw issue("invalid_string_map", "/formValues/envVars") }
            env = members.isEmpty ? .null : .object(members)
            envError = AgentRuntimeConfigDocument.validatedEnvVars(.object(members)).error.map { error in
                error.hasPrefix("Invalid env var key")
                    ? error.replacingOccurrences(of: "Invalid env var key", with: "Invalid runtimeConfig.envVars key")
                    : error.replacingOccurrences(of: "envVars", with: "runtimeConfig.envVars")
            }
        } else { env = .null; envError = nil }
        let providerID = values["providerId"]?.legacyString ?? ""
        if providerID.hasPrefix("connection:") {
            let id = String(providerID.dropFirst("connection:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw issue("select_valid_provider", "/formValues/providerId") }
            guard ServerScope.isUUID(id) else { throw issue("connection_id_malformed", "/formValues/providerId") }
            for owned in ["apiKey", "baseUrl", "supportsImageInput"] where values[owned] != nil {
                throw issue("connection_field_forbidden", "/formValues/\(owned)")
            }
            guard !(values["model"]?.legacyString ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw issue("model_required", "/formValues/model")
            }
            if let envError { throw canonicalFailure(envError, code: "invalid_runtime_config", pointer: "/formValues") }
            if !dependencies.cards.isProviderConnectionsEnabled(serverId: serverId) {
                throw AgentPrivateSurfaceError.runtimeFormFailure(status: 404,
                    message: "Provider connections are not enabled for this server", code: "provider_connections_disabled", pointer: nil)
            }
            // The actual owner flag may be enabled, but this base form has no
            // revision/owned-field capability. Never pretend it can resolve one.
            throw AgentPrivateSurfaceError.runtimeFormFailure(status: 409,
                message: "Provider connection is unavailable", code: "provider_connection_unavailable", pointer: nil)
        }
        let gateway = RuntimeFormCatalog.builtinGatewayIDs.contains(providerID)
        guard gateway || RuntimeFormCatalog.builtinV2ModelGroups.contains(where: { $0.provider == providerID }) else {
            throw issue("select_valid_provider", "/formValues/providerId")
        }
        var key = (values["apiKey"]?.legacyString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = (values["baseUrl"]?.legacyString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let providerKind = gateway ? "gateway" : "preset"
        if key.isEmpty, editing {
            let previous = existing?["provider"]?.legacyObject
            let identityMatches = existing?["runtime"]?.legacyString == "builtin"
                && previous?["kind"]?.legacyString == providerKind && previous?["providerId"]?.legacyString == providerID
                && (!gateway || Self.builtinEndpointIdentity(previous?["baseUrl"]?.legacyString ?? "") == Self.builtinEndpointIdentity(endpoint))
            if identityMatches { key = previous?["apiKey"]?.legacyString ?? "" }
        }
        if key.isEmpty, !editing { throw issue("api_key_required", "/formValues/apiKey") }
        let model = (values["model"]?.legacyString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw issue("model_required", "/formValues/model") }
        if !gateway, !RuntimeFormCatalog.builtinV2ModelGroups.contains(where: { $0.provider == providerID && $0.models.contains(where: { $0.value == model }) }) {
            throw issue("select_valid_provider_model", "/formValues/model")
        }
        if gateway, !(endpoint.lowercased().hasPrefix("http://") || endpoint.lowercased().hasPrefix("https://")) {
            throw issue("base_url_invalid", "/formValues/baseUrl")
        }
        guard !key.isEmpty else {
            throw canonicalFailure("runtimeConfig.provider.apiKey is required", code: "required", pointer: "/formValues/apiKey")
        }
        var provider: [String: JSONValue] = ["kind": .string(providerKind), "providerId": .string(providerID), "apiKey": .string(key.trimmingCharacters(in: .whitespacesAndNewlines))]
        if gateway {
            if let error = Self.builtinEndpointError(endpoint) {
                throw canonicalFailure(error, code: "invalid", pointer: "/formValues/baseUrl")
            }
            provider["baseUrl"] = .string(endpoint)
            provider["supportsImageInput"] = .bool(values["supportsImageInput"] == .bool(true))
        }
        if let envError { throw canonicalFailure(envError, code: "invalid_runtime_config", pointer: "/formValues") }
        let assembled: JSONValue = .object([
            "version": .integer(1), "runtime": .string("builtin"), "provider": .object(provider),
            "model": .object(["kind": .string(gateway ? "custom" : "preset"), (gateway ? "name" : "id"): .string(model)]),
            "mode": .object(["kind": .string("default")]), "reasoningEffort": .null,
            "envVars": env, "hostUserState": .string("forbidden"), "loadLocalPlugins": .bool(values["loadLocalPlugins"] == .bool(true)),
        ])
        var adopted = fields
        adopted["runtimeConfig"] = assembled
        return adopted
    }

    private static func builtinEndpointIdentity(_ value: String) -> String {
        var endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        return endpoint
    }

    private static func builtinEndpointError(_ value: String) -> String? {
        // WHATWG's special HTTP(S) URL handling treats backslashes as slashes
        // and drops ASCII tabs/newlines before checking embedded credentials.
        let parsedText = value.replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard let parsed = URLComponents(string: parsedText), parsed.url != nil, !(parsed.host ?? "").isEmpty,
              parsed.port.map({ (0...65535).contains($0) }) ?? true else { return "runtimeConfig.provider.baseUrl must be a valid URL" }
        if !(parsed.user ?? "").isEmpty || !(parsed.password ?? "").isEmpty { return "runtimeConfig.provider.baseUrl must not contain credentials" }
        return nil
    }
}
