import Foundation
@testable import RaftHTTP
import Testing

@Test func supportHelperTaskCatalogKeepsPublishedBytesAndNulls() throws {
    let task = TaskRecord(id: "task", channelId: "channel", title: "a\"/中", description: "é", status: "todo", taskNumber: 7, messageId: "message", createdAt: Date(timeIntervalSince1970: 0))
    let oauth = OAuthLedger()
    let channelId = oauth.createChannel(serverId: "helper-server", name: "general", creatorUserId: "helper-creator")
    var scopedTask = task
    scopedTask.channelId = channelId
    let catalog = TaskCatalogService(tasks: TasksAndRemindersStore(), profiles: AuthProfileStore(), oauth: oauth, messages: MessagesAndThreadsStore(), channels: ServersAndChannelsStore(), flags: AgentsRuntimeStore())
    let full = try catalog.fullTaskJSON(scopedTask, channelName: "general", channelType: "channel")
    #expect(full == #"{"id":"task","messageId":"message","channelId":"\#(channelId)","channelName":"general","channelType":"channel","taskNumber":7,"title":"a\"/中","description":"é","status":"todo","createdByType":null,"createdById":null,"createdByName":null,"createdByMembershipStatus":null,"claimedByType":null,"claimedById":null,"claimedByName":null,"claimedAt":null,"completedAt":null,"requiresResourceReceipt":false,"resourceReceipt":null,"resourceReceiptRecordedAt":null,"resourceTeardownOwnerAgentId":null,"resourceExpiryFollowupId":null,"createdAt":"1970-01-01T00:00:00.000Z","updatedAt":null,"revision":0,"isLegacy":false}"#)
    let fullObject = try #require(try JSONSerialization.jsonObject(with: Data(full.utf8)) as? [String: Any])
    #expect(fullObject["title"] as? String == "a\"/中")
    #expect(fullObject["description"] as? String == "é")
    #expect(fullObject["channelId"] as? String == channelId)
    #expect(fullObject["createdById"] is NSNull)
    #expect(fullObject["updatedAt"] is NSNull)
    #expect(fullObject["taskCurrentProjection"] == nil)
    #expect(try catalog.summaryTaskJSON(scopedTask, channelName: "general", channelType: "channel") == #"{"channelId":"\#(channelId)","channelName":"general","channelType":"channel","claimedAt":null,"claimedById":null,"claimedByName":null,"claimedByType":null,"completedAt":null,"createdAt":"1970-01-01T00:00:00.000Z","createdById":null,"createdByName":null,"createdByType":null,"descriptionBytes":2,"hasDescription":true,"id":"task","isLegacy":false,"messageId":"message","readOnlyReason":null,"revision":0,"source":"tasks","status":"todo","taskNumber":7,"title":"a\"/中","updatedAt":null}"#)
}

@Test func supportHelperForwardPointersKeepOmissionAndScrubOrder() {
    let item = ForwardItemRecord(sourceMessageId: "m", exposesPointers: false, sourceAuthorUniqueName: "name", sourceIsThreadParent: true, contentSnapshot: "hi", sourceTargetId: nil, sourceThreadId: "thread", parentChannelId: nil, snapshotId: nil, snapshotType: "", snapshotLabel: "label", snapshotLabelVisibility: "private", provenanceState: "available", attachments: [ForwardAttachmentSnapshot(id: "a", filename: "a/b", mimeType: "image/png", sizeBytes: 2, width: nil, height: 3)], attachmentPolicy: "snapshot")
    #expect(MessageForwardProjection.forwardItemJSON(item) == #"{"sourceMessageId":null,"sourceIsThreadParent":true,"contentSnapshot":"hi","sourceAuthorSnapshot":{"uniqueName":"name"},"sourceTargetId":null,"sourceMessageSeq":null,"sourceServerId":null,"sourceThreadId":"thread","sourceTargetSnapshot":{"id":null,"type":"","label":"label","labelVisibility":"private"},"attachmentSnapshots":[{"id":"a","filename":"a/b","mimeType":"image/png","sizeBytes":2,"width":null,"height":3}],"attachmentPolicy":"snapshot","provenanceState":"available"}"#)
    #expect(MessageForwardProjection.scrubbedForwardItemJSON(item) == #"{"sourceMessageId":null,"sourceIsThreadParent":true,"contentSnapshot":"hi","sourceServerId":null,"sourceTargetId":null,"sourceThreadId":null,"parentChannelId":null,"sourceTargetSnapshot":{"id":null,"type":"channel","label":"","labelVisibility":"restricted"},"attachmentSnapshots":[{"id":"a","filename":"a/b","mimeType":"image/png","sizeBytes":2,"width":null,"height":3}],"attachmentPolicy":"snapshot","provenanceState":"original_unavailable"}"#)
}

