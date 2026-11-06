import Foundation
import Synchronization
import RaftHTTP
import Vapor

/// Derives the internal route-auth projection from the live router.
///
/// The `/internal/*` surfaces are credential-principal routes: `/internal/computer/`
/// is only reachable with an `sk_computer_*` principal and `/internal/agent-api/`
/// plus `/internal/agent/` only with an `sk_agent_*` principal. Preflight reports
/// exactly what the router currently claims, so a route added without a principal
/// decision is visible instead of silently unaccounted for.
enum InternalSurfacePolicy {
    /// Bumped when a claimed surface changes principal or a prefix is added.
    static let surfaceVersion = "1"

    static let claimedPrefixes = [
        "/internal/agent/",
        "/internal/agent-api/",
        "/internal/computer/",
    ]

    static func principal(forPath path: String) -> String? {
        if path.hasPrefix("/internal/computer/") { return "sk_computer" }
        if path.hasPrefix("/internal/agent-api/") || path.hasPrefix("/internal/agent/") { return "sk_agent" }
        return nil
    }

    static func snapshot(routes: [Route]) -> InternalSurfaceSnapshot {
        var entries: [InternalSurfaceEntry] = []
        for route in routes {
            // Wildcard routes (the unregistered-path catch-all) are not claimed
            // surfaces: they answer, but they describe nothing.
            let wildcard = route.path.contains { $0.description == "*" || $0.description == "**" }
            guard !wildcard else { continue }
            let pattern = "/" + route.path.string
            guard let principal = principal(forPath: pattern) else { continue }
            entries.append(InternalSurfaceEntry(method: route.method.rawValue, path: pattern, principal: principal))
        }
        entries.sort { left, right in
            left.path == right.path ? left.method < right.method : left.path < right.path
        }
        let principals = Array(Set(entries.map(\.principal))).sorted()
        return InternalSurfaceSnapshot(
            surfaceVersion: surfaceVersion,
            claimedPrefixes: claimedPrefixes,
            registeredPrincipals: principals,
            computerSurface: entries.filter { $0.path.hasPrefix("/internal/computer/") }
        )
    }

    static let empty = InternalSurfaceSnapshot(
        surfaceVersion: surfaceVersion,
        claimedPrefixes: claimedPrefixes,
        registeredPrincipals: [],
        computerSurface: []
    )
}

/// Holds the projection computed once at configuration time, after every route
/// (including preflight itself) is registered. Written before the server starts
/// serving, read-only afterwards.
final class InternalSurfaceBox: Sendable {
    private let stored = Mutex<InternalSurfaceSnapshot?>(nil)

    func set(_ value: InternalSurfaceSnapshot) {
        stored.withLock { $0 = value }
    }

    var value: InternalSurfaceSnapshot {
        stored.withLock { $0 ?? InternalSurfacePolicy.empty }
    }
}
