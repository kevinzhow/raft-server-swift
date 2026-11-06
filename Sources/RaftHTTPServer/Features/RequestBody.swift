import Foundation
import Vapor

/// The body parser is a route policy: some legacy handlers used the registered
/// content decoder, some always read JSON, and some never tried raw bytes.
enum JSONRequestBodyDecoding {
    case contentThenJSON
    case json
    case contentOnly
}

/// Shared typed decode without changing a route's empty-body or media-type
/// policy. Collection errors propagate for callers that previously threw;
/// `jsonRequestBody` retains the lenient, nonthrowing API used by other routes.
func decodeJSONRequestBody<T: Decodable>(
    _ type: T.Type,
    _ request: Request,
    decoding: JSONRequestBodyDecoding = .contentThenJSON,
    emptyDefault: String? = nil,
    blankDefault: String? = nil,
    rawFallback: String? = nil
) async throws -> T? {
    let decoded: T?
    switch decoding {
    case .json:
        decoded = try? await request.content.decode(type, using: JSONDecoder())
    case .contentThenJSON, .contentOnly:
        decoded = try? await request.content.decode(type)
    }
    if let decoded { return decoded }
    if case .contentOnly = decoding { return nil }

    let data: Data
    if let rawFallback {
        data = Data(rawFallback.utf8)
    } else if emptyDefault != nil || blankDefault != nil {
        var text = try await request.bodyText(default: emptyDefault ?? "")
        if let blankDefault, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = blankDefault
        }
        data = Data(text.utf8)
    } else {
        guard let collected = try await request.body.collect() else { return nil }
        data = collected
    }
    return try? JSONDecoder().decode(type, from: data)
}

/// Raw JSON remains accepted when the client omits a JSON content type. A
/// missing or malformed body returns nil for the service's published refusal.
func jsonRequestBody<T: Decodable>(_ type: T.Type, _ request: Request) async -> T? {
    try? await decodeJSONRequestBody(type, request)
}
