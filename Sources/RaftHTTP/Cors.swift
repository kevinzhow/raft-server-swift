import Foundation

/// CORS preflight from `app.ts` and `config/appUrl.ts` at raft-source
/// v1.21.23-source.1. The `cors` middleware answers OPTIONS before the
/// robots-tag middleware, so this response does not carry `X-Robots-Tag`.

public enum WebCORS {
    public static let defaultAppURL = "http://localhost:5173"

    /// `getAppUrl()`: `APP_URL` when it is an http(s) URL, otherwise the dev origin.
    public static func appURL(environment: [String: String]) -> String {
        normalizeAppURL(environment["APP_URL"]) ?? defaultAppURL
    }
    public static let preflightMaxAgeSeconds = 7200

    public static func origins(corsOrigin: String?, appURL: String?) -> [String] {
        var origins = parseOriginList(corsOrigin)
        if origins.contains("*") { return ["*"] }
        if let appURL = normalizeAppURL(appURL) {
            origins.append(appURL)
        }
        if origins.isEmpty {
            origins.append(defaultAppURL)
        }
        var seen: [String] = []
        for origin in origins where !seen.contains(origin) {
            seen.append(origin)
        }
        return seen
    }

    /// 204 when this is a preflight for an allowed origin. Otherwise nil and
    /// the request continues to the route or the JSON 404.
    public static func preflight(
        method: String,
        origin: String?,
        requestMethod: String?,
        allowed: [String]
    ) -> HTTPReply? {
        guard method.uppercased() == "OPTIONS",
              let requestMethod, !requestMethod.isEmpty,
              let origin, !origin.isEmpty
        else { return nil }
        let allowedOrigin = (allowed.contains("*") || allowed.contains(origin)) ? origin : nil
        guard let allowedOrigin else { return nil }
        return HTTPReply(
            status: 204,
            headers: [
                "Access-Control-Allow-Origin": allowedOrigin,
                "Access-Control-Allow-Credentials": "true",
                "Access-Control-Max-Age": String(preflightMaxAgeSeconds),
                "Content-Length": "0",
            ],
            body: ""
        )
    }
}

private func parseOriginList(_ raw: String?) -> [String] {
    (raw ?? "").split(separator: ",", omittingEmptySubsequences: false).compactMap { piece in
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func normalizeAppURL(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let components = URLComponents(string: trimmed),
          let scheme = components.scheme, scheme == "http" || scheme == "https",
          let host = components.host
    else { return nil }
    if let port = components.port {
        return "\(scheme)://\(host):\(port)"
    }
    return "\(scheme)://\(host)"
}
