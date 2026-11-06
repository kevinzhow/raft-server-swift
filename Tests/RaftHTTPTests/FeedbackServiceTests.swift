import Foundation
import RaftShared
import Synchronization
import Testing
@testable import RaftHTTP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Hands transport plumbing: the exact route-binding and reporter-session
/// requests, the legacy leniency of the upstream body checks, and the store
/// critical sections behind the commitment and session caches.

private let appId = "a48a84f8-04ed-4db3-9297-189a14a36afc"

private func root(_ byte: UInt8) -> String {
    EmailLoginDirectory.feedbackBase64URL(Data(repeating: byte, count: 32))
}

private func environment(
    root rootValue: String,
    scope: String = "multi",
    sessions: Bool = false
) -> FeedbackRouteEnvironment {
    FeedbackRouteEnvironment(
        baseURL: "https://hands.test",
        appSlug: "raft-feedback-web",
        appId: appId,
        clientKey: "qk",
        appToken: "app-token",
        conversationToken: "conv-token",
        credentialRevision: "7",
        reporterIntegrationId: appId,
        reporterIdSecret: "secret",
        routeSubjectKeyId: "v1",
        routeSubjectRoot: rootValue,
        routeCommitmentScope: scope,
        cursorSecret: "cursor",
        conversationSessionEnabled: sessions,
        isMultiApp: true
    )
}

private struct Seen: Sendable {
    var method: String
    var url: String
    var authorization: String?
    var contentType: String?
    var reporter: String?
    var timeout: TimeInterval
    var body: String
}

private final class Upstream: Sendable {
    private let calls = Mutex<[Seen]>([])
    private let responses = Mutex<[(Int, String)]>([])

    init(_ responses: [(Int, String)]) { self.responses.withLock { $0 = responses } }

    var seen: [Seen] { calls.withLock { $0 } }

    func answer(_ request: URLRequest) -> (status: Int, headers: [String: String], body: Data) {
        calls.withLock {
            $0.append(Seen(
                method: request.httpMethod ?? "",
                url: request.url?.absoluteString ?? "",
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                reporter: request.value(forHTTPHeaderField: "X-Hands-Reporter-Id"),
                timeout: request.timeoutInterval,
                body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            ))
        }
        let next: (Int, String) = responses.withLock { queue in
            queue.count > 1 ? queue.removeFirst() : (queue.first ?? (0, ""))
        }
        return (next.0, [:], Data(next.1.utf8))
    }
}

private func makeService(
    upstream: Upstream,
    store: FeedbackStore = FeedbackStore(),
    now: @escaping @Sendable () -> Date = { Date() },
    warn: @escaping @Sendable (String) -> Bool = { _ in true }
) -> FeedbackService {
    store.handsFeedbackUpstreamHandler = { upstream.answer($0) }
    return FeedbackService(
        store: store,
        dependencies: FeedbackService.Dependencies(
            conversationSessionEnabled: { nil },
            multiAppEnabled: { _ in true },
            deliverWarning: warn,
            processEnvironment: { [:] },
            now: now
        )
    )
}

private func bindingReason(_ error: any Error) -> String? {
    if case FeedbackRouteFailure.routeBinding(let reason) = error { return reason }
    return nil
}

@Test func routeBindingSendsTheExactPutAndCachesTheSuccess() async throws {
    let upstream = Upstream([(201, "{\"changed\":true,\"subject_version\":\"v1\"}")])
    let service = makeService(upstream: upstream)
    let env = environment(root: root(7))
    let reporter = try await service.ensureRouteBindingAsync(userId: "user-1", environment: env)

    let call = try #require(upstream.seen.first)
    #expect(upstream.seen.count == 1)
    #expect(call.method == "PUT")
    #expect(call.url == "https://hands.test/api/apps/\(appId)/reporter-feedback/route-subject")
    #expect(call.authorization == "Bearer conv-token")
    #expect(call.contentType == "application/json")
    #expect(call.reporter == reporter)
    #expect(call.timeout == 4)
    let subject = try #require(EmailLoginDirectory.feedbackRouteConfig(env).flatMap {
        EmailLoginDirectory.feedbackRouteSubject(config: $0, userId: "user-1", reporterId: reporter)
    })
    #expect(call.body == "{\"route_subject\":\"\(subject)\"}")
    #expect(subject.hasPrefix("rfr_v1_"))

    // The cached success answers without a second upstream call.
    #expect(try await service.ensureRouteBindingAsync(userId: "user-1", environment: env) == reporter)
    #expect(upstream.seen.count == 1)
    // Another user is a different cache key.
    _ = try await service.ensureRouteBindingAsync(userId: "user-2", environment: env)
    #expect(upstream.seen.count == 2)
}

