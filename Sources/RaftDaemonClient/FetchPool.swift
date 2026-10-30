import Foundation

/// Connection pools from `buildFetchDispatcher` and `daemonFetch` in
/// `packages/daemon/src/proxy.ts` and `daemonFetch.ts`.
///
/// One proxy URL keeps one dispatcher. A transport rejection drops that
/// dispatcher. Any HTTP response, including 4xx and 5xx, keeps it.
/// The pre-response timeout bounds connect and headers only. It is 30s unless
/// `SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS` is a positive integer.

public final class DaemonDispatcher: Equatable, Sendable {
    public let proxyURL: String?
    public let connectTimeoutMs: Int
    public let headersTimeoutMs: Int
    public let bodyTimeoutMs: Int?

    init(proxyURL: String?, connectTimeoutMs: Int, headersTimeoutMs: Int, bodyTimeoutMs: Int?) {
        self.proxyURL = proxyURL
        self.connectTimeoutMs = connectTimeoutMs
        self.headersTimeoutMs = headersTimeoutMs
        self.bodyTimeoutMs = bodyTimeoutMs
    }

    public static func == (lhs: DaemonDispatcher, rhs: DaemonDispatcher) -> Bool {
        lhs === rhs
    }
}

public struct DaemonFetchResponse: Equatable, Sendable {
    public var status: Int
    public var body: String

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

public final class DaemonFetchPool: @unchecked Sendable {
    private let lock = NSLock()
    private var shared: [String: DaemonDispatcher] = [:]
    private var isolated: [String: DaemonDispatcher] = [:]
    private var direct: DaemonDispatcher?

    public init() {}

    public func buildFetchDispatcher(_ targetURL: String, environment: [String: String]) -> DaemonDispatcher? {
        guard let proxyURL = DaemonProxy.fetchProxyURL(targetURL, environment: environment) else { return nil }
        let timeout = preResponseTimeoutMs(environment)
        lock.lock()
        defer { lock.unlock() }
        if let cached = shared[proxyURL] { return cached }
        let created = DaemonDispatcher(
            proxyURL: proxyURL,
            connectTimeoutMs: timeout,
            headersTimeoutMs: timeout,
            bodyTimeoutMs: nil
        )
        shared[proxyURL] = created
        return created
    }

