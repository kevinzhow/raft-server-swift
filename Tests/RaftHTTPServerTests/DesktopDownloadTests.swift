import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Synchronization
import Testing
import Vapor
import VaporTesting

private let macFeed = """
version: 0.1.42
files:
- url: Raft-Desktop-0.1.42-x64.zip
  sha512: 2FOw==
  size: 179049932
- url: Raft-Desktop-0.1.42-arm64.zip
  sha512: sAKC==
  size: 173576747
- url: Raft-Desktop-0.1.42-x64.dmg
  sha512: 6LE8==
  size: 167443598
- url: Raft-Desktop-0.1.42-arm64.dmg
  sha512: mcEM==
  size: 162809563
path: Raft-Desktop-0.1.42-x64.zip
sha512: 2FOw==
releaseDate: '2026-10-12T16:47:42.526Z'
minimumSystemVersion: 22.0.0

"""

private let linuxFeed = """
version: 0.1.42
files:
  - url: Raft-Desktop-0.1.42-x86_64.AppImage
    sha512: Rp82==
    size: 137221139
    blockMapSize: 144423
  - url: Raft-Desktop-0.1.42-amd64.deb
    sha512: B+WQ==
    size: 117049482
path: Raft-Desktop-0.1.42-x86_64.AppImage
sha512: Rp82==
releaseDate: '2026-10-12T16:26:07.802Z'

"""

private let releasesBase = "https://github.com/botiverse/desktop-beta/releases"

private final class ScriptedFeeds: Sendable {
    private struct State: Sendable {
        var requested: [String] = []
        var status: Int
        var feeds: [String: String]
        var throwsError = false
    }

    private let state: Mutex<State>

    var requested: [String] {
        state.withLock { $0.requested }
    }

    var status: Int {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var feeds: [String: String] {
        get { state.withLock { $0.feeds } }
        set { state.withLock { $0.feeds = newValue } }
    }

    var throwsError: Bool {
        get { state.withLock { $0.throwsError } }
        set { state.withLock { $0.throwsError = newValue } }
    }

    init(feeds: [String: String], status: Int = 200) {
        state = Mutex(State(status: status, feeds: feeds))
    }

    func fetch(_ url: String) async throws -> DesktopFeedHTTP {
        try state.withLock { value in
            value.requested.append(url)
            if value.throwsError { throw URLError(.cannotConnectToHost) }
            let name = url.split(separator: "/").last.map(String.init) ?? ""
            guard let body = value.feeds[name] else { return DesktopFeedHTTP(status: 404, body: "Not Found") }
            return DesktopFeedHTTP(status: value.status, body: body)
        }
    }
}

private func deps(
    _ script: ScriptedFeeds,
    cache: DesktopFeedCache? = nil,
    now: @escaping @Sendable () -> Int = { 0 },
    appURL: String = WebCORS.defaultAppURL
) -> DesktopDownloadDeps {
    DesktopDownloadDeps(
        fetch: { url in try await script.fetch(url) },
        releasesBase: releasesBase,
        cache: cache,
        now: now,
        appURL: appURL
    )
}

private func services(_ script: ScriptedFeeds, cache: DesktopFeedCache? = nil) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        desktop: deps(script, cache: cache)
    )
}

@Test func parsesTheRealElectronBuilderFeeds() {
    let mac = DesktopDownload.parseUpdateFeed(macFeed)
    #expect(mac?.version == "0.1.42")
    #expect(mac?.files == [
        "Raft-Desktop-0.1.42-x64.zip",
        "Raft-Desktop-0.1.42-arm64.zip",
        "Raft-Desktop-0.1.42-x64.dmg",
        "Raft-Desktop-0.1.42-arm64.dmg",
    ])
    #expect(DesktopDownload.parseUpdateFeed(linuxFeed)?.files == [
        "Raft-Desktop-0.1.42-x86_64.AppImage",
        "Raft-Desktop-0.1.42-amd64.deb",
    ])
    #expect(mac?.files.count == 4)
    #expect(DesktopDownload.parseUpdateFeed("files:\n- url: a.dmg\n") == nil)
}

@Test func versionMustBePlainSemver() {
    #expect(DesktopDownload.parseUpdateFeed("version: ../../../../evil/x/releases/download/v1\nfiles:\n- url: a-arm64.dmg\n") == nil)
    #expect(DesktopDownload.parseUpdateFeed("version: 1.2.3?x=1\nfiles:\n") == nil)
    #expect(DesktopDownload.parseUpdateFeed("version: 0.1.43-beta.1\nfiles:\n")?.version == "0.1.43-beta.1")
}