@Test func supportHelperCursorsAndFreshnessIdentityKeepSignedBytes() throws {
    let cursor = ActorCursor(principalId: "p", serverId: "s", messageId: "m", emoji: "👍", discussionVersion: 4, visibilityHash: "v", actorKind: "agent", actorId: "a")
    let token = MessagePageCursor.encodeActorCursor(cursor)
    #expect(String(data: try #require(AuthTokenCodec.base64urlDecode(token)), encoding: .utf8) == #"{"principalId":"p","serverId":"s","messageId":"m","emoji":"👍","discussionVersion":4,"visibilityHash":"v","actorKind":"agent","actorId":"a"}"#)
    #expect(MessagePageCursor.decodeActorCursor(token)?.discussionVersion == 4)
    let id = "11111111-1111-4111-8111-111111111622"
    #expect(TaskCatalogPolicy.decodeCursor(TaskCatalogPolicy.encodeCursor(channelId: id, taskNumber: 9))?.taskNumber == 9)
    let bytes = #"{"action":"send","agentId":"a","decision":"syncing_hold","heldMessageCount":2,"modelSeenSeq":3,"omittedMessageCount":4,"pendingMaxSeq":5,"reason":"why","target":"target"}"#
    #expect(AgentFreshnessIdentity.freshnessDecisionProducerFactId(agentId: "a", target: "target", reason: "why", pendingMaxSeq: 5, modelSeenSeq: 3, heldMessageCount: 2, omittedMessageCount: 4) == "freshness_decision_fact:" + AuthTokenCodec.sha256Hex(bytes))
}

@Test func supportHelperAuthTokensKeepClaimsAndValidation() async throws {
    let secret = "synthetic-helper-signing-secret-71-only"
    let state = SocialAuthState(provider: "github", mode: "login", nonce: "n", kind: "web", mobileRequestId: "m", desktopNonce: "d", returnTo: "/a", linkUserId: "u", linkOnConflict: true)
    let stateToken = try await AuthTokenCodec.signSocialAuthState(state, secret: secret)
    #expect(await AuthTokenCodec.verifySocialAuthState(stateToken, secret: secret) == state)
    #expect(await AuthTokenCodec.verifySocialAuthState("bad", secret: secret) == nil)
    let token = try await AuthTokenCodec.signNativeAppleRequestToken(secret: secret, requestId: "r", mode: "login", codeChallenge: String(repeating: "a", count: 32), expiresAt: Date().addingTimeInterval(60))
    if case .valid(let claims) = await AuthTokenCodec.verifyNativeAppleRequestToken(token, secret: secret) {
        #expect(claims.requestId == "r")
    } else { Issue.record("Expected valid native request token") }
    if case .invalid = await AuthTokenCodec.verifyNativeAppleRequestToken(token, secret: "synthetic-different-signing-secret-71") {} else { Issue.record("Wrong key must fail") }
}

@Test func supportHelperUnsubscribeKeepsInvalidHTML() {
    let result = MobileAppEmailUnsubscribe(notifications: EmailLoginDirectory().nativeNotifications).mobileAppEmailUnsubscribePage(token: nil)
    if case .invalidLink(let html) = result {
        #expect(html.contains("This unsubscribe link is invalid."))
    } else { Issue.record("Missing token must publish the invalid-link outcome") }
}
