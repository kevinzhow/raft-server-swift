import Foundation
import Vapor

/// Decode one JSON request body with the published fallback behavior.
///
/// A body sent without a JSON `Content-Type` was accepted by the legacy
/// `bodyText` + `JSONSerialization` handlers, so a typed `req.content.decode`
/// fallback alone would turn it into a 415. This helper tries the content-type
/// decoder first and then a plain JSON decode of the collected bytes; a missing
/// or malformed body returns `nil` so the service keeps its legacy 400.
func jsonRequestBody<T: Decodable>(_ type: T.Type, _ request: Request) async -> T? {
    if let decoded = try? await request.content.decode(type) {
        return decoded
    }
    guard let data = try? await request.body.collect() else {
        return nil
    }
    return try? JSONDecoder().decode(type, from: data)
}
