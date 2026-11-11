import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// The pinned `channelService.resolveDMByPeerName` matches only the canonical
/// `users.name` / `agents.name`, exactly and case-sensitively, and only accepts
/// the exact `~agent` / `~human` suffixes. A human whose `displayName` equals
/// another human's handle must never make `dm:@<handle>` name the wrong person.
private struct ExactDMPeerFixture {
    let accounts: EmailLoginDirectory
    var serverId = "33333333-3333-4333-8333-000001300001"
    var ownerId = "11111111-1111-4111-8111-000001300001"
    var aliceId = "11111111-1111-4111-8111-000001300002"
    var bobId = "11111111-1111-4111-8111-000001300003"
    var graceId = ""
    var aliceDM = ""
    var bobDM = ""
    var receiptChannelId = ""
    var agentKey = ""
    var machineKey = ""
}

private func makeExactDMPeerFixture(suffix: String) -> ExactDMPeerFixture {
    var f = ExactDMPeerFixture(accounts: EmailLoginDirectory())
    let number = Int(suffix) ?? 0
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 300_000 + number)
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 300_000 + number)
    let aliceId = String(format: "11111111-1111-4111-8111-%012d", 310_000 + number)
    let bobId = String(format: "11111111-1111-4111-8111-%012d", 320_000 + number)
    let accounts = f.accounts
    accounts.addAccount(id: ownerId, email: "dm-exact-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: aliceId, email: "dm-exact-alice-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: aliceId)
    accounts.addAccount(id: bobId, email: "dm-exact-bob-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: bobId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "dm-exact-\(suffix)", name: "DM Exact", ownerId: ownerId)
    // alice's display name is bob's handle; bob's display name is a third name.
    accounts.setAccountProfileForTesting(id: aliceId, name: "alice", displayName: "bob")
    accounts.setAccountProfileForTesting(id: bobId, name: "bob", displayName: "Bobby")
    accounts.oauth.addMember(serverId: serverId, userId: aliceId, role: "member")
    accounts.oauth.addMember(serverId: serverId, userId: bobId, role: "member")
    let grace = accounts.oauth.createAgent(serverId: serverId, name: "Grace-\(suffix)", runtime: "claude")

    func humanDM(_ userId: String) -> String {
        let channelId = accounts.oauth.createDirectChannel(
            serverId: serverId, firstUserId: grace, secondUserId: userId,
            firstKind: .agent, secondKind: .human
        )
        for member in [grace, userId] {
            accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: member, kind: "dm", name: "dm")
        }
        return channelId
    }
    let aliceDM = humanDM(aliceId)
    let bobDM = humanDM(bobId)
    _ = accounts.oauth.createMessageRecord(channelId: aliceDM, content: "from alice", senderId: aliceId)
    _ = accounts.oauth.createMessageRecord(channelId: bobDM, content: "from bob", senderId: bobId)
    let receiptChannel = accounts.createMigrationReceiptDmForTesting(agentId: grace, supportRef: "receipt-\(suffix)") ?? ""

    f.serverId = serverId
    f.ownerId = ownerId
    f.aliceId = aliceId
    f.bobId = bobId
    f.graceId = grace
    f.aliceDM = aliceDM
    f.bobDM = bobDM
    f.receiptChannelId = receiptChannel
    f.agentKey = accounts.mintAgentCredential(agentId: grace, scopes: ["send", "read"], name: "dm-exact-\(suffix)")
    f.machineKey = accounts.registerMachineForAgent(serverId: serverId, agentId: grace)
    return f
}

