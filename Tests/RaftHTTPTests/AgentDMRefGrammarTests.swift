import Foundation
import Testing
@testable import RaftHTTP

/// The agent-facing ref grammar (`parseChannelRef` / `parseDmPeerRef`) and the
/// stable cross-kind twin label (`findCrossKindTwinPeerNames` / `agentFacingDmRef`).
@Suite(.serialized) struct AgentDMRefGrammarTests {
    // MARK: - `channelService.parseChannelRef` (channelService.ts:7256-7275)

    @Test func threadSuffixIsExactlyEightHexDigits() {
        // A full 8-hex suffix (either case) is the thread short id.
        #expect(AgentChannelRef.parse("#room:abcdef01") ==
            AgentChannelRef.ParsedRef(baseRef: "#room", threadShortId: "abcdef01"))
        #expect(AgentChannelRef.parse("#room:ABCDEF01") ==
            AgentChannelRef.ParsedRef(baseRef: "#room", threadShortId: "ABCDEF01"))
        #expect(AgentChannelRef.parse("dm:@peer:abcdef01") ==
            AgentChannelRef.ParsedRef(baseRef: "dm:@peer", threadShortId: "abcdef01"))
        #expect(AgentChannelRef.parse("DM:@peer:abcdef01") ==
            AgentChannelRef.ParsedRef(baseRef: "DM:@peer", threadShortId: "abcdef01"))

        // Anything else stays in the base ref: a short id that is too short,
        // too long, non-hex, or empty cannot become a thread.
        for ref in ["#room:1", "#room:abcdef0", "#room:abcdef012", "#room:zzzzzzzz",
                    "#room:", "#room:abcdef0g", "dm:@peer:1", "dm:@peer:deadbeef00"] {
            let parsed = AgentChannelRef.parse(ref)
            #expect(parsed.threadShortId == nil, "\(ref) must not split a thread suffix")
            #expect(parsed.baseRef == ref, "\(ref) must remain wholly in the base ref")
        }
        // The `lastColon > 0` rule: a suffix at the start of the rest is not a
        // thread split (the base would otherwise lose its only segment).
        #expect(AgentChannelRef.parse("dm:@:abcdef01").baseRef == "dm:@:abcdef01")
        #expect(AgentChannelRef.parse("dm:@:abcdef01").threadShortId == nil)
    }

    // MARK: - `shared/src/dmPeerRef.ts` (dmPeerRef.ts:29-39)

    @Test func peerKindIsTheExactLowercaseSuffixBeforeAnyThreadId() {
        #expect(AgentChannelRef.parsePeer("Twin") == .ok(name: "Twin", kind: nil))
        #expect(AgentChannelRef.parsePeer("Twin~agent") == .ok(name: "Twin", kind: "agent"))
        #expect(AgentChannelRef.parsePeer("Twin~human") == .ok(name: "Twin", kind: "human"))
        // Case variants and unknown words are refused, never read as a name.
        #expect(AgentChannelRef.parsePeer("Twin~AGENT") == .unknownKind("AGENT"))
        #expect(AgentChannelRef.parsePeer("Twin~bot") == .unknownKind("bot"))
        #expect(AgentChannelRef.parsePeer("Twin~") == .unknownKind(""))
        #expect(AgentChannelRef.parsePeer("~agent") == .emptyName)
        #expect(AgentChannelRef.parsePeer("") == .emptyName)
        // Only the first `~` is the separator; the suffix is everything after it.
        #expect(AgentChannelRef.parsePeer("Twin~agent~human") == .unknownKind("agent~human"))
        #expect(AgentChannelRef.formatPeer("Twin", kind: "agent") == "Twin~agent")
        #expect(AgentChannelRef.formatPeer("Twin", kind: nil) == "Twin")
    }

    // MARK: - `findCrossKindTwinPeerNames` / `agentFacingDmRef`

    @Test func twinLabelNeedsOnlyTheServerDirectoryNotBothDMs() {
        // A human member and a live agent share the exact canonical name; no
        // DM row is involved, so the label is stable before either DM exists.
        let directory = AgentDMRefDirectory(
            humanMemberNames: ["Twin", "alice"],
            agentNames: ["Twin", "Grace"]
        )
        #expect(directory.hasTwin("Twin"))
        #expect(!directory.hasTwin("alice"))
        #expect(directory.label(name: "Twin", kind: "human") == "dm:@Twin~human")
        #expect(directory.label(name: "Twin", kind: "agent") == "dm:@Twin~agent")
        #expect(directory.label(name: "alice", kind: "human") == "dm:@alice")
        #expect(directory.label(name: "Grace", kind: "agent") == "dm:@Grace")
    }

    // MARK: - Resume/local-context unread summary

    @Test func resumeSummaryLabelsTheTwinKindOnEachConversation() throws {
        let accounts = EmailLoginDirectory()
        let server = "33333333-3333-4333-8333-000001400001"
        let owner = "11111111-1111-4111-8111-000001400001"
        let humanTwin = "11111111-1111-4111-8111-000001400002"
        for (id, email) in [(owner, "resume-twin-owner"), (humanTwin, "resume-twin-human")] {
            accounts.addAccount(id: id, email: "\(email)@slock.test", password: "password123")
            accounts.markEmailVerified(userId: id)
        }
        accounts.oauth.addOwnedServer(id: server, slug: "resume-twin", name: "Resume Twin", ownerId: owner)
        accounts.setAccountProfileForTesting(id: humanTwin, name: "Twin")
        accounts.oauth.addMember(serverId: server, userId: humanTwin, role: "member")
        let grace = accounts.oauth.createAgent(serverId: server, name: "Grace", runtime: "claude")
        let agentTwin = accounts.oauth.createAgent(serverId: server, name: "Twin", runtime: "claude")
        let solo = accounts.oauth.createAgent(serverId: server, name: "Solo", runtime: "claude")

        func dm(peer: String, kind: OAuthLedger.DirectChannelParticipantKind) -> String {
            let channel = accounts.oauth.createDirectChannel(
                serverId: server, firstUserId: grace, secondUserId: peer,
                firstKind: .agent, secondKind: kind
            )
            accounts.addPostableChannel(serverId: server, channelId: channel, memberId: grace, kind: "dm")
            accounts.addPostableChannel(serverId: server, channelId: channel, memberId: peer, kind: "dm")
            return channel
        }
        let humanTwinDm = dm(peer: humanTwin, kind: .human)
        let soloDm = dm(peer: solo, kind: .agent)
        _ = accounts.addHumanMessageForTesting(channelId: humanTwinDm, senderId: humanTwin, content: "from the human Twin")
        _ = accounts.addHumanMessageForTesting(channelId: soloDm, senderId: solo, content: "from Solo")

        let context = AgentResumeContext(
            messages: accounts.messagesAndThreadsStore,
            channels: accounts.serversAndChannelsStore,
            oauth: accounts.oauth,
            tasks: accounts.tasksAndRemindersStore,
            profiles: accounts.authProfileStore
        )
        // The agent Twin exists in the directory, but its DM does not yet: the
        // human Twin conversation must already carry `~human`, not flip later
        // when the second DM appears.
        let beforeSecondDM = context.build(serverId: server, agentId: grace)
        let beforeSummary = try #require(beforeSecondDM.unreadSummary)
        #expect(beforeSummary["dm:@Twin~human"] == 1)
        #expect(beforeSummary["dm:@Solo"] == 1)
        #expect(beforeSummary["dm:@Twin"] == nil)

        let agentTwinDm = dm(peer: agentTwin, kind: .agent)
        _ = accounts.addHumanMessageForTesting(channelId: agentTwinDm, senderId: agentTwin, content: "from the agent Twin")
        let afterSecondDM = context.build(serverId: server, agentId: grace)
        let afterSummary = try #require(afterSecondDM.unreadSummary)
        #expect(afterSummary["dm:@Twin~human"] == 1)
        #expect(afterSummary["dm:@Twin~agent"] == 1)
        #expect(afterSummary["dm:@Solo"] == 1)
        // A bare twin name may not label either conversation: it names both.
        #expect(afterSummary["dm:@Twin"] == nil)
    }
}
