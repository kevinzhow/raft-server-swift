import Foundation
import Synchronization
import Testing
import RaftDaemonClient

private final class LogEventCollector: Sendable {
    private let events = Mutex<[DaemonLog.Event]>([])

    func append(_ event: DaemonLog.Event) {
        events.withLock { $0.append(event) }
    }

    func snapshot() -> [DaemonLog.Event] {
        events.withLock { $0 }
    }
}

private final class SubscriberRetirementLease: Sendable {
    private let logger: DaemonLog

    init(logger: DaemonLog) {
        self.logger = logger
    }

    deinit {
        logger.info("subscriber retired")
    }
}

private func subscribeRetiringLease(to logger: DaemonLog) -> Int {
    let lease = SubscriberRetirementLease(logger: logger)
    return logger.subscribe { [lease] _ in
        withExtendedLifetime(lease) {}
    }
}

@Test func unsubscribeCanReleaseASubscriberThatLogsOnDeinit() {
    let logger = DaemonLog()
    let collector = LogEventCollector()
    let collectorToken = logger.subscribe { event in collector.append(event) }
    defer { logger.unsubscribe(collectorToken) }
    let retiringToken = subscribeRetiringLease(to: logger)

    logger.unsubscribe(retiringToken)

    let actual = collector.snapshot()
    #expect(actual.map(\.level) == ["INFO"])
    #expect(actual.map(\.message) == ["subscriber retired"])
    #expect(actual.first?.line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z \[INFO\] subscriber retired$"#, options: .regularExpression) != nil)
}
