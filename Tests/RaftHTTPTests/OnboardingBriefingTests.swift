import Foundation
import RaftShared
import TestSupport
import Testing
@testable import RaftHTTP

/// The owner onboarding briefing: gates, the claim lease, the transient ledger
/// wake, the typed receipt that decides the sent stamp, idempotency, owner
/// facts, and the visible `agentSendKey`-deduped opener.
@Suite(.serialized) struct OnboardingBriefingTests {
    private final class Fixture: Sendable {
        let profiles: AuthProfileStore
        let agents: AgentsRuntimeStore
        let machines: MachinesAndComputersStore
        let channels: ServersAndChannelsStore
        let messages: MessagesAndThreadsStore
        let oauth: OAuthLedger
        let execution: AgentExecutionService
        let service: OnboardingBriefingService
        let serverId: String
        let machineId: String
        let ownerId: String
        let agentId: String
        let allChannelId: String
        let fixedDate: Date
        let context: AgentExecutionMachineContext

        init(surveyAnswered: Bool = true, agentStatus: String = "active", bindAgent: Bool = true) {
            let serverId = "11111111-1111-4111-8111-111111111811"
            let machineId = "briefing-machine"
            let ownerId = "11111111-1111-4111-8111-111111111812"
            let fixedDate = Date(timeIntervalSinceReferenceDate: 820_000_000.25)
            self.serverId = serverId
            self.machineId = machineId
            self.ownerId = ownerId
            self.fixedDate = fixedDate
            let profiles = AuthProfileStore()
            let agents = AgentsRuntimeStore()
            let machines = MachinesAndComputersStore()
            let channels = ServersAndChannelsStore()
            let messages = MessagesAndThreadsStore()
            let oauth = OAuthLedger()
            oauth.addOwnedServer(id: serverId, slug: "briefing-server", name: "Briefing", ownerId: ownerId)
            allChannelId = oauth.allChannelId(serverId: serverId) ?? ""
            channels.insertOwnedChannel(channelId: allChannelId, serverId: serverId, userId: ownerId, name: "all")
            agentId = oauth.createAgent(serverId: serverId, name: "Cindy", displayName: "Cindy",
                                        runtime: "codex")
            oauth.setAgentStatus(id: agentId, status: agentStatus)
            agents.agentMachineIds = [agentId: machineId]
            machines.machines = [MachineRecord(id: machineId, serverId: serverId, userId: ownerId,
                                               name: "Computer", description: nil, apiKey: nil)]
            if bindAgent {
                channels.bindOnboardingAgent(serverId: serverId, agentId: agentId)
            }
            profiles.state.withLock { owned in
                let email = "briefing-owner@slock.test"
                owned.accountSurface.accounts[email] = Account(
                    id: ownerId, email: email, passwordHash: AuthFixturePassword.encoded("password123"),
                    passwordCredentialEstablishedAt: Date(), displayLanguage: nil, name: "owner",
                    displayName: "Owner Display", profileSetupSuggestedHandle: nil,
                    profileSetupProvider: nil, profileSetupCompletedAt: Date(), avatarUrl: nil,
                    referralSource: "search",
                    signupRole: surveyAnswered ? "founder" : nil,
                    signupSurveyCompletedAt: surveyAnswered ? Date(timeIntervalSinceReferenceDate: 810_000_000) : nil
                )
            }
            self.profiles = profiles
            self.agents = agents
            self.machines = machines
            self.channels = channels
            self.messages = messages
            self.oauth = oauth
            self.execution = AgentExecutionService(
                producerTransactionAgents: agents, machines: machines, oauth: oauth,
                channels: channels, messages: messages
            )
            self.context = AgentExecutionMachineContext(machineId: machineId, serverId: serverId,
                                                        connectionEpochId: "briefing-epoch")
            self.service = OnboardingBriefingService(
                channels: channels, profiles: profiles, agents: agents, messages: messages, oauth: oauth,
                execution: execution, now: { [fixedDate] in fixedDate }
            )
        }

