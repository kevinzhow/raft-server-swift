import Foundation

public enum AuthRedirects {
    static func isDesktopLoopback(_ returnUri: String) -> Bool {
        guard let url = URL(string: returnUri),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.path == "/auth/done",
              let port = url.port,
              (1024...65535).contains(port),
              let fragment = url.fragment,
              fragment.wholeMatch(of: /^state=[A-Za-z0-9_-]{16,256}$/) != nil
        else { return false }
        return url.absoluteString == returnUri || "\(url.absoluteString)" == returnUri
    }

    static func desktopNonce(from returnUri: String) -> String? {
        guard AuthRedirects.isDesktopLoopback(returnUri), let fragment = URL(string: returnUri)?.fragment else { return nil }
        return String(fragment.dropFirst("state=".count))
    }

    static func authorizationURL(provider: String, state: String) -> String {
        switch provider {
        case "github":
            var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "configured"),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/api/auth/github/callback"),
                URLQueryItem(name: "scope", value: "read:user user:email"),
                URLQueryItem(name: "state", value: state),
            ]
            return components.string ?? ""
        default:
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "configured"),
                URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/api/auth/google/callback"),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: "openid email profile"),
                URLQueryItem(name: "state", value: state),
            ]
            return components.string ?? ""
        }
    }

    static func failureLocation(returnUri: String, provider: String, mode: String, error: String) -> String {
        let pieces = returnUri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let base = pieces[0]
        let hash = pieces.count > 1 ? "#\(pieces[1])" : ""
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)provider=\(provider)&mode=\(mode)&error=\(error)\(hash)"
    }

    static func loopbackLocation(returnUri: String, provider: String, mode: String, code: String) -> String {
        let pieces = returnUri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let base = pieces[0]
        let hash = pieces.count > 1 ? "#\(pieces[1])" : ""
        let separator = base.contains("?") ? "&" : "?"
        return "\(base)\(separator)provider=\(provider)&mode=\(mode)&code=\(code)\(hash)"
    }

    static func providerLabel(_ id: String) -> String {
        switch id {
        case "google": "Google"
        case "github": "GitHub"
        case "apple": "Apple"
        default: id
        }
    }

    static func sanitizeReturnTo(_ input: String?) -> String {
        guard let input, input.hasPrefix("/"), !input.hasPrefix("//"), !input.contains("\\"), !input.contains("://") else {
            return "/"
        }
        return input
    }

    static func socialCallbackURL(appURL: String, provider: String, mode: String, returnTo: String, error: String? = nil, code: String? = nil) -> String {
        let base = appURL.hasSuffix("/") ? String(appURL.dropLast()) : appURL
        var items = [
            URLQueryItem(name: "auth_callback", value: "social"),
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "mode", value: mode),
            URLQueryItem(name: "returnTo", value: returnTo),
        ]
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        if let error { items.append(URLQueryItem(name: "error", value: error)) }
        var components = URLComponents(string: base) ?? URLComponents()
        components.queryItems = items
        return components.string ?? base
    }

    static func appLoginExpiresAt(_ now: Date = Date()) -> Date {
        now.addingTimeInterval(600)
    }

    static func appLoginRedirect(_ returnUri: String, requestId: String, query: String) -> String {
        let separator = returnUri.contains("?") ? "&" : "?"
        return "\(returnUri)\(separator)requestId=\(requestId)&\(query)"
    }

    static func deviceLoginEnabled(_ raw: String?) -> Bool {
        guard let raw else { return true }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return true }
        return !(value == "0" || value == "false" || value == "no" || value == "off")
    }

    static func parseConfiguredMobileReturnURIs(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        var values: Set<String> = []
        for part in raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "\n" }) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values.insert(trimmed) }
        }
        return values
    }

    static let appLoginReturnUris: Set<String> = [
        "raft://login/callback",
        "raft-debug://login/callback",
    ]

    static let socialProviders: Set<String> = ["google", "github", "apple"]

    static let defaultMobileReturnURIs: Set<String> = [
        "raft://oauth/callback",
        "raft-alpha://oauth/callback",
        "raft-beta://oauth/callback",
        "raft-debug://oauth/callback",
        "raft-dev://oauth/callback",
    ]
}
