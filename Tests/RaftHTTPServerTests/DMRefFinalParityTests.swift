import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The remaining DM-ref grammar class, end to end over the published routes:
///
/// - `dm:@reminders` is reserved only as the exact raw peer, case-insensitively,
///   before `~kind` is parsed; `dm:@remindersX` is an ordinary peer and
///   `dm:@reminders~agent` is an agent named reminders
///   (channelService.ts:7467-7471, 7493-7503).
/// - Only a full 8-hex suffix is a thread id (channelService.ts:7256-7275). Any
///   other `:...` stays in the base ref and fails as a channel/peer lookup.
/// - A cross-kind twin publishes `dm:@name~human` / `dm:@name~agent`
///   (channelService.ts:6778-6812).
/// - `channel=dm:@peer` resolves through the same canonical DM rules on both
///   agent search routes; a non-empty unresolvable ref is 404, not a broad page.
/// - `sender=` / `sender=@` are 400 `invalid_member_ref`; an unknown typed-looking
///   handle is the ordinary 404 `member_not_found`, never a broadened search
///   (searchSenderFilterService.ts:36-115).
private struct DMRefFinalFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerId: String
    let humanTwinId: String
    let remindersHumanId: String
    let graceId: String
    let agentTwinId: String
    let soloAgentId: String
    let humanTwinDM: String
    let agentTwinDM: String
    let remindersHumanDM: String
    let soloDM: String
    let remindersSurface: String
    let roomId: String
    let roomName: String
    let roomAnchor: String
    let roomThread: String
    let humanThread: String
    let humanThreadAnchor: String
    let remindersThread: String
    let remindersThreadAnchor: String
    let agentKey: String
    let machineKey: String
    let machineSendKey: String
}

