import Crypto
import Foundation
import RaftShared
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asynchronous transport for the upstream Hands product-feedback API plus the
/// shared configuration, route-binding and conversation plumbing.
///
/// The feedback handlers run on Vapor's concurrency pool. `URLSession` is
/// bridged with `withCheckedContinuation` so a request never parks a worker
/// thread on a semaphore; the 12 s ceiling is enforced by the request timeout
/// and a watchdog task that resumes the continuation exactly once.
///
/// The feedback ledger (route-binding cache, reporter sessions, commitments)
/// lives in `FeedbackStore`; the ticket routes live in
/// `FeedbackMultiAppService` and the submission in
/// `ProductFeedbackSubmissionService`, which both reach this plumbing through
/// closures wired by the directory accessors.
public struct FeedbackService: Sendable {
    public typealias UpstreamResponse = (status: Int, headers: [String: String], body: Data)
    public typealias InjectedTransport = (URLRequest) -> UpstreamResponse

    /// Mirrors the old `semaphore.wait(timeout: .now() + 12)` ceiling.
    public static let requestTimeout: TimeInterval = 12

    /// Feature flag key from `productFeedbackApps.ts`.
    public static let productFeedbackMultiAppFlag = "product_feedback_multi_app"

    /// Trusted client sources; anything else is an invalid request.
    static let productFeedbackSources: Set<String> = ["web", "ios", "android", "ohos"]

    static let productFeedbackLegacyCommitmentLabel = "hands-feedback-route-subject:v1"
    static let productFeedbackMultiCommitmentLabel = "hands-feedback-route-subject:multi:v1"

    static let feedbackTimingNames: Set<String> = [
        "hands_auth", "hands_preflight", "hands_commit", "hands_postcommit",
        "hands_list", "hands_session_mint", "hands_session_verify",
    ]

    /// Cross-domain reads that belong to unmigrated or other domains.
    struct Dependencies: Sendable {
        /// `HANDS_FEEDBACK_CONVERSATION_SESSION_ENABLED` test seam (account store).
        var conversationSessionEnabled: @Sendable () -> Bool?
        /// The `product_feedback_multi_app` feature-flag decision for a user.
        var multiAppEnabled: @Sendable (_ userId: String) -> Bool
        /// Hands the warning to the operator sink; `false` when none is
        /// installed, in which case the service prints it.
        var deliverWarning: @Sendable (_ message: String) -> Bool
        var processEnvironment: @Sendable () -> [String: String]
        var now: @Sendable () -> Date

        init(
            conversationSessionEnabled: @escaping @Sendable () -> Bool?,
            multiAppEnabled: @escaping @Sendable (String) -> Bool,
            deliverWarning: @escaping @Sendable (String) -> Bool,
            processEnvironment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.conversationSessionEnabled = conversationSessionEnabled
            self.multiAppEnabled = multiAppEnabled
            self.deliverWarning = deliverWarning
            self.processEnvironment = processEnvironment
            self.now = now
        }
    }

    let store: FeedbackStore
    let dependencies: Dependencies

    init(store: FeedbackStore, dependencies: Dependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    /// Sends `request` upstream.
    ///
    /// When a test seam is installed (`injected`), it answers synchronously and
    /// no `URLSession` work is scheduled. Otherwise the request is executed
    /// asynchronously; transport failures and the timeout produce the same
    /// zero status the synchronous implementation reported.
    public func sendUpstreamRequest(
        _ request: URLRequest,
        injected: InjectedTransport? = nil
    ) async -> UpstreamResponse {
        if let injected {
            return injected(request)
        }
        var prepared = request
        if prepared.timeoutInterval <= 0 || prepared.timeoutInterval > Self.requestTimeout {
            prepared.timeoutInterval = Self.requestTimeout
        }

        return await withCheckedContinuation { continuation in
            let box = UpstreamContinuationBox(continuation: continuation)
            let taskBox = DataTaskBox()
            let task = URLSession.shared.dataTask(with: prepared) { data, response, _ in
                var status = 0
                var headers: [String: String] = [:]
                if let http = response as? HTTPURLResponse {
                    status = http.statusCode
                    for (key, value) in http.allHeaderFields {
                        headers[String(describing: key)] = String(describing: value)
                    }
                }
                box.resume((status, headers, data ?? Data()))
            }
            taskBox.task = task
            // Install the watchdog before starting the task so a very fast
            // response can still cancel it.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Self.requestTimeout))
                if box.resume((0, [:], Data())) {
                    taskBox.task?.cancel()
                }
            }
            box.install(timeoutTask: watchdog)
            task.resume()
        }
    }

    // MARK: - Transport seam

