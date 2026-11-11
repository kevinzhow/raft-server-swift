import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The tool-execution service owns the published saved-message, direct-channel,
/// read-state and agent mute/archive replies. These tests lock the exact bytes,
/// the typed refusals and the read-state critical sections.

private struct ToolFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let memberId: String
    let ownerToken: String
    let memberToken: String
    let channelId: String
    let agentId: String

    var ownerAuthorization: String { "Bearer \(ownerToken)" }
    var memberAuthorization: String { "Bearer \(memberToken)" }
    var service: ManagedMCPToolExecutionService { accounts.managedMCPToolExecution }
}

private func makeFixture(_ suffix: String) -> ToolFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000987\(suffix)"
    let ownerId = "11111111-1111-4111-8111-000000987\(suffix)"
    let memberId = "11111111-1111-4111-8111-000000988\(suffix)"
    for (id, email) in [(ownerId, "tool-owner-\(suffix)@slock.test"), (memberId, "tool-member-\(suffix)@slock.test")] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "tool-\(suffix)", name: "Tool \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "tool-\(suffix)", creatorUserId: ownerId)
    for id in [ownerId, memberId] {
        accounts.addPostableChannel(serverId: serverId, channelId: channelId, memberId: id, name: "tool-\(suffix)")
        accounts.oauth.addChannelHuman(channelId: channelId, userId: id)
    }
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "atlas-\(suffix)", runtime: "codex")
    return ToolFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        memberId: memberId,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        channelId: channelId,
        agentId: agentId
    )
}

private func body(_ error: any DomainError) -> String {
    error.publishedErrorBody.render()
}

// MARK: - DTO bytes

