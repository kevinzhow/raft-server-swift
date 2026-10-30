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

private func send(
    _ client: any Client,
    _ method: HTTPRequest.Method,
    _ path: String,
    token: String?,
    body: String
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func isoTime(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? .distantPast
}

@Test func ownerSearchSwitchBackfillsPublicIdsAndRejectsAdmins() async throws {
    let directory = PublicServerDirectory()
    _ = directory.addServer(
        id: "settings",
        name: "Settings",
        slug: "seo-settings",
        ownerId: "owner",
        ownerToken: "owner-token",
        adminId: "admin",
        adminToken: "admin-token",
        channels: [
            (id: "older", name: "older", description: nil, guestVisible: true, publicId: nil, threads: [
                (id: "thread", publicId: nil, parent: "Older question", replies: []),
            ]),
        ]
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicServerDirectory: directory
        ))
        try await app.testing { client in
            let goPublic = try await send(client, .patch, "/api/servers/settings/public-visibility", token: "owner-token", body: "{\"publiclyVisible\":true}")
            #expect(goPublic.status == .ok)
            let published = try JSONSerialization.jsonObject(with: Data(bodyText(goPublic).utf8)) as? [String: Any]
            #expect((published?["publicSearchEnabled"] as? NSNumber)?.boolValue == true)
            let ids = directory.publicIds(serverId: "settings")
            #expect(ids.count == 2)
            #expect(ids.allSatisfy { $0.wholeMatch(of: /^[0-9a-f]{32}$/) != nil })

            let adminWrite = try await send(client, .patch, "/api/servers/settings/public-search", token: "admin-token", body: "{\"publicSearchEnabled\":false}")
            #expect(adminWrite.status == .forbidden)

            let badBody = try await send(client, .patch, "/api/servers/settings/public-search", token: "owner-token", body: "{\"publicSearchEnabled\":\"no\"}")
            #expect(badBody.status == .badRequest)

            let ownerWrite = try await send(client, .patch, "/api/servers/settings/public-search", token: "owner-token", body: "{\"publicSearchEnabled\":false}")
            #expect(ownerWrite.status == .ok)
            let read = try await client.get("/api/servers/settings/public-visibility", headers: [.authorization: "Bearer owner-token"])
            let visibility = try JSONSerialization.jsonObject(with: Data(bodyText(read).utf8)) as? [String: Any]
            #expect((visibility?["publicSearchEnabled"] as? NSNumber)?.boolValue == false)

            directory.rolloutEnabled = false
            let gated = try await send(client, .patch, "/api/servers/settings/public-search", token: "owner-token", body: "{\"publicSearchEnabled\":true}")
            #expect(gated.status == .notFound)
        }
    }
}

@Test func onlyTheOwnerCanFlipPublicVisibility() async throws {
    let directory = PublicServerDirectory()
    _ = directory.addServer(
        id: "toggle",
        name: "Toggle",
        slug: "public-toggle-70",
        ownerId: "owner",
        ownerToken: "owner-token",
        adminId: "admin",
        adminToken: "admin-token",
        channels: [
            (id: "open", name: "open", description: nil, guestVisible: true, publicId: nil, threads: []),
        ]
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicServerDirectory: directory
        ))
        try await app.testing { client in
            let adminRead = try await client.get("/api/servers/toggle/public-visibility", headers: [
                .authorization: "Bearer admin-token",
            ])
            #expect(adminRead.status == .forbidden)
            #expect(bodyText(adminRead) == "{\"error\":\"Only the server owner can manage public visibility\"}")

            let adminWrite = try await send(
                client, .patch, "/api/servers/toggle/public-visibility",
                token: "admin-token", body: "{\"publiclyVisible\":true}"
            )
            #expect(adminWrite.status == .forbidden)
            #expect(bodyText(adminWrite) == "{\"error\":\"Only the server owner can manage public visibility\"}")

            let ownerRead = try await client.get("/api/servers/toggle/public-visibility", headers: [
                .authorization: "Bearer owner-token",
            ])
            #expect(ownerRead.status == .ok)
            let state = try JSONSerialization.jsonObject(with: Data(bodyText(ownerRead).utf8)) as? [String: Any]
            #expect((state?["publiclyVisible"] as? NSNumber)?.boolValue == false)
            let exposed = state?["exposedChannels"] as? [[String: Any]]
            #expect(exposed?.compactMap { $0["id"] as? String } == ["open"])

            let ownerWrite = try await send(
                client, .patch, "/api/servers/toggle/public-visibility",
                token: "owner-token", body: "{\"publiclyVisible\":true}"
            )
            #expect(ownerWrite.status == .ok)

            let anon = try await client.get("/api/public/servers/public-toggle-70")
            #expect(anon.status == .ok)
            #expect(anon.headers[HTTPField.Name("Cache-Control")!] == "no-store")
        }
    }
}

