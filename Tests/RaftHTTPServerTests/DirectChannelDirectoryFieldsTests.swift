import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Published-path regressions for the DM directory and the channel rows a cold
/// DM/channel load reads.
///
/// The pinned official Web computes the DM document title with
/// `(peerDisplayName || peerName || name).trim()`. A row without any of those
/// keys crashes the whole app shell, so these tests assert the upstream
/// `listDMChannels` row shape and the client expression directly over HTTP.

private struct DMDirectoryFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111761"
    let peerId = "11111111-1111-4111-8111-111111111762"
    let serverId = "33333333-3333-4333-8333-333333333761"
    let agentId: String
    let emptyAgentId: String

    init() {
        for (id, email, avatar) in [
            (ownerId, "dm-dir-owner@slock.test", nil),
            (peerId, "dm-dir-peer@slock.test", "https://cdn.slock.test/peer.png"),
        ] {
            accounts.addAccount(id: id, email: email, password: "password123", avatarUrl: avatar)
            accounts.markEmailVerified(userId: id)
        }
        accounts.setAccountProfileForTesting(id: peerId, name: "peer-user", displayName: "Peer Display")
        accounts.oauth.addOwnedServer(id: serverId, slug: "dm-dir", name: "DM Directory", ownerId: ownerId)
        accounts.oauth.addMember(serverId: serverId, userId: peerId, role: "member")
        agentId = accounts.oauth.createAgent(
            serverId: serverId,
            name: "atlas-agent",
            displayName: "Atlas Display",
            avatarUrl: "https://cdn.slock.test/atlas.png",
            description: "Atlas peer description",
            creatorUserId: ownerId,
            runtime: "codex"
        )
        emptyAgentId = accounts.oauth.createAgent(
            serverId: serverId,
            name: "empty-agent",
            creatorUserId: ownerId,
            runtime: "codex"
        )
    }

    func headers() -> HTTPFields {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
        fields[.contentType] = "application/json"
        fields[HTTPField.Name("X-Server-Id")!] = serverId
        return fields
    }

    func directChannel(peerId: String, agent: Bool) -> String {
        accounts.oauth.createDirectChannel(
            serverId: serverId,
            firstUserId: ownerId,
            secondUserId: peerId,
            secondKind: agent ? .agent : .human
        )
    }
}

/// Top-level `{...}` texts of a JSON array, in wire order. Row objects nest
/// (`readState`), so this scans braces and string escapes instead of splitting.
private func topLevelObjectTexts(_ arrayText: String) -> [String] {
    var objects: [String] = []
    var depth = 0
    var inString = false
    var escaped = false
    var start: String.Index?
    for index in arrayText.indices {
        let character = arrayText[index]
        if inString {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
            continue
        }
        switch character {
        case "\"":
            inString = true
        case "{":
            if depth == 0 { start = index }
            depth += 1
        case "}":
            depth -= 1
            if depth == 0, let start {
                objects.append(String(arrayText[start...index]))
            }
        default:
            break
        }
    }
    return objects
}

