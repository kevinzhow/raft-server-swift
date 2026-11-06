import Foundation
import RaftShared
import Testing
import TestSupport
@testable import RaftHTTP

/// The byte-exact HTTP replies are locked by
/// `IntegrationsAndAppAccessBytesTests`. These tests lock what a black-box
/// request cannot reach deterministically: the two atomic sections this slice
/// wrote (agent login insert-if-absent, comment row plus message row), the typed
/// request reads that replace the retired object casts, and the pure body
/// projections.

private func decode(_ text: String) throws -> IntegrationRequestBody {
    try JSONDecoder().decode(IntegrationRequestBody.self, from: Data(text.utf8))
}

@Test func concurrentFirstAgentLoginsReportLoggedInExactlyOnce() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001301001"
    let ownerId = "11111111-1111-4111-8111-000001301001"
    accounts.addAccount(id: ownerId, email: "login-owner@bytes.test", password: "password123")
    accounts.oauth.addOwnedServer(id: serverId, slug: "login-race", name: "Login Race", ownerId: ownerId)
    _ = try accounts.oauth.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Race App", clientId: "race-app",
        allowedScopes: ["openid"]
    )
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "RaceBot", runtime: "claude")
    let key = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "race")
    let service = accounts.agentIntegrationApps
    let body = try decode("{\"service\":\"race-app\"}")
    let authorization = "Bearer \(key)"

    let statuses = await withTaskGroup(of: String.self) { group in
        for _ in 0..<64 {
            group.addTask {
                guard case .loggedIn(let status, _, _, _)? = try? service.agentIntegrationLogin(
                    authorization: authorization, body: body
                ) else { return "error" }
                return status
            }
        }
        var all: [String] = []
        for await status in group { all.append(status) }
        return all
    }
    #expect(statuses.filter { $0 == "logged_in" }.count == 1)
    #expect(statuses.filter { $0 == "already_logged_in" }.count == 63)
}

@Test func concurrentCommentAppendsStampDistinctSequencesInOneSection() async throws {
    let store = EmailLoginDirectory().messagesAndThreadsStore
    let sequences = await withTaskGroup(of: Int.self) { group in
        for index in 0..<100 {
            group.addTask {
                let id = "comment-\(index)"
                return store.appendAttachmentComment(
                    AttachmentCommentRecord(
                        id: id, attachmentId: "att-1", content: "c\(index)", anchorJSON: nil,
                        senderId: "u", senderType: "user", createdAt: Date(),
                        threadChannelId: "t", hostMessageId: "h", hostChannelId: "c"
                    ),
                    message: StoredHumanMessage(
                        id: id, channelId: "t", senderId: "u", content: "c\(index)", randomId: nil,
                        messageType: "comment", senderType: "user", createdAt: Date()
                    )
                )
            }
        }
        var all: [Int] = []
        for await sequence in group { all.append(sequence) }
        return all
    }
    #expect(Set(sequences) == Set(1...100))
    let state = store.state
    #expect(state.attachmentCommentRecords["att-1"]?.count == 100)
    #expect(state.humanMessageRows.count == 100)
    // Every comment row has its message row at the sequence it was stamped with.
    #expect(Set(state.humanMessageRows.map(\.seq)) == Set(1...100))
    #expect(state.humanMessageRows.allSatisfy { $0.messageType == "comment" })
}

@Test func requestBodyReadsKeepTheLegacyObjectCastRules() throws {
    let body = try decode("""
    {"s":"x","n":3,"d":3.0,"f":3.5,"t":true,"one":1,"two":2,"nil":null,"a":["a",1,"b",null],"o":{}}
    """)
    #expect(body.string("s") == "x")
    #expect(body.string("n") == nil)
    #expect(body.string("nil") == nil)
    #expect(body.has("nil"))
    #expect(!body.has("missing"))
    #expect(body.int("n") == 3)
    #expect(body.int("d") == 3)
    #expect(body.int("f") == nil)
    #expect(body.int("t") == 1)
    #expect(body.int("s") == nil)
    #expect(body.bool("t") == true)
    #expect(body.bool("one") == true)
    #expect(body.bool("two") == nil)
    #expect(body.bool("n") == nil)
    #expect(body.stringElements("a") == ["a", "b"])
    #expect(body.stringElements("s") == nil)
    #expect(body.value("nil") == .null)
    #expect(body.value("missing") == nil)
    // Only a JSON object decodes; the service answers its own refusal otherwise.
    #expect(throws: (any Error).self) { try decode("[1]") }
    #expect(throws: (any Error).self) { try decode("null") }
}

