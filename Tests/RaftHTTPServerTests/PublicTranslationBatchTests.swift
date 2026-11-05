import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func publicTranslationOnlyCoversThePublicProjection() async throws {
    let directory = PublicVisitDirectory()
    let slug = "public-translation"
    let serverId = "33333333-3333-4333-8333-333333333671"
    let publicChannel = "44444444-4444-4444-8444-000000000671"
    let privateChannel = "44444444-4444-4444-8444-000000000672"
    let threadChannel = "44444444-4444-4444-8444-000000000673"
    directory.addServer(
        id: serverId, slug: slug,
        publiclyVisible: true, publicEnabled: true,
        guestChannelIds: [publicChannel],
        translationEnabled: true
    )
    directory.setTranslationAvailable(true)
    directory.addThread(slug: slug, id: threadChannel, parentChannelId: publicChannel)
    let sender = PublicHistorySender(displayName: "Translator", handle: "translator", avatarUrl: nil, description: nil, actorId: "55555555-5555-4555-8555-000000000671")
    func record(_ id: String, _ channel: String, _ content: String, seq: Int) -> PublicHistoryMessage {
        PublicHistoryMessage(id: id, channelId: channel, content: content, createdAt: "2026-01-01T00:00:00.000Z", seq: seq, senderType: "agent", sender: sender)
    }
    let publicMessage = "66666666-6666-4666-8666-000000000671"
    let hiddenMessage = "66666666-6666-4666-8666-000000000672"
    let replyMessage = "66666666-6666-4666-8666-000000000673"
    directory.addPublicMessage(slug: slug, message: record(publicMessage, publicChannel, "你好 anonymous public", seq: 1))
    directory.addPublicMessage(slug: slug, message: record(hiddenMessage, privateChannel, "你好 hidden", seq: 2))
    directory.addPublicMessage(slug: slug, message: record(replyMessage, threadChannel, "你好 public reply", seq: 3))
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory
        ))
        try await app.testing { client in
            func post(_ ids: [String]) async throws -> (ClientResponse, [String: Any]) {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let data = try JSONSerialization.data(withJSONObject: ["targetLanguage": "en", "mode": "manual", "messageIds": ids])
                let response = try await client.send(.post, headers: headers, to: URI(string: "/api/public/servers/\(slug)/message-translations:batch")) { request in
                    request.body = .init(data: data)
                }
                return (response, (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let allowed = try await post([publicMessage, hiddenMessage, replyMessage])
            #expect(allowed.0.status == .ok)
            let rows = allowed.1["results"] as? [[String: Any]] ?? []
            #expect(rows.map { "\($0["messageId"] as? String ?? ""):\($0["status"] as? String ?? "")" } == [
                "\(publicMessage):translated",
                "\(hiddenMessage):not_found",
                "\(replyMessage):translated",
            ])

            var page: [String] = []
            for index in 0..<50 {
                let id = "77777777-7777-4777-8777-\(String(format: "%012d", index + 1))"
                directory.addPublicMessage(slug: slug, message: record(id, publicChannel, "你好 public page \(index)", seq: index + 10))
                page.append(id)
            }
            let fullPage = try await post(page)
            #expect(fullPage.0.status == .ok)
            #expect((fullPage.1["results"] as? [Any])?.count == 50)

            directory.addServer(
                id: serverId, slug: slug,
                publiclyVisible: true, publicEnabled: true,
                guestChannelIds: [],
                translationEnabled: true
            )
            let revokedChannel = try await post([publicMessage, replyMessage])
            #expect(revokedChannel.0.status == .ok)
            #expect((revokedChannel.1["results"] as? [[String: Any]])?.map { $0["status"] as? String } == ["not_found", "not_found"])

            directory.setPubliclyVisible(slug: slug, visible: false)
            let revokedServer = try await post([publicMessage])
            #expect(revokedServer.0.status == .notFound)
        }
    }
}
