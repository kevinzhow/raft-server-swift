import Foundation
import TestSupport
import Testing

@testable import RaftHTTP

/// Locks the typed Computers-fleet service: the published bodies keep their
/// member order (which `JSONEncoder` cannot do on Linux), the error bodies keep
/// `error` then `code`, and every read-modify-write the retired directory
/// handlers ran under the directory lock is one store critical section.

private let ownerId = "11111111-1111-4111-8111-111111111811"
private let serverId = "33333333-3333-4333-8333-333333333811"
private let slug = "fleet-unit"

private func makeDirectory() -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    accounts.addAccount(id: ownerId, email: "fleet-unit@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "Fleet Unit", ownerId: ownerId)
    return accounts
}

private func bearer(_ accounts: EmailLoginDirectory) -> String {
    "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))"
}

@Test func fleetResponseBodiesKeepTheLegacyMemberOrder() {
    #expect(MachineDescriptionResponse(id: "m1", name: "box", description: nil).jsonBody.render()
        == #"{"id":"m1","name":"box","description":null}"#)
    #expect(ComputerAdoptResponse(apiKey: "k", computerId: "c", machineId: "m", serverId: "s", resumed: true).jsonBody.render()
        == #"{"apiKey":"k","computerId":"c","machineId":"m","serverId":"s","resumed":true}"#)
    #expect(ComputerAttachResponse(apiKey: "k", serverMachineId: "c", machineId: "m", serverId: "s", serverSlug: "slug", name: "n").jsonBody.render()
        == #"{"apiKey":"k","serverMachineId":"c","machineId":"m","serverId":"s","serverSlug":"slug","name":"n","resumed":false}"#)
    #expect(ComputerRunnerCredentialResponse(credentialId: "id", apiKey: "k", scopes: ["send", "read"], agentId: "a", agentName: "Bot", serverId: "s").jsonBody.render()
        == #"{"credentialId":"id","apiKey":"k","scopes":["send","read"],"agentId":"a","agentName":"Bot","serverId":"s"}"#)
    #expect(ComputerRunnersResponse(runners: [ComputerRunnerEntry(agentId: "a", name: "Bot", status: "running", model: "sonnet", runtime: "claude")]).jsonBody.render()
        == #"{"whitelist":["agentId","name","status","model","runtime"],"runners":[{"agentId":"a","name":"Bot","status":"running","model":"sonnet","runtime":"claude"}]}"#)
    #expect(ComputerActionResponse(action: "stop", requestId: "r", operationId: "o", computerVersion: "1.0.0").jsonBody.render()
        == #"{"ok":true,"action":"stop","requestId":"r","operationId":"o","computerVersion":"1.0.0"}"#)
    #expect(ComputerLifecycleOperationResponse(operationId: "o", parentOperationId: "p", serverId: "s", machineId: "m", actorUserId: "u", action: "upgrade", targetVersion: "2.0.0").jsonBody.render()
        == #"{"operationId":"o","parentOperationId":"p","serverId":"s","machineId":"m","actorUserId":"u","action":"upgrade","dispatchMode":"local","connectionEpochBefore":null,"targetVersion":"2.0.0"}"#)
    #expect(LegacyMachinesResponse(serverId: "s", serverSlug: "slug", entries: [
        LegacyMachineEntry(daemonId: "d", machineName: "n", hostname: nil, lastSeenAt: nil, hasFingerprint: true, legacyKeyMigratedAt: nil, apiKeyFingerprint: "abcd"),
        LegacyMachineEntry(daemonId: "e", machineName: "o", hostname: "h", lastSeenAt: "t", hasFingerprint: false, legacyKeyMigratedAt: "u", apiKeyFingerprint: nil),
    ]).jsonBody.render()
        == #"{"serverId":"s","serverSlug":"slug","entries":[{"daemonId":"d","machineName":"n","hostname":null,"lastSeenAt":null,"hasFingerprint":true,"legacyKeyMigratedAt":null,"apiKeyFingerprint":"abcd"},{"daemonId":"e","machineName":"o","hostname":"h","lastSeenAt":"t","hasFingerprint":false,"legacyKeyMigratedAt":"u"}]}"#)
    #expect(ModelLabelCatalogResponse(machines: [
        ModelLabelCatalogMachine(machineId: "m", runtimes: [
            ModelLabelCatalogRuntime(runtime: "codex", models: [ModelLabelCatalogModel(id: "g", label: "G")], updatedAt: "2025-10-11T08:00:00.000Z"),
        ]),
    ]).jsonBody.render()
        == #"{"machines":{"m":{"runtimes":{"codex":{"models":[{"id":"g","label":"G"}],"updatedAt":"2025-10-11T08:00:00.000Z"}}}}}"#)
    let entry = ServerMachineEntry(
        id: "m", name: "n", userId: "u", description: "d", isComputer: true,
        computerAttachedByCurrentUser: false, agentCount: 2,
        creator: ServerMachineCreator(id: "u", name: "un", displayName: nil, avatarUrl: nil, gravatarHash: "h"),
        runtimes: ["claude"], computerUpgradeAvailable: false,
        computerBroadcastPolicy: .raw(#"{"eligibility":"eligible"}"#)
    )
    #expect(ServerMachinesResponse(machines: [entry], latestComputerVersion: "1.2.3", latestComputerReleaseNotesJSON: #"["a"]"#).jsonBody.render()
        == #"{"machines":[{"id":"m","name":"n","userId":"u","description":"d","isComputer":true,"computerAttachedByCurrentUser":false,"agentCount":2,"creator":{"type":"human","id":"u","name":"un","displayName":null,"avatarUrl":null,"gravatarHash":"h"},"runtimes":["claude"],"computerUpgradeAvailable":false,"computerBroadcastPolicy":{"eligibility":"eligible"}}],"latestComputerVersion":"1.2.3","latestComputerReleaseNotes":["a"]}"#)
}

