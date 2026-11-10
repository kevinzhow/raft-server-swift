import Crypto
import Foundation
import RaftObjectStorage
import RaftShared
import Synchronization
import TestSupport
import Testing
@testable import RaftHTTP

/// The owner-opener Team-Mode artifact in the accepted-receipt path: the
/// thread, the generated HTML attachment, the `team-mode-thread` reply, the
/// ledger line that records it, and idempotent replay.
///
/// Upstream `sendOwnerOpenerV2` (`services/onboardingService.ts:531-602`) creates
/// the thread and the artifact for the `team_mode_artifact` message before it
/// posts the reply; the ledger's `team_mode_artifact_attachment_id` line is
/// conditional on that artifact. This fixture reaches the accepted notice
/// receipt in memory, so the one-shot stamp is written here too.
@Suite(.serialized) struct OnboardingBriefingArtifactTests {
    private final class MemoryStorage: AttachmentObjectStoring, Sendable {
        struct Put: Sendable {
            let attachmentID: String
            /// True when a referencing row already existed at put time. The
            /// port's attachment pipeline requires objects before rows, so this
            /// must be false for the first write.
            let rowExisted: Bool
        }

        private let messages: MessagesAndThreadsStore
        private let bytes = Mutex<[String: Data]>([:])
        private let puts = Mutex<[Put]>([])

        init(messages: MessagesAndThreadsStore) {
            self.messages = messages
        }

        var recordedPuts: [Put] { puts.withLock { $0 } }

        func put(attachmentID: String, bytes newBytes: Data) async throws -> AttachmentObjectReference {
            let rowExisted = messages.channelAttachments[attachmentID] != nil
            puts.withLock { $0.append(Put(attachmentID: attachmentID, rowExisted: rowExisted)) }
            bytes.withLock { $0[attachmentID] = newBytes }
            return AttachmentObjectReference(
                objectKey: "attachments/\(attachmentID)", sha256: Self.sha256(newBytes),
                byteCount: newBytes.count, encryptionVersion: 1
            )
        }

        func get(_ reference: AttachmentObjectReference) async throws -> Data {
            guard let id = reference.objectKey.split(separator: "/").last.map(String.init),
                  let stored = bytes.withLock({ $0[id] }) else {
                throw AttachmentStorageError.notFound
            }
            return stored
        }

