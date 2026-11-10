import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func post(
    _ client: any Client,
    _ path: String,
    body: String,
    site: String? = "same-site"
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let site {
        headers[HTTPField.Name("Sec-Fetch-Site")!] = site
    }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func expectEmpty204(_ response: ClientResponse) {
    #expect(response.status == .noContent)
    #expect(bodyText(response).isEmpty)
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
}

@Test func everyPublicVisitOutcomeIsAnEmpty204() async throws {
    let viewed = "{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"event\":\"public_page_viewed\"}"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {}
        ))
        try await app.testing { client in
            expectEmpty204(try await post(client, "/api/public-visits/no-such-slug", body: viewed))
            expectEmpty204(try await post(client, "/api/public-visits/visits-private", body: viewed))
            expectEmpty204(try await post(client, "/api/public-visits/visits-refused", body: viewed, site: "cross-site"))
            expectEmpty204(try await post(client, "/api/public-visits/visits-refused", body: viewed, site: nil))
            expectEmpty204(try await post(
                client,
                "/api/public-visits/visits-refused",
                body: "{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"event\":\"public_page_viewed\",\"visitor\":\"signed_in_member\"}"
            ))
            expectEmpty204(try await post(
                client,
                "/api/public-visits/visits-refused",
                body: "{\"uuid\":\"not-a-uuid\",\"event\":\"public_page_viewed\"}"
            ))
            expectEmpty204(try await post(
                client,
                "/api/public-visits/visits-refused",
                body: "{\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"event\":\"message_read\"}"
            ))
            expectEmpty204(try await post(
                client,
                "/api/public-visits/visits-refused",
                body: "{\"uuid\":\"33333333-3333-4333-8333-333333333333\",\"event\":\"public_page_channel_opened\"}"
            ))
            expectEmpty204(try await post(
                client,
                "/api/public-visits/visits-refused",
                body: "{\"uuid\":\"44444444-4444-4444-8444-444444444444\",\"event\":\"public_page_viewed\",\"padding\":\"\(String(repeating: "x", count: 2048))\"}"
            ))
            expectEmpty204(try await post(client, "/api/public-visits/visits-refused", body: "{not json"))
            expectEmpty204(try await post(client, "/api/public-visits/visits-counted", body: viewed))
        }
    }
}

private func postVisit(
    _ client: any Client,
    _ path: String,
    body: String,
    site: String? = "same-site",
    authorization: String? = nil,
    extra: HTTPFields = [:]
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let site {
        headers[HTTPField.Name("Sec-Fetch-Site")!] = site
    }
    if let authorization {
        headers[.authorization] = authorization
    }
    for field in extra {
        headers[field.name] = field.value
    }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func countedDirectory() -> PublicVisitDirectory {
    let directory = PublicVisitDirectory()
    directory.addServer(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        slug: "visits-counted",
        memberIds: ["owner"],
        guestChannelIds: ["bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"]
    )
    directory.addUser(PublicVisitUser(id: "owner", shareUsageData: nil, analyticsId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    directory.addUser(PublicVisitUser(
        id: "outsider",
        shareUsageData: true,
        analyticsId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    ))
    directory.addToken("owner-token", userId: "owner")
    directory.addToken("outsider-token", userId: "outsider")
    return directory
}

@Test func aVisitCarriesCoarseRequestContextAndNotTheRawUserAgent() async throws {
    let directory = PublicVisitDirectory()
    directory.addServer(id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", slug: "visits-context")
    let iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-context",
                body: "{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"event\":\"public_page_viewed\"}",
                extra: [
                    .userAgent: iphone,
                    HTTPField.Name("CloudFront-Viewer-Country")!: "JP",
                ]
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-context",
                body: "{\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"event\":\"public_page_viewed\"}",
                extra: [HTTPField.Name("CloudFront-Viewer-Country")!: "jp"]
            ))
        }
    }
    let rows = directory.rows
    #expect(rows.count == 2)
    #expect(rows[0].visitor == "anonymous")
    #expect(rows[0].browser == "safari")
    #expect(rows[0].browserVersion == 17)
    #expect(rows[0].os == "ios")
    #expect(rows[0].deviceType == "mobile")
    #expect(rows[0].country == "JP")
    #expect(String(describing: rows).contains("iPhone OS") == false)
    #expect(rows[1].browser == "other")
    #expect(rows[1].browserVersion == nil)
    #expect(rows[1].os == "other")
    #expect(rows[1].deviceType == "other")
    #expect(rows[1].country == nil)
}