        func prepareExecution(liveLaunch: Bool) async throws {
            let context = self.context
            let serverId = self.serverId
            let agentId = self.agentId
            let agents = self.agents
            _ = try await briefingCommit {
                try AgentExecutionDomain(agents: agents, machines: self.machines, oauth: self.oauth,
                                         channels: self.channels, messages: self.messages)
                    .connectionOpened(context)
                try AgentExecutionDomain(agents: agents, machines: self.machines, oauth: self.oauth,
                                         channels: self.channels, messages: self.messages)
                    .connectionReady(context, daemonInstanceId: "briefing-daemon", runtimes: ["codex"],
                                     runningAgentIds: [], detectionComplete: true)
            }
            guard liveLaunch else { return }
            let admission = try await briefingCommit {
                try self.execution.requestStart(.init(serverId: serverId, agentId: agentId, control: .humanStart))
            }
            let frame = try JSONSerialization.data(withJSONObject: [
                "type": "agent:start:ack", "agentId": agentId, "launchId": admission.launchId,
                "startDispatchId": admission.startDispatchId ?? "", "queueState": "starting",
                "queueDepth": 0, "queueAgeMs": 0,
            ], options: .sortedKeys)
            _ = try await briefingCommit {
                try AgentExecutionDomain(agents: agents, machines: self.machines, oauth: self.oauth,
                                         channels: self.channels, messages: self.messages)
                    .stageIngress(context: context, type: "agent:start:ack", payload: frame)
            }
        }

        func trigger(requestedBy: String? = nil, activated: String? = nil) async throws -> OnboardingBriefingOutcome {
            let serverId = self.serverId
            return try await briefingCommit {
                [self] in await service.trigger(serverId: serverId, requestedByOwnerId: requestedBy,
                                                activatedAgentId: activated)
            }
        }

        func connectionReady() async throws {
            let serverId = self.serverId
            try await briefingCommit { [self] in await service.connectionReady(serverId: serverId) }
        }

        func deliverOwnerFacts() async throws -> Bool {
            let serverId = self.serverId
            return try await briefingCommit { [self] in service.deliverOwnerFacts(serverId: serverId) }
        }

        /// Runs the ready hook and returns the durable intents it staged in
        /// their actual order (facts, then the opener ledger).
        func connectionReadyRecordingIntents() async throws -> [DurableEffectIntent] {
            let context = TransactionContext()
            let serverId = self.serverId
            return try await withTransactionContext(context) { [self] in
                await service.connectionReady(serverId: serverId)
                try context.prepareCommit()
                let intents = try context.preparedDurableEffects()
                context.publishCommitted()
                context.flushDeferredEffects()
                return intents
            }
        }

        var noticeCommands: [AgentExecutionCommand] {
            agents.state.execution.commands.values.filter { $0.kind == .notice }
        }

        var ledger: OwnerOpenerLedger {
            channels.ownerOpenerLedger(serverId: serverId, ownerId: ownerId)
        }

        var openerRows: [StoredHumanMessage] {
            messages.humanMessageRows.filter { $0.senderId == agentId }
        }
    }

