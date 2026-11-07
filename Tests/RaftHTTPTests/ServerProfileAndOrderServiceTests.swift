import Crypto
import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The service/store contract behind the server profile, switcher order,
/// translation and scope-attestation routes. The HTTP tests lock the wire
/// shape; these lock each atomic section and the signed bytes.

private func profileFixture(
    ownerId: String,
    serverId: String,
    slug: String
) -> EmailLoginDirectory {
    let directory = EmailLoginDirectory()
    directory.addAccount(id: ownerId, email: "\(slug)@slock.test", password: "password123")
    directory.markEmailVerified(userId: ownerId)
    directory.oauth.addOwnedServer(id: serverId, slug: slug, name: slug, ownerId: ownerId)
    return directory
}

@Test func switcherOrderPatchBumpsTheVersionExactlyOnceUnderConcurrency() async {
    let ownerId = "11111111-1111-4111-8111-000001170101"
    let serverA = "33333333-3333-4333-8333-000001170101"
    let serverB = "33333333-3333-4333-8333-000001170102"
    let directory = profileFixture(ownerId: ownerId, serverId: serverA, slug: "order-cas-a")
    directory.oauth.addOwnedServer(id: serverB, slug: "order-cas-b", name: "B", ownerId: ownerId)
    let store = directory.serversAndChannelsStore
    let memberships = ServerMembershipQuery(oauth: directory.oauth)
    // Stored order is [A, B]; eight racing patches all ask for [B, A]. Only one
    // can observe a change, so the version ends at exactly one.
    directory.seedServerSwitcherOrder(userId: ownerId, ids: [serverA, serverB], version: 0)

    let versions = await withTaskGroup(of: Int.self) { group in
        for _ in 0..<8 {
            group.addTask {
                store.updateServerOrder(
                    userId: ownerId,
                    requested: [serverB, serverA],
                    memberships: memberships
                ).version
            }
        }
        var collected: [Int] = []
        for await version in group { collected.append(version) }
        return collected
    }
    #expect(versions.allSatisfy { $0 == 1 })
    let snapshot = store.serverOrder(userId: ownerId, memberships: memberships)
    #expect(snapshot.ids == [serverB, serverA])
    #expect(snapshot.version == 1)
}

@Test func switcherOrderDropsNonMembersAndAppendsTheRest() {
    let ownerId = "11111111-1111-4111-8111-000001170102"
    let serverA = "33333333-3333-4333-8333-000001170103"
    let serverB = "33333333-3333-4333-8333-000001170104"
    let directory = profileFixture(ownerId: ownerId, serverId: serverA, slug: "order-san-a")
    let store = directory.serversAndChannelsStore
    let oauth = directory.oauth
    let memberships = ServerMembershipQuery(oauth: oauth)

    let initial = store.updateServerOrder(userId: ownerId, requested: [serverA], memberships: memberships)
    #expect(initial.ids == [serverA])
    #expect(initial.version == 0, "persisting the default order is not a version change")

    // Reuse the same query after changing its actual OAuth owner's membership.
    oauth.addOwnedServer(id: serverB, slug: "order-san-b", name: "B", ownerId: ownerId)
    let result = store.updateServerOrder(
        userId: ownerId,
        requested: [serverB, "stranger", serverB],
        memberships: memberships
    )
    #expect(result.ids == [serverB, serverA])
    #expect(result.version == 1)

    oauth.removeMember(serverId: serverB, userId: ownerId)
    let reduced = store.serverOrder(userId: ownerId, memberships: memberships)
    #expect(reduced.ids == [serverA])
    #expect(reduced.version == 1, "GET sanitizes its response without changing the stored order")
    let cleaned = store.updateServerOrder(userId: ownerId, requested: [serverA], memberships: memberships)
    #expect(cleaned.ids == [serverA])
    #expect(cleaned.version == 2, "PATCH compares with the unsanitized stored order")

    oauth.addMember(serverId: serverB, userId: ownerId, role: "guest")
    let restored = store.serverOrder(userId: ownerId, memberships: memberships)
    #expect(restored.ids == [serverA, serverB], "all live membership roles remain eligible")
    #expect(restored.version == 2)
    let reordered = store.updateServerOrder(
        userId: ownerId, requested: [serverB, serverA], memberships: memberships
    )
    #expect(reordered.ids == [serverB, serverA])
    #expect(reordered.version == 3)
}