@Test func publicVisitsCountTheClassTheServerDecides() async throws {
    let directory = countedDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let viewed = "{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"event\":\"public_page_viewed\"}"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            expectEmpty204(try await postVisit(client, "/api/public-visits/visits-counted", body: viewed))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-counted",
                body: "{\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"event\":\"public_page_channel_opened\",\"channel_id\":\"\(channelId)\"}",
                authorization: "Bearer outsider-token"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-counted",
                body: "{\"uuid\":\"33333333-3333-4333-8333-333333333333\",\"event\":\"public_page_viewed\"}",
                authorization: "Bearer owner-token"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-counted",
                body: "{\"uuid\":\"44444444-4444-4444-8444-444444444444\",\"event\":\"public_page_viewed\"}",
                authorization: "Bearer not-a-token"
            ))
            let rows = directory.rows
            #expect(rows.map(\.event) == [
                "public_page_viewed", "public_page_channel_opened", "public_page_viewed", "public_page_viewed",
            ])
            #expect(rows.map(\.visitor) == ["anonymous", "signed_in_non_member", "signed_in_member", "anonymous"])
            #expect(rows.map(\.serverId) == [serverId, serverId, serverId, serverId])
            #expect(rows.map(\.source) == ["server", "server", "server", "server"])
            #expect(rows.map(\.analyticsId) == [nil, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", nil, nil])
            #expect(rows[1].analyticsId != "outsider")
            #expect(rows.allSatisfy { $0.clientSessionId == nil })
            #expect(rows.map(\.channelId) == [nil, channelId, nil, nil])

            let before = directory.rows.count
            expectEmpty204(try await postVisit(client, "/api/public-visits/no-such-slug", body: viewed))
            expectEmpty204(try await postVisit(client, "/api/public-visits/visits-counted", body: viewed, site: "cross-site"))
            expectEmpty204(try await postVisit(client, "/api/public-visits/visits-counted", body: viewed, site: nil))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-counted",
                body: "{\"uuid\":\"55555555-5555-4555-8555-555555555555\",\"event\":\"public_page_viewed\",\"visitor\":\"signed_in_member\"}"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-counted",
                body: "{\"uuid\":\"not-a-uuid\",\"event\":\"public_page_viewed\"}"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-counted",
                body: "{\"uuid\":\"66666666-6666-4666-8666-666666666666\",\"event\":\"public_page_channel_opened\",\"channel_id\":\"99999999-9999-4999-8999-999999999999\"}"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-counted",
                body: "{\"uuid\":\"77777777-7777-4777-8777-777777777777\",\"event\":\"public_page_viewed\",\"entry\":\"bookmark\"}"
            ))
            expectEmpty204(try await postVisit(client, "/api/public-visits/visits-counted", body: viewed))
            #expect(directory.rows.count == before)
        }
    }
}

@Test func aRepeatedVisitUuidCountsOnceUntilTheDailyCap() async throws {
    let directory = PublicVisitDirectory(dailyCap: 2)
    directory.addServer(id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", slug: "visits-capped")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            let again = "{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"event\":\"public_page_viewed\"}"
            expectEmpty204(try await postVisit(client, "/api/public-visits/visits-capped", body: again))
            expectEmpty204(try await postVisit(client, "/api/public-visits/visits-capped", body: again))
            #expect(directory.rows.count == 1)
            for nth in 2...4 {
                expectEmpty204(try await postVisit(
                    client,
                    "/api/public-visits/visits-capped",
                    body: "{\"uuid\":\"2222222\(nth)-2222-4222-8222-222222222222\",\"event\":\"public_page_viewed\"}"
                ))
            }
            #expect(directory.rows.count == 2)
        }
    }
}

