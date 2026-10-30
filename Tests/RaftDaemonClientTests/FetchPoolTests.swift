import Testing
@testable import RaftDaemonClient

private struct TransportRejected: Error {}

@Test func oneProxyUrlKeepsOneDispatcher() {
    let pool = DaemonFetchPool()
    let env = ["HTTPS_PROXY": "http://proxy.cache-reuse.test:8080"]
    let first = pool.buildFetchDispatcher("https://api.slock.ai/internal/agent/1/receive", environment: env)
    let second = pool.buildFetchDispatcher("https://api.slock.ai/internal/agent/2/receive", environment: env)
    #expect(first != nil)
    #expect(second == first)
    #expect(first?.connectTimeoutMs == 30_000)
    #expect(first?.headersTimeoutMs == 30_000)
    #expect(first?.proxyURL == "http://proxy.cache-reuse.test:8080")
}

@Test func preResponseTimeoutComesFromTheEnvironment() {
    let pool = DaemonFetchPool()
    let env = [
        "HTTPS_PROXY": "http://proxy.timeout.test:8080",
        "SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "300",
    ]
    let dispatcher = pool.buildFetchDispatcher("https://api.slock.ai/internal/agent-api/send", environment: env)
    #expect(dispatcher?.connectTimeoutMs == 300)
    #expect(dispatcher?.headersTimeoutMs == 300)
    #expect(preResponseTimeoutMs([:]) == 30_000)
    #expect(preResponseTimeoutMs(["SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "0"]) == 30_000)
    #expect(preResponseTimeoutMs(["SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "nope"]) == 30_000)
}

@Test func isolatedLanesDoNotSharePools() {
    let pool = DaemonFetchPool()
    let directURL = "http://127.0.0.1:3001/internal/agent-api/send"
    #expect(pool.buildFetchDispatcher(directURL, environment: [:]) == nil)

    let proxyLane = pool.buildIsolatedFetchDispatcher(directURL, isolationKey: "agent-credential-proxy", environment: [:])
    let proxyLaneAgain = pool.buildIsolatedFetchDispatcher(directURL, isolationKey: "agent-credential-proxy", environment: [:])
    let backlogLane = pool.buildIsolatedFetchDispatcher(directURL, isolationKey: "daemon-backlog", environment: [:])
    #expect(proxyLaneAgain == proxyLane)
    #expect(backlogLane != proxyLane)
    #expect(pool.evictIsolatedFetchDispatcher(directURL, isolationKey: "daemon-backlog", environment: [:]))
    #expect(pool.buildIsolatedFetchDispatcher(directURL, isolationKey: "agent-credential-proxy", environment: [:]) == proxyLane)

    let proxyEnv = ["HTTPS_PROXY": "http://127.0.0.1:8899"]
    let proxiedURL = "https://api.raft.build/internal/agent-api/send"
    let shared = pool.buildFetchDispatcher(proxiedURL, environment: proxyEnv)
    let isolated = pool.buildIsolatedFetchDispatcher(proxiedURL, isolationKey: "agent-credential-proxy", environment: proxyEnv)
    #expect(shared != nil)
    #expect(isolated != shared)

    let env = ["SLOCK_DAEMON_FETCH_PRE_RESPONSE_TIMEOUT_MS": "30000"]
    let upload = "http://127.0.0.1:3001/internal/agent-api/upload"
    let ordinary = pool.buildIsolatedFetchDispatcher(upload, isolationKey: "credential-lane-timeout-test", environment: env)
    let extended = pool.buildIsolatedFetchDispatcher(
        upload,
        isolationKey: "credential-lane-timeout-test",
        environment: env,
        headersTimeoutMs: 300_000
    )
    #expect(extended != ordinary)
    #expect(extended.headersTimeoutMs == 300_000)
    #expect(ordinary.headersTimeoutMs == 30_000)
    #expect(pool.buildIsolatedFetchDispatcher(
        upload,
        isolationKey: "credential-lane-timeout-test",
        environment: env,
        headersTimeoutMs: 300_000
    ) == extended)
    #expect(pool.evictIsolatedFetchDispatcher(
        upload,
        isolationKey: "credential-lane-timeout-test",
        environment: env,
        headersTimeoutMs: 300_000
    ))
    #expect(pool.buildIsolatedFetchDispatcher(upload, isolationKey: "credential-lane-timeout-test", environment: env) == ordinary)
}

@Test func evictIsFalseWhenTheRequestGoesDirect() {
    let pool = DaemonFetchPool()
    #expect(pool.evictFetchDispatcher("https://api.slock.ai/internal/agent-api/send", environment: [:]) == false)
    #expect(pool.evictFetchDispatcher(
        "http://localhost:3001/internal/agent-api/send",
        environment: ["HTTP_PROXY": "http://proxy.internal:8080", "NO_PROXY": "localhost"]
    ) == false)
}

@Test func evictDropsTheCachedDispatcher() {
    let pool = DaemonFetchPool()
    let env = ["HTTPS_PROXY": "http://proxy.evict-unit.test:8080"]
    let url = "https://api.slock.ai/internal/agent-api/send"
    let first = pool.buildFetchDispatcher(url, environment: env)
    #expect(pool.buildFetchDispatcher(url, environment: env) == first)
    #expect(pool.evictFetchDispatcher(url, environment: env))
    let rebuilt = pool.buildFetchDispatcher(url, environment: env)
    #expect(rebuilt != nil)
    #expect(rebuilt != first)
    #expect(pool.evictFetchDispatcher(
        url,
        environment: ["HTTPS_PROXY": "http://proxy.evict-unit-empty.test:8080"]
    ) == false)
}

@Test func transportRejectEvictsAndAnHttpResponseDoesNot() throws {
    let pool = DaemonFetchPool()
    let env = ["HTTPS_PROXY": "http://proxy.blackhole.test:8080"]
    let url = "https://api.slock.invalid/internal/agent-api/send"
    let before = pool.buildFetchDispatcher(url, environment: env)
    #expect(throws: TransportRejected.self) {
        try pool.fetch(url, environment: env) { _ in throw TransportRejected() }
    }
    let after = pool.buildFetchDispatcher(url, environment: env)
    #expect(after != before)

    let kept = pool.buildFetchDispatcher(url, environment: env)
    let serverError = try pool.fetch(url, environment: env) { _ in
        DaemonFetchResponse(status: 500, body: "{\"error\":\"boom\"}")
    }
    #expect(serverError.status == 500)
    #expect(pool.buildFetchDispatcher(url, environment: env) == kept)

    let missing = try pool.fetch(url, environment: env) { _ in
        DaemonFetchResponse(status: 404, body: "{\"error\":\"not_found\"}")
    }
    #expect(missing.status == 404)
    #expect(pool.buildFetchDispatcher(url, environment: env) == kept)
}