@Test func hideHumansUpdateWritesAndReadsInOneSection() {
    let ownerId = "11111111-1111-4111-8111-000001170103"
    let serverId = "33333333-3333-4333-8333-000001170105"
    let directory = profileFixture(ownerId: ownerId, serverId: serverId, slug: "hide-section")
    let store = directory.serversAndChannelsStore

    #expect(store.updateHideHumans(serverId: serverId, hidden: nil) == false)
    #expect(store.updateHideHumans(serverId: serverId, hidden: true))
    #expect(store.updateHideHumans(serverId: serverId, hidden: nil))
    #expect(store.updateHideHumans(serverId: serverId, hidden: false) == false)
}

@Test func translationLedgerRowIsWrittenWholeUnderConcurrency() async {
    let store = MessagesAndThreadsStore()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            group.addTask {
                store.recordMessageTranslation(
                    messageId: "m-\(index % 4)",
                    status: "translated",
                    providerBilledChars: index,
                    targetLanguage: "en",
                    translatedContent: "row-\(index)"
                )
            }
        }
        for await _ in group {}
    }
    for slot in 0..<4 {
        let row = store.messageTranslationLedger["m-\(slot)"]
        #expect(row != nil)
        // Whichever writer landed last, its chars and content belong together.
        #expect(row?.translatedContent == "row-\(row?.providerBilledChars ?? -1)")
    }
}

// MARK: - Scope attestation bytes

private let attestationNow = Date(timeIntervalSince1970: 1_700_000_000.75)

private func decodeSegment(_ segment: Substring) -> String {
    var text = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    return String(decoding: Data(base64Encoded: text) ?? Data(), as: UTF8.self)
}

