import Crypto
import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import RaftObjectStorage
import Synchronization
import TestSupport
import Testing
import Vapor
import VaporTesting

/// The published owner-opener Team-Mode artifact: the second visible opener
/// message must carry a real thread whose agent reply owns the generated
/// `text/html` attachment. Upstream `sendOwnerOpenerV2`
/// (`services/onboardingService.ts:533-601`) always creates the thread, the
/// artifact projection and the `team-mode-thread` reply; this port deferred it.
///
/// This focused app has no durable writer, so the transient ledger notice is
/// dropped and the sent stamp stays null (the accepted-receipt path is covered
/// by the briefing unit fixture). The thread, the reply and the attachment are
/// posted before that ledger, exactly as upstream, and must be readable through
/// the ordinary attachment routes by the owner.
@Suite(.serialized) struct OnboardingBriefingArtifactHTTPTests {
    /// Byte-for-byte facts of the pinned upstream asset
    /// `packages/server/src/services/ownerOpenerArtifactHtml.ts`
    /// (`OWNER_OPENER_TEAM_MODE_HTML`, imported with Node type stripping).
    static let upstreamArtifactSize = 569_032
    static let upstreamArtifactSHA256 = "ed98e1a523c12814eee0cc0af0ea7ec43d5bbe8abc636a9c81bcde029c740147"

    private struct Seed {
        let accounts: EmailLoginDirectory
        let storage: AttachmentPreviewStorageFixture
        let ownerId: String
        let serverId: String
        let agentId: String
        let allChannelId: String
        let ownerToken: String
    }

