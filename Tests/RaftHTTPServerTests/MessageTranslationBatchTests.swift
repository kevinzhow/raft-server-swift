import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func translationBatchRejectsDisabledServerAndTranslatesVisibleMessages() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111626"
    let serverId = "33333333-3333-4333-8333-333333333670"
    accounts.addAccount(id: ownerId, email: "translation-owner@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "translation-fixture", name: "Translation Fixture", ownerId: ownerId)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "TranslationBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "translation-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "translation-room", humanIds: [ownerId], agentIds: [agentId])
    let chinese = accounts.addHumanMessageForTesting(channelId: channelId, senderId: agentId, content: "你好 translation phase one", senderType: "agent")
    let english = accounts.addHumanMessageForTesting(channelId: channelId, senderId: agentId, content: "hello already english", senderType: "agent")
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    accounts.setTranslationProviderForTesting("fake")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func post(_ ids: [String]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: ["targetLanguage": "en", "mode": "manual", "messageIds": ids])
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/message-translations:batch")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let disabled = try await post([chinese])
            #expect(disabled.0.status == .forbidden)
            #expect(disabled.1["error"] as? String == "Translation is disabled for this server")
            // The disabled check happens before any provider or message work.
            #expect(accounts.messageTranslationForTesting(messageId: chinese) == nil)

            accounts.oauth.setServerTranslationEnabled(id: serverId, enabled: true)
            let translated = try await post([chinese, english, "00000000-0000-0000-0000-000000000000"])
            #expect(translated.0.status == .ok)
            let results = translated.1["results"] as? [[String: Any]] ?? []
            #expect(results.count == 3)
            #expect(results[0]["messageId"] as? String == chinese)
            #expect(results[0]["status"] as? String == "translated")
            #expect(results[0]["sourceLanguage"] as? String == "zh")
            #expect(results[0]["sourceConfidence"] as? Int == 95)
            #expect(results[0]["targetLanguage"] as? String == "en")
            #expect(results[0]["translatedContent"] as? String == "[en] 你好 translation phase one")
            #expect(results[0]["provider"] as? String == "fake")
            #expect(results[0]["providerVersion"] as? String == "fake@v0+fake-v0")
            #expect(results[0]["placeholderPolicyVersion"] as? String == "placeholder-v0")
            #expect((results[0]["contentHash"] as? String)?.count == 64)
            #expect(results[1]["status"] as? String == "skipped")
            #expect(results[1]["reason"] as? String == "target_is_source")
            #expect(results[2]["status"] as? String == "not_found")
            let ledger = try #require(accounts.messageTranslationForTesting(messageId: chinese))
            #expect(ledger.status == "translated")
            #expect(ledger.providerBilledChars == "你好 translation phase one".count)
        }
    }
}

@Test func openAICompatibleProviderRequiresProServer() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111630"
    let serverId = "33333333-3333-4333-8333-333333333673"
    accounts.addAccount(id: ownerId, email: "translation-pro@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "translation-pro", name: "Translation Pro", ownerId: ownerId)
    accounts.oauth.setServerTranslationEnabled(id: serverId, enabled: true)
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "ProBot", creatorUserId: ownerId, runtime: "claude")
    let channelId = accounts.oauth.createChannel(serverId: serverId, name: "translation-pro-room", creatorUserId: ownerId, type: "channel")
    accounts.seedPostableChannelForTesting(serverId: serverId, channelId: channelId, name: "translation-pro-room", humanIds: [ownerId], agentIds: [agentId])
    let messageId = accounts.addHumanMessageForTesting(channelId: channelId, senderId: agentId, content: "你好 gated translation", senderType: "agent")
    let token = accounts.mintAccessTokenForTesting(userId: ownerId)
    accounts.setTranslationProviderForTesting("openai-compatible")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func batch() async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: ["targetLanguage": "en", "mode": "manual", "messageIds": [messageId]])
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/message-translations:batch")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let denied = try await batch()
            #expect(denied.0.status == .forbidden)
            #expect(denied.1["error"] as? String == "LLM translation is not available for this server")

            accounts.oauth.setServerPlan(id: serverId, plan: "pro")
            let allowed = try await batch()
            #expect(allowed.0.status == .ok)
            let first = (allowed.1["results"] as? [[String: Any]])?.first
            #expect(first?["status"] as? String == "translated")
            #expect(first?["provider"] as? String == "openai-compatible")
        }
    }
}
