import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider-connection materialization for spawn: the daemon asks the server
/// for a one-time env projection plus the provider connection metadata, and
/// only accepts an exact shape — unknown fields, inconsistent gateway base URLs
/// and malformed env values are rejected. Ported from the upstream daemon path.
public struct ProviderConnectionProjection: Sendable, Equatable {
    public var providerId: String
    public var endpointUrl: String?
    public var supportsImageInput: Bool
    public init(providerId: String, endpointUrl: String?, supportsImageInput: Bool) {
        self.providerId = providerId
        self.endpointUrl = endpointUrl
        self.supportsImageInput = supportsImageInput
    }
}

public struct ProviderConnectionLaunch: Sendable, Equatable {
    public var envVars: [String: String]
    public var providerConnection: ProviderConnectionProjection
    public init(envVars: [String: String], providerConnection: ProviderConnectionProjection) {
        self.envVars = envVars
        self.providerConnection = providerConnection
    }
}

public final class ProviderConnectionMaterializationError: Error, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case http, invalidPayload = "invalid_payload", invalidEnvironment = "invalid_environment" }
    public let kind: Kind
    public let status: Int?
    public let message: String
    public init(kind: Kind, status: Int? = nil, message: String) {
        self.kind = kind
        self.status = status
        self.message = message
    }
    public var description: String { message }
}

public enum ProviderConnectionLaunchClient {
    public typealias Send = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    public static let presetEnvKeys: [String: String] = [
        "deepseek": "DEEPSEEK_API_KEY", "minimax": "MINIMAX_API_KEY",
        "minimax-cn": "MINIMAX_CN_API_KEY", "zai": "ZAI_API_KEY",
        "zai-coding-cn": "ZAI_CODING_CN_API_KEY", "moonshotai": "MOONSHOT_API_KEY",
        "moonshotai-cn": "MOONSHOT_API_KEY", "kimi-coding": "KIMI_API_KEY",
        "qwen-token-plan": "QWEN_TOKEN_PLAN_API_KEY",
        "qwen-token-plan-cn": "QWEN_TOKEN_PLAN_CN_API_KEY",
        "openrouter": "OPENROUTER_API_KEY", "openai": "OPENAI_API_KEY",
        "anthropic": "ANTHROPIC_API_KEY", "google": "GEMINI_API_KEY",
        "xai": "XAI_API_KEY", "xiaomi": "XIAOMI_API_KEY",
    ]
    public static let gatewayEnvKeys: [String: (apiKey: String, baseUrl: String)] = [
        "openai-compatible": ("OPENAI_API_KEY", "OPENAI_BASE_URL"),
        "anthropic-compatible": ("ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"),
    ]
    public static var providerIds: Set<String> {
        Set(presetEnvKeys.keys).union(gatewayEnvKeys.keys)
    }

    public static func request(
        serverUrl: String,
        daemonApiKey: String,
        agentId: String,
        connectionId: String,
        send: Send
    ) async throws -> ProviderConnectionLaunch {
        var base = serverUrl
        while base.hasSuffix("/") { base.removeLast() }
        let encodedAgent = agentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agentId
        let url = base + "/internal/computer/runners/\(encodedAgent)/provider-connection"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(daemonApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("daemon-server-session-worker", forHTTPHeaderField: "X-Raft-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["connectionId": connectionId])
        let response: (status: Int, body: Data)
        do {
            response = try await send(request)
        } catch {
            throw ProviderConnectionMaterializationError(kind: .http, message: "Provider connection materialization failed")
        }
        guard (200..<300).contains(response.status) else {
            throw ProviderConnectionMaterializationError(
                kind: .http, status: response.status,
                message: "Provider connection materialization failed (HTTP \(response.status))"
            )
        }
        guard let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw ProviderConnectionMaterializationError(kind: .invalidPayload, message: "Provider connection materialization returned an invalid payload")
        }
        return try parse(body)
    }

    /// Strict parser shared by the launch and probe paths.
    public static func parse(_ body: [String: Any]) throws -> ProviderConnectionLaunch {
        guard Set(body.keys) == ["envVars", "providerConnection"],
              let projection = body["providerConnection"] as? [String: Any],
              let envVars = body["envVars"] as? [String: String]
        else {
            throw ProviderConnectionMaterializationError(kind: .invalidPayload, message: "Provider connection materialization returned an invalid payload")
        }
        guard Set(projection.keys) == ["endpointUrl", "providerId", "supportsImageInput"],
              let providerId = projection["providerId"] as? String,
              providerIds.contains(providerId),
              projection["endpointUrl"] == nil || projection["endpointUrl"] is String || projection["endpointUrl"] is NSNull,
              let supportsImageInput = projection["supportsImageInput"] as? Bool
        else {
            throw ProviderConnectionMaterializationError(kind: .invalidPayload, message: "Provider connection materialization returned an invalid payload")
        }
        var endpoint: String?
        if let raw = projection["endpointUrl"], !(raw is NSNull) {
            guard let value = raw as? String else {
                throw ProviderConnectionMaterializationError(kind: .invalidPayload, message: "Provider connection materialization returned an invalid payload")
            }
            endpoint = value
        }
        let connection = ProviderConnectionProjection(
            providerId: providerId, endpointUrl: endpoint, supportsImageInput: supportsImageInput
        )
        let expected: [String]
        if let preset = presetEnvKeys[providerId] {
            expected = [preset]
        } else if let gateway = gatewayEnvKeys[providerId] {
            expected = [gateway.apiKey, gateway.baseUrl]
        } else {
            expected = []
        }
        let entries = Array(envVars)
        let valuesValid = entries.allSatisfy { expected.contains($0.key) && !$0.value.isEmpty }
        var consistent = entries.count == expected.count && valuesValid && !expected.isEmpty
        if let preset = presetEnvKeys[providerId] {
            consistent = consistent && endpoint == nil && supportsImageInput == false
            _ = preset
        }
        if let gateway = gatewayEnvKeys[providerId] {
            consistent = consistent && (endpoint?.isEmpty == false)
                && envVars[gateway.baseUrl] == endpoint
        }
        guard consistent else {
            throw ProviderConnectionMaterializationError(kind: .invalidEnvironment, message: "Provider connection materialization returned an invalid environment")
        }
        return ProviderConnectionLaunch(envVars: envVars, providerConnection: connection)
    }
}
