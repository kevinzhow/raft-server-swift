import Foundation
import Synchronization

/// How much memory this daemon process holds, sampled on a timer: process
/// counters only, never heap contents. Samples go to a local file the Computer
/// reads for doctor, and at most every 30 minutes to the
/// `daemon.process.memory` event. Ported from the upstream daemon reporter;
/// Swift has no V8 heap spaces, so the space map is derived from the process
/// heap figures (documented substitution).
public struct ProcessMemorySample: Sendable, Equatable {
    public var sampledAt: String
    public var pid: Int
    public var uptimeMs: Int
    public var rssBytes: Int
    public var heapUsedBytes: Int
    public var heapTotalBytes: Int
    public var externalBytes: Int
    public var arrayBuffersBytes: Int
    public var swapBytes: Int?
    public var heapSpaceUsedBytes: [String: Int]
    public var lazySchemasRegistered: Int
    public var lazySchemasBuilt: Int
    public init(
        sampledAt: String, pid: Int, uptimeMs: Int, rssBytes: Int, heapUsedBytes: Int,
        heapTotalBytes: Int, externalBytes: Int, arrayBuffersBytes: Int, swapBytes: Int? = nil,
        heapSpaceUsedBytes: [String: Int] = [:], lazySchemasRegistered: Int = 0, lazySchemasBuilt: Int = 0
    ) {
        self.sampledAt = sampledAt
        self.pid = pid
        self.uptimeMs = uptimeMs
        self.rssBytes = rssBytes
        self.heapUsedBytes = heapUsedBytes
        self.heapTotalBytes = heapTotalBytes
        self.externalBytes = externalBytes
        self.arrayBuffersBytes = arrayBuffersBytes
        self.swapBytes = swapBytes
        self.heapSpaceUsedBytes = heapSpaceUsedBytes
        self.lazySchemasRegistered = lazySchemasRegistered
        self.lazySchemasBuilt = lazySchemasBuilt
    }
}

public protocol ProcessMemoryClock: Sendable {
    var nowMs: Int { get }
    func schedule(afterMs: Int, _ body: @escaping @Sendable () -> Void) -> Int
    func cancel(_ id: Int)
}

public enum ProcessMemory {
    public static let sampleMs = 5 * 60_000
    public static let traceEveryMs = 30 * 60_000
    public static let firstSampleMs = 60_000
    static let serviceSampleMaxAgeMs = 15 * 60_000

    public static let traceAttrs = [
        "process_instance_id", "agents_running", "agents_in_process", "uptime_ms", "rss_mb",
        "heap_used_mb", "heap_total_mb", "external_mb", "array_buffers_mb", "old_space_mb",
        "code_space_mb", "large_object_space_mb", "lazy_schemas_built", "lazy_schemas_registered",
        "service_rss_mb", "service_heap_used_mb", "swap_mb", "service_swap_mb",
    ]

    static func mb(_ bytes: Int?) -> Int {
        Int((Double(bytes ?? 0) / (1024 * 1024)).rounded())
    }

