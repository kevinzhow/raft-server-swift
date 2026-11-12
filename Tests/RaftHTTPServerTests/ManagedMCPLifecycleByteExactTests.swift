import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

// Byte-exact bodies and header sets of the managed MCP lifecycle routes after
// they moved onto `ManagedMCPLifecycleService`, `ManagedMCPPushService`,
// `ManagedMCPProviderConnectionsService` and `ManagedMCPOAuthService`.

private struct LifecycleFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001170001"
    let serverId = "33333333-3333-4333-8333-000001170001"
    let secondServerId = "33333333-3333-4333-8333-000001170002"

    init() {
        accounts.addAccount(id: ownerId, email: "lifecycle-exact@slock.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "lifecycle-exact", name: "Lifecycle Exact", ownerId: ownerId)
        accounts.oauth.addOwnedServer(id: secondServerId, slug: "lifecycle-exact-two", name: "Lifecycle Two", ownerId: ownerId)
    }

    func run(_ body: @escaping (Sender, HTTPFields) async throws -> Void) async throws {
        let accounts = self.accounts
        let serverId = self.serverId
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts
            ))
            try await app.testing { client in
                var loginHeaders = HTTPFields()
                loginHeaders[.contentType] = "application/json"
                let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"lifecycle-exact@slock.test\",\"password\":\"password123\"}")
                }
                let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                let sender = Sender { method, headers, path, requestBody in
                    try await client.send(method, headers: headers, to: URI(string: path)) { request in
                        if let requestBody { request.body = .init(string: requestBody) }
                    }
                }
                try await body(sender, headers)
            }
        }
    }
}

/// Wraps the testing client so the helper closure type does not name it.
private struct Sender {
    let perform: (HTTPRequest.Method, HTTPFields, String, String?) async throws -> ClientResponse

    func send(
        _ method: HTTPRequest.Method,
        headers: HTTPFields,
        to path: String,
        body: String? = nil
    ) async throws -> ClientResponse {
        try await perform(method, headers, path, body)
    }
}

private func headerPairs(_ response: ClientResponse) -> [String: String] {
    var pairs: [String: String] = [:]
    for field in response.headers { pairs[field.name.rawName.lowercased()] = field.value }
    return pairs
}

@Test func pushDeliveryStatusBodyAndHeadersAreByteExact() async throws {
    let fixture = LifecycleFixture()
    try await fixture.run { client, headers in
        let response = try await client.send(.get, headers: headers, to: "/api/push/delivery-status?installationId=a-1")
        #expect(response.status == .ok)
        #expect(response.body.string == "{\"servers\":{\"\(fixture.serverId)\":{\"fcmActive\":false},\"\(fixture.secondServerId)\":{\"fcmActive\":false}}}")
        let pairs = headerPairs(response)
        #expect(pairs["x-robots-tag"] == AppFallback.robotsTag)
        #expect(pairs["content-type"] == AppFallback.jsonContentType)
        #expect(pairs["cache-control"] == "private, no-store")
        #expect(pairs["content-length"] == "131")
    }
}

