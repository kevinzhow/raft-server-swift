import Foundation
import RaftShared

// MARK: - Byte-exact bodies
//
// The legacy feedback-locator replies publish a fixed key order that is not
// alphabetical (`status, receipt_id, report_id, duplicate` and
// `error, code, requiredCapability`). Linux `JSONEncoder` writes keyed
// containers in hash order, so a synthesized `Codable` body would reorder keys
// between runs. Each body is a `JSONBodyConvertible` tree, and
// `Sources/RaftHTTPServer/Features/Respond.swift` has one overload for it.

// MARK: - Request

/// `POST /internal/agent-api/feedback-locators` request body.
///
/// The three envelope members stay `JSONValue` because the legacy handler
/// validated their runtime shape itself: a non-string `artifact_kind` answered
/// `unknown_artifact_kind`, not a decode failure. Keeping the decoded value
/// untyped preserves every published `reason_code`.
public struct FeedbackLocatorIngestRequest: Codable, Sendable, Equatable {
    public var artifactKind: JSONValue?
    public var eventKind: JSONValue?
    public var payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case artifactKind = "artifact_kind"
        case eventKind = "event_kind"
        case payload
    }

    public init(
        artifactKind: JSONValue? = nil,
        eventKind: JSONValue? = nil,
        payload: JSONValue? = nil
    ) {
        self.artifactKind = artifactKind
        self.eventKind = eventKind
        self.payload = payload
    }
}

// MARK: - Responses

/// `200` body of `POST /internal/agent-api/feedback-locators`.
///
/// Published order: `status`, `receipt_id`, `report_id`, `duplicate`.
public struct FeedbackLocatorAcceptedResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var status: String
    public var receiptId: String
    public var reportId: String
    public var duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case receiptId = "receipt_id"
        case reportId = "report_id"
        case duplicate
    }

    public init(receiptId: String, reportId: String, duplicate: Bool) {
        self.status = "accepted"
        self.receiptId = receiptId
        self.reportId = reportId
        self.duplicate = duplicate
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("status", status)
        body.append("receipt_id", receiptId)
        body.append("report_id", reportId)
        body.append("duplicate", duplicate)
        return body.json
    }
}

/// One stored locator row in `GET /internal/agent-api/feedback-locators`.
///
/// Published order matches the legacy serializer exactly, including the two
/// nullable route fields and the served-exact array.
public struct FeedbackLocatorRow: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var reportId: String
    public var receiptId: String
    public var capturedAt: String
    public var runtime: String
    public var nativeStatus: String
    public var nativeLookupMethod: String
    public var nativeLocatorKind: String
    public var hasServedExact: Bool
    public var servedExactSha256: [String]
    public var routeBasis: String?
    public var routeTarget: String?

    enum CodingKeys: String, CodingKey {
        case reportId = "report_id"
        case receiptId = "receipt_id"
        case capturedAt = "captured_at"
        case runtime
        case nativeStatus = "native_status"
        case nativeLookupMethod = "native_lookup_method"
        case nativeLocatorKind = "native_locator_kind"
        case hasServedExact = "has_served_exact"
        case servedExactSha256 = "served_exact_sha256"
        case routeBasis = "route_basis"
        case routeTarget = "route_target"
    }

    public init(
        reportId: String,
        receiptId: String,
        capturedAt: String,
        runtime: String,
        nativeStatus: String,
        nativeLookupMethod: String,
        nativeLocatorKind: String,
        hasServedExact: Bool,
        servedExactSha256: [String],
        routeBasis: String?,
        routeTarget: String?
    ) {
        self.reportId = reportId
        self.receiptId = receiptId
        self.capturedAt = capturedAt
        self.runtime = runtime
        self.nativeStatus = nativeStatus
        self.nativeLookupMethod = nativeLookupMethod
        self.nativeLocatorKind = nativeLocatorKind
        self.hasServedExact = hasServedExact
        self.servedExactSha256 = servedExactSha256
        self.routeBasis = routeBasis
        self.routeTarget = routeTarget
    }

    public var jsonBody: OrderedJSON {
        var body = OrderedJSONObject()
        body.append("report_id", reportId)
        body.append("receipt_id", receiptId)
        body.append("captured_at", capturedAt)
        body.append("runtime", runtime)
        body.append("native_status", nativeStatus)
        body.append("native_lookup_method", nativeLookupMethod)
        body.append("native_locator_kind", nativeLocatorKind)
        body.append("has_served_exact", hasServedExact)
        body.append("served_exact_sha256", .array(servedExactSha256.map(OrderedJSON.string)))
        body.append("route_basis", optional: routeBasis)
        body.append("route_target", optional: routeTarget)
        return body.json
    }
}

/// `200` body of `GET /internal/agent-api/feedback-locators`.
public struct FeedbackLocatorListResponse: Codable, Sendable, Equatable, JSONBodyConvertible {
    public var locators: [FeedbackLocatorRow]

    public init(locators: [FeedbackLocatorRow]) {
        self.locators = locators
    }

    public var jsonBody: OrderedJSON {
        .object([OrderedJSONField("locators", .array(locators.map(\.jsonBody)))])
    }
}