@Test func eachTargetResolvesFromTheLatestFeed() async {
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": macFeed, "latest-linux.yml": linuxFeed])
    let expect = [
        "mac": "Raft-Desktop-0.1.42-arm64.dmg",
        "mac-arm64": "Raft-Desktop-0.1.42-arm64.dmg",
        "mac-x64": "Raft-Desktop-0.1.42-x64.dmg",
        "linux-appimage": "Raft-Desktop-0.1.42-x86_64.AppImage",
        "linux-deb": "Raft-Desktop-0.1.42-amd64.deb",
    ]
    for (target, file) in expect {
        let result = await DesktopDownload.lookupAsset(target, deps: deps(script))
        #expect(result == .asset(url: "\(releasesBase)/download/v0.1.42/\(file)", version: "0.1.42"))
    }
    #expect(script.requested.allSatisfy { $0.hasPrefix("\(releasesBase)/latest/download/latest-") })
}

@Test func aUniversalBuildWinsForEveryMacTarget() async {
    let feed = macFeed.replacingOccurrences(of: "files:\n", with: "files:\n- url: Raft-Desktop-0.1.42-universal.dmg\n  size: 1\n")
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": feed])
    for target in ["mac", "mac-arm64", "mac-x64"] {
        let result = await DesktopDownload.lookupAsset(target, deps: deps(script))
        if case .asset(let url, _) = result {
            #expect(url.hasSuffix("/Raft-Desktop-0.1.42-universal.dmg"))
        } else {
            Issue.record("expected an asset for \(target)")
        }
    }
}

@Test func aMissingFeedIsNoBuild() async {
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": macFeed])
    let result = await DesktopDownload.lookupAsset("windows", deps: deps(script))
    #expect(result == .noBuild)
}

@Test func aFeedWithoutTheInstallerIsNoBuild() async {
    let pattern = #"- url: [^\n]*\.dmg\n(  [^\n]*\n)*"#
    let zipsOnly = macFeed.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    #expect(DesktopDownload.parseUpdateFeed(zipsOnly)?.files.contains { $0.hasSuffix(".dmg") } == false)
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": zipsOnly])
    #expect(await DesktopDownload.lookupAsset("mac", deps: deps(script)) == .noBuild)
}

@Test func upstreamFailuresAreNotAMissingBuild() async {
    let failing = ScriptedFeeds(feeds: [:], status: 500)
    failing.feeds = ["latest-mac.yml": "boom"]
    #expect(await DesktopDownload.lookupAsset("mac", deps: deps(failing)) == .upstreamError)
    let throwing = ScriptedFeeds(feeds: [:])
    throwing.throwsError = true
    #expect(await DesktopDownload.lookupAsset("mac", deps: deps(throwing)) == .upstreamError)
}

@Test func onlyKnownTargetsAreAccepted() {
    #expect(DesktopDownload.isDesktopTarget("mac"))
    #expect(DesktopDownload.isDesktopTarget("windows"))
    #expect(DesktopDownload.isDesktopTarget("toString") == false)
    #expect(DesktopDownload.isDesktopTarget(nil) == false)
}

@Test func platformsReportWhatTheLatestReleaseOffers() async {
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": macFeed, "latest-linux.yml": linuxFeed])
    let platforms = await DesktopDownload.lookupPlatforms(deps(script))
    #expect(platforms.mac == .available("0.1.42", universal: false))
    #expect(platforms.linux == .available("0.1.42"))
    #expect(platforms.windows == .none)

    let withWindows = ScriptedFeeds(feeds: [
        "latest-mac.yml": macFeed.replacingOccurrences(of: "files:\n", with: "files:\n- url: Raft-Desktop-0.1.42-universal.dmg\n"),
        "latest-linux.yml": linuxFeed,
        "latest.yml": "version: 0.1.42\nfiles:\n  - url: Raft-Desktop-0.1.42-x64.exe\n    size: 1\n",
    ])
    let shipped = await DesktopDownload.lookupPlatforms(deps(withWindows))
    #expect(shipped.mac.universal == true)
    #expect(shipped.windows == .available("0.1.42"))
}