@Test func pushRegistrationAndFamilyRevokeAreByteExact() async throws {
    let fixture = LifecycleFixture()
    try await fixture.run { client, headers in
        let registered = try await client.send(
            .post, headers: headers, to: "/api/push/registrations",
            body: "{\"installationId\":\"ios-exact-1\",\"provider\":\"apns\",\"env\":\"sandbox\",\"topic\":\"build.raft.app\",\"deviceToken\":\"tok-1\"}"
        )
        #expect(registered.status == .ok)
        let body = registered.body.string ?? ""
        let prefix = "{\"revoke_capability\":\""
        let suffix = "\",\"registration\":{\"installationId\":\"ios-exact-1\",\"provider\":\"apns\",\"env\":\"sandbox\",\"topic\":\"build.raft.app\"}}"
        #expect(body.hasPrefix(prefix) && body.hasSuffix(suffix))
        let capability = String(body.dropFirst(prefix.count).dropLast(suffix.count))
        #expect(capability.split(separator: ".").count == 2)

        let invalid = try await client.send(
            .post, headers: headers, to: "/api/push/registrations",
            body: "{\"installationId\":\"bad id\",\"provider\":\"apns\"}"
        )
        #expect(invalid.status == .badRequest)
        #expect(invalid.body.string == "{\"error\":\"Invalid push registration\"}")

        let revoked = try await client.send(
            .post, headers: headers, to: "/api/push/family-revoke",
            body: "{\"capability\":\"\(capability)\"}"
        )
        #expect(revoked.status == .noContent)
        #expect(revoked.body.string == nil || revoked.body.string == "")
        let pairs = headerPairs(revoked)
        #expect(pairs["x-robots-tag"] == AppFallback.robotsTag)
        #expect(pairs["content-type"] == AppFallback.jsonContentType)

        let replay = try await client.send(
            .post, headers: headers, to: "/api/push/family-revoke",
            body: "{\"capability\":\"\(capability)\"}"
        )
        #expect(replay.status == .noContent)

        let missing = try await client.send(.post, headers: headers, to: "/api/push/family-revoke", body: "{}")
        #expect(missing.status == .badRequest)
        #expect(missing.body.string == "{\"error\":\"Invalid capability\"}")
        let unknown = try await client.send(
            .post, headers: headers, to: "/api/push/family-revoke",
            body: "{\"capability\":\"abc-def.0123456789\"}"
        )
        #expect(unknown.status == .forbidden)
        #expect(unknown.body.string == "{\"error\":\"Capability is no longer valid\"}")
    }
}

@Test func readMutationBodiesAndFrontierAreByteExact() async throws {
    let fixture = LifecycleFixture()
    let mutationId = "aaaaaaaa-aaaa-4aaa-8aaa-000001170001"
    try await fixture.run { client, headers in
        let invalid = try await client.send(.post, headers: headers, to: "/api/read-mutations", body: "{}")
        #expect(invalid.status == .badRequest)
        #expect(invalid.body.string == "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
        let noKind = try await client.send(
            .post, headers: headers, to: "/api/read-mutations", body: "{\"mutationId\":\"\(mutationId)\"}"
        )
        #expect(noKind.body.string == "{\"error\":\"Invalid mutation payload\",\"code\":\"INVALID_MUTATION_PAYLOAD\"}")

        let admitted = try await client.send(
            .post, headers: headers, to: "/api/read-mutations",
            body: "{\"mutationId\":\"\(mutationId)\",\"kind\":\"global_read_all\"}"
        )
        #expect(admitted.status == .created)
        #expect(admitted.body.string == "{\"outcome\":\"ADMITTED\",\"serverId\":\"\(fixture.serverId)\",\"principalId\":\"\(fixture.ownerId)\",\"authoritySeq\":1,\"mutationId\":\"\(mutationId)\"}")

        let replay = try await client.send(
            .post, headers: headers, to: "/api/read-mutations",
            body: "{\"mutationId\":\"\(mutationId)\",\"kind\":\"global_read_all\"}"
        )
        #expect(replay.status == .ok)
        #expect(replay.body.string == "{\"outcome\":\"ALREADY_ADMITTED\"}")

        let mismatch = try await client.send(
            .post, headers: headers, to: "/api/read-mutations",
            body: "{\"mutationId\":\"\(mutationId)\",\"kind\":\"channel_read_all\"}"
        )
        #expect(mismatch.status == .conflict)
        #expect(mismatch.body.string == "{\"error\":\"Mutation id reused with a different payload\",\"code\":\"MUTATION_ID_PAYLOAD_MISMATCH\"}")

        let frontier = try await client.send(.get, headers: headers, to: "/api/read-mutations/frontier?scopeIds=s1,s2")
        #expect(frontier.status == .ok)
        #expect(frontier.body.string == "{\"nextAuthoritySeq\":2,\"lastTerminalAuthoritySeq\":0,\"snapshotUpperAuthoritySeq\":1,\"items\":[{\"mutationId\":\"\(mutationId)\",\"authoritySeq\":1,\"state\":\"admitted\"}],\"scopes\":[{\"scopeId\":\"s1\",\"maxReadSeq\":0},{\"scopeId\":\"s2\",\"maxReadSeq\":0}]}")
        let bare = try await client.send(.get, headers: headers, to: "/api/read-mutations/frontier")
        #expect(bare.body.string == "{\"nextAuthoritySeq\":2,\"lastTerminalAuthoritySeq\":0,\"snapshotUpperAuthoritySeq\":1,\"items\":[{\"mutationId\":\"\(mutationId)\",\"authoritySeq\":1,\"state\":\"admitted\"}]}")
    }
}