private func makeDMRefFinalFixture() -> DMRefFinalFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001410001"
    let serverSlug = "dm-ref-final"
    let ownerId = "11111111-1111-4111-8111-000001410001"
    let humanTwinId = "11111111-1111-4111-8111-000001410002"
    let remindersHumanId = "11111111-1111-4111-8111-000001410003"
    for (id, email) in [
        (ownerId, "dm-ref-final-owner"),
        (humanTwinId, "dm-ref-final-human-twin"),
        (remindersHumanId, "dm-ref-final-reminders-human"),
    ] {
        accounts.addAccount(id: id, email: "\(email)@slock.test", password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: serverSlug, name: "DM Ref Final", ownerId: ownerId)
    accounts.setAccountProfileForTesting(id: ownerId, name: "Owner")
    accounts.setAccountProfileForTesting(id: humanTwinId, name: "Twin")
    accounts.setAccountProfileForTesting(id: remindersHumanId, name: "remindersX")
    accounts.oauth.addMember(serverId: serverId, userId: humanTwinId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: remindersHumanId, role: "member")
    let grace = accounts.oauth.createAgent(serverId: serverId, name: "Grace", runtime: "claude")
    let agentTwin = accounts.oauth.createAgent(serverId: serverId, name: "Twin", runtime: "claude")
    let solo = accounts.oauth.createAgent(serverId: serverId, name: "Solo", runtime: "claude")

    func dm(peer: String, kind: OAuthLedger.DirectChannelParticipantKind) -> String {
        let channel = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: grace, secondUserId: peer,
            firstKind: .agent, secondKind: kind
        )
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: grace, kind: "dm")
        accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: peer, kind: "dm")
        return channel
    }
    let humanTwinDM = dm(peer: humanTwinId, kind: .human)
    let agentTwinDM = dm(peer: agentTwin, kind: .agent)
    let remindersHumanDM = dm(peer: remindersHumanId, kind: .human)
    let soloDM = dm(peer: solo, kind: .agent)
    _ = accounts.addChannelMessageForTesting(
        channelId: humanTwinDM, content: "humantwin-needle from the human Twin", senderId: humanTwinId
    )
    _ = accounts.addChannelMessageForTesting(
        channelId: agentTwinDM, content: "agenttwin-needle from the agent Twin", senderId: agentTwin
    )
    _ = accounts.addChannelMessageForTesting(
        channelId: remindersHumanDM, content: "remindersx-needle ordinary human peer", senderId: remindersHumanId
    )
    _ = accounts.addChannelMessageForTesting(
        channelId: soloDM, content: "solo-needle from Solo", senderId: solo
    )

    let remindersSurface = accounts.oauth.createChannel(
        serverId: serverId, name: "reminders", creatorUserId: grace, type: "dm"
    )
    accounts.oauth.addChannelAgent(channelId: remindersSurface, agentId: grace)
    accounts.addPostableChannel(
        serverId: serverId, channelId: remindersSurface, memberId: grace, kind: "dm", name: "reminders"
    )
    accounts.setAgentReminderSurfaceForTesting(agentId: grace, channelId: remindersSurface)
    _ = accounts.addChannelMessageForTesting(
        channelId: remindersSurface, content: "reminders-needle private surface", senderId: "system"
    )

    let roomName = "dm-ref-room"
    let roomId = accounts.oauth.createChannel(
        serverId: serverId, name: roomName, creatorUserId: ownerId, type: "channel"
    )
    for member in [ownerId, grace] {
        accounts.addPostableChannel(
            serverId: serverId, channelId: roomId, memberId: member, kind: "channel", name: roomName
        )
    }
    _ = accounts.addChannelMessageForTesting(
        channelId: roomId, content: "room-needle public body", senderId: ownerId
    )
    let roomAnchor = accounts.addChannelMessageForTesting(
        channelId: roomId, content: "room thread parent", senderId: ownerId
    )
    let roomThread = accounts.oauth.createThreadChannel(parentChannelId: roomId, parentMessageId: roomAnchor)
    for member in [ownerId, grace] {
        accounts.addPostableChannel(
            serverId: serverId, channelId: roomThread, memberId: member, kind: "thread",
            parentChannelId: roomId, parentMessageId: roomAnchor, name: "thread"
        )
    }
    _ = accounts.addChannelMessageForTesting(
        channelId: roomThread, content: "roomthread-needle reply", senderId: ownerId
    )

    let humanThreadAnchor = accounts.addChannelMessageForTesting(
        channelId: humanTwinDM, content: "human thread parent", senderId: humanTwinId
    )
    let humanThread = accounts.oauth.createThreadChannel(
        parentChannelId: humanTwinDM, parentMessageId: humanThreadAnchor
    )
    for member in [grace, humanTwinId] {
        accounts.addPostableChannel(
            serverId: serverId, channelId: humanThread, memberId: member, kind: "thread",
            parentChannelId: humanTwinDM, parentMessageId: humanThreadAnchor, name: "thread"
        )
    }
    _ = accounts.addChannelMessageForTesting(
        channelId: humanThread, content: "humantwin-thread-needle reply", senderId: humanTwinId
    )

    let remindersThreadAnchor = accounts.addChannelMessageForTesting(
        channelId: remindersHumanDM, content: "reminders thread parent", senderId: remindersHumanId
    )
    let remindersThread = accounts.oauth.createThreadChannel(
        parentChannelId: remindersHumanDM, parentMessageId: remindersThreadAnchor
    )
    for member in [grace, remindersHumanId] {
        accounts.addPostableChannel(
            serverId: serverId, channelId: remindersThread, memberId: member, kind: "thread",
            parentChannelId: remindersHumanDM, parentMessageId: remindersThreadAnchor, name: "thread"
        )
    }
    _ = accounts.addChannelMessageForTesting(
        channelId: remindersThread, content: "remindersx-thread-needle reply", senderId: remindersHumanId
    )

    return DMRefFinalFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: serverSlug,
        ownerId: ownerId,
        humanTwinId: humanTwinId,
        remindersHumanId: remindersHumanId,
        graceId: grace,
        agentTwinId: agentTwin,
        soloAgentId: solo,
        humanTwinDM: humanTwinDM,
        agentTwinDM: agentTwinDM,
        remindersHumanDM: remindersHumanDM,
        soloDM: soloDM,
        remindersSurface: remindersSurface,
        roomId: roomId,
        roomName: roomName,
        roomAnchor: roomAnchor,
        roomThread: roomThread,
        humanThread: humanThread,
        humanThreadAnchor: humanThreadAnchor,
        remindersThread: remindersThread,
        remindersThreadAnchor: remindersThreadAnchor,
        agentKey: accounts.mintAgentCredential(agentId: grace, scopes: ["send", "read"], name: "dm-ref-final"),
        machineKey: accounts.registerMachineForAgent(serverId: serverId, agentId: grace),
        machineSendKey: accounts.registerMachineForAgent(serverId: serverId, agentId: grace)
    )
}

private func encodedRef(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
}

private func refHistory(
    _ client: any Client, apiKey: String, target: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any], contents: [String]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(
        URI(string: "/internal/agent-api/history?channel=\(encodedRef(target))"), headers: headers
    )
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let contents = (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
    return (response.status, body, contents)
}