@Test func publicServerVisitorIdModeFollowsTheCountry() async throws {
    let directory = PublicVisitDirectory()
    directory.addServer(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        slug: "visits-visitor-id",
        visitorIdEnabled: true
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            func offered(_ headers: HTTPFields = [:]) async throws -> String? {
                let response = try await client.get(URI(string: "/api/public/servers/visits-visitor-id"), headers: headers)
                #expect(response.status == .ok)
                #expect(response.headers[HTTPField.Name("Cache-Control")!] == "no-store")
                let object = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                return object?["visitorIdMode"] as? String
            }
            #expect(try await offered() == "ask")
            #expect(try await offered([HTTPField.Name("CloudFront-Viewer-Country")!: "DE"]) == "ask")
            #expect(try await offered([HTTPField.Name("CloudFront-Viewer-Country")!: "CN"]) == "ask")
            #expect(try await offered([HTTPField.Name("CloudFront-Viewer-Country")!: "US"]) == "default_on")
            #expect(try await offered([
                HTTPField.Name("CloudFront-Viewer-Country")!: "CA",
                HTTPField.Name("CloudFront-Viewer-Country-Region")!: "QC",
            ]) == "ask")
            #expect(try await offered([
                HTTPField.Name("CloudFront-Viewer-Country")!: "CA",
                HTTPField.Name("CloudFront-Viewer-Country-Region")!: "ON",
            ]) == "default_on")
            #expect(try await offered([
                HTTPField.Name("CloudFront-Viewer-Country")!: "US",
                HTTPField.Name("Sec-GPC")!: "1",
            ]) == "default_off")

            directory.setVisitorIdEnabled(slug: "visits-visitor-id", enabled: false)
            #expect(try await offered([HTTPField.Name("CloudFront-Viewer-Country")!: "US"]) == nil)

            directory.setProductAnalyticsEnabled(slug: "visits-visitor-id", enabled: false)
            directory.setVisitorIdEnabled(slug: "visits-visitor-id", enabled: true)
            #expect(try await offered([HTTPField.Name("CloudFront-Viewer-Country")!: "US"]) == nil)
            let before = directory.rows.count
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-visitor-id",
                body: "{\"uuid\":\"88888888-8888-4888-8888-888888888888\",\"event\":\"public_page_viewed\"}"
            ))
            #expect(directory.rows.count == before)

            let missing = try await client.get("/api/public/servers/no-such-slug")
            #expect(missing.status == .notFound)
            #expect(bodyText(missing) == "{\"error\":\"Not found\"}")
            #expect(missing.headers[HTTPField.Name("Cache-Control")!] == "no-store")
        }
    }
}

@Test func referrerSiteKeepsTheRegistrableDomain() {
    let cases: [(String, String?)] = [
        ("x.com", "x.com"),
        ("t.co", "t.co"),
        ("news.ycombinator.com", "ycombinator.com"),
        ("google.co.uk", "google.co.uk"),
        ("mp.weixin.qq.com", "qq.com"),
        ("alice.github.io", "github.io"),
        ("bob.notion.site", "notion.site"),
        ("carol.substack.com", "substack.com"),
        ("my-app.vercel.app", "vercel.app"),
        ("wiki.corp.acme.com", "acme.com"),
        ("jira.corp.internal", nil),
        ("intranet.local", nil),
        ("com", nil),
        ("https://x.com/someone/status/1", nil),
        ("192.168.1.10", nil),
    ]
    for (host, site) in cases {
        #expect(PublicVisits.referrerSite(host) == site)
    }
}