@Test func publicGuestAdmissionIsOwnerOnlyAndClearsWhenPublicTurnsOff() async throws {
    let directory = PublicServerDirectory()
    _ = directory.addServer(
        id: "join",
        name: "Join Controls",
        slug: "public-join-controls-74",
        ownerId: "owner",
        ownerToken: "owner-token",
        adminId: "admin",
        adminToken: "admin-token"
    )
    directory.setTranslationEnabled(serverId: "join", enabled: true)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicServerDirectory: directory
        ))
        try await app.testing { client in
            let beforePublic = try await send(
                client, .patch, "/api/servers/join/public-guest-join",
                token: "owner-token", body: "{\"publicGuestJoinEnabled\":true}"
            )
            #expect(beforePublic.status == .conflict)
            #expect(bodyText(beforePublic) == "{\"error\":\"Public access must be enabled before visitors can join as Guest\"}")

            let adminAttempt = try await send(
                client, .patch, "/api/servers/join/public-guest-join",
                token: "admin-token", body: "{\"publicGuestJoinEnabled\":true}"
            )
            #expect(adminAttempt.status == .forbidden)
            #expect(bodyText(adminAttempt) == "{\"error\":\"Only the server owner can manage public Guest admission\"}")

            let openedVisibility = try await send(
                client, .patch, "/api/servers/join/public-visibility",
                token: "owner-token", body: "{\"publiclyVisible\":true}"
            )
            #expect(openedVisibility.status == .ok)

            let opened = try await send(
                client, .patch, "/api/servers/join/public-guest-join",
                token: "owner-token", body: "{\"publicGuestJoinEnabled\":true}"
            )
            #expect(opened.status == .ok)

            let publicPage = try await client.get("/api/public/servers/public-join-controls-74")
            #expect(publicPage.status == .ok)
            let card = try JSONSerialization.jsonObject(with: Data(bodyText(publicPage).utf8)) as? [String: Any]
            #expect((card?["canJoinAsGuest"] as? NSNumber)?.boolValue == true || card?["canJoinAsGuest"] as? Bool == true)
            let server = card?["server"] as? [String: Any]
            #expect((server?["translationEnabled"] as? NSNumber)?.boolValue == true || server?["translationEnabled"] as? Bool == true)
            #expect(card?["translationAvailable"] is NSNumber || card?["translationAvailable"] is Bool)

            let closed = try await send(
                client, .patch, "/api/servers/join/public-visibility",
                token: "owner-token", body: "{\"publiclyVisible\":false}"
            )
            #expect(closed.status == .ok)
            let closedBody = try JSONSerialization.jsonObject(with: Data(bodyText(closed).utf8)) as? [String: Any]
            #expect((closedBody?["publicGuestJoinEnabled"] as? NSNumber)?.boolValue == false || closedBody?["publicGuestJoinEnabled"] as? Bool == false)
            #expect((closedBody?["publiclyVisible"] as? NSNumber)?.boolValue == false || closedBody?["publiclyVisible"] as? Bool == false)
        }
    }
}

@Test func aGuestEmailInviteStaysIndependentOfPublicAdmission() async throws {
    let directory = PublicServerDirectory()
    let inviteeId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let rawToken = "public-task-74-source-specific-guest-invite"
    _ = directory.addServer(
        id: "invite",
        name: "Invite Source",
        slug: "invite-source-74",
        ownerId: "owner",
        ownerToken: "owner-token"
    )
    directory.addAccount(id: inviteeId, email: "source-invite-guest@slock.test", token: "invitee-token")
    directory.addEmailInvite(
        serverId: "invite",
        email: "source-invite-guest@slock.test",
        role: "guest",
        rawToken: rawToken,
        expiresAt: Date().addingTimeInterval(60)
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicServerDirectory: directory
        ))
        try await app.testing { client in
            let before = try await client.get("/api/servers/invite/public-visibility", headers: [
                .authorization: "Bearer owner-token",
            ])
            #expect(before.status == .ok)
            let state = try JSONSerialization.jsonObject(with: Data(bodyText(before).utf8)) as? [String: Any]
            #expect((state?["publiclyVisible"] as? NSNumber)?.boolValue == false || state?["publiclyVisible"] as? Bool == false)
            #expect((state?["publicGuestJoinEnabled"] as? NSNumber)?.boolValue == false || state?["publicGuestJoinEnabled"] as? Bool == false)

            let accepted = try await send(
                client, .post, "/api/auth/accept-invite",
                token: "invitee-token",
                body: "{\"token\":\"\(rawToken)\"}"
            )
            #expect(accepted.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(accepted).utf8)) as? [String: Any]
            #expect(body?["serverId"] as? String == "invite")
            #expect(body?["serverName"] as? String == "Invite Source")
            #expect(directory.memberRole(serverId: "invite", userId: inviteeId) == "guest")
            #expect((state?["publiclyVisible"] as? Bool) != true)
        }
    }
}

