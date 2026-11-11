import Foundation
import RaftHTTP
import RaftShared
import Vapor

/// The one transport adapter for `AgentApiContractValidator`: it extracts the
/// request parts the route's pinned schema covers, in the upstream validator
/// order (params, query, body), and projects a rejection through the shared
/// `DomainError` response path.
///
/// Pinned `routes/internalAgentApi.ts:402-431` answers the first failing part
/// with the `issues` list of that part only.
func agentApiContractRefusal(
    _ key: AgentApiContractRouteKey,
    _ request: Request,
    services: FallbackServices
) async throws -> Response? {
    // Pinned `app.ts:809` mounts `authFromRegistry()` before the router and
    // `registerAgentApiRoute` checks the capability before the request
    // validators. Keep those refusals ahead of a schema 400: when the
    // credential or capability cannot pass, the route's own auth path answers.
    guard let scopes = services.emailAccounts.agentsLifecycle.agentApiCredentialScopes(
        authorization: request.headers[.authorization]
    ), scopes.contains(key.capability) else {
        return nil
    }
    for part in AgentApiContractPart.allCases {
        guard AgentApiContractValidator.hasSchema(for: key, part: part) else {
            continue
        }
        let value = try await contractRequestValue(key, part, request: request)
        if let failure = AgentApiContractValidator.failure(for: key, part: part, value: value) {
            return domainErrorResponse(failure)
        }
    }
    return nil
}

private func contractRequestValue(
    _ key: AgentApiContractRouteKey,
    _ part: AgentApiContractPart,
    request: Request
) async throws -> JSONValue? {
    switch part {
    case .params:
        var fields: [String: JSONValue] = [:]
        for name in AgentApiContractValidator.parameterNames(for: key) {
            if let value = request.parameters.get(contractParameterName(name)) {
                fields[name] = .string(value)
            }
        }
        return .object(fields)
    case .query:
        return contractQueryValue(request.url.query)
    case .body:
        guard let data = try await request.body.collect(), !data.isEmpty else {
            return nil
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}

/// The pinned contract spells the message route parameter `msgId`; the Swift
/// routes keep the legacy `:messageId` path binding.
private func contractParameterName(_ name: String) -> String {
    name == "msgId" ? "messageId" : name
}

/// Express `req.query` for the forms the contract schemas read: repeated keys
/// become arrays, `+` is a space, and a key without `=` is the empty string.
private func contractQueryValue(_ query: String?) -> JSONValue {
    guard let query, !query.isEmpty else { return .object([:]) }
    var fields: [String: JSONValue] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = decodeQueryComponent(String(parts[0]))
        let raw = parts.count > 1 ? String(parts[1]) : ""
        let value = JSONValue.string(decodeQueryComponent(raw))
        switch fields[name] {
        case .none:
            fields[name] = value
        case .array(let existing):
            fields[name] = .array(existing + [value])
        case .some(let existing):
            fields[name] = .array([existing, value])
        }
    }
    return .object(fields)
}

private func decodeQueryComponent(_ raw: String) -> String {
    let withSpaces = raw.replacingOccurrences(of: "+", with: " ")
    return withSpaces.removingPercentEncoding ?? withSpaces
}
