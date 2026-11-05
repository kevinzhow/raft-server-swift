import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asynchronous transport for the upstream Hands product-feedback API.
///
/// The feedback handlers run on Vapor's concurrency pool. `URLSession` is
/// bridged with `withCheckedContinuation` so a request never parks a worker
/// thread on a semaphore; the 12 s ceiling is enforced by the request timeout
/// and a watchdog task that resumes the continuation exactly once.
public struct FeedbackService: Sendable {
    public typealias UpstreamResponse = (status: Int, headers: [String: String], body: Data)
    public typealias InjectedTransport = (URLRequest) -> UpstreamResponse

    /// Mirrors the old `semaphore.wait(timeout: .now() + 12)` ceiling.
    public static let requestTimeout: TimeInterval = 12

    public init() {}

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
}

/// Resumes a continuation at most once: the data task and the timeout watchdog
/// race, and whichever finishes first wins. The loser's asynchronous work is
/// cancelled as soon as the winner resumes.
private final class UpstreamContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var timeoutTask: Task<Void, Never>?
    private let continuation: CheckedContinuation<FeedbackService.UpstreamResponse, Never>

    init(continuation: CheckedContinuation<FeedbackService.UpstreamResponse, Never>) {
        self.continuation = continuation
    }

    func install(timeoutTask: Task<Void, Never>) {
        lock.lock()
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    /// Returns `true` when this call performed the resume.
    @discardableResult
    func resume(_ result: FeedbackService.UpstreamResponse) -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        resumed = true
        let watchdog = timeoutTask
        timeoutTask = nil
        lock.unlock()
        watchdog?.cancel()
        continuation.resume(returning: result)
        return true
    }
}

/// Keeps the in-flight task reachable from the timeout watchdog without
/// crossing an actor boundary with a mutable reference.
private final class DataTaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
}