private func refSend(
    _ client: any Client, apiKey: String, agentId: String, target: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let payload = "{\"target\":\(OrderedJSONTestValue.string(target)),\"content\":\"ref send body\"}"
    let response = try await client.send(
        .post, headers: headers, to: URI(string: "/internal/agent/\(agentId)/send")
    ) { request in
        request.body = .init(string: payload)
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private enum OrderedJSONTestValue {
    static func string(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let rendered = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(rendered.dropFirst().dropLast())
    }
}

private func refAgentApiSearch(
    _ client: any Client, apiKey: String, query: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(URI(string: "/internal/agent-api/search?\(query)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func refMachineSearch(
    _ client: any Client, apiKey: String, agentId: String, query: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(URI(string: "/internal/agent/\(agentId)/search?\(query)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func refSearchRows(_ body: [String: Any]) -> [[String: Any]] {
    body["results"] as? [[String: Any]] ?? []
}

private func refWakeHints(
    _ client: any Client, apiKey: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.get(URI(string: "/internal/agent-api/wake-hints"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func withDMRefFinalFixture(
    _ body: (DMRefFinalFixture, any Client) async throws -> Void
) async throws {
    let fixture = makeDMRefFinalFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            try await body(fixture, client)
        }
    }
}

@Test func historyReservedRemindersPeerIsExactAndTyped() async throws {
    try await withDMRefFinalFixture { f, client in
        let exact = try await refHistory(client, apiKey: f.agentKey, target: "dm:@reminders")
        #expect(exact.status == .ok)
        #expect(exact.contents.contains("reminders-needle private surface"))
        #expect(exact.body["target"] as? String == "dm:@reminders")

        // The reserved handle is case-insensitive only for the exact word.
        let cased = try await refHistory(client, apiKey: f.agentKey, target: "dm:@Reminders")
        #expect(cased.status == .ok)
        #expect(cased.contents.contains("reminders-needle private surface"))

        // An ordinary peer whose name merely starts with the reserved word is
        // not the private surface.
        let ordinary = try await refHistory(client, apiKey: f.agentKey, target: "dm:@remindersX")
        #expect(ordinary.status == .ok)
        #expect(ordinary.contents.contains("remindersx-needle ordinary human peer"))
        #expect(!ordinary.contents.contains("reminders-needle private surface"))
        #expect(ordinary.body["target"] as? String == "dm:@remindersX")

        // `~agent` parses the kind first: an agent named reminders (none here)
        // is not the private surface.
        let typed = try await refHistory(client, apiKey: f.agentKey, target: "dm:@reminders~agent")
        #expect(typed.status == .notFound)
        #expect(typed.body["error"] as? String == "Channel not found or not visible")
        #expect(!typed.contents.contains("reminders-needle private surface"))

        let human = try await refHistory(client, apiKey: f.agentKey, target: "dm:@reminders~human")
        #expect(human.status == .notFound)

        // An unknown typed suffix is the 400 kind refusal, not the private
        // surface and not a silent 404.
        let bot = try await refHistory(client, apiKey: f.agentKey, target: "dm:@reminders~bot")
        #expect(bot.status == .badRequest)
        #expect(bot.body["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")
    }
}

@Test func historyTwinTargetsAndThreadSuffixesAreCanonical() async throws {
    try await withDMRefFinalFixture { f, client in
        let bare = try await refHistory(client, apiKey: f.agentKey, target: "dm:@Twin")
        #expect(bare.status == .conflict)
        #expect(bare.body["code"] as? String == "DM_TARGET_AMBIGUOUS")
        #expect((bare.body["error"] as? String)?.contains("dm:@Twin~agent") == true)
        #expect((bare.body["error"] as? String)?.contains("dm:@Twin~human") == true)

        let human = try await refHistory(client, apiKey: f.agentKey, target: "dm:@Twin~human")
        #expect(human.status == .ok)
        #expect(human.contents.contains("humantwin-needle from the human Twin"))
        #expect(!human.contents.contains("agenttwin-needle from the agent Twin"))
        #expect(human.body["target"] as? String == "dm:@Twin~human")
        let humanScope = human.body["consumption_scope"] as? [String: Any]
        #expect(humanScope?["target"] as? String == "dm:@Twin~human")
        #expect(humanScope?["channel_id"] as? String == f.humanTwinDM)

        let agent = try await refHistory(client, apiKey: f.agentKey, target: "dm:@Twin~agent")
        #expect(agent.status == .ok)
        #expect(agent.contents.contains("agenttwin-needle from the agent Twin"))
        #expect(agent.body["target"] as? String == "dm:@Twin~agent")

        // The legacy uppercase prefix resolves; the published target is the
        // canonical lowercase `dm:@` spelling.
        let uppercasePrefix = try await refHistory(client, apiKey: f.agentKey, target: "DM:@Twin~human")
        #expect(uppercasePrefix.status == .ok)
        #expect(uppercasePrefix.body["target"] as? String == "dm:@Twin~human")

        // Canonical names are exact and case-sensitive.
        let cased = try await refHistory(client, apiKey: f.agentKey, target: "dm:@twin~human")
        #expect(cased.status == .notFound)

        // A valid 8-hex suffix (any case) selects the thread; the published
        // target uses the thread's canonical lowercase anchor short id.
        let anchorShort = String(f.humanThreadAnchor.prefix(8))
        let upperSuffix = anchorShort.uppercased()
        let thread = try await refHistory(
            client, apiKey: f.agentKey, target: "dm:@Twin~human:\(upperSuffix)"
        )
        #expect(thread.status == .ok)
        #expect(thread.contents.contains("humantwin-thread-needle reply"))
        #expect(thread.body["target"] as? String == "dm:@Twin~human:\(anchorShort)")
        let threadScope = thread.body["consumption_scope"] as? [String: Any]
        #expect(threadScope?["channel_type"] as? String == "thread")
        #expect(threadScope?["channel_id"] as? String == f.humanThread)
        #expect(threadScope?["target"] as? String == "dm:@Twin~human:\(anchorShort)")

        // The explicit kind pins which DM the thread lives in.
        let crossed = try await refHistory(
            client, apiKey: f.agentKey, target: "dm:@Twin~agent:\(anchorShort)"
        )
        #expect(crossed.status == .notFound)

        // A shorter prefix is not a thread: it stays in the base target.
        let shortPrefix = String(f.humanThreadAnchor.prefix(4))
        let invalidTyped = try await refHistory(
            client, apiKey: f.agentKey, target: "dm:@Twin~human:\(shortPrefix)"
        )
        #expect(invalidTyped.status == .badRequest)
        #expect(invalidTyped.body["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")

        // A bare `:1` stays part of the peer name ("Twin:1"), so it is a
        // neutral not-found and never the twinned DM.
        let bareColon = try await refHistory(client, apiKey: f.agentKey, target: "dm:@Twin:1")
        #expect(bareColon.status == .notFound)
        #expect(bareColon.body["error"] as? String == "Channel not found or not visible")
    }
}

@Test func historyChannelThreadSuffixRequiresEightHex() async throws {
    try await withDMRefFinalFixture { f, client in
        let anchorShort = String(f.roomAnchor.prefix(8))
        let shortPrefix = String(f.roomAnchor.prefix(4))

        // The old rule treated this 4-hex prefix as a thread id and opened the
        // existing thread; the pinned parser keeps it in the channel name.
        let bogus = try await refHistory(
            client, apiKey: f.agentKey, target: "#\(f.roomName):\(shortPrefix)"
        )
        #expect(bogus.status == .notFound)
        #expect(bogus.body["error"] as? String == "Channel not found or not visible")
        #expect(!bogus.contents.contains("roomthread-needle reply"))

        for invalid in ["1", "zzzzzzzz", "abcdef0", "abcdef012"] {
            let refused = try await refHistory(
                client, apiKey: f.agentKey, target: "#\(f.roomName):\(invalid)"
            )
            #expect(refused.status == .notFound, "#\(f.roomName):\(invalid) must not open a thread")
        }

        // A full 8-hex suffix (either case) resolves, with a lowercase target.
        let thread = try await refHistory(
            client, apiKey: f.agentKey, target: "#\(f.roomName):\(anchorShort.uppercased())"
        )
        #expect(thread.status == .ok)
        #expect(thread.contents.contains("roomthread-needle reply"))
        #expect(thread.body["target"] as? String == "#\(f.roomName):\(anchorShort)")
    }
}

@Test func legacySendNeverCreatesAPhantomThreadFromAnInvalidSuffix() async throws {
    try await withDMRefFinalFixture { f, client in
        let before = f.accounts.humanMessageCount
        let shortPrefix = String(f.roomAnchor.prefix(4))

        let channelPhantom = try await refSend(
            client, apiKey: f.machineSendKey, agentId: f.graceId,
            target: "#\(f.roomName):\(shortPrefix)"
        )
        #expect(channelPhantom.status == .notFound)
        #expect(f.accounts.humanMessageCount == before)

        let dmPhantom = try await refSend(
            client, apiKey: f.machineSendKey, agentId: f.graceId,
            target: "dm:@remindersX:\(shortPrefix)"
        )
        #expect(dmPhantom.status == .notFound)
        #expect(f.accounts.humanMessageCount == before)

        // A real parent short id still creates/joins the thread.
        let anchorShort = String(f.roomAnchor.prefix(8))
        let valid = try await refSend(
            client, apiKey: f.machineSendKey, agentId: f.graceId,
            target: "#\(f.roomName):\(anchorShort)"
        )
        #expect(valid.status == .ok)
        #expect(f.accounts.humanMessageCount == before + 1)
        let messageId = try #require(valid.body["messageId"] as? String)
        let sentChannel = try #require(f.accounts.messageChannelIdForTesting(messageId: messageId))
        #expect(f.accounts.oauth.channelType(id: sentChannel) == "thread")

        // The invalid ref remains a not-found even after the thread exists.
        let stillInvalid = try await refSend(
            client, apiKey: f.machineSendKey, agentId: f.graceId,
            target: "#\(f.roomName):\(shortPrefix)"
        )
        #expect(stillInvalid.status == .notFound)
        #expect(f.accounts.humanMessageCount == before + 1)
    }
}

@Test func searchChannelResolvesDMRefsOnBothAgentRoutes() async throws {
    try await withDMRefFinalFixture { f, client in
        let human = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("dm:@Twin~human"))"
        )
        #expect(human.status == .ok)
        #expect(refSearchRows(human.body).allSatisfy { $0["senderId"] as? String == f.humanTwinId })
        #expect(refSearchRows(human.body).allSatisfy { $0["channelId"] as? String == f.humanTwinDM })

        let agent = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("dm:@Twin~agent"))"
        )
        #expect(agent.status == .ok)
        #expect(refSearchRows(agent.body).allSatisfy { $0["senderId"] as? String == f.agentTwinId })

        // The legacy uppercase prefix is part of the pinned DM grammar.
        let uppercasePrefix = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("DM:@Twin~human"))"
        )
        #expect(uppercasePrefix.status == .ok)
        #expect(refSearchRows(uppercasePrefix.body).allSatisfy { $0["senderId"] as? String == f.humanTwinId })

        let ambiguous = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("dm:@Twin"))"
        )
        #expect(ambiguous.status == .conflict)
        #expect(ambiguous.body["code"] as? String == "DM_TARGET_AMBIGUOUS")

        let reminders = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("dm:@reminders"))"
        )
        #expect(reminders.status == .ok)
        #expect(refSearchRows(reminders.body).allSatisfy { $0["channelId"] as? String == f.remindersSurface })

        let ordinary = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("dm:@remindersX"))"
        )
        #expect(ordinary.status == .ok)
        #expect(refSearchRows(ordinary.body).allSatisfy { $0["senderId"] as? String == f.remindersHumanId })

        let unknown = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("dm:@Ghost"))"
        )
        #expect(unknown.status == .notFound)
        #expect(unknown.body["error"] as? String == "Channel not found: dm:@Ghost")
        #expect(refSearchRows(unknown.body).isEmpty)

        let badKind = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("dm:@reminders~bot"))"
        )
        #expect(badKind.status == .badRequest)
        #expect(badKind.body["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")

        // The 8-hex thread suffix selects the DM thread, not the parent DM.
        let threadSuffix = String(f.humanThreadAnchor.prefix(8)).uppercased()
        let thread = try await refAgentApiSearch(
            client, apiKey: f.agentKey,
            query: "q=needle&channel=\(encodedRef("dm:@Twin~human:\(threadSuffix)"))"
        )
        #expect(thread.status == .ok)
        #expect(refSearchRows(thread.body).allSatisfy { $0["channelId"] as? String == f.humanThread })

        // An invalid colon suffix is a 404, never the whole server's messages.
        let invalid = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&channel=\(encodedRef("#\(f.roomName):1"))"
        )
        #expect(invalid.status == .notFound)
        #expect(refSearchRows(invalid.body).isEmpty)

        // The machine-keyed route applies the same DM resolution.
        let machineHuman = try await refMachineSearch(
            client, apiKey: f.machineKey, agentId: f.graceId,
            query: "q=needle&channel=\(encodedRef("dm:@Twin~human"))"
        )
        #expect(machineHuman.status == .ok)
        #expect(refSearchRows(machineHuman.body).allSatisfy { $0["senderId"] as? String == f.humanTwinId })

        let machineAmbiguous = try await refMachineSearch(
            client, apiKey: f.machineKey, agentId: f.graceId,
            query: "q=needle&channel=\(encodedRef("dm:@Twin"))"
        )
        #expect(machineAmbiguous.status == .conflict)
        #expect(machineAmbiguous.body["code"] as? String == "DM_TARGET_AMBIGUOUS")

        let machineReminders = try await refMachineSearch(
            client, apiKey: f.machineKey, agentId: f.graceId,
            query: "q=needle&channel=\(encodedRef("dm:@reminders"))"
        )
        #expect(machineReminders.status == .ok)
        #expect(refSearchRows(machineReminders.body).allSatisfy { $0["channelId"] as? String == f.remindersSurface })
    }
}

