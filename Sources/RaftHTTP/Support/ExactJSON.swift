import Foundation

/// A response DTO whose published JSON bytes are part of the contract.
///
/// `JSONEncoder` writes a keyed container through a dictionary, so on Linux the
/// member order of two equivalent values can differ between calls. Domains whose
/// upstream body has a fixed member order (the join-link, invite, setup and
/// agent-profile projections) build the exact bytes here and let
/// `Respond.swift` project them unchanged.
public protocol ExactJSONResponse: Encodable {
    /// Exact JSON body in the upstream member order.
    func jsonBody() -> String
}

/// A typed domain failure whose published body is fixed byte-for-byte.
///
/// The feature layer's `respond` overload renders `exactBodyJSON` with the
/// published status and headers instead of re-encoding a `Codable` shape.
public protocol ExactBodyDomainError: Error, Sendable {
    /// Status the published error answers with.
    var status: UInt { get }
    /// Exact JSON body in the upstream member order.
    var exactBodyJSON: String { get }
    /// Extra response headers; the default JSON header set needs none.
    var responseHeaders: [String: String] { get }
}

public extension ExactBodyDomainError {
    var responseHeaders: [String: String] { [:] }
}
