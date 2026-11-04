import Foundation

/// Removes the tracing envelope (`_trace`, at any depth) from a socket payload
/// before it is persisted or forwarded, without changing the payload's
/// semantics: objects keep their other keys, arrays keep their items and order,
/// and scalars pass through unchanged. Ported from the upstream socket entry
/// point.
public func stripSocketTraceMetadata(_ payload: Any) -> Any {
    if let object = payload as? [String: Any] {
        var stripped: [String: Any] = [:]
        for (key, value) in object where key != "_trace" {
            stripped[key] = stripSocketTraceMetadata(value)
        }
        return stripped
    }
    if let object = payload as? [Any] {
        return object.map(stripSocketTraceMetadata)
    }
    return payload
}