    /// Linux only: this process's swapped-out bytes (VmSwap). RSS alone hides them.
    public static func readSwapBytes(statusText: String? = nil) -> Int? {
        let text: String
        if let statusText {
            text = statusText
        } else {
            text = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
        }
        let pattern = #"(?m)^VmSwap:\s+(\d+)\s+kB$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text),
              let kilobytes = Int(text[valueRange])
        else { return nil }
        return kilobytes * 1024
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func sample(nowMs: Int) -> ProcessMemorySample {
        let rss = residentBytes() ?? 0
        let heapUsed = rss
        let heapTotal = rss
        return ProcessMemorySample(
            sampledAt: isoString(Date(timeIntervalSince1970: Double(nowMs) / 1000)),
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            uptimeMs: Int((ProcessInfo.processInfo.systemUptime * 1000).rounded()),
            rssBytes: rss, heapUsedBytes: heapUsed, heapTotalBytes: heapTotal,
            externalBytes: 0, arrayBuffersBytes: 0, swapBytes: readSwapBytes(),
            heapSpaceUsedBytes: ["old_space": heapUsed],
            lazySchemasRegistered: 0, lazySchemasBuilt: 0
        )
    }

    static func residentBytes() -> Int? {
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let pages = Int(text.split(separator: " ").first.map(String.init) ?? "")
        else { return nil }
        return pages * 4096
    }

    public static func traceAttributes(_ sample: ProcessMemorySample) -> [String: Int] {
        var attrs: [String: Int] = [
            "uptime_ms": sample.uptimeMs,
            "rss_mb": mb(sample.rssBytes),
            "heap_used_mb": mb(sample.heapUsedBytes),
            "heap_total_mb": mb(sample.heapTotalBytes),
            "external_mb": mb(sample.externalBytes),
            "array_buffers_mb": mb(sample.arrayBuffersBytes),
            "old_space_mb": mb(sample.heapSpaceUsedBytes["old_space"]),
            "code_space_mb": mb(sample.heapSpaceUsedBytes["code_space"]),
            "large_object_space_mb": mb(sample.heapSpaceUsedBytes["large_object_space"]),
            "lazy_schemas_built": sample.lazySchemasBuilt,
            "lazy_schemas_registered": sample.lazySchemasRegistered,
        ]
        if let swap = sample.swapBytes { attrs["swap_mb"] = mb(swap) }
        return attrs
    }

    /// The Computer service's sample as event attrs, or none if missing/stale.
    public static func serviceAttributes(samplePath: String?, nowMs: Int) -> [String: Int] {
        guard let samplePath, let data = FileManager.default.contents(atPath: samplePath),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sampledAt = object["sampledAt"] as? String
        else { return [:] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: sampledAt) ?? ISO8601DateFormatter().date(from: sampledAt) else { return [:] }
        let age = nowMs - Int(date.timeIntervalSince1970 * 1000)
        guard age >= 0, age <= serviceSampleMaxAgeMs else { return [:] }
        guard let rss = object["rssBytes"] as? NSNumber, let heap = object["heapUsedBytes"] as? NSNumber else {
            return [:]
        }
        var attrs: [String: Int] = [
            "service_rss_mb": mb(rss.intValue), "service_heap_used_mb": mb(heap.intValue),
        ]
        if let swap = object["swapBytes"] as? NSNumber { attrs["service_swap_mb"] = mb(swap.intValue) }
        return attrs
    }

    /// Write-then-rename so a reader never sees a half-written file.
    public static func writeSample(path: String, sample: ProcessMemorySample) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var object: [String: Any] = [
            "sampledAt": sample.sampledAt, "pid": sample.pid, "uptimeMs": sample.uptimeMs,
            "rssBytes": sample.rssBytes, "heapUsedBytes": sample.heapUsedBytes,
            "heapTotalBytes": sample.heapTotalBytes, "externalBytes": sample.externalBytes,
            "arrayBuffersBytes": sample.arrayBuffersBytes,
            "heapSpaceUsedBytes": sample.heapSpaceUsedBytes,
            "lazySchemas": ["registered": sample.lazySchemasRegistered, "built": sample.lazySchemasBuilt],
        ]
        if let swap = sample.swapBytes { object["swapBytes"] = swap }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try (String(decoding: data, as: UTF8.self) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    public final class Reporter: Sendable {
        private final class ScheduleIdentity: Sendable {}
        private struct TimerSlot: Sendable {
            let identity: ScheduleIdentity
            var id: Int?
        }
        private struct State: Sendable {
            var stopped = false
            var slot: TimerSlot?
            var lastTraceAt: Int?
        }
        private let state = Mutex(State())

        private let clock: ProcessMemoryClock
        private let sample: @Sendable (Int) -> ProcessMemorySample
        private let trace: @Sendable ([String: Int]) -> Void
        private let context: @Sendable () -> [String: Int]
        private let samplePath: String?
        private let onWriteError: (@Sendable (Error) -> Void)?
        private let sampleMs: Int
        private let traceEveryMs: Int

        fileprivate init(
            clock: ProcessMemoryClock,
            sample: @escaping @Sendable (Int) -> ProcessMemorySample,
            trace: @escaping @Sendable ([String: Int]) -> Void,
            context: @escaping @Sendable () -> [String: Int],
            samplePath: String?,
            onWriteError: (@Sendable (Error) -> Void)?,
            sampleMs: Int,
            traceEveryMs: Int,
            firstSampleMs: Int
        ) {
            self.clock = clock
            self.sample = sample
            self.trace = trace
            self.context = context
            self.samplePath = samplePath
            self.onWriteError = onWriteError
            self.sampleMs = sampleMs
            self.traceEveryMs = traceEveryMs
            arm(afterMs: firstSampleMs)
        }

        public func stop() {
            let id = state.withLock { state in
                state.stopped = true
                let id = state.slot?.id
                state.slot = nil
                return id
            }
            if let id { clock.cancel(id) }
        }

        private func tick() {
            let admitted = state.withLock { state in
                state.slot = nil
                return !state.stopped
            }
            guard admitted else { return }
            let now = clock.nowMs
            let current = sample(now)
            let shouldTrace = state.withLock { state in
                let shouldTrace = state.lastTraceAt == nil || now - state.lastTraceAt! >= traceEveryMs
                if shouldTrace { state.lastTraceAt = now }
                return shouldTrace
            }

            if let samplePath {
                do { try ProcessMemory.writeSample(path: samplePath, sample: current) } catch { onWriteError?(error) }
            }
            if shouldTrace {
                var attrs = context()
                for (key, value) in ProcessMemory.traceAttributes(current) { attrs[key] = value }
                trace(attrs)
            }
            arm(afterMs: sampleMs)
        }

        private func arm(afterMs: Int) {
            let identity = ScheduleIdentity()
            let reserved = state.withLock { state in
                guard !state.stopped else { return false }
                state.slot = TimerSlot(identity: identity)
                return true
            }
            guard reserved else { return }
            let id = clock.schedule(afterMs: afterMs) { [weak self] in self?.tick() }
            let published = state.withLock { state in
                guard !state.stopped, state.slot?.identity === identity else { return false }
                state.slot?.id = id
                return true
            }
            if !published { clock.cancel(id) }
        }
    }

    public static func startReporter(
        clock: ProcessMemoryClock,
        trace: @escaping @Sendable ([String: Int]) -> Void,
        context: @escaping @Sendable () -> [String: Int] = { [:] },
        samplePath: String? = nil,
        sample: @escaping @Sendable (Int) -> ProcessMemorySample = { ProcessMemory.sample(nowMs: $0) },
        sampleMs: Int = ProcessMemory.sampleMs,
        traceEveryMs: Int = ProcessMemory.traceEveryMs,
        firstSampleMs: Int = ProcessMemory.firstSampleMs,
        onWriteError: (@Sendable (Error) -> Void)? = nil
    ) -> Reporter {
        Reporter(
            clock: clock, sample: sample, trace: trace, context: context,
            samplePath: samplePath, onWriteError: onWriteError,
            sampleMs: sampleMs, traceEveryMs: traceEveryMs, firstSampleMs: firstSampleMs
        )
    }
}
