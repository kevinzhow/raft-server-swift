import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let apkBody = """
{"build":{"version":"1.9.1"},"expires_in":3600,"assets":[{"platform":"android","filetype":"apk","download_url":"https://r2.example/app.apk"}]}
"""

private let aabThenApk = """
{"build":{"version":"1.13.1"},"expires_in":3600,"assets":[{"platform":"android","filetype":"aab","download_url":"https://r2.example/app.aab"},{"platform":"android","filetype":"apk","download_url":"https://r2.example/app.apk"}]}
"""

private let apkThenAab = """
{"build":{"version":"1.13.1"},"expires_in":3600,"assets":[{"platform":"android","filetype":"apk","download_url":"https://r2.example/app.apk"},{"platform":"android","filetype":"aab","download_url":"https://r2.example/app.aab"}]}
"""

private let ipaOnly = """
{"build":{"version":"1.0.0"},"assets":[{"platform":"ios","filetype":"ipa","download_url":"https://r2.example/app.ipa"}]}
"""

private let aabOnly = """
{"build":{"version":"1.13.1"},"expires_in":3600,"assets":[{"platform":"android","filetype":"aab","download_url":"https://r2.example/app.aab"}]}
"""

private let iosAndApk = """
{"build":{"version":"1.4.2"},"expires_in":3600,"assets":[{"platform":"ios","filetype":"ipa","download_url":"https://r2.example/ios.ipa"},{"platform":"android","filetype":"apk","download_url":"https://r2.example/app.apk"}]}
"""

private let androidUA = "Mozilla/5.0 (Linux; Android 14; Pixel 8)"
private let macUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)"
private let iPadUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
private let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/604"
private let legacyIPadUA = "Mozilla/5.0 (iPad; CPU OS 12_0 like Mac OS X) Safari/604"

private final class ScriptedHands: @unchecked Sendable {
    var requested: [String] = []
    var status: Int
    var body: String
    var throwsError = false

    init(status: Int = 200, body: String = "{}") {
        self.status = status
        self.body = body
    }

    func fetch(_ url: String) async throws -> MobileFeedHTTP {
        requested.append(url)
        if throwsError { throw URLError(.cannotConnectToHost) }
        return MobileFeedHTTP(status: status, body: body)
    }
}

private func services(_ script: ScriptedHands, appURL: String = WebCORS.defaultAppURL) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        mobile: MobileDownloadDeps(
            fetch: { url in try await script.fetch(url) },
            appURL: appURL
        )
    )
}

private func location(_ response: ClientResponse) -> String? {
    response.headers[HTTPField.Name("Location")!]
}

private func jsonBody(_ response: ClientResponse) -> [String: Any]? {
    guard let text = response.body.string, let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Test func androidPlatformRedirectsToTheHandsApk() async throws {
    let script = ScriptedHands(body: iosAndApk)
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let res = try await client.get("/api/mobile-download?platform=android")
            #expect(res.status == .found)
            #expect(location(res) == "https://r2.example/app.apk")
            #expect(res.headers[HTTPField.Name("Cache-Control")!] == "private, max-age=300")
            #expect(script.requested.count == 1)
            #expect(script.requested[0] == "https://hands.build/public/v2/apps/raft-android/latest?channel=main")
        }
    }
}

@Test func androidPrefersTheApkOverTheStoreBundle() async throws {
    for body in [aabThenApk, apkThenAab] {
        let script = ScriptedHands(body: body)
        try await withApp { app in
            configure(app, services: services(script))
            try await app.testing { client in
                let macChoosingAndroid = try await client.get("/api/mobile-download?platform=android", headers: [
                    HTTPField.Name("User-Agent")!: macUA,
                ])
                #expect(macChoosingAndroid.status == .found)
                #expect(location(macChoosingAndroid) == "https://r2.example/app.apk")
            }
        }
    }
}

