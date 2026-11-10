import Foundation
import HTTPTypes
import JWTKit
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private let previewJWTFixtureSecret = "synthetic-preview-jwt-signing-key-with-64-bytes-of-fixture-material-0001"
private let previewJWTFixtureAttachment = "44444444-4444-4444-8444-444444444401"
private let previewJWTFixtureServer = "33333333-3333-4333-8333-333333333401"
private let previewJWTFixtureActor = "11111111-1111-4111-8111-111111111401"

/// Independent Node wire shape, signed/verified by the mature SDK. It does not
/// reuse the production payload or signer helpers.
private struct NodePreviewJWTFixture: JWTPayload {
    var iss = "slock-server"
    var aud = "attachment-html-preview"
    var type = "attachment-html-preview"
    var sub = previewJWTFixtureActor
    var actorId = previewJWTFixtureActor
    var actorType = "user"
    var attachmentId = previewJWTFixtureAttachment
    var serverId = previewJWTFixtureServer
    var exp = 1_700_000_300
    var iat: Int? = nil

    func verify(using algorithm: some JWTAlgorithm) throws {
        guard algorithm.name == "HS256" else { throw FixtureFailure.invalid }
    }
    private enum FixtureFailure: Error { case invalid }
}

@Test func previewJWTKitIssuesStrictNodeClaimsAndSDKVerifiesBothActors() async throws {
    let codec = AttachmentPreviewTokens(secret: previewJWTFixtureSecret)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let keys = await JWTKeyCollection().add(hmac: HMACKey(from: previewJWTFixtureSecret), digestAlgorithm: .sha256)
    for actor in [AttachmentPreviewTokens.ActorType.user, .machine] {
        let token = try await codec.mint(attachmentId: previewJWTFixtureAttachment,
            serverId: previewJWTFixtureServer, actorId: previewJWTFixtureActor, actorType: actor, now: now)
        #expect(token.split(separator: ".", omittingEmptySubsequences: false).count == 3)
        let decoded = try await keys.verify(token, as: NodePreviewJWTFixture.self)
        #expect(decoded.iss == "slock-server")
        #expect(decoded.aud == "attachment-html-preview")
        #expect(decoded.type == "attachment-html-preview")
        #expect(decoded.actorType == actor.rawValue)
        #expect(decoded.sub == decoded.actorId)
        #expect(decoded.exp == 1_700_000_300)
        #expect(decoded.iat == 1_700_000_000)
        let proof = try #require(await codec.verifyForFlex(token, attachmentId: previewJWTFixtureAttachment, now: now))
        #expect(proof.actorType == actor)
        #expect(proof.actorId == previewJWTFixtureActor)
        #expect(proof.serverId == previewJWTFixtureServer)
        #expect(proof.isValid(attachmentId: previewJWTFixtureAttachment, serverId: previewJWTFixtureServer, now: now))
        #expect(!proof.isValid(attachmentId: previewJWTFixtureAttachment, serverId: previewJWTFixtureServer,
            now: now.addingTimeInterval(301)))
        #expect(await codec.verify(token, attachmentId: previewJWTFixtureAttachment,
            serverId: "33333333-3333-4333-8333-333333333499", now: now) == nil)
    }
}

@Test func previewJWTKitAcceptsIndependentNodeProofAndRejectsWrongClaims() async throws {
    let codec = AttachmentPreviewTokens(secret: previewJWTFixtureSecret)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let keys = await JWTKeyCollection().add(hmac: HMACKey(from: previewJWTFixtureSecret), digestAlgorithm: .sha256)
    let valid = try await keys.sign(NodePreviewJWTFixture())
    #expect(await codec.verify(valid, attachmentId: previewJWTFixtureAttachment,
        serverId: previewJWTFixtureServer, now: now) != nil)
    for field in ["issuer", "audience", "type", "subject", "actorType", "emptyActor", "expired"] {
        var payload = NodePreviewJWTFixture()
        switch field {
        case "issuer": payload.iss = "synthetic-wrong-issuer"
        case "audience": payload.aud = "synthetic-download"
        case "type": payload.type = "access"
        case "subject": payload.sub = "synthetic-other-actor"
        case "actorType": payload.actorType = "synthetic-agent"
        case "emptyActor": payload.actorId = ""; payload.sub = ""
        default: payload.exp = 1_699_999_999
        }
        let token = try await keys.sign(payload)
        #expect(await codec.verifyForFlex(token, attachmentId: previewJWTFixtureAttachment, now: now) == nil)
    }
    #expect(await codec.verifyForFlex(valid, attachmentId: "44444444-4444-4444-8444-444444444499", now: now) == nil)
}