@Test func savedAndDirectChannelResponsesRenderThePublishedMemberOrder() throws {
    #expect(try String(decoding: JSONEncoder.sortedForTesting.encode(SavedCheckResponse(savedIds: ["a", "b"])), as: UTF8.self)
        == #"{"savedIds":["a","b"]}"#)

    let row = SavedMessageRowDTO(
        messageId: "m", channelId: "c", channelType: "channel", content: "hi \"there\"",
        parentChannelId: nil, parentMessageId: nil, parentMessagePreview: nil, replyCount: 2
    )
    #expect(SavedMessagesResponse(saved: [row], total: 5, hasMore: true).jsonBody.render() == """
    {"saved":[{"messageId":"m","channelId":"c","channelType":"channel","content":"hi \\"there\\"","parentChannelId":null,"parentMessageId":null,"parentMessagePreview":null,"replyCount":2}],"total":5,"hasMore":true}
    """)
    #expect(SavedMessagesResponse(saved: [], total: 0, hasMore: false).jsonBody.render()
        == #"{"saved":[],"total":0,"hasMore":false}"#)

    #expect(AllChannelVisibilityResponse(id: "c", visible: false).jsonBody.render() == #"{"id":"c","visible":false}"#)

    let agentPeer = DirectChannelPeerFacts(
        peerId: "a", peerName: "atlas", peerDisplayName: "Atlas", peerDescription: nil,
        peerGravatarHash: nil, peerAvatarUrl: nil, peerType: "agent"
    )
    #expect(DirectChannelResponse(
        id: "d", name: "", description: nil, createdAt: "2026-01-01T00:00:00.000Z", peer: agentPeer
    ).jsonBody.render() == """
    {"id":"d","name":"","type":"dm","description":null,"createdAt":"2026-01-01T00:00:00.000Z","peerId":"a","peerName":"atlas","peerDisplayName":"Atlas","peerDescription":null,"peerGravatarHash":null,"peerAvatarUrl":null,"peerType":"agent"}
    """)
    let userPeer = DirectChannelPeerFacts(
        peerId: "p", peerName: "peer", peerDisplayName: "Peer", peerDescription: nil,
        peerGravatarHash: "hash", peerAvatarUrl: "https://cdn.test/p.png", peerType: "user"
    )
    #expect(DirectChannelResponse(
        id: "d", name: "peer", description: nil, createdAt: "2026-01-01T00:00:00.000Z", peer: userPeer
    ).jsonBody.render() == """
    {"id":"d","name":"peer","type":"dm","description":null,"createdAt":"2026-01-01T00:00:00.000Z","peerType":"user","peerId":"p","peerName":"peer","peerDisplayName":"Peer","peerDescription":null,"peerAvatarUrl":"https://cdn.test/p.png","peerGravatarHash":"hash"}
    """)

    let listed = DirectChannelListRowDTO(
        id: "d", name: "peer", description: nil, createdAt: "2026-01-01T00:00:00.000Z", peer: userPeer,
        activityMuted: false, muteFromSeq: nil, prefsVersion: 0, collapseLongMessages: true,
        displayPrefsVersion: 0, maxReadSeq: 0, readStateVersion: 0, readState: .absent,
        lastMessageAt: "2026-01-02T00:00:00.000Z", lastMessagePreview: "yo", lastMessageSenderName: nil
    )
    #expect(DirectChannelListResponse(rows: [listed]).jsonBody.render() == """
    [{"id":"d","name":"peer","type":"dm","description":null,"createdAt":"2026-01-01T00:00:00.000Z","peerId":"p","peerName":"peer","peerDisplayName":"Peer","peerDescription":null,"peerAvatarUrl":"https://cdn.test/p.png","peerGravatarHash":"hash","peerType":"user","activityMuted":false,"muteFromSeq":null,"prefsVersion":0,"activityMuteSupported":false,"collapseLongMessages":true,"displayPrefsVersion":0,"maxReadSeq":0,"readStateVersion":0,"readState":{"kind":"absent"},"lastMessageAt":"2026-01-02T00:00:00.000Z","lastMessagePreview":"yo","lastMessageSenderName":null}]
    """)
    #expect(DirectChannelListResponse(rows: []).jsonBody.render() == "[]")
}

@Test func readStateAndAgentResponsesRenderThePublishedMemberOrder() {
    #expect(ChannelReadStateResponse(maxReadSeq: 4, readStateVersion: 2).jsonBody.render()
        == #"{"ok":true,"maxReadSeq":4,"readStateVersion":2}"#)
    #expect(ChannelReadAllResponse(seq: 9, readStateVersion: 1).jsonBody.render()
        == #"{"ok":true,"seq":9,"readStateVersion":1}"#)
    #expect(ResumeAllAgentsResponse(started: 1, total: 2, results: [
        .init(agentId: "a", skipReason: nil),
        .init(agentId: "b", skipReason: "start_in_flight"),
    ]).jsonBody.render() == """
    {"ok":false,"started":1,"total":2,"results":[{"agentId":"a","ok":true},{"agentId":"b","ok":false,"reason":"start_in_flight"}]}
    """)
    #expect(ResumeAllAgentsResponse(started: 0, total: 0, results: []).jsonBody.render()
        == #"{"ok":true,"started":0,"total":0,"results":[]}"#)
    #expect(AgentChannelArchiveResponse(archived: true).jsonBody.render() == #"{"ok":true,"archived":true}"#)
    #expect(AgentChannelMuteResponse(muted: false, muteFromSeq: nil, channelId: "c", channelName: "general").jsonBody.render() == """
    {"activityMuted":false,"muteFromSeq":null,"attention":{"state":"unmuted","muteCommand":"raft channel mute #general"}}
    """)
    #expect(AgentChannelMuteResponse(muted: true, muteFromSeq: 7, channelId: "c", channelName: "general").jsonBody.render() == """
    {"activityMuted":true,"muteFromSeq":7,"attention":{"state":"muted","unmuteCommand":"raft channel unmute #general","unmuteApi":"POST /internal/agent-api/channels/c/unmute","stillArrives":["Personal @mentions still arrive.","Direct messages still arrive.","Threads you follow deliver independently."],"threadBoundary":"Channel mute suppresses ordinary Activity from this channel only. Threads you follow keep delivering independently until you unfollow them.","catchUp":"Run `raft channel history #general` or GET /internal/agent-api/history to catch up."}}
    """)
}

@Test func channelDetailRendersTheDirectPeerCapabilitiesAndPeerReadState() {
    let capabilities = ChannelDetailResponse.Capabilities(
        editChannelMetadata: true, archiveChannels: false, addChannelMembers: true, removeChannelMembers: false,
        changeChannelMemberRoles: true, manageGuestAccess: false, deleteChannels: true,
        changeChannelVisibility: false, federateChannels: true
    )
    func detail(peer: DirectChannelPeerFacts?, read: ChannelDetailResponse.PeerReadState?) -> String {
        ChannelDetailResponse(
            id: "c", serverId: "s", name: "general", description: nil, type: "dm", createdAt: "2026-01-01T00:00:00.000Z",
            directPeer: peer, joined: true, collapseLongMessages: true, displayPrefsVersion: 2,
            maxReadSeq: 3, readStateVersion: 1, readState: .present(readStateVersion: 1, maxReadSeq: 3),
            activityMuteSupported: false, channelRole: "admin", channelAdminBasis: nil,
            capabilities: capabilities, channelAuthorityRevision: 4, peerReadState: read
        ).jsonBody.render()
    }
    let head = #"{"id":"c","serverId":"s","name":"general","description":null,"type":"dm","createdAt":"2026-01-01T00:00:00.000Z""#
    let tail = #""joined":true,"collapseLongMessages":true,"displayPrefsVersion":2,"maxReadSeq":3,"readStateVersion":1,"readState":{"kind":"present","readStateVersion":1,"maxReadSeq":"3","latestActivity":null},"activityMuteSupported":false,"channelRole":"admin","channelAdminBasis":null,"channelCapabilities":{"editChannelMetadata":true,"archiveChannels":false,"addChannelMembers":true,"removeChannelMembers":false,"changeChannelMemberRoles":true,"manageGuestAccess":false,"deleteChannels":true,"changeChannelVisibility":false,"federateChannels":true},"channelAuthorityRevision":4"#
    #expect(detail(peer: nil, read: nil) == head + "," + tail + "}")
    let agentPeer = DirectChannelPeerFacts(
        peerId: "a", peerName: "Atlas", peerDisplayName: "Atlas Display", peerDescription: nil,
        peerGravatarHash: nil, peerAvatarUrl: nil, peerType: "agent"
    )
    #expect(detail(peer: agentPeer, read: nil)
        == head + #","peerId":"a","peerName":"Atlas","peerDisplayName":"Atlas Display","peerDescription":null,"peerGravatarHash":null,"peerAvatarUrl":null,"peerType":"agent","# + tail + "}")
    let userPeer = DirectChannelPeerFacts(
        peerId: "p", peerName: "peer", peerDisplayName: nil, peerDescription: nil,
        peerGravatarHash: "hash", peerAvatarUrl: nil, peerType: "user"
    )
    #expect(detail(peer: userPeer, read: nil)
        == head + #","peerType":"user","peerId":"p","peerName":"peer","peerDisplayName":null,"peerDescription":null,"peerAvatarUrl":null,"peerGravatarHash":"hash","# + tail + "}")
    let tailBeforePeerRead = #""joined":true,"collapseLongMessages":true,"displayPrefsVersion":2,"maxReadSeq":3,"readStateVersion":1,"readState":{"kind":"present","readStateVersion":1,"maxReadSeq":"3","latestActivity":null}"#
    let tailAfterPeerRead = #","activityMuteSupported":false,"channelRole":"admin","channelAdminBasis":null,"channelCapabilities":{"editChannelMetadata":true,"archiveChannels":false,"addChannelMembers":true,"removeChannelMembers":false,"changeChannelMemberRoles":true,"manageGuestAccess":false,"deleteChannels":true,"changeChannelVisibility":false,"federateChannels":true},"channelAuthorityRevision":4"#
    #expect(detail(peer: nil, read: .states([(peerId: "a", maxReadSeq: 2)]))
        == head + "," + tailBeforePeerRead
        + #","peerReadStates":[{"peerKind":"agent","peerId":"a","maxReadSeq":2}]"# + tailAfterPeerRead + "}")
    #expect(detail(peer: nil, read: .summary(peerCount: 51, readCountAtSeq: [(seq: 1, count: 3)]))
        == head + "," + tailBeforePeerRead
        + #","peerReadSummary":{"peerCount":51,"readCountAtSeq":[{"seq":1,"count":3}]}"# + tailAfterPeerRead + "}")
}

// MARK: - Typed refusals

@Test func toolExecutionRefusalsCarryTheirPublishedStatusAndBody() {
    let cases: [(ManagedMCPToolExecutionError, UInt, String)] = [
        (.unauthorized, 401, #"{"error":"Unauthorized"}"#),
        (.invalidSavedCheckRequest, 400, #"{"error":"Invalid saved check request"}"#),
        (.invalidDirectMessagePeer, 400, #"{"error":"Invalid DM peer"}"#),
        (.agentNotFoundInServer, 404, #"{"error":"Agent not found in this server"}"#),
        (.directMessageTargetNotFound, 404, #"{"error":"DM target not found"}"#),
        (.displayPreferencesOnParentChannel, 400, #"{"error":"Display preferences are stored on the parent channel"}"#),
        (.collapseLongMessagesNotBoolean, 400, #"{"error":"collapseLongMessages must be a boolean"}"#),
        (.invalidReadSeq, 400, #"{"error":"seq must be a non-negative integer"}"#),
        (.invalidResumeRequest, 400, #"{"error":"Invalid resume request"}"#),
        (.agentIdsNotArray, 400, #"{"error":"agentIds must be an array of agent ids"}"#),
        (.invalidChannelTarget, 400, #"{"error":"Invalid channel target"}"#),
        (.agentNotChannelMember, 403, #"{"error":"Agent is not a member of this channel","code":"not_channel_member"}"#),
    ]
    for (error, status, expected) in cases {
        #expect(error.status == status, "\(error)")
        #expect(body(error) == expected, "\(error)")
    }
}

// MARK: - Request leniency

@Test func toolExecutionRequestsReadAWrongTypedMemberAsAbsent() throws {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    // The legacy `as? [String]` cast fails the whole member on one non-string.
    #expect(try decode(SavedCheckRequest.self, #"{"messageIds":["a",1,"b"]}"#) == SavedCheckRequest(messageIds: nil))
    #expect(try decode(SavedCheckRequest.self, #"{"messageIds":["a","b"]}"#) == SavedCheckRequest(messageIds: ["a", "b"]))
    #expect(try decode(SavedCheckRequest.self, #"{"messageIds":"a"}"#) == SavedCheckRequest(messageIds: nil))
    #expect(try decode(DirectChannelRequest.self, #"{"agentId":1,"userId":"u"}"#) == DirectChannelRequest(agentId: nil, userId: "u"))
    #expect(try decode(ChannelDisplayPatchRequest.self, #"{"collapseLongMessages":"yes"}"#)
        == ChannelDisplayPatchRequest(collapseLongMessages: nil))
    #expect(try decode(ChannelReadRequest.self, #"{"seq":"3"}"#) == ChannelReadRequest(seq: nil))
    #expect(try decode(ChannelReadRequest.self, #"{"seq":3}"#) == ChannelReadRequest(seq: 3))
    #expect(try decode(ResumeAllAgentsRequest.self, #"{}"#) == ResumeAllAgentsRequest())
    #expect(try decode(ResumeAllAgentsRequest.self, #"{"agentIds":null}"#) == ResumeAllAgentsRequest())
    #expect(try decode(ResumeAllAgentsRequest.self, #"{"agentIds":["a"],"prompt":"go"}"#)
        == ResumeAllAgentsRequest(prompt: "go", agentIds: .ids(["a"])))
    #expect(try decode(ResumeAllAgentsRequest.self, #"{"agentIds":"a"}"#) == ResumeAllAgentsRequest(agentIds: .invalid))
    #expect(try decode(ChannelReadAllRequest.self, #"{"receiver":{"kind":"agent","id":"a"}}"#).receiver?.id == "a")
    #expect(try decode(ChannelReadAllRequest.self, #"{"receiver":{"kind":"agent"}}"#).receiver == nil)
    #expect(try decode(AgentChannelArchiveRequest.self, ##"{"target":"#general"}"##) == AgentChannelArchiveRequest(target: "#general"))
    #expect(throws: (any Error).self) { try decode(ChannelReadRequest.self, "[1]") }
}

// MARK: - Service flows

@Test func savedMessageRoutesRefuseBeforeReading() {
    let f = makeFixture("001")
    let service = f.service
    #expect(throws: ManagedMCPToolExecutionError.unauthorized) {
        try service.checkSavedMessages(authorization: nil, serverId: f.serverId, body: SavedCheckRequest(messageIds: []))
    }
    #expect(throws: ManagedMCPToolExecutionError.invalidSavedCheckRequest) {
        try service.checkSavedMessages(authorization: f.ownerAuthorization, serverId: f.serverId, body: nil)
    }
    #expect(throws: ManagedMCPToolExecutionError.invalidSavedCheckRequest) {
        try service.checkSavedMessages(authorization: f.ownerAuthorization, serverId: f.serverId, body: SavedCheckRequest())
    }
    #expect(throws: ChannelMembershipError.self) {
        try service.listSavedMessages(
            authorization: f.ownerAuthorization, serverId: "33333333-3333-4333-8333-000000000000",
            query: nil, channelId: nil, sort: nil, limit: 50, offset: 0
        )
    }
}

@Test func savedListRendersAnEmptyPage() throws {
    let f = makeFixture("002")
    let page = try f.service.listSavedMessages(
        authorization: f.ownerAuthorization, serverId: f.serverId, query: nil, channelId: nil, sort: "asc", limit: 50, offset: 0
    )
    #expect(page.jsonBody.render() == #"{"saved":[],"total":0,"hasMore":false}"#)
    let checked = try f.service.checkSavedMessages(
        authorization: f.ownerAuthorization, serverId: f.serverId, body: SavedCheckRequest(messageIds: ["x"])
    )
    #expect(checked == SavedCheckResponse(savedIds: []))
}

@Test func directChannelCreateAndListPublishTheDmRow() throws {
    let f = makeFixture("003")
    let service = f.service
    #expect(throws: ManagedMCPToolExecutionError.invalidDirectMessagePeer) {
        try service.createDirectChannel(authorization: f.ownerAuthorization, serverId: f.serverId, body: nil)
    }
    #expect(throws: ManagedMCPToolExecutionError.invalidDirectMessagePeer) {
        try service.createDirectChannel(authorization: f.ownerAuthorization, serverId: f.serverId, body: DirectChannelRequest())
    }
    #expect(throws: ManagedMCPToolExecutionError.agentNotFoundInServer) {
        try service.createDirectChannel(
            authorization: f.ownerAuthorization, serverId: f.serverId, body: DirectChannelRequest(agentId: "ghost")
        )
    }

    let created = try service.createDirectChannel(
        authorization: f.ownerAuthorization, serverId: f.serverId, body: DirectChannelRequest(agentId: f.agentId)
    )
    #expect(created.peer.peerType == "agent")
    #expect(created.peer.peerId == f.agentId)
    #expect(created.peer.peerName == "atlas-003")
    #expect(created.peer.peerDisplayName == "atlas-003")
    #expect(created.name == "")
    let createdBody = created.jsonBody.render()
    #expect(createdBody.hasPrefix(#"{"id":"\#(created.id)","name":"","type":"dm","description":null,"createdAt":""#))
    #expect(createdBody.hasSuffix(#"","peerId":"\#(f.agentId)","peerName":"atlas-003","peerDisplayName":"atlas-003","peerDescription":null,"peerGravatarHash":null,"peerAvatarUrl":null,"peerType":"agent"}"#))
    let row = f.accounts.serversAndChannelsStore.postableChannel(id: created.id)
    #expect(row?.kind == "dm")
    #expect(row?.memberIds == [f.ownerId, f.agentId])

    let human = try service.createDirectChannel(
        authorization: f.ownerAuthorization, serverId: f.serverId, body: DirectChannelRequest(userId: f.memberId)
    )
    #expect(human.peer.peerType == "user")
    #expect(human.peer.peerName == "tool-member-003")
    #expect(human.peer.peerGravatarHash
        == "4d1879a2098156e6f34ef6562a00d5c48303f5e5ade31cbeed9d0385fb2d1a82")

    let list = try service.listDirectChannels(authorization: f.ownerAuthorization, serverId: f.serverId)
    #expect(list.rows.count == 2)
    #expect(list.rows.contains {
        $0.id == created.id && $0.peer.peerId == f.agentId && $0.peer.peerType == "agent" && $0.peer.peerName == "atlas-003"
    })
    #expect(list.jsonBody.render().hasPrefix("[{\"id\":\""))
}

@Test func channelReadWritesTheVersionOnlyWhenTheFrontierAdvances() throws {
    let f = makeFixture("004")
    let service = f.service
    let first = f.accounts.addChannelMessageForTesting(channelId: f.channelId, content: "one", senderId: f.memberId)
    let second = f.accounts.addChannelMessageForTesting(channelId: f.channelId, content: "two", senderId: f.memberId)
    let firstSeq = try #require(f.accounts.humanMessageSequence(id: first))
    let secondSeq = try #require(f.accounts.humanMessageSequence(id: second))

    #expect(throws: ManagedMCPToolExecutionError.invalidReadSeq) {
        try service.updateChannelReadState(
            authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: ChannelReadRequest(seq: -1)
        )
    }
    let advanced = try service.updateChannelReadState(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: ChannelReadRequest(seq: secondSeq)
    )
    #expect(advanced.jsonBody.render() == #"{"ok":true,"maxReadSeq":\#(secondSeq),"readStateVersion":1}"#)
    let covered = try service.updateChannelReadState(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: ChannelReadRequest(seq: firstSeq)
    )
    #expect(covered.jsonBody.render() == #"{"ok":true,"maxReadSeq":\#(secondSeq),"readStateVersion":1}"#)

    let all = try service.markChannelReadAll(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: nil
    )
    #expect(all.jsonBody.render() == #"{"ok":true,"seq":\#(secondSeq),"readStateVersion":2}"#)
}

@Test func delegatedReadAllAdvancesTheAgentCursorNotTheCallers() throws {
    let f = makeFixture("005")
    let service = f.service
    f.accounts.oauth.addChannelAgent(channelId: f.channelId, agentId: f.agentId)
    let message = f.accounts.addChannelMessageForTesting(channelId: f.channelId, content: "one", senderId: f.memberId)
    let seq = try #require(f.accounts.humanMessageSequence(id: message))

    let response = try service.markChannelReadAll(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
        body: try JSONDecoder().decode(ChannelReadAllRequest.self, from: Data(#"{"receiver":{"kind":"agent","id":"\#(f.agentId)"}}"#.utf8))
    )
    #expect(response.jsonBody.render() == #"{"ok":true,"seq":\#(seq),"readStateVersion":1}"#)
    #expect(f.accounts.agentReadCursor(channelId: f.channelId, agentId: f.agentId) == seq)
    #expect(f.accounts.humanReadCursor(channelId: f.channelId, userId: f.ownerId) == 0)

    #expect(throws: ChannelMembershipError.self) {
        try service.markChannelReadAll(
            authorization: f.memberAuthorization, serverId: f.serverId, channelId: f.channelId,
            body: try JSONDecoder().decode(ChannelReadAllRequest.self, from: Data(#"{"receiver":{"kind":"agent","id":"\#(f.agentId)"}}"#.utf8))
        )
    }
}

@Test func displaySettingsRoundTripThePublishedBytes() throws {
    let f = makeFixture("006")
    let service = f.service
    #expect(throws: ManagedMCPToolExecutionError.collapseLongMessagesNotBoolean) {
        try service.patchChannelDisplaySettings(
            authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: ChannelDisplayPatchRequest()
        )
    }
    let patched = try service.patchChannelDisplaySettings(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
        body: ChannelDisplayPatchRequest(collapseLongMessages: true)
    )
    #expect(patched.collapseLongMessages)
    let read = try service.channelDisplaySettings(authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId)
    #expect(read == patched)
}

@Test func resumeAllAgentsReportsSkippedStartsAndRefusesBadRequests() async throws {
    let f = makeFixture("007")
    let service = f.service
    do {
        _ = try await service.resumeAllAgents(
            authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: nil
        )
        Issue.record("a body that is not a JSON object is refused")
    } catch let error as ManagedMCPToolExecutionError {
        #expect(error == .invalidResumeRequest)
    }
    do {
        _ = try await service.resumeAllAgents(
            authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId,
            body: ResumeAllAgentsRequest(agentIds: .invalid)
        )
        Issue.record("agentIds that is not an array is refused")
    } catch let error as ManagedMCPToolExecutionError {
        #expect(error == .agentIdsNotArray)
    }
    let empty = try await service.resumeAllAgents(
        authorization: f.ownerAuthorization, serverId: f.serverId, channelId: f.channelId, body: ResumeAllAgentsRequest()
    )
    #expect(empty.jsonBody.render() == #"{"ok":true,"started":0,"total":0,"results":[]}"#)
}

@Test func readReceiptsAreAPerServerStoreFlag() {
    let f = makeFixture("008")
    let service = f.service
    #expect(!service.readReceiptsEnabled(serverId: f.serverId))
    f.accounts.enableReadReceiptsForServer(f.serverId)
    #expect(service.readReceiptsEnabled(serverId: f.serverId))
    #expect(!service.readReceiptsEnabled(serverId: "other"))
}

@Test func agentMuteAndArchiveRefuseWithoutAnAgentCredential() {
    let f = makeFixture("009")
    let service = f.service
    #expect(throws: (any Error).self) {
        try service.agentSetChannelMute(authorization: nil, channelId: f.channelId, muted: true)
    }
    #expect(throws: (any Error).self) {
        try service.agentChannelArchive(authorization: nil, body: AgentChannelArchiveRequest(target: "#x"), archive: true)
    }
}

// MARK: - Store sections

@Test func directChannelRowIsWrittenWholeAndReplacedNotMerged() {
    let channels = ServersAndChannelsStore()
    channels.upsertDirectChannel(serverId: "s", channelId: "d", memberIds: ["a", "b"])
    channels.upsertDirectChannel(serverId: "s", channelId: "d", memberIds: ["a"])
    let row = channels.postableChannel(id: "d")
    #expect(row?.kind == "dm")
    #expect(row?.name == "dm")
    #expect(row?.memberIds == ["a"])
}

@Test func concurrentReadReceiptTogglesAreIdempotent() {
    let channels = ServersAndChannelsStore()
    DispatchQueue.concurrentPerform(iterations: 64) { index in
        channels.enableReadReceipts(serverId: "s-\(index % 4)")
    }
    for index in 0..<4 { #expect(channels.readReceiptsEnabled(serverId: "s-\(index)")) }
    #expect(!channels.readReceiptsEnabled(serverId: "s-9"))
}

private extension JSONEncoder {
    static var sortedForTesting: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