@Test func anEmptyHandsChannelIs404Not502() async throws {
    let script = ScriptedHands(status: 404, body: "{\"error\":\"no active release for this client on channel 'main'\",\"code\":\"no_active_release\"}")
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let res = try await client.get("/api/mobile-download?platform=android")
            #expect(res.status == .notFound)
            #expect(jsonBody(res)?["error"] as? String == "No build available yet")
            #expect(jsonBody(res)?["code"] as? String == "no_active_release")
            #expect(location(res) == nil)
        }
    }
}

@Test func aMisconfiguredHandsSlugIs502() async throws {
    let prose = ScriptedHands(status: 404, body: "{\"error\":\"no active release for this client\",\"code\":\"app_not_found\"}")
    let missingCode = ScriptedHands(status: 404, body: "{\"error\":\"no active release\"}")
    let wrongPlatform = ScriptedHands(body: ipaOnly)
    let thrown = ScriptedHands()
    thrown.throwsError = true
    for (script, code) in [(prose, "not_configured"), (missingCode, "not_configured"), (wrongPlatform, "not_configured"), (thrown, "upstream_error")] {
        try await withApp { app in
            configure(app, services: services(script))
            try await app.testing { client in
                let res = try await client.get("/api/mobile-download?platform=android")
                #expect(res.status == .badGateway)
                #expect(jsonBody(res)?["code"] as? String == code)
                #expect(jsonBody(res)?["error"] as? String == "Mobile download is unavailable")
                #expect(location(res) == nil)
            }
        }
    }
}

@Test func aPhoneWithoutAPlatformQueryUsesItsUserAgent() async throws {
    let script = ScriptedHands(body: apkBody)
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let res = try await client.get("/api/mobile-download", headers: [
                HTTPField.Name("User-Agent")!: androidUA,
            ])
            #expect(res.status == .found)
            #expect(location(res) == "https://r2.example/app.apk")
        }
    }
}

@Test func anUnclassifiableDeviceGoesToTheAbsoluteChooser() async throws {
    let cases = [
        (macUA, "https://raft-app-staging.botiverse.dev", "https://raft-app-staging.botiverse.dev/download"),
        (iPadUA, "https://raft-app-staging.botiverse.dev/", "https://raft-app-staging.botiverse.dev/download"),
        (macUA, "http://localhost:5173", "http://localhost:5173/download"),
    ]
    for (agent, appURL, expected) in cases {
        let script = ScriptedHands(body: "{\"build\":{},\"assets\":[]}")
        try await withApp { app in
            configure(app, services: services(script, appURL: appURL))
            try await app.testing { client in
                let res = try await client.get("/api/mobile-download", headers: [
                    HTTPField.Name("User-Agent")!: agent,
                ])
                #expect(res.status == .found)
                #expect(location(res) == expected)
                #expect(res.headers[HTTPField.Name("Cache-Control")!] == "private, max-age=300")
                #expect(script.requested.isEmpty)
            }
        }
    }
}

@Test func iosGoesToTestFlightAndNeverToTheHandsIpa() async throws {
    let script = ScriptedHands(body: ipaOnly)
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let explicit = try await client.get("/api/mobile-download?platform=ios")
            #expect(explicit.status == .found)
            #expect(location(explicit)?.hasPrefix("https://testflight.apple.com/") == true)
            #expect(location(explicit)?.contains("hands.build") == false)
            #expect(location(explicit)?.contains("app.ipa") == false)

            let phone = try await client.get("/api/mobile-download", headers: [
                HTTPField.Name("User-Agent")!: iPhoneUA,
            ])
            #expect(phone.status == .found)
            #expect(location(phone)?.hasPrefix("https://testflight.apple.com/") == true)

            let legacyIPad = try await client.get("/api/mobile-download", headers: [
                HTTPField.Name("User-Agent")!: legacyIPadUA,
            ])
            #expect(legacyIPad.status == .found)
            #expect(location(legacyIPad)?.hasPrefix("https://testflight.apple.com/") == true)
            #expect(script.requested.isEmpty)
        }
    }
}

