import Foundation
import Testing
@testable import RaftHTTP

/// Upstream `agent:start` resume context over the retained read cursors:
/// unread summary, the bounded catch-up batch, ordering and the transport-owned
/// exclusion this port needs because it delivers the wake as its own frame.
@Suite(.serialized) struct AgentResumeContextTests {
    private struct Fixture: Sendable {
        let messages: MessagesAndThreadsStore
        let channels: ServersAndChannelsStore
        let oauth: OAuthLedger
        let tasks: TasksAndRemindersStore
        let profiles: AuthProfileStore
        let server = "resume-server"
        let agent: String
        let dm: String
        let room: String
    }

    private func fixture() -> Fixture {
        let messages = MessagesAndThreadsStore()
        let channels = ServersAndChannelsStore()
        let oauth = OAuthLedger()
        let profiles = AuthProfileStore()
        oauth.addOwnedServer(id: "resume-server", slug: "resume", name: "Resume", ownerId: "owner")
        let agent = oauth.createAgent(serverId: "resume-server", name: "Cindy", runtime: "codex")
        let dm = oauth.createChannel(serverId: "resume-server", name: "dm-cindy", creatorUserId: "owner")
        channels.addDirectMessage(serverId: "resume-server", channelId: dm, participantIds: ["owner", agent], agentId: agent)
        oauth.addChannelAgent(channelId: dm, agentId: agent)
        let room = oauth.createChannel(serverId: "resume-server", name: "resume-room", creatorUserId: "owner")
        channels.addPostableChannel(serverId: "resume-server", channelId: room, memberId: "owner",
                                    kind: "private", name: "resume-room")
        channels.addPostableChannel(serverId: "resume-server", channelId: room, memberId: agent,
                                    kind: "private", name: "resume-room")
        oauth.addChannelAgent(channelId: room, agentId: agent)
        return Fixture(messages: messages, channels: channels, oauth: oauth,
                       tasks: TasksAndRemindersStore(), profiles: profiles,
                       agent: agent, dm: dm, room: room)
    }

    @discardableResult
    private func addMessage(_ f: Fixture, channel: String, seq: Int, content: String,
                            sender: String = "owner", at offset: TimeInterval = 0) -> String {
        let id = "resume-message-\(channel)-\(seq)"
        f.messages.withState { state in
            state.humanMessageRows.append(StoredHumanMessage(
                id: id, channelId: channel, senderId: sender, content: content, seq: seq,
                messageType: "chat", senderType: "user",
                createdAt: Date(timeIntervalSinceReferenceDate: 1_000 + offset)))
        }
        return id
    }

    private func build(_ f: Fixture) -> AgentResumeContext.Output {
        AgentResumeContext(messages: f.messages, channels: f.channels, oauth: f.oauth,
                           tasks: f.tasks, profiles: f.profiles)
            .build(serverId: f.server, agentId: f.agent)
    }

    @Test func unreadMessagesBecomeTheBoundedCatchupAndSummary() throws {
        let f = fixture()
        addMessage(f, channel: f.dm, seq: 3, content: "DM one")
        addMessage(f, channel: f.dm, seq: 4, content: "DM two")
        addMessage(f, channel: f.room, seq: 5, content: "@Cindy room one")
        // Read history is not resume context.
        f.messages.setAgentReadCursor(channelId: f.room, agentId: f.agent, seq: 2)
        let output = build(f)
        #expect(output.resumeMessages.count == 3)
        #expect(output.resumeMessages.allSatisfy {
            if case .object = $0 { true } else { false }
        })
        // The DM is the piercing conversation (DMs sort before channels).
        let first = try #require(output.resumeMessages.first)
        guard case .object(let fields) = first else { throw ResumeTestFailure.invalid }
        #expect(fields["channel_id"] == .string(f.dm))
        #expect(fields["channel_type"] == .string("dm"))
        #expect(fields["message_id"] == .string("resume-message-\(f.dm)-3"))
        // Summary labels use the agent-facing target DSL.
        let dmKey = try #require(output.unreadSummary?.keys.first { $0.hasPrefix("dm:@") })
        #expect(output.unreadSummary?[dmKey] == 2)
        #expect(output.unreadSummary?["#resume-room"] == 1)
    }

    @Test func everyUnreadRowIsCatchupInputAndTheDaemonOwnsDedupe() throws {
        let f = fixture()
        addMessage(f, channel: f.dm, seq: 3, content: "DM one")
        addMessage(f, channel: f.dm, seq: 4, content: "DM two")
        // Both rows are unread even if a separate `agent:deliver` frame also
        // carries them; upstream sends the whole unread catch-up and the
        // daemon decides what the model already saw.
        let output = build(f)
        #expect(output.resumeMessages.count == 2)
        #expect(output.unreadSummary?.values.reduce(0, +) == 2)
    }

    @Test func catchupIsBoundedToTheUpstreamRowAndChannelCaps() throws {
        let f = fixture()
        var extra: [String] = []
        // Nine conversations with unread rows: at most 8 contribute.
        for index in 0..<9 {
            let channel = index == 0 ? f.room : f.oauth.createChannel(
                serverId: f.server, name: "bounded-\(index)", creatorUserId: "owner")
            f.channels.addPostableChannel(serverId: f.server, channelId: channel, memberId: "owner",
                                          kind: "private", name: "bounded-\(index)")
            f.channels.addPostableChannel(serverId: f.server, channelId: channel, memberId: f.agent,
                                          kind: "private", name: "bounded-\(index)")
            f.oauth.addChannelAgent(channelId: channel, agentId: f.agent)
            for seq in 1...4 {
                addMessage(f, channel: channel, seq: index * 10 + seq, content: "row \(seq)")
            }
            extra.append(channel)
        }
        let output = build(f)
        #expect(output.resumeMessages.count <= AgentResumeContext.maxRowsTotal)
        let channelIds = Set(output.resumeMessages.compactMap { value -> String? in
            guard case .object(let fields) = value, case .string(let id)? = fields["channel_id"] else { return nil }
            return id
        })
        #expect(channelIds.count <= AgentResumeContext.maxChannels)
        // Per-channel rows never exceed the per-channel cap.
        for channel in channelIds {
            let count = output.resumeMessages.filter {
                guard case .object(let fields) = $0 else { return false }
                return fields["channel_id"] == .string(channel)
            }.count
            #expect(count <= AgentResumeContext.maxRowsPerChannel)
        }
    }

    @Test func unreadSummaryCapsAtTwentyTargetsAndFoldsTheRest() {
        var counts: [String: Int] = [:]
        for index in 0..<23 {
            counts["#room-\(index)"] = index + 1
        }
        counts["dm:@peer"] = 1
        let capped = AgentResumeContext.capSummary(counts)
        #expect(capped.count == AgentResumeContext.maxSummaryTargets + 1)
        #expect(capped["dm:@peer"] == 1, "DMs sort first")
        // The folded line names how many conversations were left out.
        let folded = capped.first { $0.key.contains("more conversations") }
        #expect(folded != nil)
        #expect(folded?.value == 10, "the four smallest room counts fold: 4+3+2+1")
    }

    @Test func noUnreadMeansNoSummaryAndNoCatchup() {
        let f = fixture()
        let output = build(f)
        #expect(output.resumeMessages.isEmpty)
        #expect(output.unreadSummary == nil)
    }

    private enum ResumeTestFailure: Error { case invalid }
}
