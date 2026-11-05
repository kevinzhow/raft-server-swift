import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func psSend(_ client: any Client, _ method: HTTPRequest.Method, _ path: String, token: String?, body: String = "{}") async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func psBody(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func psSeed(_ rollout: Bool = true, guestRollout: Bool = true, publicVisible: Bool = false) -> PublicServerDirectory {
    let directory = PublicServerDirectory(rolloutEnabled: rollout, guestRolloutEnabled: guestRollout)
    _ = directory.addServer(
        id: "srv",
        name: "Settings",
        slug: "settings",
        ownerId: "owner",
        ownerToken: "owner-token",
        adminId: "admin",
        adminToken: "admin-token",
        publiclyVisible: publicVisible,
        channels: [(id: "open", name: "open", description: nil, guestVisible: true, publicId: nil, threads: [])]
    )
    return directory
}

@Test func publicRolloutOffFailsClosedAtOwnerAndAnonymousBoundaries() async throws {
    let directory = psSeed(false, publicVisible: true)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicServerDirectory: directory))
        try await app.testing { client in
            let ownerRead = try await psSend(client, .get, "/api/servers/srv/public-visibility", token: "owner-token")
            #expect(ownerRead.status == .notFound)
            let ownerWrite = try await psSend(client, .patch, "/api/servers/srv/public-visibility", token: "owner-token", body: "{\"publiclyVisible\":false}")
            #expect(ownerWrite.status == .notFound)
            let anonymous = try await psSend(client, .get, "/api/public/servers/settings", token: nil)
            let missing = try await psSend(client, .get, "/api/public/servers/does-not-exist", token: nil)
            #expect(anonymous.status == .notFound)
            #expect(anonymous.body.string == missing.body.string)
        }
    }
}

@Test func publicVisibilityIsOwnerOnlyAndExposesTheChannelList() async throws {
    let directory = psSeed(publicVisible: false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicServerDirectory: directory))
        try await app.testing { client in
            for method in [HTTPRequest.Method.get, .patch] {
                let denied = try await psSend(client, method, "/api/servers/srv/public-visibility", token: "admin-token", body: "{\"publiclyVisible\":true}")
                #expect(denied.status == .forbidden, Comment(rawValue: "\(method)"))
            }
            let read = try await psSend(client, .get, "/api/servers/srv/public-visibility", token: "owner-token")
            #expect(read.status == .ok)
            let state = psBody(read)
            #expect(state["publiclyVisible"] as? Bool == false)
            let exposed = state["exposedChannels"] as? [[String: Any]] ?? []
            #expect(exposed.compactMap { $0["id"] as? String } == ["open"])

            let published = try await psSend(client, .patch, "/api/servers/srv/public-visibility", token: "owner-token", body: "{\"publiclyVisible\":true}")
            #expect(published.status == .ok)
            let card = try await psSend(client, .get, "/api/public/servers/settings", token: nil)
            #expect(card.status == .ok)
        }
    }
}

@Test func publicGuestAdmissionIsOwnerOnlyAndClearedWhenPublicTurnsOff() async throws {
    let directory = psSeed(publicVisible: false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicServerDirectory: directory))
        try await app.testing { client in
            let before = try await psSend(client, .patch, "/api/servers/srv/public-guest-join", token: "owner-token", body: "{\"publicGuestJoinEnabled\":true}")
            #expect(before.status == .conflict)
            let admin = try await psSend(client, .patch, "/api/servers/srv/public-guest-join", token: "admin-token", body: "{\"publicGuestJoinEnabled\":true}")
            #expect(admin.status == .forbidden)
            _ = try await psSend(client, .patch, "/api/servers/srv/public-visibility", token: "owner-token", body: "{\"publiclyVisible\":true}")
            let opened = try await psSend(client, .patch, "/api/servers/srv/public-guest-join", token: "owner-token", body: "{\"publicGuestJoinEnabled\":true}")
            #expect(opened.status == .ok)
            _ = try await psSend(client, .patch, "/api/servers/srv/public-visibility", token: "owner-token", body: "{\"publiclyVisible\":false}")
            let read = try await psSend(client, .get, "/api/servers/srv/public-visibility", token: "owner-token")
            let state = psBody(read)
            #expect(state["publiclyVisible"] as? Bool == false)
            #expect(state["publicGuestJoinEnabled"] as? Bool == false)
        }
    }
}

@Test func independentGuestEmailInviteSurvivesClosedPublicAdmission() async throws {
    let directory = psSeed(publicVisible: false)
    directory.addEmailInvite(serverId: "srv", email: "invitee@slock.test", role: "guest", rawToken: "invite-token", expiresAt: Date().addingTimeInterval(3600))
    directory.addAccount(id: "invitee", email: "invitee@slock.test", token: "invitee-token")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicServerDirectory: directory))
        try await app.testing { client in
            let accepted = try await psSend(client, .post, "/api/auth/accept-invite", token: "invitee-token", body: "{\"token\":\"invite-token\"}")
            #expect(accepted.status == .ok)
            #expect(directory.memberRole(serverId: "srv", userId: "invitee") == "guest")
        }
    }
}

@Test func memberServerListReportsPublicPageLiveGate() async throws {
    let visits = PublicVisitDirectory()
    visits.addServer(id: "srv", slug: "settings", publiclyVisible: true, publicEnabled: false, memberIds: ["owner"], guestChannelIds: ["open"])
    visits.addServer(id: "srv2", slug: "other", publiclyVisible: true, publicEnabled: true, memberIds: ["owner"], guestChannelIds: ["open"])
    visits.addUser(PublicVisitUser(id: "owner", shareUsageData: nil, analyticsId: nil))
    visits.addToken("owner-token", userId: "owner")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, publicVisits: visits))
        try await app.testing { client in
            let response = try await psSend(client, .get, "/api/servers", token: "owner-token")
            #expect(response.status == .ok)
            let rows = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [[String: Any]] ?? []
            let bySlug = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Bool)? in
                guard let slug = row["slug"] as? String, let live = row["publicPageLive"] as? Bool else { return nil }
                return (slug, live)
            })
            #expect(bySlug["settings"] == false)
            #expect(bySlug["other"] == true)
        }
    }
}
