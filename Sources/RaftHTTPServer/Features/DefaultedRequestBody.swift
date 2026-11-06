import Foundation
import Vapor

/// Decode one JSON request body for a route whose legacy handler read
/// `bodyText(default: …)` and then parsed the text.
///
/// The content-type decoder runs first; otherwise the collected text (the
/// fallback text when the request carried no body at all) is decoded as raw
/// JSON. A body that is not a JSON object returns `nil`, which the service
/// answers with its published 400, exactly as the retired object cast did.
func jsonRequestBody<T: Decodable>(
    _ type: T.Type,
    _ request: Request,
    emptyDefault: String
) async -> T? {
    if let decoded = try? await request.content.decode(type) {
        return decoded
    }
    guard let text = try? await request.bodyText(default: emptyDefault) else {
        return nil
    }
    return try? JSONDecoder().decode(type, from: Data(text.utf8))
}