@Test func serverSettingsAndDetailsAreByteExact() async throws {
    let fixture = LifecycleFixture()
    try await fixture.run { client, headers in
        let settings = try await client.send(
            .get, headers: headers, to: "/api/servers/\(fixture.serverId)/product-analytics-settings"
        )
        #expect(settings.body.string == "{\"productAnalyticsEnabled\":true,\"canManageProductAnalytics\":true}")
        let patched = try await client.send(
            .patch, headers: headers, to: "/api/servers/\(fixture.serverId)/product-analytics-settings",
            body: "{\"productAnalyticsEnabled\":false}"
        )
        #expect(patched.body.string == "{\"productAnalyticsEnabled\":false,\"canManageProductAnalytics\":true}")
        let bad = try await client.send(
            .patch, headers: headers, to: "/api/servers/\(fixture.serverId)/product-analytics-settings",
            body: "{\"productAnalyticsEnabled\":\"no\"}"
        )
        #expect(bad.status == .badRequest)
        #expect(bad.body.string == "{\"error\":\"productAnalyticsEnabled must be a boolean\"}")

        let details = try await client.send(.get, headers: headers, to: "/api/servers/\(fixture.serverId)")
        let body = details.body.string ?? ""
        #expect(body.hasPrefix("{\"id\":\"\(fixture.serverId)\",\"ownerId\":\"\(fixture.ownerId)\",\"name\":\"Lifecycle Exact\",\"slug\":\"lifecycle-exact\",\"avatarUrl\":null,\"plan\":\""))
        #expect(body.hasSuffix(",\"publicGuestJoinEnabled\":false}") || body.hasSuffix(",\"publicGuestJoinEnabled\":true}"))

        let created = try await client.send(
            .post, headers: headers, to: "/api/servers", body: "{\"name\":\" Fresh \",\"slug\":\"lifecycle-fresh\"}"
        )
        #expect(created.status == .ok)
        let createdBody = created.body.string ?? ""
        #expect(createdBody.hasPrefix("{\"id\":\""))
        #expect(createdBody.hasSuffix("\",\"name\":\"Fresh\",\"slug\":\"lifecycle-fresh\",\"role\":\"owner\"}"))
        let again = try await client.send(
            .post, headers: headers, to: "/api/servers", body: "{\"name\":\"Fresh\",\"slug\":\"lifecycle-fresh\"}"
        )
        #expect(again.body.string?.hasSuffix("\",\"name\":\"Fresh\",\"slug\":\"lifecycle-fresh\",\"role\":\"owner\"}") == true)
        let short = try await client.send(.post, headers: headers, to: "/api/servers", body: "{\"name\":\"x\",\"slug\":\"abc\"}")
        #expect(short.body.string == "{\"error\":\"Slug must be at least 5 characters\"}")
        let invalid = try await client.send(.post, headers: headers, to: "/api/servers", body: "[1]")
        #expect(invalid.body.string == "{\"error\":\"Invalid server request\"}")
    }
}

