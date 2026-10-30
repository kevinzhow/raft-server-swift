import Foundation

/// Proxy selection from `packages/daemon/src/proxy.ts` at raft-source
/// v1.21.23-source.1. This decides whether a websocket or fetch uses a proxy.
/// It does not open a tunnel.

public struct ProviderProxyRejection: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum DaemonProxy {
    /// `serverUrl.replace(/^http/, "ws") + "/daemon/connect"`.
    public static func webSocketURL(serverUrl: String) -> String {
        var url = serverUrl
        if url.hasPrefix("http") {
            url = "ws" + url.dropFirst(4)
        }
        return url + "/daemon/connect"
    }

    /// The proxy URL passed to the websocket agent, or nil when the socket
    /// goes direct. Nil is the Node `agent: undefined` case.
    public static func webSocketProxyURL(_ webSocketURL: String, environment: [String: String]) -> String? {
        resolve(webSocketURL, environment: environment)
    }

    public static func fetchProxyURL(_ targetURL: String, environment: [String: String]) -> String? {
        resolve(targetURL, environment: environment)
    }

    public static func shouldBypass(_ targetURL: String, environment: [String: String]) -> Bool {
        guard let raw = environment["NO_PROXY"] ?? environment["no_proxy"], !raw.isEmpty else { return false }
        guard let parts = targetParts(targetURL) else { return false }
        return raw.split(separator: ",", omittingEmptySubsequences: false).contains { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            if trimmed == "*" { return true }
            let pieces = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let ruleHost = pieces.first ?? ""
            if pieces.count == 2, pieces[1] != parts.port { return false }
            return hostMatches(parts.hostname, ruleHost: ruleHost)
        }
    }

    /// Closed HTTP(S) protocols for provider fetches. The message never includes
    /// the proxy URL.
    public static func validateProviderProxy(environment: [String: String]) throws {
        let options = providerProxyOptions(environment)
        try assertSupported(options.http)
        try assertSupported(options.https)
    }
}

private struct TargetParts {
    var scheme: String
    var hostname: String
    var port: String
}

private func resolve(_ targetURL: String, environment: [String: String]) -> String? {
    guard let proxy = proxyURL(for: targetURL, environment: environment) else { return nil }
    if DaemonProxy.shouldBypass(targetURL, environment: environment) { return nil }
    return proxy
}

private func proxyURL(for targetURL: String, environment: [String: String]) -> String? {
    guard let parts = targetParts(targetURL) else { return nil }
    switch parts.scheme {
    case "wss:":
        return first(environment, "WSS_PROXY", "wss_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy")
    case "ws:":
        return first(environment, "WS_PROXY", "ws_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy")
    case "https:":
        return first(environment, "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy")
    case "http:":
        return first(environment, "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy")
    default:
        return first(environment, "ALL_PROXY", "all_proxy")
    }
}

private func providerProxyOptions(_ environment: [String: String]) -> (http: String?, https: String?) {
    let all = environment["ALL_PROXY"] ?? environment["all_proxy"]
    return (
        environment["HTTP_PROXY"] ?? environment["http_proxy"] ?? all,
        environment["HTTPS_PROXY"] ?? environment["https_proxy"] ?? all
    )
}

private func assertSupported(_ proxyURL: String?) throws {
    guard let proxyURL else { return }
    guard let scheme = URLComponents(string: proxyURL)?.scheme else {
        throw ProviderProxyRejection(code: "PI_PROVIDER_PROXY_INVALID", message: "Pi provider proxy URL is invalid")
    }
    if scheme == "http" || scheme == "https" { return }
    throw ProviderProxyRejection(
        code: "PI_PROVIDER_PROXY_PROTOCOL_UNSUPPORTED",
        message: "Pi provider proxy protocol is unsupported"
    )
}

private func first(_ environment: [String: String], _ keys: String...) -> String? {
    for key in keys {
        if let value = environment[key] { return value }
    }
    return nil
}

private func targetParts(_ targetURL: String) -> TargetParts? {
    guard let components = URLComponents(string: targetURL), let scheme = components.scheme, let host = components.host else {
        return nil
    }
    let port = components.port.map(String.init) ?? defaultPort(scheme + ":")
    return TargetParts(scheme: scheme + ":", hostname: host, port: port)
}

private func defaultPort(_ scheme: String) -> String {
    switch scheme {
    case "https:", "wss:": "443"
    case "http:", "ws:": "80"
    default: ""
    }
}

private func hostMatches(_ hostname: String, ruleHost: String) -> Bool {
    if ruleHost.isEmpty { return false }
    var rule = ruleHost
    if rule.hasPrefix("*.") {
        rule = String(rule.dropFirst())
    }
    if rule.hasPrefix(".") {
        rule = String(rule.dropFirst())
    }
    let normalizedRule = rule.lowercased()
    let normalizedHost = hostname.lowercased()
    return normalizedHost == normalizedRule || normalizedHost.hasSuffix("." + normalizedRule)
}