@Test func aViewKeepsSourceFieldsAndAnOpenKeepsItsChannel() async throws {
    let directory = PublicVisitDirectory()
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    directory.addServer(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        slug: "visits-sources",
        guestChannelIds: [channelId]
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-sources",
                body: "{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"event\":\"public_page_viewed\",\"entry\":\"landing\",\"referrer_domain\":\"news.ycombinator.com\",\"utm_source\":\"newsletter\",\"utm_medium\":\"email\",\"utm_campaign\":\"launch-2026\"}"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-sources",
                body: "{\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"event\":\"public_page_viewed\",\"entry\":\"in_app\"}"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-sources",
                body: "{\"uuid\":\"33333333-3333-4333-8333-333333333333\",\"event\":\"public_page_viewed\",\"entry\":\"landing\",\"referrer_domain\":\"https://x.com/someone/status/1\",\"utm_source\":\"someone@example.com\",\"utm_campaign\":\"Spring Sale\"}"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-sources",
                body: "{\"uuid\":\"44444444-4444-4444-8444-444444444444\",\"event\":\"public_page_channel_opened\",\"channel_id\":\"\(channelId.uppercased())\",\"referrer_domain\":\"x.com\"}"
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-sources",
                body: "{\"uuid\":\"55555555-5555-4555-8555-555555555555\",\"event\":\"public_page_viewed\",\"entry\":\"bookmark\"}"
            ))
        }
    }
    let rows = directory.rows
    #expect(rows.count == 4)
    #expect(rows.map(\.visitor) == ["anonymous", "anonymous", "anonymous", "anonymous"])
    #expect(rows[0].entry == "landing")
    #expect(rows[0].referrerDomain == "ycombinator.com")
    #expect(rows[0].utmSource == "newsletter")
    #expect(rows[0].utmMedium == "email")
    #expect(rows[0].utmCampaign == "launch-2026")
    #expect(rows[0].channelId == nil)
    #expect(rows[1].entry == "in_app")
    #expect(rows[1].referrerDomain == nil)
    #expect(rows[2].entry == "landing")
    #expect(rows[2].referrerDomain == nil)
    #expect(rows[2].utmSource == nil)
    #expect(rows[2].utmCampaign == nil)
    #expect(rows[3].channelId == channelId)
    #expect(rows[3].entry == nil)
    #expect(rows[3].referrerDomain == nil)
}

@Test func aThreadOpenKeepsOnlyALiveThreadUnderThatPublicChannel() async throws {
    let directory = PublicVisitDirectory()
    let open = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let closed = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let otherOpen = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let thread = "11111111-1111-4111-8111-111111111111"
    let closedThread = "22222222-2222-4222-8222-222222222222"
    let archivedThread = "33333333-3333-4333-8333-333333333333"
    directory.addServer(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        slug: "visits-threads",
        guestChannelIds: [open, otherOpen]
    )
    directory.addThread(slug: "visits-threads", id: thread, parentChannelId: open)
    directory.addThread(slug: "visits-threads", id: closedThread, parentChannelId: closed)
    directory.addThread(slug: "visits-threads", id: archivedThread, parentChannelId: open, archived: true)
    func body(_ id: String, _ fields: String) -> String {
        "{\"uuid\":\"\(id)\",\"event\":\"public_page_thread_opened\",\(fields)}"
    }
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: body("44444444-4444-4444-8444-444444444444", "\"channel_id\":\"\(open.uppercased())\",\"thread_channel_id\":\"\(thread.uppercased())\"")
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: body("55555555-5555-4555-8555-555555555555", "\"channel_id\":\"\(open)\"")
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: body("66666666-6666-4666-8666-666666666666", "\"thread_channel_id\":\"\(thread)\"")
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: body("77777777-7777-4777-8777-777777777777", "\"channel_id\":\"\(closed)\",\"thread_channel_id\":\"\(closedThread)\"")
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: body("88888888-8888-4888-8888-888888888888", "\"channel_id\":\"\(otherOpen)\",\"thread_channel_id\":\"\(thread)\"")
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: body("99999999-9999-4999-8999-999999999999", "\"channel_id\":\"\(open)\",\"thread_channel_id\":\"\(archivedThread)\"")
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: body("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "\"channel_id\":\"\(open)\",\"thread_channel_id\":\"\(otherOpen)\"")
            ))
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-threads",
                body: "{\"uuid\":\"bbbbbbbb-1111-4111-8111-111111111111\",\"event\":\"public_page_channel_opened\",\"channel_id\":\"\(open)\",\"thread_channel_id\":\"\(thread)\"}"
            ))
        }
    }
    let rows = directory.rows
    #expect(rows.map(\.event) == ["public_page_thread_opened", "public_page_channel_opened"])
    #expect(rows[0].visitor == "anonymous")
    #expect(rows[0].channelId == open)
    #expect(rows[0].threadChannelId == thread)
    #expect(rows[1].visitor == "anonymous")
    #expect(rows[1].channelId == open)
    #expect(rows[1].threadChannelId == nil)
}