@Test func rolloutFlagDefaultsClosedAtOwnerAndAnonymousBoundaries() async throws {
    let directory = PublicServerDirectory(rolloutEnabled: false)
    let channelId = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    _ = directory.addServer(
        id: "gated",
        name: "Gated",
        slug: "public-gated-70",
        ownerId: "owner",
        ownerToken: "owner-token",
        publiclyVisible: true,
        channels: [
            (id: channelId, name: "would-be-public", description: nil, guestVisible: true, publicId: nil, threads: []),
        ]
    )
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicServerDirectory: directory
        ))
        try await app.testing { client in
            let ownerRead = try await client.get("/api/servers/gated/public-visibility", headers: [
                .authorization: "Bearer owner-token",
            ])
            #expect(ownerRead.status == .notFound)

            let ownerWrite = try await send(
                client, .patch, "/api/servers/gated/public-visibility",
                token: "owner-token", body: "{\"publiclyVisible\":false}"
            )
            #expect(ownerWrite.status == .notFound)

            let publicList = try await client.get("/api/public/servers/public-gated-70")
            let publicRead = try await client.get("/api/public/servers/public-gated-70/channels/\(channelId)/messages")
            let missing = try await client.get("/api/public/servers/does-not-exist-70")
            #expect(publicList.status == .notFound)
            #expect(publicRead.status == .notFound)
            #expect(bodyText(publicList) == bodyText(missing))

            directory.rolloutEnabled = true
            let after = try await client.get("/api/servers/gated/public-visibility", headers: [
                .authorization: "Bearer owner-token",
            ])
            #expect(after.status == .ok)
            let state = try JSONSerialization.jsonObject(with: Data(bodyText(after).utf8)) as? [String: Any]
            #expect((state?["publiclyVisible"] as? NSNumber)?.boolValue == true || state?["publiclyVisible"] as? Bool == true)
        }
    }
}

@Test func publicSearchLastmodMovesOnlyForRenderedEdits() async throws {
    let directory = PublicServerDirectory()
    let seed = directory.addServer(
        id: "server",
        name: "Server seo-lastmod",
        slug: "seo-lastmod",
        ownerId: "owner",
        ownerToken: "owner-token",
        publiclyVisible: true,
        channels: [
            (id: "open", name: "open-talk", description: "Open to guests", guestVisible: true, publicId: nil, threads: [
                (id: "thread", publicId: nil, parent: "# How do I set up agents?\nSecond line", replies: ["First reply"]),
            ]),
            (id: "hidden", name: "members-only", description: nil, guestVisible: false, publicId: nil, threads: [
                (id: "hidden-thread", publicId: nil, parent: "Members only question", replies: ["Members only reply"]),
            ]),
        ]
    )
    let steps: [(PublicServerDirectory.Edit, Set<String>)] = [
        (.renameChannel(id: "open", name: "open-talk-2"), ["server", "channel", "thread"]),
        (.editChannelDescription(id: "open", description: "New words"), ["server", "channel", "thread"]),
        (.editParent(channelId: "open", content: "# Agents, set up\nSecond line"), ["channel", "thread"]),
        (.editReply(threadId: "thread", content: "First reply, edited"), ["thread"]),
        (.addReply(threadId: "thread", content: "Second reply"), ["channel", "thread"]),
        (.renameServer(id: "server", name: "Renamed"), ["server", "channel", "thread"]),
        (.renamePrivateChannel(id: "hidden", name: "members-only-2"), []),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicServerDirectory: directory
        ))
        try await app.testing { client in
            func lastmods() async throws -> [String: Date] {
                let response = try await client.get("/api/public/search/index")
                let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
                let entries = body?["entries"] as? [[String: Any]] ?? []
                func of(_ type: String, _ pid: String) -> Date {
                    let entry = entries.first { ($0["type"] as? String) == type && (($0["canonicalPath"] as? String)?.contains(pid) == true) }
                    return isoTime(entry?["lastmod"] as? String ?? "")
                }
                return [
                    "server": of("server", seed?.serverPublicId ?? ""),
                    "channel": of("channel", seed?.openPublicId ?? ""),
                    "thread": of("thread", seed?.threadPublicId ?? ""),
                ]
            }
            for (edit, moves) in steps {
                let before = try await lastmods()
                directory.apply(edit)
                let after = try await lastmods()
                for kind in ["server", "channel", "thread"] {
                    if moves.contains(kind) {
                        #expect(after[kind]! > before[kind]!)
                    } else {
                        #expect(after[kind] == before[kind])
                    }
                }
            }
        }
    }
}
