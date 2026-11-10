import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

/// The required attachment fields consumed by attachmentPreview.ts before any
/// optional preview request. Decoding must succeed before invoking string APIs.
private struct ColdAttachmentConsumer: Decodable {
    let id: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
}

/// Published cold reads after real multipart upload and message/thread writes.
/// Uses the existing real Soto ciphertext fixture; never an injected projection.
@Test(.timeLimit(.minutes(2))) func coldMessageReadsRetainConsumerIdentityAttachmentsAndReplyCoordinates() async throws {
    try await withSingleURLStorage { storage in
        let setup = AttachmentPreviewAccounts(storage: storage.storage)
        // Start this synthetic account at the retained pending-profile state;
        // the published completion route establishes its actual sender labels.
        setup.accounts.authProfileStore.state.withLock { state in
            state.accountSurface.accounts["preview-owner@example.com"]?.profileSetupCompletedAt = nil
        }
        try await withApp { app in
            configure(app, services: singleURLServices(setup.accounts))
            try await app.testing(.running, options: .live(clientOptions: .init(timeout: .seconds(10)))) { client in
                var headers = singleURLHeaders(setup.authorization, setup.serverId)
                headers[.contentType] = "application/json"
                func object(_ response: ClientResponse) async throws -> [String: Any] {
                    try #require(JSONSerialization.jsonObject(with: try await attachmentPreviewBody(response)) as? [String: Any])
                }
                func post(_ path: String, _ value: [String: Any]) async throws -> ClientResponse {
                    let bytes = try JSONSerialization.data(withJSONObject: value)
                    return try await client.send(.post, headers: headers, to: URI(string: path)) { $0.body = .init(data: bytes) }
                }
                let profileBytes = try JSONSerialization.data(withJSONObject: ["name": "projection_reader", "displayName": "Projection Reader"])
                let profile = try await client.send(.post, headers: headers, to: "/api/auth/me/complete-profile") { $0.body = .init(data: profileBytes) }
                #expect(profile.status == .ok)
                let firstBytes = Data("# Retained REPORT\n".utf8)
                let firstId = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "REPORT.MD", mime: "text/markdown", bytes: firstBytes)
                let secondId = try await singleURLUpload(client, authorization: setup.authorization, server: setup.serverId,
                    channel: setup.channelId, filename: "rows.csv", mime: "text/csv", bytes: Data("n\n".utf8))
                let sent = try await post("/api/messages", ["channelId": setup.channelId, "content": "cold parent", "attachmentIds": [secondId, firstId]])
                #expect(sent.status == .ok)
                let parentId = try #require(try await object(sent)["id"] as? String)
                // An intervening parent-channel message makes reply seq differ
                // from the first index inside the thread. Navigation must retain seq.
                _ = try await post("/api/messages", ["channelId": setup.channelId, "content": "intervening"])
                let threadResponse = try await post("/api/channels/\(setup.channelId)/threads", ["parentMessageId": parentId])
                #expect(threadResponse.status == .ok)
                let threadId = try #require(try await object(threadResponse)["threadChannelId"] as? String)
                let replyResponse = try await post("/api/messages", ["channelId": threadId, "content": "cold reply"])
                #expect(replyResponse.status == .ok)
                let replyId = try #require(try await object(replyResponse)["id"] as? String)
                let replyPage = try await client.get(URI(string: "/api/messages/channel/\(threadId)"), headers: headers)
                let replyRows = try #require(try await object(replyPage)["messages"] as? [[String: Any]])
                let reply = try #require(replyRows.first { $0["id"] as? String == replyId })
                let replySeq = try #require(reply["seq"] as? Int)
                #expect(replySeq > 1)
                let replyTime = try #require(reply["createdAt"] as? String)
                let dateParser = ISO8601DateFormatter()
                dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                #expect(dateParser.date(from: replyTime) != nil)
                var parentRows: [[String: Any]] = []
                for path in [
                    "/api/messages/channel/\(setup.channelId)",
                    "/api/messages/context/\(parentId)?channelId=\(setup.channelId)",
                    "/api/messages/sync?channel_id=\(setup.channelId)&since_seq=0",
                    "/api/messages/sync?since_seq=0",
                ] {
                    let response = try await client.get(URI(string: path), headers: headers)
                    #expect(response.status == .ok)
                    let data = try await attachmentPreviewBody(response)
                    let value = try JSONSerialization.jsonObject(with: data)
                    let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
                    let row = try #require(rows.first { $0["id"] as? String == parentId })
                    parentRows.append(row)
                    #expect(row["channelId"] as? String == setup.channelId)
                    #expect(row["senderId"] as? String == setup.userId)
                    #expect(row["senderType"] as? String == "user")
                    #expect(row["senderName"] as? String == "Projection Reader")
                    #expect(row["senderHandle"] as? String == "projection_reader")
                    #expect(row["senderDisplayName"] as? String == "Projection Reader")
                    #expect(row["senderAvatarUrl"] is NSNull)
                    #expect(row["messageType"] as? String == "chat")
                    #expect(row["content"] as? String == "cold parent")
                    #expect(row["seq"] is Int && row["createdAt"] is String)
                    #expect(row["threadId"] as? String == threadId)
                    #expect(row["senderTimezone"] == nil)
                    let chips = try #require(row["attachments"] as? [[String: Any]])
                    #expect(chips.compactMap { $0["id"] as? String } == [secondId, firstId])
                    #expect(chips[0]["filename"] as? String == "rows.csv")
                    #expect(chips[0]["mimeType"] as? String == "text/csv")
                    #expect(chips[0]["sizeBytes"] as? Int == 2)
                    #expect(chips[1]["filename"] as? String == "REPORT.MD")
                    #expect(chips[1]["mimeType"] as? String == "text/markdown")
                    #expect(chips[1]["sizeBytes"] as? Int == firstBytes.count)
                    let attachmentData = try JSONSerialization.data(withJSONObject: chips)
                    let consumers = try JSONDecoder().decode([ColdAttachmentConsumer].self, from: attachmentData)
                    #expect(consumers[1].filename.lowercased() == "report.md")
                    #expect(consumers[1].mimeType.lowercased().split(separator: ";").first == "text/markdown")
                    #expect(consumers[1].sizeBytes == firstBytes.count)
                    #expect(chips.allSatisfy { $0["storageKey"] == nil && $0["objectKey"] == nil })
                    if let body = value as? [String: Any] {
                        let summaries = try #require(body["threadSummariesByParentMessageId"] as? [String: Any])
                        let summary = try #require(summaries[parentId] as? [String: Any])
                        #expect(summary["threadChannelId"] as? String == threadId)
                        let previews = try #require(summary["latestReplies"] as? [[String: Any]])
                        let preview = try #require(previews.first { $0["messageId"] as? String == replyId })
                        #expect(preview["seq"] as? Int == replySeq)
                        #expect(preview["senderId"] as? String == setup.userId)
                        #expect(preview["senderType"] as? String == "user")
                        #expect(preview["senderName"] as? String == "projection_reader")
                        #expect(preview["senderDisplayName"] as? String == "Projection Reader")
                        #expect(preview["createdAt"] as? String == replyTime)
                        #expect(preview["preview"] as? String == "cold reply")
                        #expect(summary["epoch"] == nil && summary["watermark"] == nil)
                    }
                }
                #expect(Set(parentRows.compactMap { $0["createdAt"] as? String }).count == 1)
                let replyContextResponse = try await client.get(
                    URI(string: "/api/messages/context/\(replyId)?channelId=\(setup.channelId)"), headers: headers)
                #expect(replyContextResponse.status == .ok)
                let replyContext = try await object(replyContextResponse)
                #expect(replyContext["channelId"] as? String == threadId)
                let canonicalTarget = try #require(replyContext["canonicalTarget"] as? [String: Any])
                #expect(canonicalTarget["messageId"] as? String == replyId)
                #expect(canonicalTarget["threadParentMessageId"] as? String == parentId)
                #expect(canonicalTarget["threadChannelId"] as? String == threadId)
                let replyWindow = try #require(replyContext["messages"] as? [[String: Any]])
                let restoredReply = try #require(replyWindow.first)
                #expect(restoredReply["id"] as? String == replyId)
                #expect(restoredReply["channelId"] as? String == threadId)
                #expect(restoredReply["seq"] as? Int == replySeq)
                #expect(restoredReply["senderId"] as? String == setup.userId)
                #expect(restoredReply["senderType"] as? String == "user")
                #expect(restoredReply["senderName"] as? String == "Projection Reader")
                #expect(restoredReply["senderHandle"] as? String == "projection_reader")
                #expect(restoredReply["createdAt"] as? String == replyTime)
                // The actual stored objects stay sealed outside the message owner.
                let sealed = storage.state.value.withLock { Array($0.ciphertext.values) }
                #expect(sealed.count == 2)
                #expect(sealed.allSatisfy { $0 != firstBytes })
                #expect(setup.accounts.messagesAndThreadsStore.withState { $0.developmentAttachmentBytes.isEmpty })
            }
        }
    }
}