@Test func aConsentingLoggedOutVisitorIdStaysOutOfTheVisitEvent() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    directory.addServer(id: serverId, slug: "visits-visitor-id", visitorIdEnabled: true, memberIds: ["owner"])
    directory.addUser(PublicVisitUser(id: "owner", shareUsageData: nil, analyticsId: nil))
    directory.addToken("owner-token", userId: "owner")
    let anonymousId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-visitor-id",
                body: "{\"uuid\":\"11111111-1111-4111-8111-111111111111\",\"event\":\"public_page_viewed\",\"anonymous_id\":\"\(anonymousId.uppercased())\"}"
            ))
            #expect(directory.rows.count == 1)
            #expect(String(describing: directory.rows).contains(anonymousId) == false)
            #expect(directory.visitors == [
                PublicVisitorRow(
                    uuid: "11111111-1111-4111-8111-111111111111",
                    event: "public_page_viewed",
                    serverId: serverId,
                    anonymousId: anonymousId
                ),
            ])

            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-visitor-id",
                body: "{\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"event\":\"public_page_viewed\",\"anonymous_id\":\"not-a-uuid\"}"
            ))
            #expect(directory.rows.count == 2)
            #expect(directory.visitors.count == 1)

            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-visitor-id",
                body: "{\"uuid\":\"33333333-3333-4333-8333-333333333333\",\"event\":\"public_page_viewed\",\"anonymous_id\":\"dddddddd-dddd-4ddd-8ddd-dddddddddddd\"}",
                authorization: "Bearer owner-token"
            ))
            #expect(directory.rows.count == 3)
            #expect(directory.visitors.count == 1)

            directory.setVisitorIdEnabled(slug: "visits-visitor-id", enabled: false)
            let offered = try await client.get("/api/public/servers/visits-visitor-id", headers: [
                HTTPField.Name("CloudFront-Viewer-Country")!: "US",
            ])
            #expect(offered.status == .ok)
            let offeredObject = try JSONSerialization.jsonObject(with: Data(bodyText(offered).utf8)) as? [String: Any]
            #expect(offeredObject?["visitorIdMode"] == nil)
            expectEmpty204(try await postVisit(
                client,
                "/api/public-visits/visits-visitor-id",
                body: "{\"uuid\":\"44444444-4444-4444-8444-444444444444\",\"event\":\"public_page_viewed\",\"anonymous_id\":\"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee\"}"
            ))
            #expect(directory.rows.count == 4)
            #expect(directory.visitors.count == 1)
        }
    }
}