private func hmac(_ input: String, secret: String) -> String {
    let mac = Data(HMAC<SHA256>.authenticationCode(
        for: Data(input.utf8),
        using: SymmetricKey(data: Data(secret.utf8))
    ))
    return mac.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func sortedJSON(_ object: [String: Any]) -> String {
    String(
        decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(),
        as: UTF8.self
    )
}

private func attestationService(directory: EmailLoginDirectory) -> ServerProfileAndOrderService {
    var dependencies = ServerProfileAndOrderDependencies(
        auth: directory.authCore,
        machineIdForCredential: directory.machinesAndHostedRuntime.machineIdForCredential,
        oauth: directory.oauth,
        channels: directory.serversAndChannelsStore,
        messages: directory.messagesAndThreadsStore,
        profiles: directory.authProfileStore,
        machines: directory.machinesAndComputersStore,
        agents: directory.agentsRuntimeStore
    )
    dependencies.now = { attestationNow }
    dependencies.makeUUID = { "00000000-0000-4000-8000-00000000abcd" }
    dependencies.environment = { [:] }
    return ServerProfileAndOrderService(dependencies: dependencies)
}

@Test func machineAttestationSignsTheSortedClaimsAndEchoesTheSameMetadataBytes() throws {
    let ownerId = "11111111-1111-4111-8111-000001170201"
    let serverId = "33333333-3333-4333-8333-000001170201"
    let directory = profileFixture(ownerId: ownerId, serverId: serverId, slug: "attest-bytes")
    directory.setScopeAttestationSecretForTesting("top-secret")
    directory.setDeploymentEnvironmentForTesting("production")
    let machine = directory.registerMachineWithKeyForTesting(serverId: serverId, userId: ownerId, name: "m")
    let machineId = machine.id
    let machineKey = machine.apiKey
    let service = attestationService(directory: directory)

    let request = MachineScopeAttestationRequest(
        scope: "daemon-trace-bundle:create",
        metadata: [
            "bundleId": .string("bundle/1"),
            "bundleSha256": .string(String(repeating: "a", count: 64)),
            "bundleSizeBytes": .integer(1024),
            "feedbackTranscriptTruncated": .bool(true),
            "feedbackTranscriptWindowToleranceMs": .number(250.0),
        ]
    )
    let response = try service.machineScopeAttestation(
        authorization: "Bearer \(machineKey)",
        body: request
    )

    let expectedMetadata: [String: Any] = [
        "bundleId": "bundle/1",
        "bundleSha256": String(repeating: "a", count: 64),
        "bundleSizeBytes": 1024,
        "deploymentEnvironment": "production",
        "bundleContentType": "application/x-ndjson",
        "bundleContentEncoding": "gzip",
        "maxBytes": 50 * 1024 * 1024,
        "objectKey": "trace-bundles/\(serverId)/\(machineId)/00000000-0000-4000-8000-00000000abcd.jsonl.gz",
        "feedbackTranscriptTruncated": "true",
        "feedbackTranscriptWindowToleranceMs": 250,
    ]
    let expectedClaims: [String: Any] = [
        "sub": "machine:\(machineId)", "actorType": "machine", "machineId": machineId,
        "serverId": serverId, "serverSlug": "attest-bytes", "scope": "daemon-trace-bundle:create",
        "aud": "trace-ingest-worker",
        "resource": "servers/\(serverId)/machines/\(machineId)/trace-bundles",
        "jti": "00000000-0000-4000-8000-00000000abcd", "nonce": "00000000-0000-4000-8000-00000000abcd",
        "exp": 1_700_000_120, "metadata": expectedMetadata,
    ]
    let parts = response.attestation.split(separator: ".", omittingEmptySubsequences: false)
    #expect(parts.count == 3)
    #expect(decodeSegment(parts[0]) == "{\"alg\":\"HS256\",\"typ\":\"JWT\"}")
    #expect(decodeSegment(parts[1]) == sortedJSON(expectedClaims))
    #expect(String(parts[2]) == hmac("\(parts[0]).\(parts[1])", secret: "top-secret"))
    #expect(response.jsonBody.render() == "{\"attestation\":\(jsonString(response.attestation)),\"scope\":\"daemon-trace-bundle:create\",\"audience\":\"trace-ingest-worker\",\"resource\":\"servers/\(serverId)/machines/\(machineId)/trace-bundles\",\"expiresAt\":\"2023-11-14T22:15:20.000Z\",\"metadata\":\(sortedJSON(expectedMetadata))}")
}

@Test func machineAttestationRefusalsKeepTheirPublishedOrder() throws {
    let ownerId = "11111111-1111-4111-8111-000001170202"
    let serverId = "33333333-3333-4333-8333-000001170202"
    let directory = profileFixture(ownerId: ownerId, serverId: serverId, slug: "attest-refusals")
    directory.setScopeAttestationSecretForTesting("top-secret")
    let machine = directory.registerMachineWithKeyForTesting(serverId: serverId, userId: ownerId, name: "m")
    let machineId = machine.id
    let machineKey = machine.apiKey
    let service = attestationService(directory: directory)
    let auth = "Bearer \(machineKey)"

    func refusal(_ request: MachineScopeAttestationRequest?) -> ServerProfileAndOrderError? {
        do {
            _ = try service.machineScopeAttestation(authorization: auth, body: request)
            return nil
        } catch let error as ServerProfileAndOrderError {
            return error
        } catch {
            return nil
        }
    }

    #expect(refusal(nil) == .invalidAttestationRequest)
    #expect(refusal(MachineScopeAttestationRequest(scope: "feedback-report:create", hasAudience: true))
        == .audienceDerived)
    #expect(refusal(MachineScopeAttestationRequest(scope: "feedback-report:create", hasResource: true))
        == .resourceDerived)
    #expect(refusal(MachineScopeAttestationRequest(scope: "nope")) == .unsupportedScope("nope"))
    // The unsupported-scope body keeps the legacy unescaped interpolation.
    #expect(ServerProfileAndOrderError.unsupportedScope("a\"b").publishedErrorBody.render()
        == "{\"error\":\"Unsupported scope: a\"b\"}")
    #expect(refusal(MachineScopeAttestationRequest(scope: "daemon-trace-bundle:create"))
        == .invalidAttestationRequest)
    #expect(ServerProfileAndOrderError.agentNotOnMachine.publishedErrorBody.render()
        == "{\"error\":\"Agent does not belong to this machine\",\"code\":\"agent_not_on_machine\"}")

    // No signing secret configured and none in the environment.
    directory.setScopeAttestationSecretForTesting(nil)
    #expect(refusal(MachineScopeAttestationRequest(scope: "feedback-report:create"))
        == .scopeAttestationNotConfigured)
    // No machine credential.
    #expect(throws: ServerProfileAndOrderError.machineUnauthorized) {
        _ = try service.machineScopeAttestation(authorization: "Bearer nope", body: nil)
    }
}

