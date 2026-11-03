import Foundation

/// Structured daemon log stream: subscribers observe `{level, line, message}`,
/// and unsubscribing stops delivery. Ported from the upstream daemon logger.
public final class DaemonLog: @unchecked Sendable {
    public struct Event: Sendable, Equatable {
        public var level: String
        public var line: String
        public var message: String
    }

    public static let shared = DaemonLog()

    private let lock = NSLock()
    private var subscribers: [Int: (Event) -> Void] = [:]
    private var nextToken = 0
    private let formatter: DateFormatter

    public init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        self.formatter = formatter
    }

    @discardableResult
    public func subscribe(_ handler: @escaping (Event) -> Void) -> Int {
        lock.lock()
        nextToken += 1
        let token = nextToken
        subscribers[token] = handler
        lock.unlock()
        return token
    }

    public func unsubscribe(_ token: Int) {
        lock.lock()
        subscribers[token] = nil
        lock.unlock()
    }

    public func log(level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        lock.lock()
        let handlers = Array(subscribers.values)
        lock.unlock()
        let event = Event(level: level, line: line, message: message)
        for handler in handlers { handler(event) }
    }

    public func info(_ message: String) { log(level: "INFO", message) }
    public func warn(_ message: String) { log(level: "WARN", message) }
    public func error(_ message: String) { log(level: "ERROR", message) }
}
