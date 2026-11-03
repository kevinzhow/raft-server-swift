import Foundation
import RaftDaemonClient
import Testing

@Test func feedbackTranscriptWindowMarksANearReportJsonlTranscriptCovered() {
    let transcript = [
        #"{"timestamp":"2026-07-20T16:20:00.000Z","type":"turn"}"#,
        #"{"nested":{"created_at":"2026-07-20T16:39:38.024Z"}}"#,
    ].joined(separator: "\n")
    let result = FeedbackTranscriptWindow.assess(
        transcript: transcript,
        reportGeneratedAt: "2026-07-20T16:40:04.797Z",
        reportTimeSource: "web_report_bundle"
    )
    #expect(result.coverage == "covered")
    #expect(result.transcriptFirstEventAt == "2026-07-20T16:20:00.000Z")
    #expect(result.transcriptLastEventAt == "2026-07-20T16:39:38.024Z")
    #expect(result.reportWindowStartAt == "2026-07-20T16:25:04.797Z")
}

@Test func feedbackTranscriptWindowExposesStaleOrUnavailableEvidenceWithoutReadingContent() {
    let stale = FeedbackTranscriptWindow.assess(
        transcript: #"{"events":[{"timestamp":"2026-07-08T06:00:00.000Z"}]}"#,
        reportGeneratedAt: "2026-07-20T16:40:04.797Z",
        reportTimeSource: "web_report_bundle"
    )
    #expect(stale.coverage == "outside_report_window")

    let unavailable = FeedbackTranscriptWindow.assess(
        transcript: #"{"prompt":"private content with no timestamp"}"#,
        reportGeneratedAt: "2026-07-20T16:40:04.797Z",
        reportTimeSource: "server_request_received"
    )
    #expect(unavailable == FeedbackTranscriptWindowAssessment(
        reportGeneratedAt: "2026-07-20T16:40:04.797Z",
        reportTimeSource: "server_request_received",
        reportWindowStartAt: "2026-07-20T16:25:04.797Z",
        toleranceMs: 900_000,
        coverage: "timestamps_unavailable"
    ))
}