    public func buildIsolatedFetchDispatcher(
        _ targetURL: String,
        isolationKey: String,
        environment: [String: String],
        headersTimeoutMs: Int? = nil,
        bodyTimeoutMs: Int? = nil
    ) -> DaemonDispatcher {
        let key = isolatedCacheKey(
            targetURL,
            isolationKey: isolationKey,
            environment: environment,
            headersTimeoutMs: headersTimeoutMs,
            bodyTimeoutMs: bodyTimeoutMs
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = isolated[key.cacheKey] { return cached }
        let created = DaemonDispatcher(
            proxyURL: key.proxyURL,
            connectTimeoutMs: key.connectTimeoutMs,
            headersTimeoutMs: key.headersTimeoutMs,
            bodyTimeoutMs: key.bodyTimeoutMs
        )
        isolated[key.cacheKey] = created
        return created
    }

    private func directDispatcher(_ environment: [String: String]) -> DaemonDispatcher {
        let timeout = preResponseTimeoutMs(environment)
        lock.lock()
        defer { lock.unlock() }
        if let direct { return direct }
        let created = DaemonDispatcher(
            proxyURL: nil,
            connectTimeoutMs: timeout,
            headersTimeoutMs: timeout,
            bodyTimeoutMs: nil
        )
        direct = created
        return created
    }

    @discardableResult
    public func evictFetchDispatcher(_ targetURL: String, environment: [String: String]) -> Bool {
        guard let proxyURL = DaemonProxy.fetchProxyURL(targetURL, environment: environment) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return shared.removeValue(forKey: proxyURL) != nil
    }

    @discardableResult
    public func evictIsolatedFetchDispatcher(
        _ targetURL: String,
        isolationKey: String,
        environment: [String: String],
        headersTimeoutMs: Int? = nil,
        bodyTimeoutMs: Int? = nil
    ) -> Bool {
        let key = isolatedCacheKey(
            targetURL,
            isolationKey: isolationKey,
            environment: environment,
            headersTimeoutMs: headersTimeoutMs,
            bodyTimeoutMs: bodyTimeoutMs
        )
        lock.lock()
        defer { lock.unlock() }
        return isolated.removeValue(forKey: key.cacheKey) != nil
    }

    /// Opens the real socket. A transport timeout evicts the pool that served it.
    public func perform(
        _ targetURL: String,
        method: String,
        environment: [String: String],
        isolationKey: String? = nil
    ) async throws -> DaemonFetchResponse {
        let dispatcher: DaemonDispatcher
        if let isolationKey {
            dispatcher = buildIsolatedFetchDispatcher(targetURL, isolationKey: isolationKey, environment: environment)
        } else if let proxied = buildFetchDispatcher(targetURL, environment: environment) {
            dispatcher = proxied
        } else {
            dispatcher = directDispatcher(environment)
        }
        do {
            return try await DaemonHTTP.execute(targetURL: targetURL, method: method, dispatcher: dispatcher)
        } catch {
            if let isolationKey {
                evictIsolatedFetchDispatcher(targetURL, isolationKey: isolationKey, environment: environment)
            } else {
                evictFetchDispatcher(targetURL, environment: environment)
            }
            throw error
        }
    }

    /// A thrown transport error evicts the pool that served the request.
    /// A returned response does not.
    public func fetch(
        _ targetURL: String,
        environment: [String: String],
        isolationKey: String? = nil,
        headersTimeoutMs: Int? = nil,
        bodyTimeoutMs: Int? = nil,
        transport: (DaemonDispatcher) throws -> DaemonFetchResponse
    ) throws -> DaemonFetchResponse {
        let dispatcher: DaemonDispatcher
        if let isolationKey {
            dispatcher = buildIsolatedFetchDispatcher(
                targetURL,
                isolationKey: isolationKey,
                environment: environment,
                headersTimeoutMs: headersTimeoutMs,
                bodyTimeoutMs: bodyTimeoutMs
            )
        } else if let proxied = buildFetchDispatcher(targetURL, environment: environment) {
            dispatcher = proxied
        } else {
            dispatcher = directDispatcher(environment)
        }
        do {
            return try transport(dispatcher)
        } catch {
            if let isolationKey {
                evictIsolatedFetchDispatcher(
                    targetURL,
                    isolationKey: isolationKey,
                    environment: environment,
                    headersTimeoutMs: headersTimeoutMs,
                    bodyTimeoutMs: bodyTimeoutMs
                )
            } else {
                evictFetchDispatcher(targetURL, environment: environment)
            }
            throw error
        }
    }
}

private struct IsolatedCacheKey {
    var cacheKey: String
    var proxyURL: String?
    var connectTimeoutMs: Int
    var headersTimeoutMs: Int
    var bodyTimeoutMs: Int?
}

private func isolatedCacheKey(
    _ targetURL: String,
    isolationKey: String,
    environment: [String: String],
    headersTimeoutMs: Int?,
    bodyTimeoutMs: Int?
) -> IsolatedCacheKey {
    let proxyURL = DaemonProxy.fetchProxyURL(targetURL, environment: environment)
    let routeKey = proxyURL.map { "proxy:\($0)" } ?? "direct:\(origin(of: targetURL))"
    let connectTimeoutMs = preResponseTimeoutMs(environment)
    let headers = headersTimeoutMs ?? connectTimeoutMs
    let bodyKey = bodyTimeoutMs.map(String.init) ?? "default"
    return IsolatedCacheKey(
        cacheKey: "\(isolationKey)\u{0}\(routeKey)\u{0}connect:\(connectTimeoutMs)\u{0}headers:\(headers)\u{0}body:\(bodyKey)",
        proxyURL: proxyURL,
        connectTimeoutMs: connectTimeoutMs,
        headersTimeoutMs: headers,
        bodyTimeoutMs: bodyTimeoutMs
    )
}

func preResponseTimeoutMs(_ environment: [String: String]) -> Int {
    let raw = environment["SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS"] ?? ""
    guard let parsed = jsParseInt(raw), parsed > 0 else { return 30_000 }
    return parsed
}

private func jsParseInt(_ raw: String) -> Int? {
    var index = raw.startIndex
    while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
    guard index < raw.endIndex else { return nil }
    var sign = 1
    if raw[index] == "+" || raw[index] == "-" {
        if raw[index] == "-" { sign = -1 }
        index = raw.index(after: index)
    }
    var value = 0
    var digits = 0
    while index < raw.endIndex, let digit = raw[index].wholeNumberValue, digit < 10 {
        value = value * 10 + digit
        digits += 1
        index = raw.index(after: index)
    }
    guard digits > 0 else { return nil }
    return sign * value
}

private func origin(of targetURL: String) -> String {
    guard let components = URLComponents(string: targetURL),
          let scheme = components.scheme,
          let host = components.host
    else { return targetURL }
    if let port = components.port {
        return "\(scheme)://\(host):\(port)"
    }
    return "\(scheme)://\(host)"
}