    @Test func triggerPostsTheOwnerOpenerAndBriefsCindyThenStampsTheRealReceipt() async throws {
        let fixture = Fixture()
        try await fixture.prepareExecution(liveLaunch: true)
        let outcome = try await fixture.trigger(requestedBy: fixture.ownerId)
        guard case .sent(let agentId, let channelId, let messageIds, let commandId) = outcome else {
            Issue.record("expected sent, got \(outcome)")
            return
        }
        #expect(agentId == fixture.agentId)
        #expect(channelId == fixture.allChannelId)
        #expect(messageIds.count == 4)

        // The visible opener: four agent messages, one per upstream topic, in
        // the owner's enabled #all (no onboarding-owner channel exists here).
        let rows = fixture.openerRows
        #expect(rows.count == 5)
        let channelRows = rows.filter { $0.channelId == fixture.allChannelId }
        #expect(channelRows.map(\.id) == messageIds)
        let expectedKeys = OnboardingBriefingContent.openerV2Topics.map {
            "owner-opener-v2.0:\(fixture.serverId):\(fixture.ownerId):\($0)"
        }
        #expect(channelRows.map { $0.agentSendKey ?? "" } == expectedKeys)
        #expect(channelRows.allSatisfy { $0.senderType == "agent" })
        #expect(channelRows.map(\.content) == OnboardingBriefingContent.openerMessages(userName: "owner").map(\.content))

        // The briefing itself: one transient system notice, never a chat row.
        let commands = fixture.noticeCommands
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(command.commandId == commandId)
        #expect(command.messageId == "opener-v2-ledger-\(fixture.serverId)")
        #expect(command.channelId == fixture.allChannelId)
        #expect(command.notice?.channelType == "channel")
        let content = try #require(command.notice?.content)
        #expect(content.hasPrefix("Owner opener v2 ledger:\nopener_v2_sent=true\n"))
        #expect(content.contains("opener_v2_version=owner-opener-v2.0"))
        #expect(content.contains("opener_v2_message_ids=\(messageIds.joined(separator: ","))"))
        #expect(content.contains("opener_v2_topics=language_preference,team_mode_artifact,message_like_teammates,workflow_migration_or_create_agent_card"))
        #expect(content.contains("team_mode_artifact_attachment_id=191cda91-0b96-4be3-9461-7f74f16a2326"))
        #expect(content.contains("Continue onboarding @owner in #all channel from the owner's reply."))
        #expect(content.contains("They told us their role is: Founder. Pitch Raft and pick a starting point that fits that."))
        #expect(content.contains("They found Raft via: Search."))
        #expect(!content.contains("Onboarding task (system-triggered)"))

        // The one-shot sent ledger was written from the accepted receipt, with
        // one sentAt for the whole group.
        let ledger = fixture.ledger
        #expect(ledger.openerV2SentAt == fixture.fixedDate)
        #expect(ledger.openerV2SentByAgentId == fixture.agentId)
        #expect(ledger.openerV2MessageIds == messageIds)
        #expect(ledger.openerV2Version == "owner-opener-v2.0")
        #expect(ledger.openerV2Topics == OnboardingBriefingContent.openerV2Topics)
        #expect(ledger.dmSentAt == fixture.fixedDate)
        #expect(ledger.dmSentByAgentId == fixture.agentId)
        #expect(fixture.messages.humanMessageRows.allSatisfy { !$0.content.contains("Owner opener v2 ledger:") })

        // A second trigger (the second handoff click, another ready) is a
        // no-op: no second notice, no duplicate opener.
        #expect(try await fixture.trigger(requestedBy: fixture.ownerId) == .alreadySent)
        #expect(fixture.noticeCommands.count == 1)
        #expect(fixture.openerRows.count == 5)
    }

    @Test func droppedLedgerLeavesTheStampUnsetAndTheRetryIsInvisible() async throws {
        let fixture = Fixture()
        // Connected machine, active agent, but no live launch: a notice to a
        // dead agent is dropped, never cold-started.
        try await fixture.prepareExecution(liveLaunch: false)
        let dropped = try await fixture.trigger(requestedBy: fixture.ownerId)
        guard case .noticeDropped(let reason) = dropped else {
            Issue.record("expected noticeDropped, got \(dropped)")
            return
        }
        #expect(reason == .agentNotRunning)
        #expect(fixture.ledger.openerV2SentAt == nil)
        #expect(fixture.ledger.dmSentAt == nil)
        // The claim is released for the retry.
        #expect(fixture.ledger.openerClaimedAt == nil)
        // Upstream posts the visible opener before the ledger; retry dedupes it.
        let firstIds = fixture.openerRows.map(\.id)
        #expect(firstIds.count == 5)
        let firstChannelIds = fixture.openerRows.filter { $0.channelId == fixture.allChannelId }.map(\.id)
        #expect(firstChannelIds.count == 4)

        // The agent actually starts; the identical trigger now delivers and
        // stamps, without a second copy of the visible opener.
        try await fixture.prepareExecution(liveLaunch: true)
        let retried = try await fixture.trigger(requestedBy: fixture.ownerId)
        guard case .sent(_, _, let messageIds, _) = retried else {
            Issue.record("expected sent on retry, got \(retried)")
            return
        }
        #expect(messageIds == firstChannelIds)
        #expect(fixture.openerRows.map(\.id) == firstIds)
        #expect(fixture.ledger.openerV2SentAt == fixture.fixedDate)
        #expect(fixture.noticeCommands.count == 1)
    }

