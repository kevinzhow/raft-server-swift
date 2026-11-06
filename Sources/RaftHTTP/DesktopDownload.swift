import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public desktop download redirects from `routes/desktopDownload.ts`.
///
/// `GET /api/desktop-download?target=...` sends the browser to the Latest
/// desktop-beta asset named by that release's electron-builder feed. No target
/// goes to the web `/download` chooser. The User-Agent is never consulted.
/// A missing build or a GitHub failure redirects to the Latest release page,
/// not a JSON error. `GET /api/desktop-download/platforms` reports what that
/// release offers.

public struct DesktopFeedHTTP: Equatable, Sendable {
    public var status: Int
    public var body: String

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

public struct DesktopDownloadDeps: Sendable {
    public var fetch: @Sendable (String) async throws -> DesktopFeedHTTP
    public var releasesBase: String
    public var cache: DesktopFeedCache?
    public var now: @Sendable () -> Int
    public var appURL: String

    public init(
        fetch: @escaping @Sendable (String) async throws -> DesktopFeedHTTP,
        releasesBase: String = DesktopDownload.defaultReleasesBase,
        cache: DesktopFeedCache? = nil,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        appURL: String = WebCORS.defaultAppURL
    ) {
        self.fetch = fetch
        self.releasesBase = releasesBase
        self.cache = cache
        self.now = now
        self.appURL = appURL
    }

    public static func live(environment: [String: String]) -> DesktopDownloadDeps {
        let configured = environment["RAFT_DESKTOP_RELEASES_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (configured?.isEmpty == false ? configured! : DesktopDownload.defaultReleasesBase)
        return DesktopDownloadDeps(
            fetch: DesktopDownload.urlSessionFetch,
            releasesBase: base,
            cache: DesktopFeedCache(),
            appURL: WebCORS.appURL(environment: environment)
        )
    }
}

public final class DesktopFeedCache: Sendable {
    private let entries = Mutex<[String: (at: Int, read: FeedRead)]>([:])

    public init() {}

    func get(_ key: String) -> (at: Int, read: FeedRead)? {
        entries.withLock { $0[key] }
    }

    func set(_ key: String, at: Int, read: FeedRead) {
        entries.withLock { $0[key] = (at, read) }
    }
}

public struct UpdateFeed: Equatable, Sendable {
    public var version: String
    public var files: [String]
}

public enum DesktopAssetLookup: Equatable, Sendable {
    case asset(url: String, version: String)
    case noBuild
    case upstreamError
}

public struct DesktopPlatformReport: Equatable, Sendable {
    public var status: String
    public var version: String?
    public var universal: Bool?

    public static func available(_ version: String, universal: Bool? = nil) -> DesktopPlatformReport {
        DesktopPlatformReport(status: "available", version: version, universal: universal)
    }

    public static let none = DesktopPlatformReport(status: "none", version: nil, universal: nil)
    public static let unknown = DesktopPlatformReport(status: "unknown", version: nil, universal: nil)
}

public struct DesktopPlatforms: Equatable, Sendable {
    public var mac: DesktopPlatformReport
    public var linux: DesktopPlatformReport
    public var windows: DesktopPlatformReport
}

enum FeedRead: Equatable, Sendable {
    case feed(version: String, files: [String])
    case noFeed
    case upstreamError(String)
}

public enum DesktopDownload {
    public static let defaultReleasesBase = "https://github.com/botiverse/desktop-beta/releases"
    static let feedTTLMs = 60_000
    static let feedErrorTTLMs = 10_000

    private static let targets: [String: (feed: String, files: [String])] = [
        "mac": ("latest-mac.yml", ["-universal\\.dmg$", "-arm64\\.dmg$"]),
        "mac-arm64": ("latest-mac.yml", ["-universal\\.dmg$", "-arm64\\.dmg$"]),
        "mac-x64": ("latest-mac.yml", ["-universal\\.dmg$", "-x64\\.dmg$"]),
        "linux-appimage": ("latest-linux.yml", ["-x86_64\\.AppImage$"]),
        "linux-deb": ("latest-linux.yml", ["-amd64\\.deb$"]),
        "windows": ("latest.yml", ["-x64\\.exe$", "\\.exe$"]),
    ]

    public static func isDesktopTarget(_ value: String?) -> Bool {
        guard let value else { return false }
        return targets[value] != nil
    }

