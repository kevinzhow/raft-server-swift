import Foundation
import RaftShared

// MARK: - Product-feedback submission DTOs
//
// Wire shapes for `POST /api/product-feedback` and
// `POST /api/product-events/onboarding-wizard`. The feature decodes request
// shapes, the service returns these values, and `Respond.swift` owns the HTTP
// projection.

/// The multipart input `POST /api/product-feedback` accepts.
///
/// The published contract is a multipart form, not JSON, so the route passes
/// the raw body and its `Content-Type` through; the service owns the field
/// validation. Keeping the inputs in one value avoids a long positional call.
public struct ProductFeedbackSubmissionRequest: Sendable, Equatable {
    public var authorization: String?
    public var contentType: String
    public var body: String
    public var serverId: String
    public var clientKindHeader: String

    public init(
        authorization: String? = nil,
        contentType: String,
        body: String,
        serverId: String = "",
        clientKindHeader: String = ""
    ) {
        self.authorization = authorization
        self.contentType = contentType
        self.body = body
        self.serverId = serverId
        self.clientKindHeader = clientKindHeader
    }
}

/// `201` body of `POST /api/product-feedback`: the Hands receipt reduced to the
/// two published fields.
///
/// `serverTiming` is transport metadata for the `Server-Timing` response
/// header; `CodingKeys` keeps it out of the body, so the published bytes are
/// only `id` and `status` (alphabetical, which is why the feature projection
/// can sort keys and stay byte-stable).
public struct ProductFeedbackReceipt: Codable, Sendable, Equatable {
    public var id: String
    public var status: String
    public var serverTiming: String = ""

    public init(id: String, status: String, serverTiming: String = "") {
        self.id = id
        self.status = status
        self.serverTiming = serverTiming
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
    }
}

/// Server attribution attached to the Hands metadata when the caller is a
/// member of the claimed server and the server has a slug.
public struct ProductFeedbackReporterAttribution: Sendable, Equatable {
    public var serverSlug: String
    public var handle: String

    public init(serverSlug: String, handle: String) {
        self.serverSlug = serverSlug
        self.handle = handle
    }
}

/// `POST /api/product-events/onboarding-wizard` request body.
///
/// Decoding mirrors the retired raw parser: a field of the wrong JSON type is
/// dropped instead of rejecting the body (`eventType` missing or non-string is
/// still the published 400; a non-string `idempotencyKey` is ignored). A
/// `metadata` that is not a JSON object fails the decode, which the route turns
/// into the same published invalid-product-event 400.
public struct ProductEventOnboardingWizardRequest: Codable, Sendable, Equatable {
    public var eventType: String?
    public var idempotencyKey: String?
    public var metadata: [String: JSONValue]?

    public init(
        eventType: String? = nil,
        idempotencyKey: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.eventType = eventType
        self.idempotencyKey = idempotencyKey
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try? container.decodeIfPresent(String.self, forKey: .eventType)
        idempotencyKey = try? container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        metadata = try? container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case eventType
        case idempotencyKey
        case metadata
    }
}

/// One canonical encoder for the multipart `metadata` field and the recorded
/// onboarding metadata.
///
/// The legacy code serialized both with the sorted-key serializer;
/// `JSONEncoder` with `.sortedKeys` produces the same bytes, including the
/// default slash escaping the legacy writer used.
public enum ProductFeedbackMetadataJSON {
    public static func string(_ metadata: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(metadata) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// The string value for `key`, matching the retired `as? String` reads: a
    /// non-string JSON value (including `null`) reads as absent.
    func productFeedbackString(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}