@Test func fleetErrorsKeepErrorThenCodeAndTheBroadcastPolicyBody() {
    #expect(ComputersFleetError.computerNameCollision.publishedErrorBody.render()
        == #"{"error":"A Computer with this name already exists","code":"COMPUTER_NAME_COLLISION"}"#)
    #expect(ComputersFleetError.invalidComputerCredential.publishedErrorBody.render()
        == #"{"error":"Invalid computer credential"}"#)
    #expect(ComputersFleetError.runtimeRescanOffline.publishedErrorBody.render() == #"{"error":"Computer is offline"}"#)
    #expect(ComputersFleetError.computerOffline.publishedErrorBody.render()
        == #"{"error":"Computer is offline","code":"computer_offline"}"#)
    #expect(ComputersFleetError.lifecycleBroadcastDisabled.publishedErrorBody.render()
        == #"{"error":"Hands could not select a newer alpha release for this Computer.","code":"broadcast_disabled","policy":{"eligibility":"no_broadcast","reasonCode":"broadcast_disabled"}}"#)
    #expect(ComputersFleetError.lifecycleBroadcastDisabled.status == 409)
    #expect(ComputersFleetError.scopesInvalid(message: "scopes must be an array of capability literals").publishedErrorBody.render()
        == #"{"error":"scopes must be an array of capability literals","code":"scopes_invalid"}"#)
}