private func exactHistory(
    _ client: any Client, apiKey: String, target: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any], contents: [String]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
    let response = try await client.get(URI(string: "/internal/agent-api/history?channel=\(encoded)"), headers: headers)
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    let contents = (body["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }
    return (response.status, body, contents)
}

private func exactAgentSend(
    _ client: any Client, apiKey: String, target: String, content: String = "sent"
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(apiKey)"
    headers[.contentType] = "application/json"
    let payload = "{\"target\":\"\(target)\",\"content\":\"\(content)\",\"idempotencyKey\":\"\(UUID().uuidString.lowercased())\"}"
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent-api/v2/send")) { request in
        request.body = .init(string: payload)
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

private func exactMachineSend(
    _ client: any Client, agentId: String, machineKey: String, target: String, content: String = "sent"
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(machineKey)"
    headers[.contentType] = "application/json"
    let payload = "{\"target\":\"\(target)\",\"content\":\"\(content)\",\"idempotencyKey\":\"\(UUID().uuidString.lowercased())\"}"
    let response = try await client.send(.post, headers: headers, to: URI(string: "/internal/agent/\(agentId)/send")) { request in
        request.body = .init(string: payload)
    }
    let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, body)
}

@Test func dmHandleIgnoresDisplayNamesAndCaseVariants() async throws {
    let f = makeExactDMPeerFixture(suffix: "901")
    #expect(!f.receiptChannelId.isEmpty)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            // `dm:@bob` names the human whose canonical handle is bob, never
            // the human whose *display name* is bob.
            let bobHistory = try await exactHistory(client, apiKey: f.agentKey, target: "dm:@bob")
            #expect(bobHistory.status == .ok)
            #expect(bobHistory.contents.contains("from bob"))
            #expect(!bobHistory.contents.contains("from alice"))

            let bobSend = try await exactAgentSend(client, apiKey: f.agentKey, target: "dm:@bob", content: "to bob")
            #expect(bobSend.status == .ok)
            #expect(bobSend.body["channelId"] as? String == f.bobDM)
            let bobHistoryAfter = try await exactHistory(client, apiKey: f.agentKey, target: "dm:@bob")
            #expect(bobHistoryAfter.contents.contains("to bob"))

            let aliceBefore = f.accounts.messageCountForTesting(channelId: f.aliceDM)
            let aliceSend = try await exactAgentSend(client, apiKey: f.agentKey, target: "dm:@alice", content: "to alice")
            #expect(aliceSend.status == .ok)
            #expect(aliceSend.body["channelId"] as? String == f.aliceDM)
            #expect(f.accounts.messageCountForTesting(channelId: f.aliceDM) == aliceBefore + 1)

            // Case variants and display names are not handles.
            for target in ["dm:@Alice", "dm:@ALICE", "dm:@Bobby", "dm:@bobby"] {
                let history = try await exactHistory(client, apiKey: f.agentKey, target: target)
                #expect(history.status == .notFound, "\(target) must not resolve a peer")
                #expect(history.contents.isEmpty)
                let sent = try await exactAgentSend(client, apiKey: f.agentKey, target: target)
                #expect(sent.status == .notFound, "\(target) must not send a message")
            }

            // The machine-on-behalf route uses the same exact rules.
            let machineBob = try await exactMachineSend(
                client, agentId: f.graceId, machineKey: f.machineKey, target: "dm:@bob", content: "machine to bob"
            )
            #expect(machineBob.status == .ok)
            let machineHistory = try await exactHistory(client, apiKey: f.agentKey, target: "dm:@bob")
            #expect(machineHistory.contents.contains("machine to bob"))
            let machineAliceCase = try await exactMachineSend(
                client, agentId: f.graceId, machineKey: f.machineKey, target: "dm:@Alice"
            )
            #expect(machineAliceCase.status == .notFound)
        }
    }
}

