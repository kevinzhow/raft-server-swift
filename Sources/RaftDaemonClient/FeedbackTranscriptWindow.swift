import Foundation

/// Where a feedback report's transcript window falls relative to the report
/// time. Reports are commonly submitted minutes after the failing turn, so a
/// bounded grace period proves the transcript reaches the report window without
/// pretending the last row equals the submit instant. The scanner extracts only
/// timestamps and never exports transcript content. Ported from upstream.
public struct FeedbackTranscriptWindowAssessment: Equatable, Sendable {
    public var reportGeneratedAt: String
    public var reportTimeSource: String
    public var reportWindowStartAt: String
    public var toleranceMs: Int
    public var coverage: String
    public var transcriptFirstEventAt: String?
    public var transcriptLastEventAt: String?

    public init(
        reportGeneratedAt: String,
        reportTimeSource: String,
        reportWindowStartAt: String,
        toleranceMs: Int,
        coverage: String,
        transcriptFirstEventAt: String? = nil,
        transcriptLastEventAt: String? = nil
    ) {
        self.reportGeneratedAt = reportGeneratedAt
        self.reportTimeSource = reportTimeSource
        self.reportWindowStartAt = reportWindowStartAt
        self.toleranceMs = toleranceMs
        self.coverage = coverage
        self.transcriptFirstEventAt = transcriptFirstEventAt
        self.transcriptLastEventAt = transcriptLastEventAt
    }
}

public enum FeedbackTranscriptWindow {
    public static let defaultToleranceMs = 15 * 60 * 1000

    private static let timestampKeys: Set<String> = [
        "timestamp", "createdAt", "created_at", "updatedAt", "updated_at",
        "startedAt", "started_at", "endedAt", "ended_at",
    ]
    private static let maxScanDepth = 12
    private static let maxScannedNodes = 100_000

    public static func assess(
        transcript: String,
        reportGeneratedAt: String,
        reportTimeSource: String,
        toleranceMs: Int? = nil
    ) -> FeedbackTranscriptWindowAssessment {
        let tolerance = toleranceMs ?? defaultToleranceMs
        guard let reportMs = parseTimestamp(reportGeneratedAt) else {
            return FeedbackTranscriptWindowAssessment(
                reportGeneratedAt: reportGeneratedAt,
                reportTimeSource: reportTimeSource,
                reportWindowStartAt: reportGeneratedAt,
                toleranceMs: tolerance,
                coverage: "report_time_invalid"
            )
        }
        var timestamps = extractTranscriptTimestamps(transcript)
        let windowStartMs = reportMs - Double(tolerance)
        let base = FeedbackTranscriptWindowAssessment(
            reportGeneratedAt: formatIso(reportMs),
            reportTimeSource: reportTimeSource,
            reportWindowStartAt: formatIso(windowStartMs),
            toleranceMs: tolerance,
            coverage: ""
        )
        guard !timestamps.isEmpty else {
            var result = base
            result.coverage = "timestamps_unavailable"
            return result
        }
        let firstMs = timestamps.min()!
        let lastMs = timestamps.max()!
        var result = base
        result.coverage = lastMs >= windowStartMs ? "covered" : "outside_report_window"
        result.transcriptFirstEventAt = formatIso(firstMs)
        result.transcriptLastEventAt = formatIso(lastMs)
        return result
    }

    static func extractTranscriptTimestamps(_ transcript: String) -> [Double] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var timestamps: [Double] = []
        var visited = 0
        if let data = trimmed.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            collectTimestamps(object, into: &timestamps, visited: &visited, depth: 0)
            return timestamps
        }
        // Most runtime transcripts are JSONL: parse each record independently so
        // one malformed line cannot suppress timestamps from good rows.
        for line in transcript.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            if visited >= maxScannedNodes { break }
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty,
                  let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            collectTimestamps(object, into: &timestamps, visited: &visited, depth: 0)
        }
        return timestamps
    }

    private static func collectTimestamps(
        _ value: Any,
        into timestamps: inout [Double],
        visited: inout Int,
        depth: Int
    ) {
        if depth > maxScanDepth || visited >= maxScannedNodes { return }
        visited += 1
        if let array = value as? [Any] {
            for item in array { collectTimestamps(item, into: &timestamps, visited: &visited, depth: depth + 1) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        for (key, child) in object {
            if timestampKeys.contains(key), let parsed = parseTimestamp(child) {
                timestamps.append(parsed)
            }
            collectTimestamps(child, into: &timestamps, visited: &visited, depth: depth + 1)
        }
    }

    static func parseTimestamp(_ value: Any?) -> Double? {
        guard let string = value as? String,
              string.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: string)
        formatter.formatOptions = [.withInternetDateTime]
        date = date ?? formatter.date(from: string)
        guard let date else { return nil }
        return date.timeIntervalSince1970 * 1000
    }

    static func formatIso(_ milliseconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        // Milliseconds precision, matching the Node report format.
        let raw = formatter.string(from: date)
        if let dot = raw.firstIndex(of: ".") {
            let head = raw[..<dot]
            let fractionStart = raw.index(after: dot)
            let fraction = raw[fractionStart...].prefix(3)
            return "\(head).\(fraction)Z"
        }
        return raw
    }
}