@Test func channelCreateAndCollisionAreByteExact() async throws {
    let fixture = LifecycleFixture()
    try await fixture.run { client, headers in
        let created = try await client.send(
            .post, headers: headers, to: "/api/channels", body: "{\"name\":\"exact-room\"}"
        )
        #expect(created.status == .ok)
        let body = created.body.string ?? ""
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        let channelId = try #require(object?["id"] as? String)
        let createdAt = try #require(object?["createdAt"] as? String)
        // channels.ts:1033-1067, complete regular-channel creation envelope.
        let expected = """
        {"id":"\(channelId)","serverId":"\(fixture.serverId)","name":"exact-room","description":null,"type":"channel","guestVisible":false,"guestJoinable":false,"parentMessageId":null,"parentChannelId":null,"createdAt":"\(createdAt)","archivedAt":null,"archivedByUserId":null,"archivedByAgentId":null,"deletedAt":null,"joined":true,"jointChannelId":null,"jointRole":null,"jointPeerServerId":null,"jointPeerServerName":null,"jointPeerServerSlug":null,"jointPeerStatus":null,"jointServers":[],"jointPendingInvites":[],"jointBillingLocked":null,"channelRole":"admin","channelAdminBasis":"both","channelCapabilities":{"editChannelMetadata":true,"archiveChannels":true,"deleteChannels":true,"changeChannelVisibility":true,"manageGuestAccess":true,"federateChannels":true,"addChannelMembers":true,"removeChannelMembers":true,"changeChannelMemberRoles":true},"channelAuthorityRevision":1,"activityMuted":false,"muteFromSeq":null,"prefsVersion":0,"maxReadSeq":0,"readStateVersion":0,"readState":{"kind":"absent"},"activityMuteSupported":true,"jointInvites":[],"jointInvite":null}
        """
        #expect(body == expected)

        let collision = try await client.send(
            .post, headers: headers, to: "/api/channels", body: "{\"name\":\"exact-room\"}"
        )
        #expect(collision.status == .conflict)
        #expect(collision.body.string == "{\"error\":\"A channel named #exact-room already exists\",\"canUnarchiveArchivedChannel\":false}")
        let invalid = try await client.send(.post, headers: headers, to: "/api/channels", body: "{\"name\":\"all\"}")
        #expect(invalid.body.string == "{\"error\":\"Invalid channel\"}")

        let renamed = try await client.send(
            .patch, headers: headers, to: "/api/channels/\(channelId)", body: "{\"description\":\"hello\"}"
        )
        #expect(renamed.body.string == "{\"id\":\"\(channelId)\",\"name\":\"exact-room\",\"description\":\"hello\",\"systemMessageSeq\":null}")
        let visibility = try await client.send(
            .patch, headers: headers, to: "/api/channels/\(channelId)", body: "{\"visibility\":\"private\"}"
        )
        #expect(visibility.body.string == "{\"ok\":true,\"id\":\"\(channelId)\",\"visibility\":\"private\",\"type\":\"private\"}")
        let guest = try await client.send(
            .patch, headers: headers, to: "/api/channels/\(channelId)", body: "{\"guestVisible\":true}"
        )
        #expect(guest.body.string == "{\"ok\":true,\"id\":\"\(channelId)\",\"guestVisible\":true,\"guestJoinable\":false}")
        let notString = try await client.send(
            .patch, headers: headers, to: "/api/channels/\(channelId)", body: "[]"
        )
        #expect(notString.status == .badRequest)
        #expect(notString.body.string == "{\"error\":\"Invalid channel update\"}")

        let settings = try await client.send(
            .get, headers: headers, to: "/api/channels/\(channelId)/notification-settings"
        )
        // The PATCH above converted the channel to `private`, and upstream
        // `channelTypeSupportsActivityMute` includes private channels.
        #expect(settings.body.string == "{\"activityMuted\":false,\"muteFromSeq\":null,\"prefsVersion\":0,\"activityMuteSupported\":true}")
        let unread = try await client.send(.get, headers: headers, to: "/api/channels/unread")
        #expect(unread.body.string == "{}")
        #expect(headerPairs(unread)["cache-control"] == "private, no-store")
        let summary = try await client.send(.get, headers: headers, to: "/api/channels/unread?summary=1")
        #expect(summary.body.string == "{\"channels\":{},\"threadUnread\":{}}")
    }
}