@Test func commentAnchorsRenderTheCanonicalFragmentAndRefuseMalformedOnes() throws {
    func anchor(_ text: String) throws -> (json: String?, code: String?) {
        AttachmentCommentsService.canonicalAnchor(try decode("{\"anchor\":\(text)}").value("anchor"))
    }
    #expect(try anchor("null").json == nil)
    #expect(try anchor("null").code == nil)
    #expect(try anchor("""
    {"type":"lines","data":{"start":1,"end":2,"quote":"a/b \\"q\\"","extra":1},"extra":2}
    """).json == #"{"type":"lines","data":{"start":1,"end":2,"quote":"a/b \"q\""}}"#)
    #expect(try anchor("""
    {"type":"csv-rows","data":{"start":3.0,"end":3}}
    """).json == #"{"type":"csv-rows","data":{"start":3,"end":3}}"#)
    #expect(try anchor("""
    {"type":"md-section","data":{"headingId":"h","headingTitle":"T","quote":"q"}}
    """).json == #"{"type":"md-section","data":{"headingId":"h","headingTitle":"T","quote":"q"}}"#)
    #expect(try anchor("""
    {"type":"html-region","data":{"x":1.4,"y":2.6,"w":0,"h":4,"viewportWidth":5,"documentWidth":6,"documentHeight":7}}
    """).json == #"{"type":"html-region","data":{"x":1,"y":3,"w":0,"h":4,"viewportWidth":5,"documentWidth":6,"documentHeight":7}}"#)
    #expect(try anchor(#"{"type":"lines","data":{"start":0,"end":2}}"#).code == "anchor_invalid")
    #expect(try anchor(#"{"type":"lines","data":{"start":3,"end":2}}"#).code == "anchor_invalid")
    #expect(try anchor("5").code == "anchor_invalid")
    #expect(try anchor(#"{"type":"lines"}"#).code == "anchor_invalid")
    #expect(try anchor(#"{"type":7,"data":{}}"#).code == "anchor_type_invalid")
    #expect(try anchor(#"{"type":"nope","data":{}}"#).code == "anchor_type_invalid")
    let huge = String(repeating: "q", count: 5_000)
    #expect(try anchor("{\"type\":\"lines\",\"data\":{\"start\":1,\"end\":2,\"quote\":\"\(huge)\"}}").code == "anchor_too_large")
}

@Test func commentMentionsRequireTheStrictShape() throws {
    let id = "11111111-1111-4111-8111-000001301002"
    func mentions(_ text: String) throws -> [MentionInput]? {
        AttachmentCommentsService.strictMentions(try decode("{\"m\":\(text)}").value("m"))
    }
    #expect(try mentions("null")?.isEmpty == true)
    #expect(try mentions("[]")?.isEmpty == true)
    #expect(try mentions("5") == nil)
    #expect(try mentions("[{\"type\":\"user\"}]") == nil)
    #expect(try mentions("[{\"type\":\"team\",\"id\":\"\(id)\",\"name\":\"n\"}]") == nil)
    #expect(try mentions("[{\"type\":\"agent\",\"id\":\"nope\",\"name\":\"n\"}]") == nil)
    #expect(try mentions("[{\"type\":\"agent\",\"id\":\"\(id)\",\"name\":\"\"}]") == nil)
    let parsed = try #require(try mentions("[{\"type\":\"agent\",\"id\":\"\(id)\",\"name\":\"n\"}]"))
    #expect(parsed.count == 1)
    #expect(parsed[0].type == "agent")
    #expect(parsed[0].id == id)
}

@Test func lookupRefusalsKeepTheUnescapedReferenceBytes() {
    #expect(AgentMessageLookupError.messageNotFound("a\"b").publishedErrorBody.render()
        == #"{"error":"Message not found: a"b","errorCode":"NOT_FOUND"}"#)
    #expect(AgentMessageLookupError.ambiguousMessageId("aa").publishedErrorBody.render()
        == #"{"error":"Ambiguous message id: aa","errorCode":"AMBIGUOUS_ID","suggestedNextAction":"Retry with the full message UUID."}"#)
    #expect(AgentMessageLookupError.notJoinable.publishedErrorBody.render() == #"{"status":"NOT_JOINABLE"}"#)
    #expect(AgentMessageLookupError.capabilityNotAuthorized.publishedErrorBody.render()
        == #"{"error":"Agent credential is not authorized for this capability","code":"capability_not_authorized","requiredCapability":"read"}"#)
    #expect(AgentIntegrationAppsError.capabilityNotAuthorized(requiredCapability: nil).publishedErrorBody.render()
        == #"{"error":"Agent credential is not authorized for this capability","code":"capability_not_authorized"}"#)
    #expect(IntegrationsAndAppAccessError.invalidAppMetadata("bad").publishedErrorBody.render()
        == #"{"error":"bad","errorCode":"INVALID_APP_METADATA"}"#)
}

@Test func appProjectionEncodesSortedKeysWithExplicitNulls() throws {
    let projection = IntegrationAppProjection(
        installationId: nil, name: "N / x", clientKey: "k", createdAt: "t", updatedAt: "t",
        description: nil, homepageUrl: "https://h.example.test/p", callbackUrl: nil,
        agentManifestUrl: nil, setupUrl: nil, setupDescription: nil, setupRevision: 1,
        setup: IntegrationAppSetupProjection(
            status: "pending", url: "https://s.example.test", description: nil, revision: 1, completedAt: nil
        ),
        scopes: ["openid"], appType: "server_local", publishStatus: "draft", enabled: true,
        authority: "owner", recoveryCommand: "cmd"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(AgentIntegrationAppStatusResponse(app: projection)), as: UTF8.self)
    #expect(text == #"{"app":{"agentManifestUrl":null,"appType":"server_local","authority":"owner","callbackUrl":null,"card":null,"category":"Other","clientKey":"k","createdAt":"t","dataAccessSummary":null,"description":null,"enabled":true,"homepageUrl":"https:\/\/h.example.test\/p","installationId":null,"logoUrl":null,"name":"N \/ x","publishStatus":"draft","recoveryCommand":"cmd","scopes":["openid"],"setup":{"completedAt":null,"description":null,"revision":1,"status":"pending","url":"https:\/\/s.example.test"},"setupDescription":null,"setupRevision":1,"setupUrl":null,"state":"committed","updatedAt":"t"}}"#)
}
