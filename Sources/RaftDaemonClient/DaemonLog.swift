import Foundation
import Synchronization

/// Structured daemon log stream: subscribers observe `{level, line, message}`,
/// and unsubscribing stops delivery. Ported from the upstream daemon logger.
public final class DaemonLog: Sendable {
    public struct Event: Sendable, Equatable {
        public var level: String
        public var line: String
        public var message: String
    }

    public static let shared = DaemonLog()

    private struct State: Sendable {
        var subscribers: [Int: @Sendable (Event) -> Void] = [:]
        var nextToken = 0
    }
    private let state = Mutex(State())
    private let formatter: DateFormatter

    public init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        self.formatter = formatter
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (Event) -> Void) -> Int {
        return state.withLock { state in
            state.nextToken += 1
            let token = state.nextToken
            state.subscribers[token] = handler
            return token
        }
    }

    public func unsubscribe(_ token: Int) {
        let retired = state.withLock { $0.subscribers.removeValue(forKey: token) }
        withExtendedLifetime(retired) {}
    }

    public func log(level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        let handlers = state.withLock { Array($0.subscribers.values) }
        let event = Event(level: level, line: line, message: message)
        for handler in handlers { handler(event) }
    }

    public func info(_ message: String) { log(level: "INFO", message) }
    public func warn(_ message: String) { log(level: "WARN", message) }
    public func error(_ message: String) { log(level: "ERROR", message) }
}