@Test func routeBindingCacheExpiresAfterFiveMinutes() async throws {
    let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
    let upstream = Upstream([(200, "{\"changed\":false,\"subject_version\":\"v1\"}")])
    let service = makeService(upstream: upstream, now: { clock.withLock { $0 } })
    let env = environment(root: root(7))
    _ = try await service.ensureRouteBindingAsync(userId: "u", environment: env)
    clock.withLock { $0 = Date(timeIntervalSince1970: 1_000_299) }
    _ = try await service.ensureRouteBindingAsync(userId: "u", environment: env)
    #expect(upstream.seen.count == 1)
    clock.withLock { $0 = Date(timeIntervalSince1970: 1_000_301) }
    _ = try await service.ensureRouteBindingAsync(userId: "u", environment: env)
    #expect(upstream.seen.count == 2)
}

@Test func routeBindingRetriesOnceThenReportsTheLegacyReason() async throws {
    for (status, reason, calls) in [(503, "hands_status_503", 2), (0, "request_failed", 2), (403, "hands_status_403", 1)] {
        let upstream = Upstream([(status, "")])
        let service = makeService(upstream: upstream)
        do {
            _ = try await service.ensureRouteBindingAsync(userId: "u", environment: environment(root: root(7)))
            Issue.record("expected a route binding failure for \(status)")
        } catch {
            #expect(bindingReason(error) == reason)
        }
        #expect(upstream.seen.count == calls)
    }
}

@Test func routeBindingBodyChecksKeepTheLegacyLeniency() async throws {
    // (status, body, accepted)
    let cases: [(Int, String, Bool)] = [
        (200, "{\"changed\":false,\"subject_version\":\"v1\"}", true),
        (201, "{\"changed\":true,\"subject_version\":\"v1\"}", true),
        (201, "{\"changed\":1,\"subject_version\":\"v1\"}", true),
        (200, "{\"changed\":0,\"subject_version\":\"v1\"}", true),
        (200, "{\"changed\":2,\"subject_version\":\"v1\"}", false),
        (200, "{\"changed\":\"false\",\"subject_version\":\"v1\"}", false),
        (200, "{\"changed\":true,\"subject_version\":\"v1\"}", false),
        (201, "{\"changed\":false,\"subject_version\":\"v1\"}", false),
        (200, "{\"changed\":false,\"subject_version\":\"v2\"}", false),
        (200, "{\"changed\":false,\"subject_version\":\"v1\",\"extra\":1}", false),
        (200, "{\"changed\":false}", false),
        (200, "[]", false),
        (200, "not json", false),
        (200, "", false),
    ]
    for (status, body, accepted) in cases {
        let service = makeService(upstream: Upstream([(status, body)]))
        do {
            _ = try await service.ensureRouteBindingAsync(userId: "u", environment: environment(root: root(7)))
            #expect(accepted, "\(status) \(body) must be refused")
        } catch {
            #expect(!accepted, "\(status) \(body) must be accepted")
            #expect(bindingReason(error) == "hands_unexpected_body")
        }
    }
}

@Test func routeBindingRefusesADifferentRootForTheSameCommitmentLabel() async throws {
    let upstream = Upstream([(200, "{\"changed\":false,\"subject_version\":\"v1\"}")])
    let store = FeedbackStore()
    let service = makeService(upstream: upstream, store: store)
    _ = try await service.ensureRouteBindingAsync(userId: "u", environment: environment(root: root(1)))
    do {
        _ = try await service.ensureRouteBindingAsync(userId: "u", environment: environment(root: root(2)))
        Issue.record("expected a commitment mismatch")
    } catch {
        #expect(bindingReason(error) == "root_commitment_mismatch")
    }
    #expect(upstream.seen.count == 1)
    #expect(store.routeCommitmentLabels() == [FeedbackService.productFeedbackMultiCommitmentLabel])
}

