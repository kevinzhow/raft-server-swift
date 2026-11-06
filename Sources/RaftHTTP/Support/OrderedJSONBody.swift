import Foundation

/// A response DTO that owns the exact published JSON bytes.
///
/// Linux Foundation's `JSONEncoder` keeps keyed containers in a hash map, so
/// encoding the same multi-key object twice can emit different key order. A
/// domain whose upstream body has a fixed, non-alphabetical order implements
/// this protocol with the legacy order and the feature layer's `respond`
/// overload writes `jsonBody()` directly instead of running the encoder.
///
/// The DTO is still `Codable` for tests and clients; this is only the wire
/// projection.
public protocol OrderedJSONBody {
    func jsonBody() -> String
}

/// A `DomainError` whose error object also has a fixed key order.
///
/// The shared `domainErrorResponse` encoder is shared by domains that do not
/// care about order. A domain that does (legacy `{"error": …,"code": …}`)
/// conforms here and implements `errorJSONBody()`; the feature layer has one
/// extra `respond` overload that uses it.
public protocol OrderedJSONError: DomainError {
    func errorJSONBody() -> String
}
