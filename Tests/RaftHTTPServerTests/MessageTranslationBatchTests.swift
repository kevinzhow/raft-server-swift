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
            #expect(results[1]["skipReason"] as? String == "same_language")
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

@Test func translationSkipsOwnSystemCodeLowConfidenceAndSameLanguage() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111631"
    let memberId = "11111111-1111-4111-8111-111111111632"
    let serverId = "33333333-3333-4333-8333-333333333674"
    accounts.addAccount(id: ownerId, email: "translation-skips@test.invalid", password: "password123")
    accounts.addAccount(id: memberId, email: "translation-skips-member@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "translation-skips", name: "Translation Skips", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.setServerTranslationEnabled(id: serverId, enabled: true)
    let senderAgentId = accounts.oauth.createAgent(serverId: serverId, name: "TranslationSender", creatorUserId: ownerId, runtime: "claude")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "translation-skips-room", creatorUserId: ownerId, type: "channel")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: channel, userId: memberId)
    let own = accounts.oauth.createMessageRecord(channelId: channel, content: "我自己的消息", senderId: ownerId)
    let system = accounts.oauth.createMessageRecord(channelId: channel, content: "系统消息", senderId: "system", messageType: "system")
    let code = accounts.oauth.createMessageRecord(channelId: channel, content: "```ts\nconst value = 1;\n```", senderId: senderAgentId, senderType: "agent")
    let low = accounts.oauth.createMessageRecord(channelId: channel, content: "12345 !!!", senderId: senderAgentId, senderType: "agent")
    let english = accounts.oauth.createMessageRecord(channelId: channel, content: "hello same language", senderId: senderAgentId, senderType: "agent")
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    let memberToken = accounts.mintAccessTokenForTesting(userId: memberId)
    accounts.setTranslationProviderForTesting("fake")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func batch(_ token: String, _ mode: String, _ ids: [String], target: String = "en") async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(token)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: ["targetLanguage": target, "mode": mode, "messageIds": ids])
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/message-translations:batch")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let auto = try await batch(ownerToken, "auto", [own.id, system.id, code.id, low.id, english.id])
            let rows = auto["results"] as? [[String: Any]] ?? []
            let byId = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String?)? in
                guard let id = row["messageId"] as? String else { return nil }
                return (id, row["skipReason"] as? String)
            })
            #expect(byId[own.id] == "own_message")
            #expect(byId[system.id] == "system_message")
            #expect(byId[code.id] == "code_or_link_only")
            #expect(byId[low.id] == "low_confidence")
            #expect(byId[english.id] == "same_language")
            #expect(rows.allSatisfy { ($0["status"] as? String) == "skipped" })
            let sameLedger = try #require(accounts.messageTranslationForTesting(messageId: english.id))
            #expect(sameLedger.status == "skipped")
            #expect(sameLedger.providerBilledChars == 0)

            let locale = try await batch(ownerToken, "auto", [english.id], target: "en-US")
            let localeRow = (locale["results"] as? [[String: Any]])?.first
            #expect(localeRow?["status"] as? String == "skipped")
            #expect(localeRow?["skipReason"] as? String == "same_language")
            #expect(localeRow?["sourceLanguage"] as? String == "en")
            #expect(localeRow?["targetLanguage"] as? String == "en")

            let ownAuto = try await batch(ownerToken, "auto", [own.id])
            #expect((ownAuto["results"] as? [[String: Any]])?.first?["skipReason"] as? String == "own_message")
            #expect(accounts.messageTranslationForTesting(messageId: own.id) == nil)
            let ownManual = try await batch(ownerToken, "manual", [own.id])
            let manualRow = (ownManual["results"] as? [[String: Any]])?.first
            #expect(manualRow?["status"] as? String == "translated")
            #expect(manualRow?["translatedContent"] as? String == "[en] 我自己的消息")
            let memberManual = try await batch(memberToken, "manual", [own.id])
            #expect((memberManual["results"] as? [[String: Any]])?.first?["status"] as? String == "translated")
        }
    }
}