    @Test func gatesRefuseWithoutClaimingOrWritingTheSentStamp() async throws {
        // Survey unanswered: the survey screen is one step after Cindy's
        // creation, so this returns without claiming anything.
        let unsurveyed = Fixture(surveyAnswered: false)
        try await unsurveyed.prepareExecution(liveLaunch: true)
        #expect(try await unsurveyed.trigger(requestedBy: unsurveyed.ownerId) == .surveyPending)
        #expect(unsurveyed.ledger.openerV2SentAt == nil)
        #expect(unsurveyed.openerRows.isEmpty)
        #expect(unsurveyed.noticeCommands.isEmpty)

        // An inactive agent is deferred, not stamped (upstream does not brief a
        // dead agent).
        let inactive = Fixture(agentStatus: "active")
        try await inactive.prepareExecution(liveLaunch: true)
        // A human start sets the agent active; a stopped/inactive row while a
        // stale launch exists is exactly what the activation gate must refuse.
        inactive.oauth.setAgentStatus(id: inactive.agentId, status: "inactive")
        #expect(try await inactive.trigger(requestedBy: inactive.ownerId) == .agentInactive)
        #expect(inactive.ledger.openerV2SentAt == nil)
        #expect(inactive.noticeCommands.isEmpty)

        // The pinned default is opener-v2 ON; an explicitly provisioned row can
        // still turn it off. The legacy instruction path is not emitted here.
        let disabled = Fixture()
        try await disabled.prepareExecution(liveLaunch: true)
        disabled.agents.withState { owned in
            owned.featureFlagRecords["onboarding_opener_v2"] = FeatureFlagRecord(
                key: "onboarding_opener_v2", enabled: true, killSwitch: false, defaultEnabled: false
            )
        }
        #expect(try await disabled.trigger(requestedBy: disabled.ownerId) == .openerDisabled)
        #expect(disabled.noticeCommands.isEmpty)

        // Only the primary owner and the configured onboarding agent.
        let scoped = Fixture()
        try await scoped.prepareExecution(liveLaunch: true)
        #expect(try await scoped.trigger(requestedBy: "someone-else") == .notOwner)
        #expect(try await scoped.trigger(activated: "another-agent") == .notEligible)
        #expect(scoped.ledger.openerV2SentAt == nil)

        // No configured agent.
        let unbound = Fixture(bindAgent: false)
        try await unbound.prepareExecution(liveLaunch: true)
        #expect(try await unbound.trigger(requestedBy: unbound.ownerId) == .noOnboardingAgent)
        #expect(unbound.noticeCommands.isEmpty)

        // A legacy/generic briefing stamp blocks the opener entirely.
        let briefed = Fixture()
        try await briefed.prepareExecution(liveLaunch: true)
        briefed.channels.mutex.withLock { owned in
            var ledger = owned.ownerOpenerLedgers["\(briefed.serverId)\n\(briefed.ownerId)"] ?? OwnerOpenerLedger()
            ledger.dmSentAt = briefed.fixedDate
            owned.ownerOpenerLedgers["\(briefed.serverId)\n\(briefed.ownerId)"] = ledger
        }
        #expect(try await briefed.trigger(requestedBy: briefed.ownerId) == .alreadyBriefed)
        #expect(briefed.noticeCommands.isEmpty)
    }

