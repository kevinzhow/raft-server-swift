import Foundation
import HTTPTypes
import Testing
import Vapor
import VaporTesting
import TestSupport
@testable import RaftHTTP
@testable import RaftHTTPServer
import RaftObjectStorage

private enum MachineProjectionScene: Equatable {
    case liveLocalAuthority, liveCanonicalAuthority, ordinarySameServer
    case inactiveSource, missingSource, missingSourceChannel, deletedSource, wrongSourceServer
    case missingCanonical, deletedCanonical
    case inactiveTarget, missingTarget, missingTargetChannel, deletedTarget, wrongTargetServer
    case ambiguousSource, ambiguousTarget, unlinkedDraft
}

private struct MachineProjectionFixture: Sendable {
    let services: FallbackServices
    let key: String
    let attachmentId: String
    let canonicalId: String
    let serverId: String
    let bytes: Data
}

private func machineProjectionFixture(_ scene: MachineProjectionScene) -> MachineProjectionFixture {
    let services = FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
    let accounts = services.emailAccounts
    let owner = "11111111-1111-4111-8111-111111111654"
    let serverA = "33333333-3333-4333-8333-333333333679"
    let serverB = "33333333-3333-4333-8333-333333333680"
    let storageServer = "33333333-3333-4333-8333-333333333681"
    accounts.addAccount(id: owner, email: "machine-projection@example.com", password: "SyntheticPassword123!")
    accounts.oauth.addOwnedServer(id: serverA, slug: "projection-a", name: "Projection A", ownerId: owner)
    accounts.oauth.addOwnedServer(id: serverB, slug: "projection-b", name: "Projection B", ownerId: owner)
    let localA = accounts.oauth.createChannel(serverId: serverA, name: "local-a", creatorUserId: owner)
    let localB = accounts.oauth.createChannel(serverId: serverB, name: "local-b", creatorUserId: owner)
    let canonical = UUID().uuidString.lowercased()
    accounts.addPostableChannel(serverId: serverA, channelId: localA, memberId: owner, kind: "joint", name: "local-a")
    accounts.addPostableChannel(serverId: serverB, channelId: localB, memberId: owner, kind: "joint", name: "local-b")
    // Canonical storage is a channel fact, not a regular OAuth server or a
    // client-supplied server/canonical hint.
    accounts.addPostableChannel(serverId: storageServer, channelId: canonical, memberId: owner, name: "canonical")
    accounts.addJointChannelProjection(localChannelId: localA, canonicalChannelId: canonical, serverId: serverA)
    accounts.addJointChannelProjection(localChannelId: localB, canonicalChannelId: canonical, serverId: serverB)
    let messageChannel = scene == .liveCanonicalAuthority ? canonical : localA
    let messageId = accounts.addHumanMessageForTesting(channelId: messageChannel, senderId: owner, content: "Stored machine attachment authority")
    let bytes = Data("actual joint machine attachment bytes\n".utf8)
    // The projection's own channel intentionally points at B. The stored
    // message's LIVE old localA must remain authoritative, including denials.
    let attachment = accounts.addChannelAttachment(
        channelId: scene == .unlinkedDraft ? localA : localB,
        uploaderId: owner, filename: "machine-projection.txt", mimeType: "text/plain",
        sizeBytes: bytes.count, messageId: scene == .unlinkedDraft ? nil : messageId, bytes: bytes)
    let machineServer = scene == .ordinarySameServer ? serverA : serverB
    let machine = accounts.registerMachineWithKeyForTesting(serverId: machineServer, userId: owner, name: "projection-machine")
    var state = accounts.serversAndChannelsStore.state
    switch scene {
    case .liveLocalAuthority, .liveCanonicalAuthority, .unlinkedDraft: break
    case .ordinarySameServer:
        state.jointProjections.removeAll()
        state.postableChannels.removeValue(forKey: canonical)
    case .inactiveSource:
        for i in state.jointProjections.indices where state.jointProjections[i].localChannelId == localA {
            state.jointProjections[i].status = "disconnected"
        }
    case .missingSource:
        state.jointProjections.removeAll { $0.localChannelId == localA }
    case .missingSourceChannel:
        state.postableChannels.removeValue(forKey: localA)
    case .deletedSource:
        state.postableChannels[localA]?.deletedAt = Date()
    case .wrongSourceServer:
        for i in state.jointProjections.indices where state.jointProjections[i].localChannelId == localA {
            state.jointProjections[i].serverId = serverB
        }
    case .missingCanonical:
        state.postableChannels.removeValue(forKey: canonical)
    case .deletedCanonical:
        state.postableChannels[canonical]?.deletedAt = Date()
    case .inactiveTarget:
        for i in state.jointProjections.indices where state.jointProjections[i].localChannelId == localB {
            state.jointProjections[i].status = "disconnected"
        }
    case .missingTarget:
        state.jointProjections.removeAll { $0.localChannelId == localB }
    case .missingTargetChannel:
        state.postableChannels.removeValue(forKey: localB)
    case .deletedTarget:
        state.postableChannels[localB]?.deletedAt = Date()
    case .wrongTargetServer:
        state.postableChannels[localB]?.serverId = serverA
    case .ambiguousSource:
        let otherCanonical = UUID().uuidString.lowercased()
        var otherRow = state.postableChannels[canonical]!
        otherRow.name = "other-canonical"
        state.postableChannels[otherCanonical] = otherRow
        state.jointProjections.append(JointChannelLink(localChannelId: localA,
            canonicalChannelId: otherCanonical, serverId: serverA))
    case .ambiguousTarget:
        let otherLocal = UUID().uuidString.lowercased()
        var otherRow = state.postableChannels[localB]!
        otherRow.name = "other-target"
        state.postableChannels[otherLocal] = otherRow
        state.jointProjections.append(JointChannelLink(localChannelId: otherLocal,
            canonicalChannelId: canonical, serverId: serverB))
    }
    accounts.serversAndChannelsStore.state = state
    return MachineProjectionFixture(services: services, key: machine.apiKey,
        attachmentId: attachment, canonicalId: canonical, serverId: machineServer, bytes: bytes)
}