@Test func searchSenderRejectsEmptyAndAmbiguousRefs() async throws {
    try await withDMRefFinalFixture { f, client in
        for query in ["q=needle&sender=", "q=needle&sender=%20"] {
            let empty = try await refAgentApiSearch(client, apiKey: f.agentKey, query: query)
            #expect(empty.status == .badRequest, "\(query) must be a bad request")
            #expect(empty.body["errorCode"] as? String == "invalid_member_ref")
            #expect(empty.body["error"] as? String == "member ref must not be empty")
            #expect(refSearchRows(empty.body).isEmpty)
        }
        let atOnly = try await refAgentApiSearch(client, apiKey: f.agentKey, query: "q=needle&sender=@")
        #expect(atOnly.status == .badRequest)
        #expect(atOnly.body["error"] as? String == "member handle must not be empty")

        // The ref is validated even when the query is empty, so it cannot
        // silently turn into an unfiltered browse.
        let emptyQuery = try await refAgentApiSearch(client, apiKey: f.agentKey, query: "q=&sender=")
        #expect(emptyQuery.status == .badRequest)
        #expect(emptyQuery.body["errorCode"] as? String == "invalid_member_ref")

        let twin = try await refAgentApiSearch(client, apiKey: f.agentKey, query: "q=needle&sender=@Twin")
        #expect(twin.status == .conflict)
        #expect(twin.body["errorCode"] as? String == "ambiguous_member_ref")
        #expect(twin.body["error"] as? String == "Member @Twin is ambiguous")

        // The pinned sender helper has no `~kind` grammar: the whole string is
        // a canonical handle, so this is an unknown member, not a widened query.
        let typed = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&sender=\(encodedRef("@Twin~agent"))"
        )
        #expect(typed.status == .notFound)
        #expect(typed.body["errorCode"] as? String == "member_not_found")
        #expect(typed.body["error"] as? String == "Member not found: @Twin~agent")
        #expect(refSearchRows(typed.body).isEmpty)

        let ordinary = try await refAgentApiSearch(
            client, apiKey: f.agentKey, query: "q=needle&sender=@remindersX"
        )
        #expect(ordinary.status == .ok)
        #expect(refSearchRows(ordinary.body).allSatisfy { $0["senderId"] as? String == f.remindersHumanId })

        // Same validation on the machine-keyed route.
        for query in ["q=needle&sender=", "q=needle&sender=@"] {
            let empty = try await refMachineSearch(
                client, apiKey: f.machineKey, agentId: f.graceId, query: query
            )
            #expect(empty.status == .badRequest, "\(query) must be a bad request")
            #expect(empty.body["errorCode"] as? String == "invalid_member_ref")
        }
        let machineTwin = try await refMachineSearch(
            client, apiKey: f.machineKey, agentId: f.graceId, query: "q=needle&sender=@Twin"
        )
        #expect(machineTwin.status == .conflict)
        #expect(machineTwin.body["errorCode"] as? String == "ambiguous_member_ref")
    }
}

@Test func wakeHintsPublishTheTwinKindInsteadOfABareName() async throws {
    try await withDMRefFinalFixture { f, client in
        let hints = try await refWakeHints(client, apiKey: f.agentKey)
        #expect(hints.status == .ok)
        let targets = Set(
            (hints.body["wake_hints"] as? [[String: Any]] ?? [])
                .compactMap { $0["target"] as? String }
        )
        #expect(targets.contains("dm:@Twin~human"))
        #expect(targets.contains("dm:@Twin~agent"))
        #expect(targets.contains("dm:@Solo"))
        #expect(!targets.contains("dm:@Twin"))
    }
}