    @Test func aStaleOnboardingAgentPointerIsClearedAndNeverReplaced() async throws {
        let fixture = Fixture(bindAgent: false)
        try await fixture.prepareExecution(liveLaunch: true)
        let otherServerAgent = fixture.oauth.createAgent(serverId: "foreign-server", name: "Foreign")
        fixture.channels.bindOnboardingAgent(serverId: fixture.serverId, agentId: otherServerAgent)
        #expect(try await fixture.trigger(requestedBy: fixture.ownerId) == .noOnboardingAgent)
        let snapshot = fixture.channels.onboardingSnapshot(serverId: fixture.serverId, userId: fixture.ownerId)
        #expect(snapshot.agentId == nil)
        #expect(fixture.noticeCommands.isEmpty)
    }

    @Test func claimLeaseAllowsOneSenderAndReleasesOnlyItsOwnToken() {
        let store = ServersAndChannelsStore()
        let server = "claim-server"
        let owner = "claim-owner"
        let first = Date(timeIntervalSinceReferenceDate: 100_000)
        #expect(store.claimOwnerOpener(serverId: server, ownerId: owner, now: first) == first)
        #expect(store.claimOwnerOpener(serverId: server, ownerId: owner, now: first.addingTimeInterval(1)) == nil)
        // A slow previous holder cannot clear the current claim.
        store.releaseOwnerOpenerClaim(serverId: server, ownerId: owner, token: first.addingTimeInterval(-1))
        #expect(store.ownerOpenerLedger(serverId: server, ownerId: owner).openerClaimedAt == first)
        store.releaseOwnerOpenerClaim(serverId: server, ownerId: owner, token: first)
        #expect(store.ownerOpenerLedger(serverId: server, ownerId: owner).openerClaimedAt == nil)
        // After the five-minute lease expires a new sender may take over.
        let later = first.addingTimeInterval(5 * 60 - 1)
        #expect(store.claimOwnerOpener(serverId: server, ownerId: owner, now: later) == later)
        #expect(store.claimOwnerOpener(serverId: server, ownerId: owner, now: later.addingTimeInterval(2)) == nil)
        // Exactly at the lease boundary it is still the holder's claim
        // (upstream `lt(claimed_at, now - lease)`), one second later it is not.
        let boundary = later.addingTimeInterval(5 * 60)
        #expect(store.claimOwnerOpener(serverId: server, ownerId: owner, now: boundary) == nil)
        let afterLease = boundary.addingTimeInterval(1)
        #expect(store.claimOwnerOpener(serverId: server, ownerId: owner, now: afterLease) == afterLease)
    }