@Test func dmPeerKindSuffixIsExactAndSelfDMUsesCanonicalName() async throws {
    let f = makeExactDMPeerFixture(suffix: "902")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            // The pinned `parseDmPeerRef` accepts only the lowercase exact
            // suffixes; `~HUMAN` is a caller error, not a case-folded human.
            for target in ["dm:@alice~HUMAN", "dm:@alice~Agent", "dm:@alice~bot"] {
                let sent = try await exactAgentSend(client, apiKey: f.agentKey, target: target)
                #expect(sent.status == .badRequest, "\(target) is an unknown peer kind")
                #expect(sent.body["code"] as? String == "DM_TARGET_INVALID_PEER_KIND")
                #expect(sent.body["suggestedNextAction"] is String)
            }
            let invalidWire = try await exactAgentSend(client, apiKey: f.agentKey, target: "dm:@alice~BOT")
            #expect((invalidWire.body["error"] as? String)?.contains("BOT") == true)

            // An exact lowercase suffix pins the kind and resolves the DM.
            let pinnedHuman = try await exactAgentSend(
                client, apiKey: f.agentKey, target: "dm:@alice~human", content: "pinned human"
            )
            #expect(pinnedHuman.status == .ok)
            #expect(pinnedHuman.body["channelId"] as? String == f.aliceDM)
            let pinnedAgentMissing = try await exactAgentSend(client, apiKey: f.agentKey, target: "dm:@bob~agent")
            #expect(pinnedAgentMissing.status == .notFound)

            // `dm:@<own exact name>` is the self-DM 400; a case variant is an
            // unknown peer and stays the neutral not-found.
            let selfExact = try await exactMachineSend(
                client, agentId: f.graceId, machineKey: f.machineKey, target: "dm:@Grace-902"
            )
            #expect(selfExact.status == .badRequest)
            #expect(selfExact.body["error"] as? String == "Cannot create a DM with yourself")
            let selfCaseVariant = try await exactMachineSend(
                client, agentId: f.graceId, machineKey: f.machineKey, target: "dm:@grace-902"
            )
            #expect(selfCaseVariant.status == .notFound)
            #expect(selfCaseVariant.body["error"] as? String == "User or agent not found: @grace-902")
            let selfCaseVariantAgentApi = try await exactAgentSend(client, apiKey: f.agentKey, target: "dm:@grace-902")
            #expect(selfCaseVariantAgentApi.status == .notFound)
        }
    }
}

@Test func crossKindTwinPeerAmbiguityKeepsThePublishedWire() async throws {
    let f = makeExactDMPeerFixture(suffix: "903")
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        // A human and a live agent share the canonical handle `Twin`; the
        // agent Twin has no DM with the newcomer yet.
        let twinHuman = "11111111-1111-4111-8111-000001390001"
        f.accounts.addAccount(id: twinHuman, email: "dm-twin-human-903@slock.test", password: "password123")
        f.accounts.markEmailVerified(userId: twinHuman)
        f.accounts.setAccountProfileForTesting(id: twinHuman, name: "Twin", displayName: "Human Twin")
        f.accounts.oauth.addMember(serverId: f.serverId, userId: twinHuman, role: "member")
        let twinAgent = f.accounts.oauth.createAgent(serverId: f.serverId, name: "Twin", runtime: "claude")
        let twinHumanDM = f.accounts.oauth.createDirectChannel(
            serverId: f.serverId, firstUserId: f.graceId, secondUserId: twinHuman,
            firstKind: .agent, secondKind: .human
        )
        for member in [f.graceId, twinHuman] {
            f.accounts.addPostableChannel(serverId: f.serverId, channelId: twinHumanDM, memberId: member, kind: "dm", name: "dm")
        }
        _ = f.accounts.oauth.createMessageRecord(channelId: twinHumanDM, content: "from the human Twin", senderId: twinHuman)
        let newcomer = f.accounts.oauth.createAgent(serverId: f.serverId, name: "Newcomer-903", runtime: "claude")
        let newcomerKey = f.accounts.mintAgentCredential(agentId: newcomer, scopes: ["send", "read"], name: "dm-twin-newcomer-903")

        try await app.testing { client in
            // The bare name is ambiguous before either DM exists for the caller.
            let ambiguous = try await exactAgentSend(client, apiKey: newcomerKey, target: "dm:@Twin")
            #expect(ambiguous.status == .conflict)
            #expect(ambiguous.body["code"] as? String == "DM_TARGET_AMBIGUOUS")
            let message = ambiguous.body["error"] as? String ?? ""
            #expect(message.contains("dm:@Twin~agent"))
            #expect(message.contains("dm:@Twin~human"))
            #expect((ambiguous.body["suggestedNextAction"] as? String)?.contains("dm:@Twin~agent") == true)

            let pinnedAgent = try await exactAgentSend(client, apiKey: newcomerKey, target: "dm:@Twin~agent", content: "agent twin pin")
            #expect(pinnedAgent.status == .ok)
            let pinnedAgentChannel = pinnedAgent.body["channelId"] as? String
            #expect(pinnedAgentChannel != nil)
            var pinnedHumanChannel: String?
            do {
                let pinnedHuman = try await exactAgentSend(client, apiKey: newcomerKey, target: "dm:@Twin~human", content: "human twin pin")
                #expect(pinnedHuman.status == .ok)
                pinnedHumanChannel = pinnedHuman.body["channelId"] as? String
            }
            #expect(pinnedHumanChannel != nil)
            #expect(pinnedAgentChannel != pinnedHumanChannel)

            let agentHistory = try await exactHistory(client, apiKey: newcomerKey, target: "dm:@Twin~agent")
            #expect(agentHistory.contents.contains("agent twin pin"))
            #expect(!agentHistory.contents.contains("human twin pin"))
            let humanHistory = try await exactHistory(client, apiKey: newcomerKey, target: "dm:@Twin~human")
            #expect(humanHistory.contents.contains("human twin pin"))
            #expect(!humanHistory.contents.contains("agent twin pin"))
            _ = twinAgent
        }
    }
}

