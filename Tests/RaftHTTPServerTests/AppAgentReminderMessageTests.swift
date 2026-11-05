import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func officialAppReminderWriteIsIdempotentAndValidated() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111641"
    let publisherId = "33333333-3333-4333-8333-333333333681"
    let serverId = "33333333-3333-4333-8333-333333333682"
    let foreignId = "33333333-3333-4333-8333-333333333683"
    accounts.addAccount(id: ownerId, email: "reminder-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: publisherId, slug: "reminder-publisher", name: "Official Publisher", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "reminder-server", name: "Reminder Server", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: foreignId, slug: "reminder-foreign", name: "Foreign Server", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "RemLocal", creatorUserId: ownerId, runtime: "claude")
    let foreignAgent = accounts.oauth.createAgent(serverId: foreignId, name: "RemForeign", creatorUserId: ownerId, runtime: "claude")
    let created = try accounts.oauth.createClient(serverId: publisherId, createdByUserId: ownerId, name: "Reminder App", clientId: "reminder-app")
    accounts.oauth.markOfficialAppForTesting(clientRecordId: created.id)
    accounts.oauth.setClientOutboundGroupsForTesting(clientRecordId: created.id, groups: ["agent_reminder_write"])
    let installationId = accounts.oauth.installClient(serverId: serverId, clientRecordId: created.id, installedByUserId: ownerId, groups: ["agent_reminder_write"])
    var token = ""
        try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            var mintHeaders = HTTPFields()
            mintHeaders[.contentType] = "application/json"
            let basic = Data("\(created.clientId):\(created.clientSecret)".utf8).base64EncodedString()
            mintHeaders[.authorization] = "Basic \(basic)"
            let mint = try await client.send(.post, headers: mintHeaders, to: URI(string: "/api/oauth/installation-token")) { request in
                request.body = .init(string: "{\"installation_id\":\"\(installationId)\"}")
            }
            #expect(mint.status == .ok, Comment(rawValue: mint.body.string ?? ""))
            let minted = (try? JSONSerialization.jsonObject(with: Data((mint.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            token = try #require(minted["access_token"] as? String)

            func post(_ token: String, _ body: [String: Any]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: body)
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/app-installation/agent-reminder-messages")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let base: [String: Any] = ["agentId": agentId, "idempotencyKey": "rem-1:fire-1", "text": "Reminder: check the deploy"]
            let first = try await post(token, base)
            #expect(first.0.status == .ok)
            #expect(first.1["created"] as? Bool == true)
            let surface = first.1["surface"] as? [String: Any]
            #expect(surface?["channelType"] as? String == "dm")
            #expect(surface?["channelName"] as? String == "reminders")
            #expect(surface?["target"] as? String == "dm:@reminders")
            let messageId = try #require(first.1["messageId"] as? String)
            let metadata = try #require(accounts.oauth.reminderMessageMetadata(id: messageId))
            #expect(metadata.senderId == "system")
            #expect(metadata.senderType == "user")
            #expect(metadata.messageType == "system")
            #expect(metadata.systemSubtype == "agent.reminder_due")
            #expect(metadata.causalActorId == nil)

            let replay = try await post(token, ["agentId": agentId, "idempotencyKey": "rem-1:fire-1", "text": "ignored on replay"])
            #expect(replay.0.status == .ok)
            #expect(replay.1["created"] as? Bool == false)
            #expect(replay.1["messageId"] as? String == messageId)
            #expect(accounts.agentReminderSurfaceForTesting(agentId: agentId) == metadata.channelId)

            let foreign = try await post(token, ["agentId": foreignAgent, "idempotencyKey": "x", "text": "hi"])
            #expect(foreign.0.status == .notFound)
            let badKey = try await post(token, ["agentId": agentId, "idempotencyKey": "", "text": "hi"])
            #expect(badKey.0.status == .badRequest)
            let badText = try await post(token, ["agentId": agentId, "idempotencyKey": "y", "text": ""])
            #expect(badText.0.status == .badRequest)
            let badId = try await post(token, ["agentId": "nope", "idempotencyKey": "z", "text": "hi"])
            #expect(badId.0.status == .badRequest)
            let bogus = try await post("raft_installation_bogus", base)
            #expect(bogus.0.status == .unauthorized)
        }
    }
}