    public static func parseUpdateFeed(_ text: String) -> UpdateFeed? {
        guard let version = firstCapture(#"^version:\s*['"]?([^'"\s]+)['"]?\s*$"#, in: text),
              isPlainSemver(version)
        else { return nil }
        let files = allCaptures(#"^\s*-\s*url:\s*['"]?([^'"\s]+)['"]?\s*$"#, in: text)
        return UpdateFeed(version: version, files: files)
    }

    public static func lookupAsset(_ target: String, deps: DesktopDownloadDeps) async -> DesktopAssetLookup {
        guard let spec = targets[target] else { return .noBuild }
        let base = trimmedBase(deps.releasesBase)
        let read = await readFeed(spec.feed, deps: deps)
        switch read {
        case .noFeed:
            return .noBuild
        case .upstreamError:
            return .upstreamError
        case .feed(let version, let files):
            guard let name = pick(files, spec.files) else { return .noBuild }
            let url = "\(base)/download/v\(version)/\(encodeURIComponent(name))"
            return .asset(url: url, version: version)
        }
    }

    public static func lookupPlatforms(_ deps: DesktopDownloadDeps) async -> DesktopPlatforms {
        async let macRead = readFeed("latest-mac.yml", deps: deps)
        async let linuxRead = readFeed("latest-linux.yml", deps: deps)
        async let windowsRead = readFeed("latest.yml", deps: deps)
        let mac = await macRead
        let macStatus = platformStatus(mac, installers: targets["mac"]!.files)
        let macReport: DesktopPlatformReport
        if macStatus.status == "available", case .feed(_, let files) = mac {
            macReport = DesktopPlatformReport(
                status: "available",
                version: macStatus.version,
                universal: pick(files, ["-universal\\.dmg$"]) != nil
            )
        } else {
            macReport = macStatus
        }
        return DesktopPlatforms(
            mac: macReport,
            linux: platformStatus(await linuxRead, installers: targets["linux-appimage"]!.files),
            windows: platformStatus(await windowsRead, installers: targets["windows"]!.files)
        )
    }

    public static func downloadReply(target: String?, deps: DesktopDownloadDeps) async -> HTTPReply {
        guard let target, isDesktopTarget(target) else {
            return redirect(chooserURL(deps.appURL), cacheControl: "private, max-age=300")
        }
        let result = await lookupAsset(target, deps: deps)
        if case .asset(let url, _) = result {
            return redirect(url, cacheControl: "private, max-age=300")
        }
        return redirect("\(trimmedBase(deps.releasesBase))/latest", cacheControl: "no-store")
    }

    public static func platformsReply(_ deps: DesktopDownloadDeps) async -> HTTPReply {
        let platforms = await lookupPlatforms(deps)
        let body = """
        {"mac":\(platformJSON(platforms.mac)),"linux":\(platformJSON(platforms.linux)),"windows":\(platformJSON(platforms.windows))}
        """
        return HTTPReply(
            status: 200,
            headers: [
                "X-Robots-Tag": AppFallback.robotsTag,
                "Content-Type": AppFallback.jsonContentType,
                "Cache-Control": "public, max-age=60",
                "Content-Length": String(Data(body.utf8).count),
            ],
            body: body
        )
    }

    public static func urlSessionFetch(_ url: String) async throws -> DesktopFeedHTTP {
        guard let target = URL(string: url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return DesktopFeedHTTP(status: status, body: String(decoding: data, as: UTF8.self))
    }

    private static func readFeed(_ feed: String, deps: DesktopDownloadDeps) async -> FeedRead {
        let base = trimmedBase(deps.releasesBase)
        let key = "\(base)/\(feed)"
        let now = deps.now()
        if let hit = deps.cache?.get(key) {
            let ttl = hit.read.isUpstreamError ? feedErrorTTLMs : feedTTLMs
            if now - hit.at < ttl { return hit.read }
        }
        let read = await fetchFeed(feed, base: base, fetch: deps.fetch)
        deps.cache?.set(key, at: now, read: read)
        return read
    }

    private static func fetchFeed(
        _ feed: String,
        base: String,
        fetch: @Sendable (String) async throws -> DesktopFeedHTTP
    ) async -> FeedRead {
        do {
            let response = try await fetch("\(base)/latest/download/\(feed)")
            if response.status == 404 { return .noFeed }
            guard (200..<300).contains(response.status) else {
                return .upstreamError("HTTP \(response.status)")
            }
            guard let parsed = parseUpdateFeed(response.body) else {
                return .upstreamError("\(feed) has no valid version")
            }
            return .feed(version: parsed.version, files: parsed.files)
        } catch {
            return .upstreamError("request failed: \(error)")
        }
    }

    private static func platformStatus(_ read: FeedRead, installers: [String]) -> DesktopPlatformReport {
        switch read {
        case .upstreamError:
            return .unknown
        case .noFeed:
            return .none
        case .feed(let version, let files):
            guard pick(files, installers) != nil else { return .none }
            return .available(version)
        }
    }

    private static func pick(_ files: [String], _ patterns: [String]) -> String? {
        for pattern in patterns {
            if let name = files.first(where: { !$0.contains("/") && hasMatch(pattern, $0) }) {
                return name
            }
        }
        return nil
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

    private static func chooserURL(_ appURL: String) -> String {
        let trimmed = appURL.hasSuffix("/") ? String(appURL.dropLast()) : appURL
        return "\(trimmed)/download"
    }

    private static func trimmedBase(_ base: String) -> String {
        base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    private static func platformJSON(_ report: DesktopPlatformReport) -> String {
        switch report.status {
        case "available":
            let version = jsonString(report.version ?? "")
            if let universal = report.universal {
                return "{\"status\":\"available\",\"version\":\(version),\"universal\":\(universal ? "true" : "false")}"
            }
            return "{\"status\":\"available\",\"version\":\(version)}"
        case "unknown":
            return "{\"status\":\"unknown\"}"
        default:
            return "{\"status\":\"none\"}"
        }
    }

    private static func isPlainSemver(_ version: String) -> Bool {
        hasMatch(#"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$"#, version)
    }

    private static func hasMatch(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, range: range) != nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        allCaptures(pattern, in: text).first
    }

    private static func allCaptures(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    private static func encodeURIComponent(_ value: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
        var out = ""
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

extension FeedRead {
    var isUpstreamError: Bool {
        if case .upstreamError = self { return true }
        return false
    }
}