@Test func serverAttestationSignsTheSortedClaimsWithoutMetadata() throws {
    let ownerId = "11111111-1111-4111-8111-000001170203"
    let serverId = "33333333-3333-4333-8333-000001170203"
    let directory = profileFixture(ownerId: ownerId, serverId: serverId, slug: "attest-server")
    let token = directory.mintAccessTokenForTesting(userId: ownerId)
    let service = attestationService(directory: directory)

    let response = try service.serverScopeAttestation(
        authorization: "Bearer \(token)",
        serverId: serverId,
        body: ServerScopeAttestationRequest(scope: "feedback-report:create")
    )
    let claims: [String: Any] = [
        "scope": "feedback-report:create", "actorType": "user", "sub": ownerId, "serverId": serverId,
        "aud": "feedback-worker", "resource": "servers/\(serverId)/feedback-reports", "exp": 1_700_000_300,
    ]
    let parts = response.attestation.split(separator: ".", omittingEmptySubsequences: false)
    #expect(decodeSegment(parts[1]) == sortedJSON(claims))
    #expect(String(parts[2]) == hmac("\(parts[0]).\(parts[1])", secret: "scope-attestation-default-secret"))
    #expect(response.jsonBody.render() == "{\"attestation\":\(jsonString(response.attestation)),\"scope\":\"feedback-report:create\",\"audience\":\"feedback-worker\",\"resource\":\"servers/\(serverId)/feedback-reports\",\"expiresAt\":\"2023-11-14T22:18:20.750Z\"}")

    #expect(throws: ServerProfileAndOrderError.unknownScope) {
        _ = try service.serverScopeAttestation(
            authorization: "Bearer \(token)",
            serverId: serverId,
            body: ServerScopeAttestationRequest(scope: "other")
        )
    }
}

@Test func requestDecodersKeepTheLegacyCasts() throws {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
    #expect(decode(ServerTranslationSettingsPatchRequest.self, "{\"translationEnabled\":1}")?.translationEnabled == true)
    #expect(decode(ServerTranslationSettingsPatchRequest.self, "{\"translationEnabled\":0.0}")?.translationEnabled == false)
    #expect(decode(ServerTranslationSettingsPatchRequest.self, "{\"translationEnabled\":2}")?.translationEnabled == nil)
    #expect(decode(ServerTranslationSettingsPatchRequest.self, "{\"translationEnabled\":\"true\"}")?.translationEnabled == nil)
    #expect(decode(ServerProfilePatchRequest.self, "{\"name\":null}")?.name == .invalid)
    #expect(decode(ServerProfilePatchRequest.self, "{}")?.name == .absent)
    #expect(decode(ServerProfilePatchRequest.self, "{\"hideHumansFromMembers\":1}")?.hideHumansFromMembers == .value(true))
    #expect(decode(ServerProfilePatchRequest.self, "[]") == nil)
    let batch = decode(MessageTranslationBatchRequest.self, "{\"targetLanguage\":\"en\",\"mode\":\"auto\",\"messageIds\":[\"a\",1,null,{\"x\":1},\"b\"]}")
    #expect(batch?.messageIds == ["a", "b"])
    #expect(decode(MessageTranslationBatchRequest.self, "{\"messageIds\":\"a\"}")?.messageIds == nil)
}