@Test func aStoreOnlyAndroidReleaseIs404WithNoRedirect() async throws {
    let script = ScriptedHands(body: aabOnly)
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let res = try await client.get("/api/mobile-download?platform=android")
            #expect(res.status == .notFound)
            #expect(jsonBody(res)?["code"] as? String == "no_installable_build")
            #expect(jsonBody(res)?["error"] as? String == "No installable build available yet")
            #expect(location(res) == nil)
        }
    }
}

@Test func theRedirectCacheNeverOutlivesTheSignedURL() async throws {
    // The signature expires; a cached redirect past it is a broken download, so
    // the asset TTL is clamped to the signature lifetime and to 300s.
    let cases: [(body: String, expected: String)] = [
        ("{\"build\":{\"version\":\"1.9.1\"},\"expires_in\":45,\"assets\":[{\"platform\":\"android\",\"filetype\":\"apk\",\"download_url\":\"https://r2.example/app.apk\"}]}", "private, max-age=45"),
        ("{\"build\":{\"version\":\"1.9.1\"},\"assets\":[{\"platform\":\"android\",\"filetype\":\"apk\",\"download_url\":\"https://r2.example/app.apk\"}]}", "private, max-age=0"),
    ]
    for (body, expected) in cases {
        let script = ScriptedHands(body: body)
        try await withApp { app in
            configure(app, services: services(script))
            try await app.testing { client in
                let res = try await client.get("/api/mobile-download?platform=android")
                #expect(res.status == .found)
                #expect(location(res) == "https://r2.example/app.apk")
                #expect(res.headers[HTTPField.Name("Cache-Control")!] == expected)
            }
        }
    }
}

@Test func anExplicitPlatformOverridesTheUserAgent() async throws {
    // The chooser hands off with `?platform=`; a desktop that picked Android
    // must not be reclassified back to "unclassifiable" by the Mac UA.
    let script = ScriptedHands(body: apkBody)
    try await withApp { app in
        configure(app, services: services(script))
        try await app.testing { client in
            let androidOnMac = try await client.get("/api/mobile-download?platform=android", headers: [
                HTTPField.Name("User-Agent")!: macUA,
            ])
            #expect(androidOnMac.status == .found)
            #expect(location(androidOnMac) == "https://r2.example/app.apk")

            let iosOnAndroid = try await client.get("/api/mobile-download?platform=ios", headers: [
                HTTPField.Name("User-Agent")!: androidUA,
            ])
            #expect(iosOnAndroid.status == .found)
            #expect(location(iosOnAndroid)?.hasPrefix("https://testflight.apple.com/") == true)
            #expect(script.requested.count == 1, "iOS never calls Hands")
        }
    }
}

@Test func theEntryPointNeedsNoSession() async throws {
    // A phone that scanned a QR code has no session at all: the route must
    // answer from the handler, never from an authentication guard.
    let emptyChannel = ScriptedHands(status: 404, body: "{\"error\":\"empty\",\"code\":\"no_active_release\"}")
    try await withApp { app in
        configure(app, services: services(emptyChannel))
        try await app.testing { client in
            let res = try await client.get("/api/mobile-download?platform=android")
            #expect(res.status == .notFound, "a guard would answer 401, not the handler's empty-channel body")
            #expect(jsonBody(res)?["error"] as? String == "No build available yet")
            #expect(jsonBody(res)?["code"] as? String == "no_active_release")
        }
    }

    // With no platform and no usable User-Agent there is nothing to install for
    // this caller, so the route hands off to the chooser instead of guessing.
    let untouched = ScriptedHands(body: apkBody)
    try await withApp { app in
        configure(app, services: services(untouched))
        try await app.testing { client in
            let res = try await client.get("/api/mobile-download")
            #expect(res.status == .found)
            #expect(location(res) == "\(WebCORS.defaultAppURL)/download")
            #expect(res.headers[HTTPField.Name("Cache-Control")!] == "private, max-age=300")
            #expect(untouched.requested.isEmpty)
        }
    }
}
