import Foundation
import Testing
@testable import RaftHTTP

/// Behavior pinned by `packages/server/src/appFallback.api.test.ts` and the
/// handlers in `app.ts` at raft-source v1.21.23-source.1.

private func header(_ reply: HTTPReply, _ name: String) -> String {
    reply.value(for: name) ?? ""
}

@Test func unmatchedRoutesAreNoindexJSON404() {
    for path in ["/", "/not-a-real-path", "/api/not-a-real-path"] {
        let reply = AppFallback.reply(method: "GET", target: path, nodeEnv: "test", health: .ok, livez: .unmonitored)
        #expect(reply.status == 404)
        #expect(header(reply, "content-type").contains("application/json"))
        #expect(header(reply, "x-robots-tag") == "noindex, nofollow")
        #expect(reply.body == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"\(path)\"}")
    }
}

@Test func queryStringIsNotPartOfThe404Path() {
    let reply = AppFallback.reply(
        method: "GET",
        target: "/not-a-real-path?x=1",
        nodeEnv: "test",
        health: .ok,
        livez: .unmonitored
    )
    #expect(reply.body.contains("\"path\":\"/not-a-real-path\""))
}

@Test func percentEncodedPathIsDecodedInThe404Body() {
    let reply = AppFallback.reply(
        method: "GET",
        target: "/a%2Db",
        nodeEnv: "test",
        health: .ok,
        livez: .unmonitored
    )
    #expect(reply.body == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/a-b\"}")
}

@Test func livezWithoutAProbeIsUnmonitoredAndSeparateFromHealth() {
    let livez = AppFallback.reply(method: "GET", target: "/livez", nodeEnv: "test", health: .databaseUnreachable, livez: .unmonitored)
    #expect(livez.status == 200)
    #expect(livez.body == "{\"status\":\"ok\",\"ok\":true,\"db\":\"unmonitored\",\"msSinceDbSuccess\":null}")

    let health = AppFallback.reply(method: "GET", target: "/health", nodeEnv: "test", health: .ok, livez: .unmonitored)
    #expect(health.status == 200)
    #expect(header(health, "x-robots-tag") == "noindex, nofollow")
    #expect(health.body == "{\"status\":\"ok\"}")
}

@Test func productionUnmonitoredLivezIs503WithTheErrorWord() {
    let reply = AppFallback.reply(method: "GET", target: "/livez", nodeEnv: "production", health: .ok, livez: .unmonitored)
    #expect(reply.status == 503)
    #expect(reply.body == "{\"status\":\"error\",\"ok\":true,\"db\":\"unmonitored\",\"msSinceDbSuccess\":null}")
    #expect(header(reply, "x-robots-tag") == "noindex, nofollow")
}

@Test func staleLivezCarriesTheAgeAndRecoveryCarriesZero() {
    let stale = LivenessVerdict(ok: false, db: .stale, msSinceDbSuccess: livezDbStaleMs + 1)
    let dead = AppFallback.reply(method: "GET", target: "/livez", nodeEnv: "production", health: .ok, livez: stale)
    #expect(dead.status == 503)
    #expect(dead.body == "{\"status\":\"error\",\"ok\":false,\"db\":\"stale\",\"msSinceDbSuccess\":60001}")

    let fresh = LivenessVerdict(ok: true, db: .ok, msSinceDbSuccess: 0)
    let alive = AppFallback.reply(method: "GET", target: "/livez", nodeEnv: "production", health: .ok, livez: fresh)
    #expect(alive.status == 200)
    #expect(alive.body == "{\"status\":\"ok\",\"ok\":true,\"db\":\"ok\",\"msSinceDbSuccess\":0}")
}

@Test func healthDatabaseFailureIs503AndDropsTheErrorText() async {
    struct Secret: Error, CustomStringConvertible {
        var description: String { "password-should-not-leak" }
    }
    let result = await HealthCheck.run { throw Secret() }
    let reply = AppFallback.reply(method: "GET", target: "/health", nodeEnv: "test", health: result, livez: .unmonitored)
    #expect(reply.status == 503)
    #expect(header(reply, "content-type").contains("application/json"))
    #expect(header(reply, "x-robots-tag") == "noindex, nofollow")
    #expect(reply.body == "{\"status\":\"error\",\"detail\":\"database unreachable\"}")
    #expect(!reply.body.contains("password-should-not-leak"))
}

@Test func ordinaryAppDoesNotMountPlaywrightRoutes() {
    let cases = [
        ("POST", "/__playwright/scenarios"),
        ("DELETE", "/__playwright/scenarios/not-owned"),
        ("POST", "/__playwright/scenarios/not-owned/thread-window"),
    ]
    for (method, path) in cases {
        let reply = AppFallback.reply(method: method, target: path, nodeEnv: "test", health: .ok, livez: .unmonitored)
        #expect(reply.status == 404)
        #expect(reply.body.contains("\"code\":\"not_found\""))
    }
}

@Test func postHealthIsTheJSON404() {
    let reply = AppFallback.reply(method: "POST", target: "/health", nodeEnv: "test", health: .ok, livez: .unmonitored)
    #expect(reply.status == 404)
    #expect(reply.body == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/health\"}")
}

@Test func robotsTxtRejectsCrawlers() {
    let reply = AppFallback.reply(method: "GET", target: "/robots.txt", nodeEnv: "test", health: .databaseUnreachable, livez: .unmonitored)
    #expect(reply.status == 200)
    #expect(header(reply, "content-type").contains("text/plain"))
    #expect(header(reply, "x-robots-tag") == "noindex, nofollow")
    #expect(reply.body == AppFallback.robotsBody)
    #expect(reply.body == [
        "# Raft API host: authenticated API surface with no indexable public pages.",
        "User-agent: *",
        "Disallow: /",
        "",
    ].joined(separator: "\n"))
}

@Test func headKeepsTheContentLengthAndOmitsTheBody() {
    let reply = AppFallback.reply(method: "HEAD", target: "/health", nodeEnv: "test", health: .ok, livez: .unmonitored)
    #expect(reply.status == 200)
    #expect(reply.body == "")
    #expect(header(reply, "content-length") == String(Data("{\"status\":\"ok\"}".utf8).count))
    #expect(header(reply, "x-robots-tag") == "noindex, nofollow")
}

@Test func respondPingsOnlyHealthAndReadsLivezWithoutAPing() async {
    let clock = MutexClock()
    let tracker = DbLivenessTracker(ping: { throw ProbeFailure() }, now: { clock.value })
    let pings = PingCount()

    let livez = await AppFallback.respond(method: "GET", target: "/livez", nodeEnv: "test", tracker: tracker) {
        pings.add()
    }
    #expect(livez.status == 200)
    #expect(livez.body.contains("\"db\":\"unmonitored\""))
    #expect(pings.value == 0)

    let health = await AppFallback.respond(method: "GET", target: "/health", nodeEnv: "test", tracker: tracker) {
        pings.add()
    }
    #expect(health.status == 200)
    #expect(health.body == "{\"status\":\"ok\"}")
    #expect(pings.value == 1)

    let missing = await AppFallback.respond(method: "GET", target: "/nope", nodeEnv: "test", tracker: tracker) {
        pings.add()
    }
    #expect(missing.status == 404)
    #expect(pings.value == 1)
}

private struct ProbeFailure: Error {}

private final class PingCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class MutexClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