@Test func aJoinLinksTheVisitorIdOnlyWhenTheJoinerSharesUsageData() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let sharingAnalytics = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let otherAnalytics = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    directory.addServer(
        id: serverId,
        slug: "visits-join-link",
        visitorIdEnabled: true,
        name: "Public visits-join-link",
        guestJoinEnabled: true,
        guestRolloutEnabled: true
    )
    directory.addUser(PublicVisitUser(id: "sharing", shareUsageData: true, analyticsId: sharingAnalytics))
    directory.addUser(PublicVisitUser(id: "noconsent", shareUsageData: true, analyticsId: otherAnalytics))
    directory.addUser(PublicVisitUser(id: "silent", shareUsageData: nil, analyticsId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"))
    directory.addToken("sharing-token", userId: "sharing")
    directory.addToken("noconsent-token", userId: "noconsent")
    directory.addToken("silent-token", userId: "silent")
    let anonymousId = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory,
            emailAccounts: publicServerAuthAccounts([("sharing", "sharing-token"), ("noconsent", "noconsent-token"), ("silent", "silent-token")])
        ))
        try await app.testing { client in
            let sharing = try await postVisit(
                client,
                "/api/public/servers/visits-join-link/join-as-guest",
                body: "{\"anonymous_id\":\"\(anonymousId)\"}",
                authorization: "Bearer sharing-token"
            )
            #expect(sharing.status == .ok)
            #expect(bodyText(sharing).contains("\"joined\":true"))
            let joined = directory.rows.filter { $0.event == "public_page_server_joined" }
            #expect(joined.count == 1)
            #expect(joined[0].analyticsId == sharingAnalytics)
            #expect(joined[0].analyticsId != "sharing")
            #expect(joined[0].serverId == serverId)
            #expect(joined[0].hasVisitorId == true)
            #expect(String(describing: joined).contains(anonymousId) == false)
            #expect(directory.visitors == [
                PublicVisitorRow(
                    uuid: joined[0].uuid ?? "",
                    event: "public_page_server_joined",
                    serverId: serverId,
                    anonymousId: anonymousId
                ),
            ])

            let noConsent = try await postVisit(
                client,
                "/api/public/servers/visits-join-link/join-as-guest",
                body: "{}",
                authorization: "Bearer noconsent-token"
            )
            #expect(noConsent.status == .ok)
            let joins = directory.rows.filter { $0.event == "public_page_server_joined" }
            #expect(joins.count == 2)
            #expect(joins[1].hasVisitorId == false)
            #expect(joins[1].analyticsId == otherAnalytics)
            #expect(directory.visitors.count == 1)

            let silent = try await postVisit(
                client,
                "/api/public/servers/visits-join-link/join-as-guest",
                body: "{\"anonymous_id\":\"\(anonymousId)\"}",
                authorization: "Bearer silent-token"
            )
            #expect(silent.status == .ok)
            #expect(directory.rows.filter { $0.event == "public_page_server_joined" }.count == 2)
            #expect(directory.visitors.count == 1)
        }
    }
}