private func jsonObject(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

/// One row of an array body, addressed by `id`, plus its parsed object.
private func rowsById(_ body: String) -> [String: (text: String, object: [String: Any])] {
    var rows: [String: (text: String, object: [String: Any])] = [:]
    for text in topLevelObjectTexts(body) {
        let object = jsonObject(text)
        guard let id = object["id"] as? String else { continue }
        rows[id] = (text, object)
    }
    return rows
}

private func replaceCreatedAt(_ rowText: String, object: [String: Any]) -> String {
    guard let createdAt = object["createdAt"] as? String else { return rowText }
    return rowText.replacingOccurrences(
        of: "\"createdAt\":\"\(createdAt)\"",
        with: "\"createdAt\":\"<createdAt>\""
    )
}

private func isISOFractional(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil && value.hasSuffix("Z")
}

/// The pinned client expression: `(peerDisplayName || peerName || name).trim()`.
/// JavaScript `||` treats an empty string as absent, so mirror that here.
private func clientTitleLabel(_ row: [String: Any]) -> String? {
    func truthy(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
    return (truthy(row["peerDisplayName"]) ?? truthy(row["peerName"]) ?? truthy(row["name"]))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func dmDirectoryPublishesTheUpstreamRowShape() async throws {
    let f = DMDirectoryFixture()
    let agentDm = f.directChannel(peerId: f.agentId, agent: true)
    let userDm = f.directChannel(peerId: f.peerId, agent: false)
    let selfDm = f.directChannel(peerId: f.ownerId, agent: false)
    let emptyDm = f.directChannel(peerId: f.emptyAgentId, agent: true)
    f.accounts.addChannelMessageForTesting(
        channelId: agentDm, content: "from the agent", senderId: f.agentId,
        createdAt: Date(timeIntervalSince1970: 1_767_398_400), senderType: "agent"
    )
    f.accounts.addChannelMessageForTesting(
        channelId: userDm, content: "from the peer", senderId: f.peerId,
        createdAt: Date(timeIntervalSince1970: 1_767_312_000)
    )
    f.accounts.addChannelMessageForTesting(
        channelId: selfDm, content: "a system notice", senderId: "system",
        createdAt: Date(timeIntervalSince1970: 1_767_225_600), messageType: "system"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/channels/dm"), headers: f.headers())
            #expect(response.status == .ok)
            let body = try #require(response.body.string)
            let rows = rowsById(body)
            #expect(rows.count == 4)

            let agentRow = try #require(rows[agentDm])
            #expect(replaceCreatedAt(agentRow.text, object: agentRow.object) == #"""
            {"id":"\#(agentDm)","name":"","type":"dm","description":null,"createdAt":"<createdAt>","peerId":"\#(f.agentId)","peerName":"atlas-agent","peerDisplayName":"Atlas Display","peerDescription":"Atlas peer description","peerAvatarUrl":"https://cdn.slock.test/atlas.png","peerGravatarHash":null,"peerType":"agent","activityMuted":false,"muteFromSeq":null,"prefsVersion":0,"activityMuteSupported":false,"collapseLongMessages":true,"displayPrefsVersion":0,"maxReadSeq":0,"readStateVersion":0,"readState":{"kind":"absent"},"lastMessageAt":"2026-01-03T00:00:00.000Z","lastMessagePreview":"from the agent","lastMessageSenderName":"Atlas Display"}
            """#)
            let agentCreatedAt = try #require(agentRow.object["createdAt"] as? String)
            #expect(isISOFractional(agentCreatedAt))
            #expect(agentRow.object["joined"] == nil, "the DM row is not a channel-list row")
            let agentLastMessageAt = try #require(agentRow.object["lastMessageAt"] as? String)
            #expect(isISOFractional(agentLastMessageAt))

            let userRow = try #require(rows[userDm])
            #expect(replaceCreatedAt(userRow.text, object: userRow.object) == #"""
            {"id":"\#(userDm)","name":"","type":"dm","description":null,"createdAt":"<createdAt>","peerId":"\#(f.peerId)","peerName":"peer-user","peerDisplayName":"Peer Display","peerDescription":null,"peerAvatarUrl":"https://cdn.slock.test/peer.png","peerGravatarHash":"09b1e1fea8789d1de25d3337b4887f47d396b8c851e4be213cb67702c968be20","peerType":"user","activityMuted":false,"muteFromSeq":null,"prefsVersion":0,"activityMuteSupported":false,"collapseLongMessages":true,"displayPrefsVersion":0,"maxReadSeq":0,"readStateVersion":0,"readState":{"kind":"absent"},"lastMessageAt":"2026-01-02T00:00:00.000Z","lastMessagePreview":"from the peer","lastMessageSenderName":"Peer Display"}
            """#)

            let selfRow = try #require(rows[selfDm])
            #expect(selfRow.object["peerType"] as? String == "user", "upstream publishes self DMs as user peers")
            #expect(selfRow.object["peerId"] as? String == f.ownerId)
            #expect(selfRow.object["peerName"] as? String == "dm-dir-owner")
            #expect(selfRow.object["peerDisplayName"] is NSNull)
            #expect(selfRow.object["peerAvatarUrl"] is NSNull)
            #expect(selfRow.object["peerGravatarHash"] as? String
                == "c6b4fbe15c796f4b4f5c153514250311637df225a68217e7734664998c3f86a8")
            #expect(selfRow.object["lastMessagePreview"] as? String == "a system notice")
            #expect(selfRow.object["lastMessageSenderName"] is NSNull)

            let emptyRow = try #require(rows[emptyDm])
            #expect(emptyRow.object["peerName"] as? String == "empty-agent")
            #expect(emptyRow.object["peerDisplayName"] as? String == "empty-agent")
            #expect(emptyRow.object["lastMessageAt"] is NSNull)
            #expect(emptyRow.object["lastMessagePreview"] is NSNull)
            #expect(emptyRow.object["lastMessageSenderName"] is NSNull)

            // Upstream orders DMs by most recent message, then by creation for
            // DMs that have none.
            let orderedIds = topLevelObjectTexts(body).compactMap { jsonObject($0)["id"] as? String }
            #expect(orderedIds == [agentDm, userDm, selfDm, emptyDm])

            // The pinned client's title expression must stay total for every row.
            for (id, row) in rows {
                #expect(clientTitleLabel(row.object)?.isEmpty == false, "row \(id) has no usable DM label")
            }
        }
    }
}

@Test func dmLastMessagePreviewMatchesTheUpstreamNormalization() async throws {
    let f = DMDirectoryFixture()
    let dm = f.directChannel(peerId: f.agentId, agent: true)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            func row() async throws -> [String: Any] {
                let response = try await client.get(URI(string: "/api/channels/dm"), headers: f.headers())
                #expect(response.status == .ok)
                let body = try #require(response.body.string)
                return try #require(rowsById(body)[dm]?.object)
            }

            f.accounts.addChannelMessageForTesting(
                channelId: dm, content: "  alpha\n\nbeta\t ", senderId: f.agentId, senderType: "agent"
            )
            #expect(try await row()["lastMessagePreview"] as? String == "alpha beta")

            let long = String(repeating: "x", count: 141)
            f.accounts.addChannelMessageForTesting(
                channelId: dm, content: long, senderId: f.agentId, senderType: "agent"
            )
            #expect(try await row()["lastMessagePreview"] as? String
                == String(repeating: "x", count: 139) + "…")

            f.accounts.addChannelMessageForTesting(
                channelId: dm, content: " \n\t  ", senderId: f.agentId, senderType: "agent"
            )
            let blank = try await row()
            #expect(blank["lastMessagePreview"] is NSNull)
            #expect(blank["lastMessageSenderName"] as? String == "Atlas Display")
        }
    }
}

@Test func dmCreatePublishesTheUpstreamChannelRow() async throws {
    let f = DMDirectoryFixture()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            func create(_ body: String) async throws -> (text: String, object: [String: Any]) {
                let response = try await client.send(.post, headers: f.headers(), to: "/api/channels/dm") { request in
                    request.body = .init(string: body)
                }
                #expect(response.status == .ok)
                let text = try #require(response.body.string)
                return (text, jsonObject(text))
            }

            let agent = try await create("{\"agentId\":\"\(f.agentId)\"}")
            let agentDmId = try #require(agent.object["id"] as? String)
            #expect(replaceCreatedAt(agent.text, object: agent.object) == #"""
            {"id":"\#(agentDmId)","name":"","type":"dm","description":null,"createdAt":"<createdAt>","peerId":"\#(f.agentId)","peerName":"atlas-agent","peerDisplayName":"Atlas Display","peerDescription":"Atlas peer description","peerGravatarHash":null,"peerAvatarUrl":"https://cdn.slock.test/atlas.png","peerType":"agent"}
            """#)
            #expect(agent.object["joined"] == nil)
            #expect(agent.object["activityMuteSupported"] == nil, "the create route publishes the DM row, not a capability stub")

            let user = try await create("{\"userId\":\"\(f.peerId)\"}")
            let userDmId = try #require(user.object["id"] as? String)
            #expect(replaceCreatedAt(user.text, object: user.object) == #"""
            {"id":"\#(userDmId)","name":"","type":"dm","description":null,"createdAt":"<createdAt>","peerType":"user","peerId":"\#(f.peerId)","peerName":"peer-user","peerDisplayName":"Peer Display","peerDescription":null,"peerAvatarUrl":"https://cdn.slock.test/peer.png","peerGravatarHash":"09b1e1fea8789d1de25d3337b4887f47d396b8c851e4be213cb67702c968be20"}
            """#)

            let selfCreated = try await create("{\"userId\":\"\(f.ownerId)\"}")
            #expect(selfCreated.object["peerType"] as? String == "user")
            #expect(selfCreated.object["peerId"] as? String == f.ownerId)
            #expect(selfCreated.object["peerName"] as? String == "dm-dir-owner")
        }
    }
}

@Test func dmDetailPublishesThePeerFieldsAndChannelRowFacts() async throws {
    let f = DMDirectoryFixture()
    let agentDm = f.directChannel(peerId: f.agentId, agent: true)
    let userDm = f.directChannel(peerId: f.peerId, agent: false)
    let selfDm = f.directChannel(peerId: f.ownerId, agent: false)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            func detail(_ channelId: String) async throws -> (text: String, object: [String: Any]) {
                let response = try await client.get(URI(string: "/api/channels/\(channelId)"), headers: f.headers())
                #expect(response.status == .ok)
                let text = try #require(response.body.string)
                return (text, jsonObject(text))
            }

            let agent = try await detail(agentDm)
            let agentCreatedAt = try #require(agent.object["createdAt"] as? String)
            #expect(isISOFractional(agentCreatedAt))
            #expect(agent.object["serverId"] as? String == f.serverId)
            #expect(agent.object["description"] is NSNull)
            #expect(agent.object["peerName"] as? String == "atlas-agent")
            #expect(agent.object["peerDisplayName"] as? String == "Atlas Display")
            #expect(agent.object["peerDescription"] as? String == "Atlas peer description")
            #expect(agent.object["peerAvatarUrl"] as? String == "https://cdn.slock.test/atlas.png")
            #expect(agent.object["peerGravatarHash"] is NSNull)
            #expect(agent.object["peerType"] as? String == "agent")
            #expect(agent.object["readState"] as? [String: Any] != nil)
            let agentPrefix = #"{"id":"\#(agentDm)","serverId":"\#(f.serverId)","name":"","description":null,"type":"dm","createdAt":"\#(agentCreatedAt)","peerId":"\#(f.agentId)","peerName":"atlas-agent","peerDisplayName":"Atlas Display","peerDescription":"Atlas peer description","peerGravatarHash":null,"peerAvatarUrl":"https://cdn.slock.test/atlas.png","peerType":"agent","joined":true,"#
            #expect(agent.text.hasPrefix(agentPrefix), Comment(rawValue: agent.text))

            let user = try await detail(userDm)
            #expect(user.object["peerType"] as? String == "user", "the user-DM peer type is `user`, not `human`")
            #expect(user.object["peerName"] as? String == "peer-user")
            #expect(user.object["peerDisplayName"] as? String == "Peer Display")
            #expect(user.object["peerGravatarHash"] as? String
                == "09b1e1fea8789d1de25d3337b4887f47d396b8c851e4be213cb67702c968be20")

            let selfRow = try await detail(selfDm)
            #expect(selfRow.object["peerType"] as? String == "user")
            #expect(selfRow.object["peerId"] as? String == f.ownerId)
            #expect(selfRow.object["peerName"] as? String == "dm-dir-owner")
            #expect(selfRow.object["peerDisplayName"] is NSNull)
        }
    }
}

@Test func channelListPublishesChannelRowFactsAndExcludesNonListableRows() async throws {
    let f = DMDirectoryFixture()
    let regular = f.accounts.oauth.createChannel(serverId: f.serverId, name: "directory-room", creatorUserId: f.ownerId)
    let privateChannel = f.accounts.oauth.createChannel(
        serverId: f.serverId, name: "directory-private", creatorUserId: f.ownerId, type: "private"
    )
    f.accounts.oauth.addChannelHuman(channelId: privateChannel, userId: f.ownerId)
    let threadParent = f.accounts.oauth.createChannel(serverId: f.serverId, name: "thread-parent", creatorUserId: f.ownerId)
    let parentMessage = f.accounts.addChannelMessageForTesting(
        channelId: threadParent, content: "thread parent", senderId: f.ownerId
    )
    let thread = f.accounts.oauth.createThreadChannel(parentChannelId: threadParent, parentMessageId: parentMessage)
    _ = f.directChannel(peerId: f.peerId, agent: false)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let response = try await client.get(URI(string: "/api/channels"), headers: f.headers())
            #expect(response.status == .ok)
            let body = try #require(response.body.string)
            let rows = rowsById(body)
            #expect(rows[thread] == nil, "GET /api/channels never lists threads")
            #expect(rows.values.allSatisfy { ($0.object["type"] as? String) != "dm" }, "GET /api/channels never lists DMs")

            let row = try #require(rows[regular])
            #expect(row.object["serverId"] as? String == f.serverId)
            #expect(row.object["description"] is NSNull)
            let rowCreatedAt = try #require(row.object["createdAt"] as? String)
            #expect(isISOFractional(rowCreatedAt))
            #expect(row.object["activityMuteSupported"] as? Bool == true)
            #expect((row.object["readState"] as? [String: Any])?["kind"] as? String == "absent")
            #expect(row.object["maxReadSeq"] as? Int == 0)
            #expect(row.object["readStateVersion"] as? Int == 0)
            let expected = #"""
            {"id":"\#(regular)","serverId":"\#(f.serverId)","name":"directory-room","description":null,"type":"channel","createdAt":"<createdAt>","archivedAt":null,"joined":true,"activityMuted":false,"muteFromSeq":null,"prefsVersion":0,"activityMuteSupported":true,"collapseLongMessages":true,"displayPrefsVersion":0,"maxReadSeq":0,"readStateVersion":0,"readState":{"kind":"absent"},"lastMessageAt":null,"channelRole":"member","channelAdminBasis":"server_role","channelCapabilities":{"editChannelMetadata":true,"archiveChannels":true,"addChannelMembers":true,"removeChannelMembers":true,"changeChannelMemberRoles":true,"manageGuestAccess":true,"deleteChannels":true,"changeChannelVisibility":true,"federateChannels":true},"channelAuthorityRevision":1}
            """#
            #expect(replaceCreatedAt(row.text, object: row.object) == expected)

            let privateRow = try #require(rows[privateChannel])
            #expect(privateRow.object["activityMuteSupported"] as? Bool == true,
                "private channels support activity mute upstream")
        }
    }
}