@Test func previewMachineCanMintAndRedeemTheNodeScopedCapability() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        setup.accounts.setChannelPostablePrivateForTesting(channelId: setup.channelId)
        setup.accounts.oauth.setChannelType(id: setup.channelId, type: "private")
        setup.accounts.oauth.addChannelHuman(channelId: setup.channelId, userId: setup.userId)
        let bytes = Data("<html>synthetic machine preview</html>".utf8)
        let id = try await setup.upload(bytes)
        let machine = setup.accounts.registerMachineWithKeyForTesting(serverId: setup.serverId,
            userId: setup.userId, name: "synthetic-preview-machine", apiKey: "sk_machine_synthetic_preview_key")
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(machine.apiKey)"
                let mint = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: headers)
                #expect(mint.status == .ok)
                let json = try JSONSerialization.jsonObject(with: mint.body.data ?? Data()) as? [String: Any]
                let path = try #require(json?["url"] as? String)
                let token = try #require(URLComponents(string: path)?.queryItems?.first { $0.name == "previewToken" }?.value)
                let proof = try #require(await AttachmentPreviewTokens(secret: setup.accounts.oauth.jwtSecret)
                    .verifyForFlex(token, attachmentId: id))
                #expect(proof.actorType == .machine)
                #expect(proof.actorId == machine.id)
                // Node's scoped preview capability survives key rotation; it is
                // not a machine API credential or a general attachment grant.
                setup.accounts.machinesAndComputersStore.storage.withLock { state in
                    if let index = state.machines.firstIndex(where: { $0.id == machine.id }) {
                        state.machines[index].apiKey = nil
                    }
                }
                let preview = try await client.get(URI(string: path))
                #expect(preview.status == .ok)
                var expected = bytes
                expected.append(Data(AttachmentPreviewBridge.script.utf8))
                #expect(try await attachmentPreviewBody(preview) == expected)
                let other = try await client.get(URI(string: "/api/attachments/\(id)?previewToken=\(token)"))
                #expect(other.status == .unauthorized)
            }
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}

@Test func previewOrdinaryJWTWinsCredentialSelectionAndLeafErrorsStayScoped() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let bytes = Data("<html>synthetic header-authorized preview</html>".utf8)
        let id = try await setup.upload(bytes)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                var headers = HTTPFields()
                headers[.authorization] = setup.authorization
                headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
                let minted = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url?previewToken=synthetic-invalid"), headers: headers)
                #expect(minted.status == .ok)
                let invalid = try await client.get(URI(string: "/api/attachments/\(id)/html-preview?previewToken=synthetic-invalid"), headers: headers)
                #expect(invalid.status == .forbidden)
                #expect(try await attachmentPreviewBody(invalid) == Data(#"{"error":"Invalid attachment preview token"}"#.utf8))
                let hidden = try await client.get(URI(string: "/api/attachments/\(UUID().uuidString.lowercased())/html-preview?previewToken=synthetic-invalid"), headers: headers)
                #expect(hidden.status == .notFound)
                #expect(try await attachmentPreviewBody(hidden) == Data(#"{"error":"Attachment not found"}"#.utf8))
                let direct = try await client.get(URI(string: "/api/attachments/\(id)/html-preview"), headers: headers)
                #expect(direct.status == .ok)
                var expected = bytes
                expected.append(Data(AttachmentPreviewBridge.script.utf8))
                #expect(try await attachmentPreviewBody(direct) == expected)
                let rawToken = String(setup.authorization.dropFirst("Bearer ".count))
                let query = try await client.get(URI(string: "/api/attachments/\(id)/html-preview?serverId=\(setup.serverId)&token=\(rawToken)"))
                #expect(query.status == .forbidden)
                #expect(try await attachmentPreviewBody(query) == Data(#"{"error":"User bearer query tokens cannot authorize HTML preview"}"#.utf8))
                setup.accounts.retireUserForTesting(userId: setup.userId)
                let retiredJWT = try await client.get(URI(string: "/api/attachments/\(id)/html-preview-url"), headers: headers)
                #expect(retiredJWT.status == .unauthorized)
                #expect(try await attachmentPreviewBody(retiredJWT) == Data(#"{"error":"Authentication required"}"#.utf8))
            }
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}

