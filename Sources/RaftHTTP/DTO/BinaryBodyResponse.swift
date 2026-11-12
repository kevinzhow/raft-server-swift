import Foundation

/// A non-text success body. The HTTP adapter must preserve these bytes and
/// compute Content-Length without passing through JSON or String decoding.
public struct BinaryBodyResponse: Sendable {
    public let bytes: Data
    public let headers: ResponseHeaders

    public init(bytes: Data, headers: ResponseHeaders) {
        self.bytes = bytes
        self.headers = headers
    }
}