@Test func fleetRequestsReadWrongTypedMembersAsAbsent() throws {
    let decoder = JSONDecoder()
    let attach = try decoder.decode(ComputerAttachRequest.self, from: Data(#"{"serverSlug":"a","name":5}"#.utf8))
    #expect(attach == ComputerAttachRequest(serverSlug: "a", name: nil))
    let adopt = try decoder.decode(ComputerAdoptLegacyRequest.self, from: Data(#"{"legacyApiKey":"","daemonId":"d","name":null}"#.utf8))
    #expect(adopt.legacyApiKey == nil && adopt.daemonId == "d" && adopt.name == .absent)
    #expect(try decoder.decode(ComputerAdoptLegacyRequest.self, from: Data(#"{"name":7}"#.utf8)).name == .invalid)
    #expect(try decoder.decode(ComputerRunnerCredentialRequest.self, from: Data(#"{"scopes":null}"#.utf8)).scopes == .invalid)
    #expect(try decoder.decode(ComputerRunnerCredentialRequest.self, from: Data(#"{"scopes":["a",1]}"#.utf8)).scopes == .invalid)
    #expect(try decoder.decode(ComputerRunnerCredentialRequest.self, from: Data(#"{"scopes":["send"]}"#.utf8)).scopes == .list(["send"]))
    let lifecycle = try decoder.decode(ComputerLifecycleRequest.self, from: Data(#"{"action":"start","completionMode":null,"targetVersion":3}"#.utf8))
    #expect(lifecycle.completionModePresent && lifecycle.completionMode == nil && lifecycle.targetVersion == nil)
    #expect(throws: (any Error).self) { try decoder.decode(ComputerAttachRequest.self, from: Data("[1]".utf8)) }
}

@Test func runnerModelReadsStringStructuredAndUnreadableConfigs() {
    #expect(ComputersFleetService.runnerModel(from: #"{"model":"sonnet"}"#) == "sonnet")
    #expect(ComputersFleetService.runnerModel(from: #"{"model":{"kind":"preset","id":"opus"}}"#) == "opus")
    #expect(ComputersFleetService.runnerModel(from: #"{"model":{"kind":"preset"}}"#) == "")
    #expect(ComputersFleetService.runnerModel(from: #"{"model":7}"#) == "")
    #expect(ComputersFleetService.runnerModel(from: "[]") == "")
    #expect(ComputersFleetService.runnerModel(from: nil) == "")
}

@Test func concurrentAttachesOfOneNameCollideExactlyOnce() async {
    let accounts = makeDirectory()
    let authorization = bearer(accounts)
    let service = accounts.computersFleet
    let outcomes = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<24 {
            group.addTask {
                (try? service.attachComputer(
                    authorization: authorization,
                    request: ComputerAttachRequest(serverSlug: slug, name: "same-name")
                )) != nil
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(accounts.machineCount(serverId: serverId) == 1)
    #expect(accounts.computersForTesting(serverId: serverId).count == 1)
}

@Test func concurrentRawKeyAdoptionsHaveOneWinner() async {
    let accounts = makeDirectory()
    let authorization = bearer(accounts)
    let machine = accounts.registerMachineWithKeyForTesting(serverId: serverId, userId: ownerId, name: "legacy-box")
    let service = accounts.computersFleet
    let outcomes = await withTaskGroup(of: String.self) { group in
        for _ in 0..<24 {
            group.addTask {
                do {
                    let response = try service.adoptLegacyComputer(
                        authorization: authorization,
                        request: ComputerAdoptLegacyRequest(legacyApiKey: machine.apiKey)
                    )
                    return "adopted:\(response.resumed)"
                } catch let error as ComputersFleetError {
                    return error.errorCode ?? "none"
                } catch {
                    return "other"
                }
            }
        }
        var results: [String] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(outcomes.filter { $0 == "adopted:false" }.count == 1)
    #expect(outcomes.filter { $0 == "legacy_machine_key_migrated" }.count == 23)
    #expect(accounts.computersForTesting(serverId: serverId).count == 1)
}

@Test func rosterAdoptionResumesTheLiveComputerWithARotatedKey() throws {
    let accounts = makeDirectory()
    let authorization = bearer(accounts)
    let machine = accounts.registerMachineWithKeyForTesting(serverId: serverId, userId: ownerId, name: "roster-box")
    let request = ComputerAdoptLegacyRequest(serverSlug: slug, legacyMachineId: machine.id, apiKeyFingerprint: machine.fingerprint)
    let first = try accounts.computersFleet.adoptLegacyComputer(authorization: authorization, request: request)
    #expect(first.resumed == false)
    let second = try accounts.computersFleet.adoptLegacyComputer(authorization: authorization, request: request)
    #expect(second.resumed == true)
    #expect(second.computerId == first.computerId)
    #expect(second.apiKey != first.apiKey)
    #expect(accounts.computerRecordForTesting(apiKey: first.apiKey) == nil)
    #expect(accounts.computerRecordForTesting(apiKey: second.apiKey)?.machineId == machine.id)
    #expect(accounts.computersForTesting(serverId: serverId).count == 1)
    // The raw-key selector never resumes: the migrated stamp is a hard conflict.
    #expect(throws: ComputersFleetError.legacyMachineKeyMigrated) {
        try accounts.computersFleet.adoptLegacyComputer(
            authorization: authorization,
            request: ComputerAdoptLegacyRequest(legacyApiKey: machine.apiKey)
        )
    }
}

@Test func machineDeleteGateRefusesWithoutWritesThenReleasesProfilesAndRevokesComputers() throws {
    let accounts = makeDirectory()
    let authorization = bearer(accounts)
    let attached = try accounts.computersFleet.attachComputer(
        authorization: authorization,
        request: ComputerAttachRequest(serverSlug: slug, name: "delete-box")
    )
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "PinnedBot", creatorUserId: ownerId, runtime: "claude")
    accounts.setAgentRuntimeProfileForTesting(agentId: agentId, machineId: attached.machineId)

    #expect(throws: ComputersFleetError.machineHasActiveRuntimeProfile) {
        try accounts.computersFleet.deleteServerMachine(authorization: authorization, serverId: serverId, machineId: attached.machineId)
    }
    #expect(accounts.machineExistsForTesting(machineId: attached.machineId))
    #expect(accounts.agentRuntimeProfileForTesting(agentId: agentId) != nil)
    #expect(accounts.computerRecordForTesting(apiKey: attached.apiKey)?.revokedAt == nil)

    accounts.oauth.deleteAgent(id: agentId)
    accounts.addAgentMigrationForTesting(id: "mig-1", sourceMachineId: attached.machineId, targetMachineId: "other", state: "running")
    #expect(throws: ComputersFleetError.machineHasActiveMigration) {
        try accounts.computersFleet.deleteServerMachine(authorization: authorization, serverId: serverId, machineId: attached.machineId)
    }
    #expect(accounts.machineExistsForTesting(machineId: attached.machineId))
    #expect(accounts.agentRuntimeProfileForTesting(agentId: agentId) != nil)

    accounts.setAgentMigrationStateForTesting(id: "mig-1", state: "completed")
    let ok = try accounts.computersFleet.deleteServerMachine(authorization: authorization, serverId: serverId, machineId: attached.machineId)
    #expect(ok == OkResponse())
    #expect(accounts.machineExistsForTesting(machineId: attached.machineId) == false)
    #expect(accounts.agentRuntimeProfileForTesting(agentId: agentId) == nil)
    let record = accounts.computerRecordForTesting(apiKey: attached.apiKey)
    #expect(record?.machineId == nil)
    #expect(record?.revokedAt != nil)
}

@Test func runnerStopAndCredentialRevokeAreMachineBound() throws {
    let accounts = makeDirectory()
    let authorization = bearer(accounts)
    let attached = try accounts.computersFleet.attachComputer(
        authorization: authorization,
        request: ComputerAttachRequest(serverSlug: slug, name: "runner-box")
    )
    let otherMachine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "other-box")
    let bound = accounts.oauth.createAgent(serverId: serverId, name: "BoundBot", creatorUserId: ownerId, runtime: "claude")
    let foreign = accounts.oauth.createAgent(serverId: serverId, name: "ForeignBot", creatorUserId: ownerId, runtime: "claude")
    accounts.setAgentMachineForTesting(agentId: bound, machineId: attached.machineId)
    accounts.setAgentMachineForTesting(agentId: foreign, machineId: otherMachine)
    let computer = "Bearer \(attached.apiKey)"
    let service = accounts.computersFleet

    let minted = try service.computerMintRunnerCredential(
        authorization: computer,
        agentId: bound,
        request: ComputerRunnerCredentialRequest(scopes: .list(["send", "read"]))
    )
    #expect(minted.scopes == ["read", "send"])
    #expect(throws: ComputersFleetError.agentMissing) {
        try service.computerMintRunnerCredential(authorization: computer, agentId: foreign, request: ComputerRunnerCredentialRequest())
    }
    #expect(throws: ComputersFleetError.agentMissing) {
        try service.computerRevokeRunnerCredential(authorization: computer, agentId: foreign, credentialId: minted.credentialId)
    }
    #expect(throws: ComputersFleetError.credentialMissing) {
        try service.computerRevokeRunnerCredential(authorization: computer, agentId: bound, credentialId: "nope")
    }
    let revoked = try service.computerRevokeRunnerCredential(authorization: computer, agentId: bound, credentialId: minted.credentialId)
    #expect(revoked == ComputerRunnerCredentialRevokeResponse(agentId: bound, credentialId: minted.credentialId, revoked: true))
    #expect(throws: ComputersFleetError.agentMissing) {
        try service.computerStopRunner(authorization: computer, agentId: foreign)
    }
    #expect(try service.computerStopRunner(authorization: computer, agentId: bound) == ComputerRunnerStopResponse(agentId: bound))
    #expect(throws: ComputersFleetError.invalidComputerCredential) {
        try service.computerRunners(authorization: "Bearer sk_computer_unknown")
    }
}