@Test func translationResolvesActiveJointProjectionsAndHidesInvisibleMessages() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111633"
    let guestId = "11111111-1111-4111-8111-111111111634"
    let hostServerId = "33333333-3333-4333-8333-333333333675"
    let guestServerId = "33333333-3333-4333-8333-333333333676"
    let storageServerId = "33333333-3333-4333-8333-333333333677"
    accounts.addAccount(id: ownerId, email: "joint-translation-host@test.invalid", password: "password123")
    accounts.addAccount(id: guestId, email: "joint-translation-guest@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.markEmailVerified(userId: guestId)
    accounts.oauth.addOwnedServer(id: hostServerId, slug: "joint-translation-host", name: "Joint Translation Host", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: guestServerId, slug: "joint-translation-guest", name: "Joint Translation Guest", ownerId: guestId)
    accounts.oauth.addOwnedServer(id: storageServerId, slug: "joint-translation-storage", name: "Joint Translation Storage", ownerId: ownerId)
    accounts.oauth.setServerTranslationEnabled(id: guestServerId, enabled: true)
    let hostProjection = accounts.oauth.createChannel(serverId: hostServerId, name: "joint-translation", creatorUserId: ownerId, type: "joint")
    let guestProjection = accounts.oauth.createChannel(serverId: guestServerId, name: "joint-translation", creatorUserId: guestId, type: "joint")
    let canonical = accounts.oauth.createChannel(serverId: storageServerId, name: "joint-storage-translation", creatorUserId: ownerId)
    accounts.oauth.addChannelHuman(channelId: hostProjection, userId: ownerId)
    accounts.oauth.addChannelHuman(channelId: guestProjection, userId: guestId)
    accounts.addJointChannelProjection(localChannelId: hostProjection, canonicalChannelId: canonical, serverId: hostServerId)
    accounts.addJointChannelProjection(localChannelId: guestProjection, canonicalChannelId: canonical, serverId: guestServerId)
    let visibleMessage = accounts.oauth.createMessageRecord(channelId: canonical, content: "你好 joint translation", senderId: ownerId)
    let guestToken = accounts.mintAccessTokenForTesting(userId: guestId)
    accounts.setTranslationProviderForTesting("fake")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func batch(_ ids: [String]) async throws -> [String: Any] {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(guestToken)"
                headers[HTTPField.Name("X-Server-Id")!] = guestServerId
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: ["targetLanguage": "en", "mode": "manual", "messageIds": ids])
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/message-translations:batch")) { request in
                    request.body = .init(data: data)
                }
                return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let visible = try await batch([visibleMessage.id])
            let visibleRow = (visible["results"] as? [[String: Any]])?.first
            #expect(visibleRow?["status"] as? String == "translated")
            #expect(visibleRow?["targetLanguage"] as? String == "en")

            accounts.setJointProjectionStatusForTesting(localChannelId: guestProjection, serverId: guestServerId, status: "disconnected")
            let disconnectedMessage = accounts.oauth.createMessageRecord(channelId: canonical, content: "你好 disconnected joint", senderId: ownerId)
            let disconnected = try await batch([disconnectedMessage.id])
            let rows = disconnected["results"] as? [[String: Any]] ?? []
            #expect(rows.count == 1)
            #expect(rows.first?["messageId"] as? String == disconnectedMessage.id)
            #expect(rows.first?["status"] as? String == "not_found")

            let privateChannel = accounts.oauth.createChannel(serverId: guestServerId, name: "translation-private", creatorUserId: guestId, type: "private")
            accounts.oauth.addChannelHuman(channelId: privateChannel, userId: ownerId)
            let privateMessage = accounts.oauth.createMessageRecord(channelId: privateChannel, content: "private translation source", senderId: ownerId)
            let hidden = try await batch([privateMessage.id, "00000000-0000-0000-0000-000000000000"])
            let hiddenRows = hidden["results"] as? [[String: Any]] ?? []
            #expect(hiddenRows.count == 2)
            #expect(hiddenRows.allSatisfy { ($0["status"] as? String) == "not_found" })
        }
    }
}
