import Foundation
import HTTPTypes
import RaftHTTP
import Vapor

/// One mount of the shared legacy-agent machine gate.
///
/// Upstream authenticates `/internal/agent/:id/*` with `requireMachineAuth` at
/// the `/internal` mount and `requireAgentScope(scope)` per route. This
/// middleware applies both, in that order, to every route registered on the
/// gated group. The scope is derived from the matched route (not the raw URL),
/// so an alias cannot widen the required grant and a newly added route without
/// a policy fails closed instead of silently skipping the gate.
struct LegacyAgentMachineGateMiddleware: Middleware {
    let gate: LegacyAgentMachineGate

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        guard let agentId = request.parameters.get("agentId"), !agentId.isEmpty else {
            return RaftHTTPServer.respond(
                status: 500,
                headers: .exact(["Content-Type": "application/json"]),
                rawJSON: OrderedJSON.object([
                    OrderedJSONField("error", "agent machine gate applied to a route without :agentId"),
                ]).render()
            )
        }
        let scope: LegacyAgentMachineGateScope
        switch Self.scope(for: request) {
        case .mapped(let required):
            scope = required
        case .unmapped:
            return RaftHTTPServer.respond(
                status: 500,
                headers: .exact(["Content-Type": "application/json"]),
                rawJSON: OrderedJSON.object([
                    OrderedJSONField("error", "agent machine gate applied to an unmapped route"),
                ]).render()
            )
        }
        do {
            _ = try gate.actor(
                authorization: request.headers[.authorization],
                agentId: agentId,
                requiredScope: scope.requiredScope
            )
        } catch let error as any DomainError {
            return domainErrorResponse(error)
        }
        return try await next.respond(to: request)
    }

    /// The grant upstream passes to `requireAgentScope` for this route.
    /// `requiredScope == nil` reproduces the legacy handlers that authenticate
    /// and check machine ownership but register no scope middleware.
    private static func scope(for request: Request) -> LegacyAgentMachineGateScopeMapping {
        guard let route = request.route else { return .unmapped }
        let components = route.path
        guard components.count >= 4,
              components[0].description == "internal",
              components[1].description == "agent",
              components[2].description.hasPrefix(":")
        else {
            return .unmapped
        }
        let tail = components.dropFirst(3).map { component -> String in
            if case .constant(let literal) = component { return literal }
            return ":"
        }
        let key = "\(request.method.rawValue) \(tail.joined(separator: "/"))"
        guard let scope = scopes[key] else { return .unmapped }
        return .mapped(LegacyAgentMachineGateScope(requiredScope: scope.isEmpty ? nil : scope))
    }

    /// Route path (after `:agentId`, parameters collapsed to `:`) to the scope
    /// from `packages/server/src/routes/internal.ts`. An empty value is a route
    /// upstream registers without `requireAgentScope`; the handler still calls
    /// `loadOwnedMachineAgent`.
    private static let scopes: [String: String] = [
        "GET reminders": "",
        "POST reminders": "",
        "DELETE reminders/:": "",
        "POST reminders/:/snooze": "",
        "PATCH reminders/:": "",
        "GET reminders/:/log": "",
        "POST receive-ack": "",
        "POST runtime-profile/migration-done": "",

        "GET server": "server:read",
        "PATCH server": "server:update",
        "POST channels": "channel:create",
        "PATCH channels/:": "channel:update",
        "POST channels/:/members": "channel:add_member",
        "DELETE channels/:/members": "channel:remove_member",
        "POST channels/:/join": "channel:join",
        "POST channels/:/leave": "channel:leave",
        "GET channel-members": "channel:read",
        "GET messages/:/resolve": "message:read",
        "GET receive": "message:read",
        "GET tasks": "task:read",
        "POST server/avatar": "server:update",
        "GET knowledge": "knowledge:read",
        "GET history": "message:read",
        "POST tasks": "task:write",
        "POST tasks/claim": "task:write",
        "POST tasks/update-status": "task:write",
        "POST tasks/delete": "task:write",
        "POST tasks/convert": "task:write",
        "POST messages/:/reactions": "message:send",
        "DELETE messages/:/reactions": "message:send",
        "POST threads/unfollow": "thread:unfollow",
        "GET search": "message:read",
        "POST upload": "attachment:upload",
    ]
}

/// A mapped route's required scope; `nil` means "ownership only".
struct LegacyAgentMachineGateScope {
    let requiredScope: String?
}

enum LegacyAgentMachineGateScopeMapping {
    case mapped(LegacyAgentMachineGateScope)
    case unmapped
}