@Test func commitmentCheckIsOneCriticalSectionUnderConcurrentFirstRequests() async {
    let store = FeedbackStore()
    let commitments = (0..<8).map { Data(repeating: UInt8($0), count: 32) }
    let results = await withTaskGroup(of: (Int, FeedbackStore.RouteBindingCheck).self) { group in
        for index in 0..<64 {
            group.addTask {
                (index % 8, store.checkRouteBinding(
                    commitmentLabel: "label",
                    commitment: commitments[index % 8],
                    cacheKey: "key-\(index)",
                    now: Date()
                ))
            }
        }
        var all: [(Int, FeedbackStore.RouteBindingCheck)] = []
        for await item in group { all.append(item) }
        return all
    }
    // Exactly one commitment won; every caller with another commitment lost and
    // every caller with the winner's commitment saw a miss.
    let winners = Set(results.filter { $0.1 == .miss }.map(\.0))
    #expect(winners.count == 1)
    #expect(results.filter { $0.1 == .miss }.count == 8)
    #expect(results.filter { $0.1 == .commitmentMismatch }.count == 56)
    #expect(store.routeCommitmentLabels() == ["label"])
}

@Test func routeBindingSuccessesAreRecordedAndExpire() {
    let store = FeedbackStore()
    let now = Date(timeIntervalSince1970: 100)
    #expect(store.checkRouteBinding(commitmentLabel: "l", commitment: Data([1]), cacheKey: "k", now: now) == .miss)
    store.recordRouteBindingSuccess(cacheKey: "k", expiresAt: now.addingTimeInterval(300))
    #expect(store.checkRouteBinding(commitmentLabel: "l", commitment: Data([1]), cacheKey: "k", now: now) == .cached)
    #expect(store.checkRouteBinding(commitmentLabel: "l", commitment: Data([1]), cacheKey: "k", now: now.addingTimeInterval(300)) == .miss)
    store.clearRouteBindingCache()
    #expect(store.checkRouteBinding(commitmentLabel: "l", commitment: Data([1]), cacheKey: "k", now: now) == .miss)
    #expect(store.routeCommitmentLabels() == ["l"])
    store.clearRouteBindingCache(includingCommitments: true)
    #expect(store.routeCommitmentLabels().isEmpty)
}

@Test func reporterSessionMintsWithTheExactRequestAndCaches() async throws {
    let clock = Mutex(Date(timeIntervalSince1970: 2_000_000))
    let upstream = Upstream([(201, "{\"session_token\":\"tok-1\",\"expires_at\":2000600}")])
    let service = makeService(upstream: upstream, now: { clock.withLock { $0 } })
    let env = environment(root: root(7), sessions: true)
    let token = try await service.bearerAsync(userId: "u", reporterId: "rep", environment: env)
    #expect(token == "tok-1")
    let call = try #require(upstream.seen.first)
    #expect(call.method == "POST")
    #expect(call.url == "https://hands.test/api/apps/\(appId)/reporter-feedback/session")
    #expect(call.authorization == "Bearer conv-token")
    #expect(call.contentType == "application/json")
    #expect(call.reporter == "rep")
    #expect(call.timeout == 10)
    #expect(call.body == "{\"scopes\":[\"feedback:comment\",\"feedback:read\"]}")

    #expect(try await service.bearerAsync(userId: "u", reporterId: "rep", environment: env) == "tok-1")
    #expect(upstream.seen.count == 1)
    // Inside the five-second leeway the cached token no longer counts.
    clock.withLock { $0 = Date(timeIntervalSince1970: 2_000_596) }
    _ = try await service.bearerAsync(userId: "u", reporterId: "rep", environment: env)
    #expect(upstream.seen.count == 2)
}

@Test func reporterSessionExpiryFollowsTheLegacyNumberBridge() async throws {
    let clock = Mutex(Date(timeIntervalSince1970: 3_000_000))
    // (body, cached): a numeric expiry far ahead caches; a boolean bridges to
    // 1.0 (long past); a string or absent expiry defaults to 30 s ahead.
    let cases: [(String, Bool)] = [
        ("{\"session_token\":\"t\",\"expires_at\":3000600}", true),
        ("{\"session_token\":\"t\",\"expires_at\":3000600.5}", true),
        ("{\"session_token\":\"t\",\"expires_at\":true}", false),
        ("{\"session_token\":\"t\",\"expires_at\":\"3000600\"}", true),
        ("{\"session_token\":\"t\"}", true),
        ("{\"session_token\":\"t\",\"expires_at\":3000001}", false),
    ]
    for (body, cached) in cases {
        let upstream = Upstream([(200, body)])
        let service = makeService(upstream: upstream, now: { clock.withLock { $0 } })
        let env = environment(root: root(7), sessions: true)
        _ = try await service.bearerAsync(userId: "u", reporterId: "r", environment: env)
        _ = try await service.bearerAsync(userId: "u", reporterId: "r", environment: env)
        #expect(upstream.seen.count == (cached ? 1 : 2), "\(body)")
    }
}