    /// Async transport used by every production feedback route.
    func sendAsync(_ request: URLRequest) async -> UpstreamResponse {
        await sendUpstreamRequest(request, injected: store.handsFeedbackUpstreamHandler)
    }

    // MARK: - Warning sink

    func warn(_ message: String) {
        if !dependencies.deliverWarning(message) {
            print(message)
        }
    }

    // MARK: - Configuration resolution

    func routeEnvironment(source: String, userId: String) throws -> FeedbackRouteEnvironment {
        guard Self.productFeedbackSources.contains(source) else {
            throw FeedbackRouteFailure.invalidSource
        }
        // One store critical section: the merged environment and the apps
        // payload are read together.
        let snapshot = store.handsFeedbackSubmissionConfiguration(
            base: dependencies.processEnvironment(),
            conversationSessionEnabled: dependencies.conversationSessionEnabled()
        )
        guard dependencies.multiAppEnabled(userId) else {
            return FeedbackRouting.feedbackLegacyRouteEnvironment(snapshot.environment)
        }
        return try FeedbackRouting.feedbackMultiRouteEnvironment(
            source: source,
            appsJSON: snapshot.appsJSON,
            environment: snapshot.environment
        )
    }

    // MARK: - Reporter id

    func reporterId(userId: String) -> String {
        let secret = store.handsFeedbackBaseURLOverride
            ?? dependencies.processEnvironment()["HANDS_FEEDBACK_REPORTER_ID_SECRET"]
            ?? "reporter-id-secret"
        let digest = SHA256.hash(data: Data("\(userId):\(secret)".utf8))
        return FeedbackRouting.feedbackBase64URL(Data(digest))
    }

    // MARK: - Route binding