        func delete(_ reference: AttachmentObjectReference) async throws {
            guard let id = reference.objectKey.split(separator: "/").last.map(String.init) else { return }
            bytes.withLock { $0.removeValue(forKey: id) }
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private final class Fixture: Sendable {
        let profiles: AuthProfileStore
        let agents: AgentsRuntimeStore
        let machines: MachinesAndComputersStore
        let channels: ServersAndChannelsStore
        let messages: MessagesAndThreadsStore
        let oauth: OAuthLedger
        let execution: AgentExecutionService
        let service: OnboardingBriefingService
        let storage: MemoryStorage
        let serverId: String
        let machineId: String
        let ownerId: String
        let agentId: String
        let allChannelId: String
        let fixedDate: Date
        let context: AgentExecutionMachineContext

        init(surveyAnswered: Bool = true) {
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
            let allChannelId = oauth.allChannelId(serverId: serverId) ?? ""
            self.allChannelId = allChannelId
            channels.insertOwnedChannel(channelId: allChannelId, serverId: serverId, userId: ownerId, name: "all")
            let agentId = oauth.createAgent(serverId: serverId, name: "Cindy", displayName: "Cindy", runtime: "codex")
            self.agentId = agentId
            oauth.setAgentStatus(id: agentId, status: "active")
            agents.agentMachineIds = [agentId: machineId]
            machines.machines = [MachineRecord(id: machineId, serverId: serverId, userId: ownerId,
                                               name: "Computer", description: nil, apiKey: nil)]
            channels.bindOnboardingAgent(serverId: serverId, agentId: agentId)
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
            let storage = MemoryStorage(messages: messages)
            self.storage = storage
            messages.withState { state in
                state.attachmentObjectStorage = storage
                state.requiresDurableAttachmentStorage = true
            }
            let execution = AgentExecutionService(
                producerTransactionAgents: agents, machines: machines, oauth: oauth,
                channels: channels, messages: messages
            )
            self.execution = execution
            self.context = AgentExecutionMachineContext(machineId: machineId, serverId: serverId,
                                                        connectionEpochId: "briefing-epoch")
            self.service = OnboardingBriefingService(
                channels: channels, profiles: profiles, agents: agents, messages: messages, oauth: oauth,
                execution: execution, now: { fixedDate }
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

        func trigger() async throws -> OnboardingBriefingOutcome {
            try await briefingCommit { [self] in await service.trigger(serverId: serverId, requestedByOwnerId: ownerId) }
        }

        /// The opener's durable intents in order: the visible-message
        /// publications and the transient notices.
        func triggerRecordingIntents() async throws -> [DurableEffectIntent] {
            let context = TransactionContext()
            return try await withTransactionContext(context) { [self] in
                _ = await service.trigger(serverId: serverId, requestedByOwnerId: ownerId)
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

        var agentRows: [StoredHumanMessage] {
            messages.humanMessageRows.filter { $0.senderId == agentId }.sorted { $0.seq < $1.seq }
        }

        var openerRows: [StoredHumanMessage] {
            agentRows.filter { $0.channelId == allChannelId }
        }

        var threadChannels: [(id: String, channel: PostableChannel)] {
            channels.postableChannels
                .filter { $0.value.serverId == serverId && $0.value.kind == "thread" }
                .map { (id: $0.key, channel: $0.value) }
                .sorted { ($0.channel.parentMessageId ?? "") < ($1.channel.parentMessageId ?? "") }
        }

        var artifactRows: [ChannelAttachment] {
            messages.channelAttachments.values.filter { $0.filename == "team-mode.html" }
        }
    }

    @Test func acceptedBriefingCreatesTheThreadReplyArtifactAndLedgerLine() async throws {
        let fixture = Fixture()
        try await fixture.prepareExecution(liveLaunch: true)
        let outcome = try await fixture.trigger()
        guard case .sent(_, let channelId, let messageIds, _) = outcome else {
            Issue.record("expected sent, got \(outcome)")
            return
        }
        #expect(channelId == fixture.allChannelId)
        #expect(messageIds.count == 4)

        // Four opener messages plus the thread reply, in upstream commit order:
        // the artifact reply lands between topic 2 and topic 3.
        let rows = fixture.agentRows
        #expect(rows.count == 5)
        #expect(rows[0].channelId == fixture.allChannelId)
        #expect(rows[1].channelId == fixture.allChannelId)
        #expect(rows[3].channelId == fixture.allChannelId)
        #expect(rows[4].channelId == fixture.allChannelId)
        #expect(fixture.openerRows.map(\.id) == messageIds)
        let parentMessage = try #require(fixture.openerRows.first {
            $0.agentSendKey == "owner-opener-v2.0:\(fixture.serverId):\(fixture.ownerId):team_mode_artifact"
        })

        // The canonical thread for the second opener message. The owner is a
        // thread member so the ordinary attachment read authority can admit the
        // owner through the existing thread model (parent-channel readers can
        // already read the thread; the attachment route checks membership).
        let threads = fixture.threadChannels
        #expect(threads.count == 1)
        let thread = try #require(threads.first)
        #expect(thread.channel.parentChannelId == fixture.allChannelId)
        #expect(thread.channel.parentMessageId == parentMessage.id)
        #expect(thread.channel.memberIds.contains(fixture.ownerId))
        #expect(thread.channel.memberIds.contains(fixture.agentId))

        let replies = fixture.agentRows.filter { $0.channelId == thread.id }
        #expect(replies.count == 1)
        let reply = try #require(replies.first)
        #expect(rows[2].id == reply.id)
        #expect(rows[2].channelId == thread.id)
        #expect(reply.content == "Here's what team mode looks like in practice:")
        #expect(reply.agentSendKey == "owner-opener-v2.0:\(fixture.serverId):\(fixture.ownerId):team-mode-thread")
        #expect(reply.messageType == "chat" && reply.senderType == "agent")

        // The generated attachment row. The id is the upstream stable UUID for
        // `owner-opener-v2.0:<server>:<owner>:team-mode`; the reference is the
        // real object written before this row.
        let artifacts = fixture.artifactRows
        #expect(artifacts.count == 1)
        let artifact = try #require(artifacts.first)
        #expect(artifact.id == "191cda91-0b96-4be3-9461-7f74f16a2326")
        #expect(reply.attachmentIds == [artifact.id])
        #expect(artifact.channelId == thread.id)
        #expect(artifact.uploaderId == fixture.agentId)
        #expect(artifact.uploaderType == "agent")
        #expect(artifact.mimeType == "text/html")
        #expect(artifact.sizeBytes == OnboardingBriefingContent.teamModeArtifactByteCount)
        #expect(artifact.messageId == reply.id)
        #expect(artifact.storageKey == "attachments/\(artifact.id)")
        let reference = try #require(fixture.messages.withState { $0.attachmentObjectReferences[artifact.id] })
        #expect(reference.objectKey == "attachments/\(artifact.id)")
        #expect(reference.byteCount == OnboardingBriefingContent.teamModeArtifactByteCount)
        #expect(reference.sha256 == OnboardingBriefingContent.teamModeArtifactSHA256)
        // Objects are written before the referencing row: one write, no row yet.
        let puts = fixture.storage.recordedPuts
        #expect(puts.count == 1)
        #expect(puts.first?.attachmentID == artifact.id)
        #expect(puts.first?.rowExisted == false)

        // The ledger carries the artifact id in its conditional line, in the
        // upstream position right after the topics line.
        let commands = fixture.noticeCommands
        #expect(commands.count == 1)
        let content = try #require(commands.first?.notice?.content)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let topicsIndex = try #require(lines.firstIndex { $0.hasPrefix("opener_v2_topics=") })
        #expect(lines[topicsIndex + 1] == "team_mode_artifact_attachment_id=\(artifact.id)")
        #expect(content.hasPrefix("Owner opener v2 ledger:\nopener_v2_sent=true\n"))

        // The stamp is still the typed accepted receipt, one sentAt for the group.
        let ledger = fixture.ledger
        #expect(ledger.openerV2SentAt == fixture.fixedDate)
        #expect(ledger.openerV2MessageIds == messageIds)

        // A second trigger is a no-op for the artifact too.
        #expect(try await fixture.trigger() == .alreadySent)
        #expect(fixture.threadChannels.map(\.id) == threads.map(\.id))
        #expect(fixture.artifactRows.map(\.id) == [artifact.id])
        #expect(fixture.storage.recordedPuts.count == 1)
    }

    @Test func threadReplyPublicationCarriesTheSevenFieldAttachmentManifest() async throws {
        let fixture = Fixture()
        try await fixture.prepareExecution(liveLaunch: true)
        let intents = try await fixture.triggerRecordingIntents()
        let thread = try #require(fixture.threadChannels.first)
        let publications = intents.compactMap { intent -> RealtimePublication? in
            guard intent.kind == "realtime.publish" else { return nil }
            return try? JSONDecoder().decode(RealtimePublication.self, from: intent.payload)
        }
        #expect(publications.count == 5)
        #expect(publications.filter { $0.room == "channel:\(thread.id)" }.count == 1)
        let replyPublication = try #require(publications.first { $0.room == "channel:\(thread.id)" })
        #expect(replyPublication.event == "message:new")
        let payload = try #require(try JSONSerialization.jsonObject(
            with: Data(replyPublication.payloadJSON.utf8)) as? [String: Any])
        #expect(payload["channelId"] as? String == thread.id)
        #expect(payload["content"] as? String == "Here's what team mode looks like in practice:")
        let attachments = try #require(payload["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        let attachment = try #require(attachments.first)
        #expect(Set(attachment.keys) == ["id", "filename", "mimeType", "sizeBytes", "width", "height", "thumbnailUrl"])
        #expect(attachment["id"] as? String == "191cda91-0b96-4be3-9461-7f74f16a2326")
        #expect(attachment["filename"] as? String == "team-mode.html")
        #expect(attachment["mimeType"] as? String == "text/html")
        #expect(attachment["sizeBytes"] as? Int == OnboardingBriefingContent.teamModeArtifactByteCount)
        #expect(attachment["width"] is NSNull)
        #expect(attachment["height"] is NSNull)
        #expect(attachment["thumbnailUrl"] is NSNull)
        let context = try #require(payload["conversationContext"] as? [String: Any])
        #expect(context["channelType"] as? String == "thread")
        #expect(context["parentMessageId"] as? String == thread.channel.parentMessageId)
        #expect(context["parentChannelId"] as? String == fixture.allChannelId)
        #expect(context["parentChannelType"] as? String == "channel")
    }

    @Test func retryAfterADroppedLedgerReusesTheArtifactThreadAndObject() async throws {
        let fixture = Fixture()
        try await fixture.prepareExecution(liveLaunch: false)
        let dropped = try await fixture.trigger()
        guard case .noticeDropped(.agentNotRunning) = dropped else {
            Issue.record("expected a dropped ledger, got \(dropped)")
            return
        }
        // The visible opener and its thread are already there; nothing stamped.
        #expect(fixture.ledger.openerV2SentAt == nil)
        #expect(fixture.ledger.openerClaimedAt == nil)
        let firstThread = try #require(fixture.threadChannels.first)
        let firstReplies = fixture.agentRows.filter { $0.channelId == firstThread.id }
        let firstArtifact = try #require(fixture.artifactRows.first)
        #expect(firstReplies.count == 1)

        // The agent starts; the identical trigger now delivers the ledger.
        try await fixture.prepareExecution(liveLaunch: true)
        let retried = try await fixture.trigger()
        guard case .sent(_, _, let messageIds, _) = retried else {
            Issue.record("expected sent on retry, got \(retried)")
            return
        }
        #expect(fixture.threadChannels.map(\.id) == [firstThread.id])
        #expect(fixture.agentRows.filter { $0.channelId == firstThread.id }.map(\.id) == firstReplies.map(\.id))
        #expect(fixture.artifactRows.map(\.id) == [firstArtifact.id])
        #expect(fixture.storage.recordedPuts.count == 1)
        #expect(fixture.openerRows.map(\.id) == messageIds)
        let content = try #require(fixture.noticeCommands.first?.notice?.content)
        #expect(content.contains("team_mode_artifact_attachment_id=\(firstArtifact.id)"))
        #expect(fixture.ledger.openerV2SentAt == fixture.fixedDate)
    }
}

private func briefingCommit<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async throws -> Value {
    let context = TransactionContext()
    return try await withTransactionContext(context) {
        let value = try await operation()
        try context.prepareCommit()
        context.publishCommitted()
        context.flushDeferredEffects()
        return value
    }
}