@Test func migrationReceiptResolutionFallsThroughAndStaysReadOnly() async throws {
    let f = makeExactDMPeerFixture(suffix: "904")
    #expect(!f.receiptChannelId.isEmpty)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts
        ))
        try await app.testing { client in
            let receiptTarget = "dm:@migration-receipt-receipt-904"
            let receiptBefore = f.accounts.messageCountForTesting(channelId: f.receiptChannelId)

            // A receipt is a one-way notice: the machine send route reports the
            // published read-only conflict instead of the self-DM 400.
            let reply = try await exactMachineSend(
                client, agentId: f.graceId, machineKey: f.machineKey, target: receiptTarget
            )
            #expect(reply.status == .conflict)
            #expect(reply.body["code"] as? String == "MIGRATION_RECEIPT_READ_ONLY")
            #expect(f.accounts.messageCountForTesting(channelId: f.receiptChannelId) == receiptBefore)

            // Another agent owns no receipt under that name: the receipt lookup
            // falls through to the ordinary peer rules and stays neutral.
            let bystander = f.accounts.oauth.createAgent(serverId: f.serverId, name: "Bystander-904", runtime: "claude")
            let bystanderKey = f.accounts.registerMachineForAgent(serverId: f.serverId, agentId: bystander)
            let bystanderSend = try await exactMachineSend(
                client, agentId: bystander, machineKey: bystanderKey, target: receiptTarget
            )
            #expect(bystanderSend.status == .notFound)
            #expect(bystanderSend.body["error"] as? String == "User or agent not found: @migration-receipt-receipt-904")

            // A real human handle that merely starts with the receipt prefix is
            // still a peer for everyone else (the pinned fall-through rule).
            let receiptNamedHuman = "11111111-1111-4111-8111-000001390002"
            f.accounts.addAccount(id: receiptNamedHuman, email: "dm-receipt-human-904@slock.test", password: "password123")
            f.accounts.markEmailVerified(userId: receiptNamedHuman)
            f.accounts.setAccountProfileForTesting(id: receiptNamedHuman, name: "migration-receipt-human", displayName: "Receipt Human")
            f.accounts.oauth.addMember(serverId: f.serverId, userId: receiptNamedHuman, role: "member")
            let humanDM = f.accounts.oauth.createDirectChannel(
                serverId: f.serverId, firstUserId: f.graceId, secondUserId: receiptNamedHuman,
                firstKind: .agent, secondKind: .human
            )
            for member in [f.graceId, receiptNamedHuman] {
                f.accounts.addPostableChannel(serverId: f.serverId, channelId: humanDM, memberId: member, kind: "dm", name: "dm")
            }
            let humanSend = try await exactMachineSend(
                client, agentId: f.graceId, machineKey: f.machineKey,
                target: "dm:@migration-receipt-human", content: "to the receipt-named human"
            )
            #expect(humanSend.status == .ok)
            #expect(f.accounts.messageCountForTesting(channelId: humanDM) == 1)
            let humanHistory = try await exactHistory(client, apiKey: f.agentKey, target: "dm:@migration-receipt-human")
            #expect(humanHistory.contents.contains("to the receipt-named human"))
        }
    }
}