    /// `ensureProductFeedbackRouteBinding`: reporter id, root commitment and one
    /// `PUT .../reporter-feedback/route-subject`, cached for five minutes.
    func ensureRouteBindingAsync(
        userId: String,
        environment: FeedbackRouteEnvironment
    ) async throws -> String {
        let fallbackReporterId = environment.reporterIdSecret.isEmpty
            ? reporterId(userId: userId)
            : FeedbackRouting.feedbackReporterId(userId: userId, secret: environment.reporterIdSecret)
        guard let config = try FeedbackRouting.feedbackRouteConfig(environment) else { return fallbackReporterId }
        let reporterId = FeedbackRouting.feedbackReporterId(userId: userId, secret: config.reporterIdSecret)
        let rootBytes = FeedbackRouting.feedbackRouteRootBytes(config.root) ?? Data()
        let commitment = Data(SHA256.hash(data: Data(config.commitmentLabel.utf8) + Data([0]) + rootBytes))
        let now = dependencies.now()
        let cacheKey = "\(config.appId)|\(config.credentialRevision)|\(config.commitmentLabel)|\(reporterId)"
        // Commitment check/insert and the cache lookup are ONE store critical
        // section, as they were under the directory lock.
        let cachedBinding: Bool
        switch store.checkRouteBinding(
            commitmentLabel: config.commitmentLabel,
            commitment: commitment,
            cacheKey: cacheKey,
            now: now
        ) {
        case .commitmentMismatch:
            throw FeedbackRouteFailure.routeBinding(reason: "root_commitment_mismatch")
        case .cached:
            cachedBinding = true
        case .miss:
            cachedBinding = false
        }
        if cachedBinding { return reporterId }
        guard let subject = FeedbackRouting.feedbackRouteSubject(config: config, userId: userId, reporterId: reporterId) else {
            throw FeedbackRouteFailure.routeBinding(reason: "route_subject_invalid")
        }
        var request = URLRequest(url: URL(string: "\(config.baseURL)/api/apps/\(config.appId)/reporter-feedback/route-subject")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 4
        request.setValue("Bearer \(config.appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        request.httpBody = Data(OrderedJSON.object([OrderedJSONField("route_subject", subject)]).render().utf8)
        func bindingReason(_ status: Int) -> String {
            status == 0 ? "request_failed" : "hands_status_\(status)"
        }
        var (status, _, body) = await sendAsync(request)
        if status == 0 || (500...599).contains(status) {
            (status, _, body) = await sendAsync(request)
        }
        guard status == 200 || status == 201 else {
            throw FeedbackRouteFailure.routeBinding(reason: bindingReason(status))
        }
        guard let object = Self.decodeObject(body),
              Set(object.keys) == ["changed", "subject_version"],
              let changed = Self.legacyBool(object["changed"]),
              object["subject_version"] == .string("v1"),
              (status == 201) == changed
        else {
            throw FeedbackRouteFailure.routeBinding(reason: "hands_unexpected_body")
        }
        store.recordRouteBindingSuccess(cacheKey: cacheKey, expiresAt: dependencies.now().addingTimeInterval(300))
        return reporterId
    }

    // MARK: - Reporter session / bearer

    func bearerAsync(
        userId: String,
        reporterId: String,
        environment: FeedbackRouteEnvironment
    ) async throws -> String {
        let conversationToken = environment.conversationToken.isEmpty
            ? environment.appToken
            : environment.conversationToken
        guard !environment.baseURL.isEmpty, !conversationToken.isEmpty else {
            throw FeedbackRouteFailure.configuration
        }
        guard environment.conversationSessionEnabled else {
            return conversationToken
        }
        let cacheKey = "\(environment.appId)|\(environment.credentialRevision)|\(userId)"
        let cachedToken = store.cachedReporterSession(
            cacheKey: cacheKey,
            validAfter: dependencies.now().addingTimeInterval(5)
        )
        if let cachedToken { return cachedToken }
        var request = URLRequest(url: URL(string: "\(environment.baseURL)/api/apps/\(environment.appId)/reporter-feedback/session")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(conversationToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        request.httpBody = Data(OrderedJSON.object([
            OrderedJSONField("scopes", .array([.string("feedback:comment"), .string("feedback:read")])),
        ]).render().utf8)
        let (status, _, body) = await sendAsync(request)
        guard status == 200 || status == 201,
              let object = Self.decodeObject(body),
              case .string(let token)? = object["session_token"], !token.isEmpty
        else {
            throw FeedbackRouteFailure.configuration
        }
        let expires = Self.legacyNumber(object["expires_at"])
            ?? dependencies.now().addingTimeInterval(30).timeIntervalSince1970
        store.storeReporterSession(
            cacheKey: cacheKey,
            token: token,
            expiresAt: Date(timeIntervalSince1970: expires)
        )
        return token
    }

    // MARK: - Conversation plumbing

    func handsRequestAsync(
        environment: FeedbackRouteEnvironment,
        method: String,
        path: String,
        bearer: String,
        reporterId: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async -> (status: Int, headers: [String: String], body: Data) {
        var request = URLRequest(url: URL(string: "\(environment.baseURL)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(reporterId, forHTTPHeaderField: "X-Hands-Reporter-Id")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        return await sendAsync(request)
    }

}

// MARK: - Upstream body decoding

extension FeedbackService {
    /// The top-level JSON object of an upstream body; any other shape (or
    /// invalid JSON) is `nil`, as the retired object cast was.
    static func decodeObject(_ body: Data) -> [String: JSONValue]? {
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return nil
        }
        return object
    }

    /// The legacy `as? Bool` bridge accepted a JSON boolean and the numbers
    /// `0`/`1`; every other value was not a boolean.
    static func legacyBool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let flag)?: return flag
        case .integer(let number)?: return number == 0 ? false : (number == 1 ? true : nil)
        case .number(let number)?: return number == 0 ? false : (number == 1 ? true : nil)
        default: return nil
        }
    }

    /// The legacy `as? NSNumber` bridge: numbers and booleans, nothing else.
    static func legacyNumber(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let number)?: return Double(number)
        case .number(let number)?: return number
        case .bool(let flag)?: return flag ? 1 : 0
        default: return nil
        }
    }
}

/// Resumes a continuation at most once: the data task and the timeout watchdog
/// race, and whichever finishes first wins. The loser's asynchronous work is
/// cancelled as soon as the winner resumes.
private final class UpstreamContinuationBox: Sendable {
    private struct State {
        var resumed = false
        var timeoutTask: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let continuation: CheckedContinuation<FeedbackService.UpstreamResponse, Never>

    init(continuation: CheckedContinuation<FeedbackService.UpstreamResponse, Never>) {
        self.continuation = continuation
    }

    func install(timeoutTask: Task<Void, Never>) {
        state.withLock { $0.timeoutTask = timeoutTask }
    }

    /// Returns `true` when this call performed the resume.
    @discardableResult
    func resume(_ result: FeedbackService.UpstreamResponse) -> Bool {
        let outcome: (won: Bool, watchdog: Task<Void, Never>?) = state.withLock { state in
            guard !state.resumed else { return (false, nil) }
            state.resumed = true
            let watchdog = state.timeoutTask
            state.timeoutTask = nil
            return (true, watchdog)
        }
        guard outcome.won else { return false }
        outcome.watchdog?.cancel()
        continuation.resume(returning: result)
        return true
    }
}

/// Keeps the in-flight task reachable from the timeout watchdog.
private final class DataTaskBox: Sendable {
    private let storage = Mutex<URLSessionDataTask?>(nil)

    var task: URLSessionDataTask? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