    @Test func ownerFactsAreResentOnEveryWakeWithTheSurveyLines() async throws {
        let fixture = Fixture()
        try await fixture.prepareExecution(liveLaunch: true)
        #expect(try await fixture.deliverOwnerFacts())
        let facts = try #require(fixture.noticeCommands.first { $0.messageId?.hasPrefix("onboarding-owner-facts-") == true })
        #expect(facts.channelId == "onboarding-context")
        #expect(facts.notice?.channelName == "onboarding-context")
        #expect(facts.notice?.channelType == "channel")
        let expected = """
        Onboarding context for this server (re-sent on every start; not a message to reply to):
        owner_name=owner
        owner_display_name=Owner Display
        owner_role=Founder
        owner_found_us_via=Search

        This is what the owner told us about themselves when they signed up. Use it. If they ask
        what they told you, you know — do not say you were never told.
        """
        #expect(facts.notice?.content == expected)
        // No stamp and no chat row: facts are context, not a message.
        #expect(fixture.ledger.openerV2SentAt == nil)
        #expect(fixture.messages.humanMessageRows.isEmpty)

        // Ready = owner facts first, then the idempotent opener trigger, in
        // that durable-intent order.
        let intents = try await fixture.connectionReadyRecordingIntents()
        // Facts notice + four opener `realtime.publish` intents + the Team-Mode
        // reply publication + ledger notice.
        #expect(intents.count == 7)
        let commandIds = intents.compactMap { intent -> UUID? in
            try? JSONDecoder().decode(AgentExecutionIntentReference.self, from: intent.payload).commandId
        }
        #expect(commandIds.count == 2)
        let factsCommand = try #require(commandIds.first.flatMap { id in
            fixture.agents.state.execution.commands[id.uuidString]
        })
        let ledgerCommand = try #require(commandIds.last.flatMap { id in
            fixture.agents.state.execution.commands[id.uuidString]
        })
        #expect(factsCommand.messageId == "onboarding-owner-facts-\(fixture.serverId)")
        #expect(factsCommand.notice?.content == expected)
        #expect(ledgerCommand.messageId == "opener-v2-ledger-\(fixture.serverId)")
        #expect(fixture.ledger.openerV2SentAt == fixture.fixedDate)

        // The next wake re-sends the facts but never the already-sent ledger.
        try await fixture.connectionReady()
        #expect(fixture.noticeCommands.filter { $0.messageId == "opener-v2-ledger-\(fixture.serverId)" }.count == 1)
        #expect(fixture.noticeCommands.filter { $0.messageId == "onboarding-owner-facts-\(fixture.serverId)" }.count == 3)
    }

    @Test func ownerFactsDropQuietlyWhenTheAgentCannotReceive() async throws {
        let fixture = Fixture()
        try await fixture.prepareExecution(liveLaunch: false)
        #expect(try await fixture.deliverOwnerFacts() == false)
        #expect(fixture.noticeCommands.isEmpty)
        #expect(fixture.messages.humanMessageRows.isEmpty)
        #expect(fixture.ledger.openerV2SentAt == nil)
    }

    // MARK: - Persistence

    @Test func openerLedgerRoundTripsAndOldSnapshotsRestoreEmpty() throws {
        let fixture = Fixture()
        fixture.channels.stampOwnerOpener(
            serverId: fixture.serverId, ownerId: fixture.ownerId, agentId: fixture.agentId,
            at: fixture.fixedDate, messageIds: ["m1", "m2"], version: "owner-opener-v2.0",
            topics: ["language_preference", "team_mode_artifact"]
        )
        let exported = try fixture.channels.exportPersistenceData()
        let restored = ServersAndChannelsStore()
        try restored.restorePersistenceData(exported)
        let ledger = restored.ownerOpenerLedger(serverId: fixture.serverId, ownerId: fixture.ownerId)
        #expect(ledger.openerV2SentAt == fixture.fixedDate)
        #expect(ledger.dmSentAt == fixture.fixedDate)
        #expect(ledger.openerV2MessageIds == ["m1", "m2"])
        #expect(ledger.openerV2Topics == ["language_preference", "team_mode_artifact"])

        // The exact older shape: no owner-opener group at all.
        var root = try #require(try JSONSerialization.jsonObject(with: exported) as? [String: Any])
        var business = try #require(root["business"] as? [String: Any])
        business.removeValue(forKey: "ownerOpenerLedgers")
        root["business"] = business
        let oldShape = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let oldRestored = ServersAndChannelsStore()
        try oldRestored.restorePersistenceData(oldShape)
        #expect(oldRestored.ownerOpenerLedger(serverId: fixture.serverId, ownerId: fixture.ownerId)
            == OwnerOpenerLedger())
    }

}


private func briefingCommit<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
    let context = TransactionContext()
    return try await withTransactionContext(context) {
        let value = try await operation()
        try context.prepareCommit()
        context.publishCommitted()
        context.flushDeferredEffects()
        return value
    }
}