@Test func machineDescriptionAndKeyRotationShareOneGatedSection() throws {
    let accounts = makeDirectory()
    let authorization = bearer(accounts)
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "desc-box")
    let service = accounts.computersFleet
    let patched = try service.patchServerMachine(
        authorization: authorization, serverId: serverId, machineId: machineId,
        request: MachineDescriptionRequest(description: "  hello  ")
    )
    #expect(patched.jsonBody.render() == #"{"id":"\#(machineId)","name":"desc-box","description":"hello"}"#)
    let cleared = try service.patchServerMachine(
        authorization: authorization, serverId: serverId, machineId: machineId,
        request: MachineDescriptionRequest(description: "   ")
    )
    #expect(cleared.description == nil)
    let untouched = try service.patchServerMachine(
        authorization: authorization, serverId: serverId, machineId: machineId,
        request: MachineDescriptionRequest()
    )
    #expect(untouched.description == nil)
    let rotated = try service.rotateServerMachineKey(authorization: authorization, serverId: serverId, machineId: machineId)
    #expect(rotated.apiKey.hasPrefix("sk_machine_"))
    #expect(accounts.machineCredential(apiKey: rotated.apiKey)?.machineId == machineId)
    #expect(throws: ComputersFleetError.unauthorized) {
        try service.rotateServerMachineKey(authorization: nil, serverId: serverId, machineId: machineId)
    }
}