@Test func previewSignedWrongServerProofUsesVisibilityBeforeLeafRefusal() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let id = try await setup.upload(Data("<html>synthetic cross-scope preview</html>".utf8))
        let token = try await setup.previewToken(id)
        let otherServer = UUID().uuidString.lowercased()
        setup.accounts.oauth.addOwnedServer(id: otherServer, slug: "synthetic-preview-other",
            name: "Synthetic Preview Other", ownerId: setup.userId)
        let channel = setup.accounts.oauth.createChannel(serverId: otherServer, name: "synthetic-preview-other", creatorUserId: setup.userId)
        setup.accounts.addPostableChannel(serverId: otherServer, channelId: channel, memberId: setup.userId, name: "synthetic-preview-other")
        setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments[id]?.channelId = channel }
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                let visible = try await client.get(URI(string: "/api/attachments/\(id)/html-preview?serverId=\(otherServer)&previewToken=\(token)"))
                #expect(visible.status == .forbidden)
                #expect(try await attachmentPreviewBody(visible) == Data(#"{"error":"Invalid attachment preview token"}"#.utf8))
                setup.accounts.messagesAndThreadsStore.withState { $0.channelAttachments.removeValue(forKey: id) }
                let missing = try await client.get(URI(string: "/api/attachments/\(id)/html-preview?serverId=\(otherServer)&previewToken=\(token)"))
                #expect(missing.status == .notFound)
                #expect(try await attachmentPreviewBody(missing) == Data(#"{"error":"Attachment not found"}"#.utf8))
            }
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}

@Test func previewLeafTokenErrorsPrecedeMIMEAfterVisibility() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        for mime in ["text/plain", "application/octet-stream; charset=binary"] {
            let setup = AttachmentPreviewAccounts(storage: fixture.storage)
            let id = try await setup.upload(Data("synthetic non-previewable attachment".utf8), filename: "report.html", mime: mime)
            let previewToken = try await setup.previewToken(id)
            try await withApp { app in
                configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                    pingDatabase: {}, emailAccounts: setup.accounts))
                try await app.testing { client in
                    var headers = HTTPFields()
                    headers[.authorization] = setup.authorization
                    headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
                    let base = "/api/attachments/\(id)/html-preview"
                    let rawToken = String(setup.authorization.dropFirst("Bearer ".count))
                    let invalidPath = base + "?previewToken=synthetic-invalid"
                    let queryPath = base + "?serverId=\(setup.serverId)&token=\(rawToken)"
                    let invalid = try await client.get(URI(string: invalidPath), headers: headers)
                    #expect(invalid.status == .forbidden)
                    #expect(try await attachmentPreviewBody(invalid) == Data(#"{"error":"Invalid attachment preview token"}"#.utf8))
                    let query = try await client.get(URI(string: queryPath))
                    #expect(query.status == .forbidden)
                    #expect(try await attachmentPreviewBody(query) == Data(#"{"error":"User bearer query tokens cannot authorize HTML preview"}"#.utf8))
                    let direct = try await client.get(URI(string: base), headers: headers)
                    #expect(direct.status == .unsupportedMediaType)
                    #expect(try await attachmentPreviewBody(direct) == Data(#"{"error":"Attachment is not previewable HTML"}"#.utf8))
                    let scoped = try await client.get(URI(string: base + "?serverId=\(setup.serverId)&previewToken=\(previewToken)"))
                    #expect(scoped.status == .unsupportedMediaType)
                    #expect(try await attachmentPreviewBody(scoped) == Data(#"{"error":"Attachment is not previewable HTML"}"#.utf8))
                    setup.accounts.setChannelPostablePrivateForTesting(channelId: setup.channelId)
                    setup.accounts.oauth.setChannelType(id: setup.channelId, type: "private")
                    setup.accounts.oauth.removeChannelHuman(channelId: setup.channelId, userId: setup.userId)
                    setup.accounts.serversAndChannelsStore.removeMember(channelId: setup.channelId, memberId: setup.userId)
                    let hiddenInvalid = try await client.get(URI(string: invalidPath), headers: headers)
                    #expect(hiddenInvalid.status == .notFound)
                    #expect(try await attachmentPreviewBody(hiddenInvalid) == Data(#"{"error":"Attachment not found"}"#.utf8))
                    let hiddenQuery = try await client.get(URI(string: queryPath))
                    #expect(hiddenQuery.status == .notFound)
                    #expect(try await attachmentPreviewBody(hiddenQuery) == Data(#"{"error":"Attachment not found"}"#.utf8))
                }
            }
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}

