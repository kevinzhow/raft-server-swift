import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public mobile download redirects from `routes/mobileDownload.ts`.
///
/// `GET /api/mobile-download` is unauthenticated. Android follows the Hands
/// `latest` APK. iOS goes to TestFlight, never an `.ipa`. A User-Agent that
/// is not Android or a legacy iPhone, iPod, or iPad goes to the web `/download`
/// chooser, including a modern iPad whose Safari string matches macOS.

public struct MobileFeedHTTP: Equatable, Sendable {
    public var status: Int
    public var body: String

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

public struct MobileDownloadDeps: Sendable {
    public var fetch: @Sendable (String) async throws -> MobileFeedHTTP
    public var handsBase: String
    public var channel: String
    public var appURL: String
    public var testFlightURL: String

    public init(
        fetch: @escaping @Sendable (String) async throws -> MobileFeedHTTP,
        handsBase: String = MobileDownload.defaultHandsBase,
        channel: String = "main",
        appURL: String = WebCORS.defaultAppURL,
        testFlightURL: String = MobileDownload.defaultTestFlightURL
    ) {
        self.fetch = fetch
        self.handsBase = handsBase
        self.channel = channel
        self.appURL = appURL
        self.testFlightURL = testFlightURL
    }

    public static func live(environment: [String: String]) -> MobileDownloadDeps {
        func configured(_ key: String, fallback: String) -> String {
            let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? fallback : raw
        }
        return MobileDownloadDeps(
            fetch: MobileDownload.urlSessionFetch,
            handsBase: configured("HANDS_PUBLIC_BASE_URL", fallback: MobileDownload.defaultHandsBase),
            channel: configured("HANDS_RELEASE_CHANNEL", fallback: "main"),
            appURL: WebCORS.appURL(environment: environment),
            testFlightURL: configured("RAFT_IOS_TESTFLIGHT_URL", fallback: MobileDownload.defaultTestFlightURL)
        )
    }
}

public enum MobileDownload {
    public static let defaultHandsBase = "https://hands.build"
    public static let defaultTestFlightURL = "https://testflight.apple.com/join/JvM5wXuc"

    public static func reply(platform rawPlatform: String?, userAgent: String?, deps: MobileDownloadDeps) async -> HTTPReply {
        let platform = mobilePlatform(rawPlatform) ?? platformFromUserAgent(userAgent)
        guard let platform else {
            return redirect(chooserURL(deps.appURL), cacheControl: "private, max-age=300")
        }
        if platform == "ios" {
            return redirect(deps.testFlightURL, cacheControl: "private, max-age=300")
        }
        switch await lookupAndroid(deps) {
        case .asset(let url, let expiresIn):
            let ttl = max(0, min(expiresIn, 300))
            return redirect(url, cacheControl: "private, max-age=\(ttl)")
        case .noActiveRelease:
            return json(404, "{\"error\":\"No build available yet\",\"code\":\"no_active_release\"}")
        case .noInstallableBuild:
            return json(404, "{\"error\":\"No installable build available yet\",\"code\":\"no_installable_build\"}")
        case .notConfigured:
            return json(502, "{\"error\":\"Mobile download is unavailable\",\"code\":\"not_configured\"}")
        case .upstreamError:
            return json(502, "{\"error\":\"Mobile download is unavailable\",\"code\":\"upstream_error\"}")
        }
    }

    public static func urlSessionFetch(_ url: String) async throws -> MobileFeedHTTP {
        guard let target = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return MobileFeedHTTP(status: status, body: String(decoding: data, as: UTF8.self))
    }

    private enum AndroidLookup {
        case asset(url: String, expiresIn: Int)
        case noActiveRelease
        case noInstallableBuild
        case notConfigured
        case upstreamError
    }

    private static func lookupAndroid(_ deps: MobileDownloadDeps) async -> AndroidLookup {
        let base = deps.handsBase.hasSuffix("/") ? String(deps.handsBase.dropLast()) : deps.handsBase
        let channel = deps.channel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deps.channel
        let url = "\(base)/public/v2/apps/raft-android/latest?channel=\(channel)"
        let response: MobileFeedHTTP
        do {
            response = try await deps.fetch(url)
        } catch {
            return .upstreamError
        }
        if response.status == 404 {
            return handsCode(response.body) == "no_active_release" ? .noActiveRelease : .notConfigured
        }
        guard (200..<300).contains(response.status) else { return .upstreamError }
        guard let object = jsonObject(response.body) else { return .notConfigured }
        let assets = object["assets"] as? [[String: Any]] ?? []
        if let apk = assets.first(where: {
            ($0["platform"] as? String) == "android"
                && ($0["filetype"] as? String) == "apk"
                && (($0["download_url"] as? String)?.isEmpty == false)
        }), let download = apk["download_url"] as? String {
            let expires = (object["expires_in"] as? NSNumber)?.intValue ?? 0
            return .asset(url: download, expiresIn: expires)
        }
        let androidAssets = assets.filter { ($0["platform"] as? String) == "android" }
        return androidAssets.isEmpty ? .notConfigured : .noInstallableBuild
    }

    private static func handsCode(_ body: String) -> String {
        guard let object = jsonObject(body), let code = object["code"] else { return "" }
        if code is NSNull { return "" }
        return String(describing: code)
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func mobilePlatform(_ value: String?) -> String? {
        if value == "android" || value == "ios" { return value }
        return nil
    }

    private static func platformFromUserAgent(_ userAgent: String?) -> String? {
        guard let userAgent, !userAgent.isEmpty else { return nil }
        if userAgent.range(of: "android", options: .caseInsensitive) != nil { return "android" }
        if userAgent.range(of: "iphone", options: .caseInsensitive) != nil
            || userAgent.range(of: "ipod", options: .caseInsensitive) != nil
            || userAgent.range(of: "ipad", options: .caseInsensitive) != nil {
            return "ios"
        }
        return nil
    }

    private static func chooserURL(_ appURL: String) -> String {
        var trimmed = appURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return "\(trimmed)/download"
    }

    private static func redirect(_ location: String, cacheControl: String) -> HTTPReply {
        HTTPReply(
            status: 302,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Location": location,
                "Cache-Control": cacheControl,
                "Content-Length": "0",
            ],
            body: ""
        )
    }

    private static func json(_ status: Int, _ body: String) -> HTTPReply {
        HTTPReply(
            status: status,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }
}
