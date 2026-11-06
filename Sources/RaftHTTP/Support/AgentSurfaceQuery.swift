import Foundation

public enum AgentSurfaceQuery {
    static func agentSurfaceQueryInt(_ query: String?, _ name: String) -> Int? {
        guard let query, !query.isEmpty else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            guard key == name, parts.count == 2 else { continue }
            let raw = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            return Int(raw)
        }
        return nil
    }

    static func agentSurfaceQueryString(_ query: String?, _ name: String) -> String? {
        guard let query, !query.isEmpty else { return nil }
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            guard key == name else { continue }
            let raw = parts.count > 1 ? String(parts[1]) : ""
            return (raw.removingPercentEncoding ?? raw)
        }
        return nil
    }
}