@Test func previewLeafMatchesScalarEmptyAndRepeatedQueryValues() async throws {
    let fixture = try AttachmentPreviewStorageFixture()
    do {
        let setup = AttachmentPreviewAccounts(storage: fixture.storage)
        let bytes = Data("<html>synthetic scalar-query preview</html>".utf8)
        let id = try await setup.upload(bytes)
        try await withApp { app in
            configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {}, emailAccounts: setup.accounts))
            try await app.testing { client in
                var headers = HTTPFields()
                headers[.authorization] = setup.authorization
                headers[HTTPField.Name("X-Server-Id")!] = setup.serverId
                let rawToken = String(setup.authorization.dropFirst("Bearer ".count))
                let bearerError = "User bearer query tokens cannot authorize HTML preview"
                let invalidError = "Invalid attachment preview token"
                let cases: [(String, String?)] = [
                    ("previewToken=", nil),
                    ("previewToken", nil),
                    ("token", bearerError),
                    ("previewToken=&token", bearerError),
                    ("previewToken=&token=", bearerError),
                    ("previewToken=&token=\(rawToken)", bearerError),
                    ("previewToken=synthetic-a&previewToken=synthetic-b", nil),
                    ("token=synthetic-a&token=synthetic-b", nil),
                    ("previewToken=&token=synthetic-a&token=synthetic-b", nil),
                    ("previewToken=synthetic-a&previewToken=synthetic-b&token=", bearerError),
                    ("previewToken=%20&token=", invalidError),
                ]
                for (query, error) in cases {
                    let response = try await client.get(URI(string: "/api/attachments/\(id)/html-preview?\(query)"), headers: headers)
                    #expect(response.status == (error == nil ? .ok : .forbidden))
                    let body = try await attachmentPreviewBody(response)
                    if let error {
                        #expect(body == Data("{\"error\":\"\(error)\"}".utf8))
                    } else {
                        var expected = bytes
                        expected.append(Data(AttachmentPreviewBridge.script.utf8))
                        #expect(body == expected)
                    }
                }
            }
        }
        await fixture.stop()
    } catch { await fixture.stop(); throw error }
}

@Test func previewJWTKitRejectsLegacyFormatWrongAlgorithmAndShortKeys() async throws {
    let codec = AttachmentPreviewTokens(secret: previewJWTFixtureSecret)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let hs384 = await JWTKeyCollection().add(hmac: HMACKey(from: previewJWTFixtureSecret), digestAlgorithm: .sha384)
    let token = try await hs384.sign(NodePreviewJWTFixture())
    #expect(await codec.verifyForFlex(token, attachmentId: previewJWTFixtureAttachment, now: now) == nil)
    #expect(await codec.verifyForFlex("e30.synthetic-legacy-signature", attachmentId: previewJWTFixtureAttachment, now: now) == nil)
    let short = AttachmentPreviewTokens(secret: "synthetic-short")
    await #expect(throws: AttachmentPreviewTokenError.self) {
        try await short.mint(attachmentId: previewJWTFixtureAttachment, serverId: previewJWTFixtureServer,
            actorId: previewJWTFixtureActor, now: now)
    }
    #expect(await short.verifyForFlex(token, attachmentId: previewJWTFixtureAttachment, now: now) == nil)
    #expect(!String(reflecting: codec).contains(previewJWTFixtureSecret))
}
