import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

/// Published-path triggers for the owner briefing: the "Let's Go" handoff and
/// the back-compat `signupSurveyServerId` field on `PATCH /api/auth/me`.
///
/// This focused app has no durable writer, so the transient notice admission
/// returns `.dropped(.transactionRequired)`. That is not a fabricated send: the
/// retained acknowledgment and the visible opener (upstream posts it before the
/// ledger) are observable, the sent stamp is not. The accepted path is covered
/// by the real-PostgreSQL acceptance in `RaftServerStartupTests`.
@Suite(.serialized) struct OnboardingBriefingTriggerTests {
    private func body(_ response: ClientResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
    }

    private func postSetup(_ response: [String: Any]) -> NSDictionary? {
        response["postSetup"] as? NSDictionary
    }

    private struct Seed {
        let accounts: EmailLoginDirectory
        let ownerId: String
        let memberId: String
        let serverId: String
        let otherServerId: String
        let agentId: String
        let allChannelId: String
        let ownerToken: String
        let memberToken: String
    }

    /// Real Store facts: a verified owner, a server with its enabled `#all`, an
    /// active onboarding agent on an online Computer, and a live connection.
    private func seed() -> Seed {
        let accounts = EmailLoginDirectory()
        let ownerId = "11111111-1111-4111-8111-111111111831"
        let memberId = "11111111-1111-4111-8111-111111111832"
        let serverId = "33333333-3333-4333-8333-333333333831"
        let otherServerId = "33333333-3333-4333-8333-333333333832"
        accounts.addAccount(id: ownerId, email: "briefing-trigger-owner@slock.test", password: "password123")
        accounts.addAccount(id: memberId, email: "briefing-trigger-member@slock.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.markEmailVerified(userId: memberId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "briefing-trigger", name: "Briefing Trigger",
                                      ownerId: ownerId)
        accounts.oauth.addOwnedServer(id: otherServerId, slug: "briefing-other", name: "Briefing Other",
                                      ownerId: memberId)
        let allChannelId = accounts.oauth.allChannelId(serverId: serverId) ?? ""
        accounts.serversAndChannelsStore.insertOwnedChannel(channelId: allChannelId, serverId: serverId,
                                                           userId: ownerId, name: "all")
        let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "briefing-machine")
        accounts.linkComputerForTesting(serverId: serverId, machineId: machine, attachedByUserId: ownerId)
        accounts.machinesAndComputersStore.storage.withLock { state in
            guard let index = state.machines.firstIndex(where: { $0.id == machine }) else { return }
            state.machines[index].runtimes = ["codex"]
            state.machines[index].lastSeenAt = Date()
        }
        let cindy = accounts.oauth.createAgent(serverId: serverId, name: "Cindy", displayName: "Cindy",
                                               runtime: "codex")
        accounts.oauth.setAgentStatus(id: cindy, status: "active")
        accounts.setAgentMachineForTesting(agentId: cindy, machineId: machine)
        accounts.agentsRuntimeStore.withState { state in
            state.execution.connections[machine] = AgentExecutionConnection(
                serverId: serverId, connectionEpochId: "briefing-trigger-epoch", online: true, ready: true,
                daemonInstanceId: "briefing-trigger-daemon", runtimes: ["codex"], capabilities: nil
            )
        }
        accounts.serversAndChannelsStore.bindOnboardingAgent(serverId: serverId, agentId: cindy)
        return Seed(accounts: accounts, ownerId: ownerId, memberId: memberId, serverId: serverId,
                    otherServerId: otherServerId, agentId: cindy, allChannelId: allChannelId,
                    ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
                    memberToken: accounts.mintAccessTokenForTesting(userId: memberId))
    }

    private func patchMe(_ client: any TestClient, token: String, body: String) async throws -> ClientResponse {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(token)"
        fields[.contentType] = "application/json"
        return try await client.send(.patch, headers: fields, to: "/api/auth/me") { request in
            request.body = .init(string: body)
        }
    }

    private func handoff(_ client: any TestClient, token: String, serverId: String) async throws -> ClientResponse {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(token)"
        fields[.contentType] = "application/json"
        fields[HTTPField.Name("X-Server-Id")!] = serverId
        return try await client.send(.post, headers: fields, to: "/api/servers/\(serverId)/setup-handoff")
    }

    private func openerRows(_ seed: Seed) -> [StoredHumanMessage] {
        seed.accounts.messagesAndThreadsStore.humanMessageRows
            .filter { $0.senderId == seed.agentId }
            .sorted { $0.seq < $1.seq }
    }

    @Test func handoffRetainsTheReceiptAndPostsTheOpenerWithoutAFabricatedStamp() async throws {
        let seed = seed()
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: seed.accounts
            ))
            try await app.testing { client in
                // Answer the survey through the published route, then take the handoff.
                let survey = try await patchMe(client, token: seed.ownerToken,
                                               body: #"{"signupRole":"founder"}"#)
                #expect(survey.status == .ok)
                let handoffResponse = try await handoff(client, token: seed.ownerToken, serverId: seed.serverId)
                #expect(handoffResponse.status == .ok)
                let projected = try body(handoffResponse)
                let nothingPending: NSDictionary = ["surveyPending": false, "handoffPending": false]
                #expect(postSetup(projected) == nothingPending)

                // The acknowledgment is retained independently of delivery.
                let receipt = seed.accounts.serversAndChannelsStore
                    .setupHandoffReceipt(serverId: seed.serverId, ownerId: seed.ownerId)
                #expect(receipt != nil)

                // The focused app has no durable writer, so the transient ledger
                // dropped. The visible opener was still posted, exactly like
                // upstream's dropped-ledger state, and nothing was stamped.
                let ledger = seed.accounts.serversAndChannelsStore
                    .ownerOpenerLedger(serverId: seed.serverId, ownerId: seed.ownerId)
                #expect(ledger.openerV2SentAt == nil)
                #expect(ledger.dmSentAt == nil)
                #expect(ledger.openerClaimedAt == nil)
                #expect(seed.accounts.agentsRuntimeStore.state.execution.commands.isEmpty)
                let rows = openerRows(seed)
                // Four visible opener messages plus the Team-Mode thread reply.
                #expect(rows.count == 5)
                let channelRows = rows.filter { $0.channelId == seed.allChannelId }
                #expect(channelRows.count == 4)
                #expect(rows.allSatisfy { $0.senderType == "agent" })
                #expect(rows.allSatisfy { $0.agentSendKey?.hasPrefix("owner-opener-v2.0:") == true })
                #expect(rows.allSatisfy { !$0.content.contains("Owner opener v2 ledger:") })

                // Pressing "Let's Go" again is idempotent: no duplicate opener,
                // same retained acknowledgment.
                let again = try await handoff(client, token: seed.ownerToken, serverId: seed.serverId)
                #expect(again.status == .ok)
                #expect(openerRows(seed).map(\.id) == rows.map(\.id))
                #expect(seed.accounts.serversAndChannelsStore
                    .setupHandoffReceipt(serverId: seed.serverId, ownerId: seed.ownerId)?.acknowledgedAt
                    == receipt?.acknowledgedAt)
            }
        }
    }

    @Test func patchMeSignupSurveyServerIdIsTriggerOnlyAndOnlyTheOwnerBriefs() async throws {
        let seed = seed()
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: seed.accounts
            ))
            try await app.testing { client in
                let response = try await patchMe(
                    client, token: seed.ownerToken,
                    body: #"{"signupRole":"founder","signupSurveyServerId":"\#(seed.serverId)"}"#
                )
                #expect(response.status == .ok)
                let projected = try body(response)
                // The field names a server to brief; it is never persisted or echoed.
                #expect(projected["signupSurveyServerId"] == nil)
                #expect(projected["signupRole"] as? String == "founder")
                #expect(projected["signupSurveyCompletedAt"] as? String != nil)
                #expect(seed.accounts.authProfileStore.account(userId: seed.ownerId)?
                    .signupSurveyCompletedAt != nil)
                // The owner's server got the visible opener (and its thread
                // reply) from this trigger.
                #expect(openerRows(seed).count == 5)

                // A member naming someone else's server is a no-op, not an error.
                let memberResponse = try await patchMe(
                    client, token: seed.memberToken,
                    body: #"{"signupSurveyServerId":"\#(seed.serverId)"}"#
                )
                #expect(memberResponse.status == .ok)
                #expect(openerRows(seed).count == 5)

                // The same owner's second save does not duplicate the opener.
                let repeated = try await patchMe(
                    client, token: seed.ownerToken,
                    body: #"{"signupRole":"founder","signupSurveyServerId":"\#(seed.serverId)"}"#
                )
                #expect(repeated.status == .ok)
                #expect(openerRows(seed).count == 5)
                #expect(seed.accounts.serversAndChannelsStore
                    .ownerOpenerLedger(serverId: seed.serverId, ownerId: seed.ownerId).openerV2SentAt == nil)

                // A non-string value is not a trigger and still does not fail the
                // profile update (upstream only fires when typeof === "string").
                let numeric = try await patchMe(
                    client, token: seed.ownerToken,
                    body: #"{"signupSurveyServerId":5,"displayLanguage":"en"}"#
                )
                #expect(numeric.status == .ok)
                #expect(openerRows(seed).count == 5)
            }
        }
    }
}