@Test func githubSilenceIsUnknownNotNone() async {
    let failing = ScriptedFeeds(feeds: ["latest-mac.yml": "boom", "latest-linux.yml": "boom", "latest.yml": "boom"], status: 503)
    let platforms = await DesktopDownload.lookupPlatforms(deps(failing))
    #expect(platforms.mac == .unknown)
    #expect(platforms.linux == .unknown)
    #expect(platforms.windows == .unknown)
}

@Test func feedsAreReusedForAMinuteAndFailuresForTenSeconds() async {
    let cache = DesktopFeedCache()
    let clock = TestClock()
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": macFeed])
    let reading = deps(script, cache: cache, now: { clock.ms })
    _ = await DesktopDownload.lookupAsset("mac", deps: reading)
    _ = await DesktopDownload.lookupAsset("mac-x64", deps: reading)
    #expect(script.requested.count == 1)
    clock.ms = 61_000
    _ = await DesktopDownload.lookupAsset("mac", deps: reading)
    #expect(script.requested.count == 2)

    let flaky = ScriptedFeeds(feeds: ["latest-linux.yml": "boom"], status: 500)
    let failing = deps(flaky, cache: cache, now: { clock.ms })
    _ = await DesktopDownload.lookupAsset("linux-deb", deps: failing)
    _ = await DesktopDownload.lookupAsset("linux-deb", deps: failing)
    #expect(flaky.requested.count == 1)
    clock.ms += 11_000
    _ = await DesktopDownload.lookupAsset("linux-deb", deps: failing)
    #expect(flaky.requested.count == 2)
}

@Test func aKnownTargetRedirectsToTheReleaseAsset() async throws {
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": macFeed])
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let res = try await client.get("/api/desktop-download?target=mac-x64")
            #expect(res.status == .found)
            #expect(res.headers[HTTPField.Name("Location")!] == "\(releasesBase)/download/v0.1.42/Raft-Desktop-0.1.42-x64.dmg")
        }
    }
}

@Test func noTargetGoesToTheChooserWithoutReadingTheUserAgent() async throws {
    let iPad = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    try await withApp { app in
        configure(app, services: services(ScriptedFeeds(feeds: [:])))
        try await app.testing { client in
            let res = try await client.get("/api/desktop-download", headers: [
                HTTPField.Name("User-Agent")!: iPad,
            ])
            #expect(res.status == .found)
            #expect(res.headers[HTTPField.Name("Location")!] == "http://localhost:5173/download")
        }
    }
}

@Test func noBuildOrGitHubDownRedirectsToTheLatestReleasePage() async throws {
    for script in [ScriptedFeeds(feeds: [:]), ScriptedFeeds(feeds: ["latest.yml": "boom"], status: 500)] {
        try await withApp { app in
            configure(app, services: services(script))
            try await app.testing { client in
                let res = try await client.get("/api/desktop-download?target=windows")
                #expect(res.status == .found)
                #expect(res.headers[HTTPField.Name("Location")!] == "\(releasesBase)/latest")
            }
        }
    }
}

@Test func platformsEndpointIsPublicJSON() async throws {
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": macFeed])
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let res = try await client.get("/api/desktop-download/platforms")
            #expect(res.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data((res.body.string ?? "").utf8)) as? [String: Any]
            let mac = body?["mac"] as? [String: Any]
            let windows = body?["windows"] as? [String: Any]
            #expect(mac?["status"] as? String == "available")
            #expect(windows?["status"] as? String == "none")
            #expect(res.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=60")
        }
    }
}

@Test func concurrentPlatformsRequestsKeepCompletePublicResponses() async throws {
    let script = ScriptedFeeds(feeds: ["latest-mac.yml": macFeed, "latest-linux.yml": linuxFeed])
    let expectedBody = #"{"mac":{"status":"available","version":"0.1.42","universal":false},"linux":{"status":"available","version":"0.1.42"},"windows":{"status":"none"}}"#
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<24 {
                    group.addTask {
                        let response = try await client.get("/api/desktop-download/platforms")
                        #expect(response.status == .ok)
                        #expect(response.body.string == expectedBody)
                        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
                        #expect(response.headers[.contentLength] == String(expectedBody.utf8.count))
                        #expect(response.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=60")
                        #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}

private final class TestClock: Sendable {
    private let milliseconds = Mutex(0)

    var ms: Int {
        get { milliseconds.withLock { $0 } }
        set { milliseconds.withLock { $0 = newValue } }
    }
}