@Test func publicSelfJoinIsGuestOnlyAndAgreementGated() async throws {
    let directory = PublicVisitDirectory()
    let serverId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    let visitorId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let agreementId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    directory.addServer(
        id: serverId,
        slug: "public-join-target-74",
        name: "Join Target",
        guestJoinEnabled: true,
        guestRolloutEnabled: true
    )
    directory.addUser(PublicVisitUser(id: visitorId, shareUsageData: nil, analyticsId: nil))
    directory.addToken("visitor-token", userId: visitorId)
    directory.setAgreement(
        slug: "public-join-target-74",
        id: agreementId,
        title: "Guest rules",
        bodyMarkdown: "Be kind."
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory,
            emailAccounts: publicServerAuthAccounts([(visitorId, "visitor-token")])
        ))
        try await app.testing { client in
            let anonymous = try await postVisit(
                client,
                "/api/public/servers/public-join-target-74/join-as-guest",
                body: "{}"
            )
            #expect(anonymous.status == .unauthorized)
            #expect(directory.serverMemberRole(slug: "public-join-target-74", userId: visitorId) == nil)

            let needsAgreement = try await postVisit(
                client,
                "/api/public/servers/public-join-target-74/join-as-guest",
                body: "{}",
                authorization: "Bearer visitor-token"
            )
            #expect(needsAgreement.status == .conflict)
            let refused = try JSONSerialization.jsonObject(with: Data(bodyText(needsAgreement).utf8)) as? [String: Any]
            #expect(refused?["error"] as? String == "agreement_required")
            let agreement = refused?["agreement"] as? [String: Any]
            #expect(agreement?["id"] as? String == agreementId)
            #expect(directory.serverMemberRole(slug: "public-join-target-74", userId: visitorId) == nil)

            let widened = try await postVisit(
                client,
                "/api/public/servers/public-join-target-74/join-as-guest",
                body: "{\"agreementId\":\"\(agreementId)\",\"role\":\"member\",\"source\":\"invite\"}",
                authorization: "Bearer visitor-token"
            )
            #expect(widened.status == .ok)
            let first = try JSONSerialization.jsonObject(with: Data(bodyText(widened).utf8)) as? [String: Any]
            #expect(first?["role"] as? String == "guest")
            #expect((first?["joined"] as? NSNumber)?.boolValue == true || first?["joined"] as? Bool == true)

            let again = try await postVisit(
                client,
                "/api/public/servers/public-join-target-74/join-as-guest",
                body: "{\"agreementId\":\"\(agreementId)\"}",
                authorization: "Bearer visitor-token"
            )
            #expect(again.status == .ok)
            let second = try JSONSerialization.jsonObject(with: Data(bodyText(again).utf8)) as? [String: Any]
            #expect(second?["role"] as? String == "guest")
            #expect((second?["joined"] as? NSNumber)?.boolValue == false || second?["joined"] as? Bool == false)
            #expect(directory.serverMemberRole(slug: "public-join-target-74", userId: visitorId) == "guest")
            #expect(directory.joinAudits(slug: "public-join-target-74") == [
                PublicJoinAudit(source: "join", agreementId: agreementId, subjectId: visitorId),
            ])
        }
    }
}

@Test func publicSelfJoinRechecksEveryGateBeforeMembership() async throws {
    let directory = PublicVisitDirectory()
    let visitorId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    directory.addServer(
        id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        slug: "public-closed-join-74",
        name: "Closed Join",
        guestJoinEnabled: false,
        guestRolloutEnabled: true
    )
    directory.addUser(PublicVisitUser(id: visitorId, shareUsageData: nil, analyticsId: nil))
    directory.addToken("visitor-token", userId: visitorId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory,
            emailAccounts: publicServerAuthAccounts([(visitorId, "visitor-token")])
        ))
        try await app.testing { client in
            let missing = try await postVisit(
                client,
                "/api/public/servers/does-not-exist/join-as-guest",
                body: "{}",
                authorization: "Bearer visitor-token"
            )
            let refused = try await postVisit(
                client,
                "/api/public/servers/public-closed-join-74/join-as-guest",
                body: "{}",
                authorization: "Bearer visitor-token"
            )
            #expect(refused.status == .notFound)
            #expect(bodyText(refused) == bodyText(missing))
            #expect(directory.serverMemberRole(slug: "public-closed-join-74", userId: visitorId) == nil)

            directory.setServerCard(slug: "public-closed-join-74", guestJoinEnabled: true, guestRolloutEnabled: false)
            let guestFlagClosed = try await postVisit(
                client,
                "/api/public/servers/public-closed-join-74/join-as-guest",
                body: "{}",
                authorization: "Bearer visitor-token"
            )
            #expect(guestFlagClosed.status == .notFound)
            #expect(bodyText(guestFlagClosed) == bodyText(missing))

            directory.setServerCard(slug: "public-closed-join-74", guestRolloutEnabled: true)
            directory.setPublicEnabled(slug: "public-closed-join-74", enabled: false)
            let publicFlagClosed = try await postVisit(
                client,
                "/api/public/servers/public-closed-join-74/join-as-guest",
                body: "{}",
                authorization: "Bearer visitor-token"
            )
            #expect(publicFlagClosed.status == .notFound)
            #expect(bodyText(publicFlagClosed) == bodyText(missing))
            #expect(directory.serverMemberRole(slug: "public-closed-join-74", userId: visitorId) == nil)
        }
    }
}