@Test func reporterSessionFailuresAreConfigurationFailures() async {
    for (status, body) in [
        (500, "{\"session_token\":\"t\"}"), (200, "{\"session_token\":\"\"}"),
        (200, "{\"session_token\":3}"), (200, "[]"), (200, "nope"), (0, ""),
    ] {
        let service = makeService(upstream: Upstream([(status, body)]))
        do {
            _ = try await service.bearerAsync(
                userId: "u", reporterId: "r", environment: environment(root: root(7), sessions: true)
            )
            Issue.record("expected failure for \(status) \(body)")
        } catch {
            if case FeedbackRouteFailure.configuration = error {} else {
                Issue.record("expected configuration failure, got \(error)")
            }
        }
    }
}

@Test func bearerWithoutSessionsReturnsTheConversationTokenWithoutUpstream() async throws {
    let upstream = Upstream([(200, "{}")])
    let service = makeService(upstream: upstream)
    let token = try await service.bearerAsync(
        userId: "u", reporterId: "r", environment: environment(root: root(7), sessions: false)
    )
    #expect(token == "conv-token")
    #expect(upstream.seen.isEmpty)
}

@Test func reporterSessionCacheIsConsistentUnderConcurrentWriters() async {
    let store = FeedbackStore()
    let valid = Date(timeIntervalSince1970: 10_000)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<64 {
            group.addTask {
                store.storeReporterSession(cacheKey: "k", token: "t\(index % 4)", expiresAt: valid)
                let token = store.cachedReporterSession(cacheKey: "k", validAfter: Date(timeIntervalSince1970: 1))
                #expect(token?.hasPrefix("t") == true)
            }
        }
    }
    #expect(store.cachedReporterSession(cacheKey: "k", validAfter: valid) == nil)
    store.clearReporterSessions()
    #expect(store.cachedReporterSession(cacheKey: "k", validAfter: Date(timeIntervalSince1970: 1)) == nil)
}

@Test func warningsGoToTheSinkOrFallBackToThePrintedLine() {
    let delivered = Mutex<[String]>([])
    let service = makeService(upstream: Upstream([]), warn: { message in
        delivered.withLock { $0.append(message) }
        return true
    })
    service.warn("reason_code")
    #expect(delivered.withLock { $0 } == ["reason_code"])
}

@Test func routeEnvironmentRejectsAnUntrustedSourceAndHonoursTheFlag() throws {
    let store = FeedbackStore()
    store.handsFeedbackBaseURLOverride = "https://hands.test/"
    store.handsFeedbackAppIdOverride = appId
    let legacy = FeedbackService(
        store: store,
        dependencies: FeedbackService.Dependencies(
            conversationSessionEnabled: { true },
            multiAppEnabled: { _ in false },
            deliverWarning: { _ in true },
            processEnvironment: { ["HANDS_FEEDBACK_CLIENT_KEY": "ck"] }
        )
    )
    #expect(throws: FeedbackRouteFailure.self) { try legacy.routeEnvironment(source: "desktop", userId: "u") }
    let env = try legacy.routeEnvironment(source: "web", userId: "u")
    #expect(env.baseURL == "https://hands.test")
    #expect(env.appId == appId)
    #expect(env.clientKey == "ck")
    #expect(env.conversationSessionEnabled)
    #expect(!env.isMultiApp)
}

/// Known divergence (not asserted): a body repeating a key keeps the FIRST value
/// under `JSONDecoder`, where the retired `JSONSerialization` kept the last.
@Test func upstreamBodyHelpersMatchTheRetiredCasts() throws {
    let samples = [
        "{\"b\":true,\"i\":1,\"z\":0,\"d\":1.5,\"s\":\"x\",\"n\":null,\"two\":2,\"neg\":-1,\"half\":0.5}",
        "{\"b\":false}", "[]", "\"x\"", "7", "", "{",
    ]
    for sample in samples {
        let data = Data(sample.utf8)
        let legacy = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let object = FeedbackService.decodeObject(data)
        #expect((legacy == nil) == (object == nil), "\(sample)")
        guard let legacy, let object else { continue }
        #expect(Set(legacy.keys) == Set(object.keys), "\(sample)")
        for key in legacy.keys {
            #expect(legacy[key] as? Bool == FeedbackService.legacyBool(object[key]), "\(sample) \(key)")
            #expect(
                (legacy[key] as? NSNumber)?.doubleValue == FeedbackService.legacyNumber(object[key]),
                "\(sample) \(key)"
            )
        }
    }
}