private func machineProjectionRequest(_ client: any Client, _ fixture: MachineProjectionFixture,
    url: Bool = false, host: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.key)"
    if let host { headers[HTTPField.Name("Host")!] = host }
    // An untrusted hint must never repair inactive, missing, or ambiguous
    // stored links. Machine scope comes from its live credential as usual.
    let path = "/api/attachments/\(fixture.attachmentId)" + (url ? "/url" : "")
        + "?canonicalChannelId=\(fixture.canonicalId)"
    return try await client.send(.get, headers: headers, to: URI(string: path))
}

@Test func machineAttachmentReadsOldLocalThroughCanonicalIntoItsOwnLiveProjection() async throws {
    for scene in [MachineProjectionScene.liveLocalAuthority, .liveCanonicalAuthority, .ordinarySameServer] {
        try await withSingleURLStorage { storage in
        let fixture = machineProjectionFixture(scene)
        try await withApp { app in
            configure(app, services: fixture.services)
            try await app.testing { client in
                // Live authorization succeeds before the real HTTP storage check.
                // The original scene deliberately starts with no configured port.
                let unconfigured = try await machineProjectionRequest(client, fixture, url: true)
                #expect(unconfigured.status == .serviceUnavailable)
                let refusal = try await singleURLError(unconfigured)
                #expect(refusal == "File storage is not configured on this server")
                let accounts = fixture.services.emailAccounts
                let reference = try await storage.storage.put(attachmentID: fixture.attachmentId, bytes: fixture.bytes)
                accounts.configureAttachmentStorage(storage.storage)
                accounts.messagesAndThreadsStore.withState { state in
                    state.attachmentObjectReferences[fixture.attachmentId] = reference
                    state.developmentAttachmentBytes.removeValue(forKey: fixture.attachmentId)
                }
                let read = try await machineProjectionRequest(client, fixture)
                #expect(read.status == .ok)
                #expect(read.body.string == String(data: fixture.bytes, encoding: .utf8))
                #expect(read.headers[.contentLength] == String(fixture.bytes.count))
                #expect(read.headers[.contentType] == "text/plain; charset=utf-8")
                #expect(read.headers[.cacheControl] == "private, immutable, max-age=31536000")
                #expect(read.headers[.acceptRanges] == "bytes")
                let url = try await machineProjectionRequest(client, fixture, url: true, host: "localhost")
                #expect(url.status == .ok)
                #expect(url.headers[.contentType] == "application/json; charset=utf-8")
                #expect(url.headers[.cacheControl] == "private, no-store")
                let body = try #require(url.body.string)
                #expect(url.headers[.contentLength] == String(body.utf8.count))
                let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                #expect(Set(object.keys) == Set(["url", "expiresAt"]))
                let generated = try #require(object["url"] as? String)
                let parsed = try #require(URLComponents(string: generated))
                #expect(parsed.path == "/api/attachments/\(fixture.attachmentId)")
                #expect(parsed.host == "localhost")
                #expect(object["expiresAt"] is NSNull)
                // Machine query keys remain invalid authentication on their own;
                // the real resolved URL is fetched with its original header key.
                let resolved = try await client.get(URI(string: generated), headers: singleURLHeaders("Bearer \(fixture.key)", nil))
                #expect(resolved.status == .ok)
                let plaintext = try await attachmentPreviewBody(resolved)
                #expect(plaintext == fixture.bytes)
            }
        }
        }
    }
}

@Test func machineAttachmentProjectionRefusalsNeverFallbackToProjectionChannelOrClientHint() async throws {
    let denied: [MachineProjectionScene] = [
        .inactiveSource, .missingSource, .missingSourceChannel, .deletedSource, .wrongSourceServer,
        .missingCanonical, .deletedCanonical, .inactiveTarget, .missingTarget, .missingTargetChannel,
        .deletedTarget, .wrongTargetServer, .ambiguousSource, .ambiguousTarget, .unlinkedDraft
    ]
    for scene in denied {
        let fixture = machineProjectionFixture(scene)
        try await withApp { app in
            configure(app, services: fixture.services)
            try await app.testing { client in
                for url in [false, true] {
                    let response = try await machineProjectionRequest(client, fixture, url: url)
                    let expected = #"{"error":"Attachment not found"}"#
                    #expect(response.status == .notFound)
                    #expect(response.body.string == expected)
                    #expect(response.headers[.contentLength] == String(expected.utf8.count))
                    #expect(response.headers[.contentType] == "application/json; charset=utf-8")
                    #expect(response.headers[.cacheControl] == "private, no-store")
                    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
                }
            }
        }
    }
}