    private func seed() throws -> Seed {
        let storage = try AttachmentPreviewStorageFixture()
        let accounts = EmailLoginDirectory()
        accounts.oauth.jwtSecret = attachmentPreviewFixtureSigningSecret
        accounts.configureAttachmentStorage(storage.storage)
        let ownerId = "11111111-1111-4111-8111-111111111871"
        let serverId = "33333333-3333-4333-8333-333333333871"
        accounts.addAccount(id: ownerId, email: "opener-artifact-owner@slock.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: "opener-artifact", name: "Opener Artifact",
                                      ownerId: ownerId)
        let allChannelId = accounts.oauth.allChannelId(serverId: serverId) ?? ""
        accounts.serversAndChannelsStore.insertOwnedChannel(channelId: allChannelId, serverId: serverId,
                                                            userId: ownerId, name: "all")
        let cindy = accounts.oauth.createAgent(serverId: serverId, name: "Cindy", displayName: "Cindy",
                                               runtime: "codex")
        accounts.oauth.setAgentStatus(id: cindy, status: "active")
        accounts.serversAndChannelsStore.bindOnboardingAgent(serverId: serverId, agentId: cindy)
        return Seed(accounts: accounts, storage: storage, ownerId: ownerId, serverId: serverId,
                    agentId: cindy, allChannelId: allChannelId,
                    ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId))
    }

    private func patchMe(_ client: any TestClient, token: String, body: String) async throws -> ClientResponse {
        var fields = HTTPFields()
        fields[.authorization] = "Bearer \(token)"
        fields[.contentType] = "application/json"
        return try await client.send(.patch, headers: fields, to: "/api/auth/me") { request in
            request.body = .init(string: body)
        }
    }

    private func openerRows(_ seed: Seed, channelId: String? = nil) -> [StoredHumanMessage] {
        seed.accounts.messagesAndThreadsStore.humanMessageRows
            .filter { $0.senderId == seed.agentId && (channelId == nil || $0.channelId == channelId) }
            .sorted { $0.seq < $1.seq }
    }

    private func threadRows(_ seed: Seed) -> [(id: String, channel: PostableChannel)] {
        seed.accounts.serversAndChannelsStore.postableChannels
            .filter { $0.value.serverId == seed.serverId && $0.value.kind == "thread" }
            .map { (id: $0.key, channel: $0.value) }
            .sorted { ($0.channel.parentMessageId ?? "") < ($1.channel.parentMessageId ?? "") }
    }

    @Test func triggerCreatesTheTeamModeThreadReplyAndADownloadableHTMLAttachment() async throws {
        let seed = try seed()
        do {
            try await runArtifactFlow(seed)
        } catch {
            await seed.storage.stop()
            throw error
        }
        await seed.storage.stop()
    }

    private func runArtifactFlow(_ seed: Seed) async throws {
        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
                emailAccounts: seed.accounts
            ))
            try await app.testing { client in
                let response = try await patchMe(
                    client, token: seed.ownerToken,
                    body: #"{"signupRole":"founder","signupSurveyServerId":"\#(seed.serverId)"}"#
                )
                #expect(response.status == .ok)

                // Four opener messages in the enabled #all plus the one thread
                // reply (upstream `team-mode-thread`), in commit order.
                let parentMessage = try #require(openerRows(seed, channelId: seed.allChannelId)
                    .first { $0.agentSendKey == "owner-opener-v2.0:\(seed.serverId):\(seed.ownerId):team_mode_artifact" })
                let threads = threadRows(seed)
                #expect(threads.count == 1)
                let thread = try #require(threads.first)
                #expect(thread.channel.parentChannelId == seed.allChannelId)
                #expect(thread.channel.parentMessageId == parentMessage.id)
                #expect(thread.channel.memberIds.contains(seed.ownerId))

                let replies = openerRows(seed, channelId: thread.id)
                #expect(replies.count == 1)
                let reply = try #require(replies.first)
                #expect(reply.content == "Here's what team mode looks like in practice:")
                #expect(reply.agentSendKey == "owner-opener-v2.0:\(seed.serverId):\(seed.ownerId):team-mode-thread")

                // The generated attachment row: agent-owned, in the thread, with
                // the pinned filename/mime/size and a durable object reference.
                let artifacts = seed.accounts.messagesAndThreadsStore.channelAttachments.values
                    .filter { $0.filename == "team-mode.html" }
                #expect(artifacts.count == 1)
                let artifact = try #require(artifacts.first)
                #expect(artifact.id == "26bd3b98-ac24-4b16-89a1-b89d1ca58595")
                #expect(reply.attachmentIds == [artifact.id])
                #expect(artifact.channelId == thread.id)
                #expect(artifact.uploaderId == seed.agentId)
                #expect(artifact.uploaderType == "agent")
                #expect(artifact.mimeType == "text/html")
                #expect(artifact.sizeBytes == Self.upstreamArtifactSize)
                #expect(artifact.messageId == reply.id)
                let reference = try #require(seed.accounts.messagesAndThreadsStore
                    .withState { $0.attachmentObjectReferences[artifact.id] })
                #expect(reference.byteCount == Self.upstreamArtifactSize)
                #expect(reference.objectKey == "attachments/26bd3b98-ac24-4b16-89a1-b89d1ca58595")
                // The bytes were sealed by the ordinary upload storage before
                // the referencing row: exactly one object write.
                #expect(seed.storage.state.value.withLock { $0.ciphertext.count } == 1)

                // The owner reads the artifact through the ordinary download
                // route; the bytes are the pinned upstream document.
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(seed.ownerToken)"
                headers[HTTPField.Name("X-Server-Id")!] = seed.serverId
                let download = try await client.send(.get, headers: headers,
                                                     to: "/api/attachments/\(artifact.id)")
                #expect(download.status == .ok)
                #expect(download.body.data?.count == Self.upstreamArtifactSize)
                #expect(Self.sha256(download.body.data ?? Data()) == Self.upstreamArtifactSHA256)
                #expect(download.headers[.contentType] == "text/html; charset=utf-8")
                #expect(download.headers[.contentDisposition]?.hasPrefix("attachment;") == true)

                // HTML preview is the upstream dedicated path, not the download
                // fallback: a short-lived token, sandbox headers and the
                // measurement bridge appended to the original document.
                let minted = try await client.get(
                    URI(string: "/api/attachments/\(artifact.id)/html-preview-url"), headers: headers)
                #expect(minted.status == .ok)
                let mintedJSON = try JSONSerialization.jsonObject(with: minted.body.data ?? Data()) as? [String: Any]
                let previewPath = try #require(mintedJSON?["url"] as? String)
                let preview = try await client.get(URI(string: previewPath))
                #expect(preview.status == .ok)
                var expected = artifactBytesForTest()
                expected.append(Data(AttachmentPreviewBridge.script.utf8))
                #expect(try await attachmentPreviewBody(preview) == expected)
                #expect(preview.headers[.contentType] == "text/html; charset=utf-8")
                #expect(preview.headers[.cacheControl] == "private, no-store")
                #expect(preview.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
                #expect(preview.headers[HTTPField.Name("Referrer-Policy")!] == "no-referrer")
                #expect(preview.headers[.contentDisposition]?.hasPrefix("inline;") == true)

                // The ledger dropped in this focused app, so nothing was stamped.
                let ledger = seed.accounts.serversAndChannelsStore
                    .ownerOpenerLedger(serverId: seed.serverId, ownerId: seed.ownerId)
                #expect(ledger.openerV2SentAt == nil)
                #expect(ledger.openerClaimedAt == nil)

                // A replay is invisible: the second survey save re-finds the
                // same thread and reply, and reuses the same sealed object.
                let again = try await patchMe(
                    client, token: seed.ownerToken,
                    body: #"{"signupRole":"founder","signupSurveyServerId":"\#(seed.serverId)"}"#
                )
                #expect(again.status == .ok)
                #expect(threadRows(seed).map(\.id) == threads.map(\.id))
                #expect(openerRows(seed, channelId: thread.id).map(\.id) == replies.map(\.id))
                #expect(seed.accounts.messagesAndThreadsStore.channelAttachments
                    .values.filter { $0.filename == "team-mode.html" }.count == 1)
                #expect(seed.storage.state.value.withLock { $0.ciphertext.count } == 1)
            }
        }
    }

    /// The pinned document as this port ships it. It is read through the target
    /// bundle so the test body verifies the delivered bytes, not a second copy.
    private func artifactBytesForTest() -> Data {
        (try? OnboardingBriefingContent.teamModeArtifactBytes()) ?? Data()
    }

    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
