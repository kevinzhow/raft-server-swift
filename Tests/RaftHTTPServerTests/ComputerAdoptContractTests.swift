import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct AdoptFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerId: String
    let adminId: String
    let memberId: String
    let strangerId: String
    let otherServerId: String
    let otherServerSlug: String
    let ownerToken: String
    let adminToken: String
    let memberToken: String
    let strangerToken: String
}

private func makeAdoptFixture(_ suffix: String) -> AdoptFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111622"
    let adminId = "11111111-1111-4111-8111-111111111623"
    let memberId = "11111111-1111-4111-8111-111111111624"
    let strangerId = "11111111-1111-4111-8111-111111111625"
    let serverId = "33333333-3333-4333-8333-333333333666"
    let serverSlug = "adopt-co-\(suffix)"
    let otherServerId = "33333333-3333-4333-8333-333333333667"
    let otherServerSlug = "other-co-\(suffix)"
    for (id, email) in [
        (ownerId, "adopt-owner-\(suffix)@slock.test"),
        (adminId, "adopt-admin-\(suffix)@slock.test"),
        (memberId, "adopt-member-\(suffix)@slock.test"),
        (strangerId, "adopt-stranger-\(suffix)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: serverSlug, name: "Adopt Co \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    accounts.oauth.addOwnedServer(id: otherServerId, slug: otherServerSlug, name: "Other Co \(suffix)", ownerId: strangerId)
    return AdoptFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: serverSlug,
        ownerId: ownerId,
        adminId: adminId,
        memberId: memberId,
        strangerId: strangerId,
        otherServerId: otherServerId,
        otherServerSlug: otherServerSlug,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        adminToken: accounts.mintAccessTokenForTesting(userId: adminId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        strangerToken: accounts.mintAccessTokenForTesting(userId: strangerId)
    )
}

private func adoptPost(
    _ client: any Client,
    token: String?,
    body: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    let response = try await client.send(.post, headers: headers, to: "/api/computer/adopt-legacy") { request in
        request.body = .init(string: body)
    }
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, json, raw)
}

private func adoptRoster(
    _ client: any Client,
    token: String,
    slug: String,
    includeAll: Bool = false
) async throws -> (status: HTTPResponse.Status, entries: [[String: Any]]) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    let query = includeAll ? "?serverSlug=\(slug)&includeAll=1" : "?serverSlug=\(slug)"
    let response = try await client.send(.get, headers: headers, to: "/api/computer/legacy-machines\(query)")
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, (json["entries"] as? [[String: Any]]) ?? [])
}

private func preflight(
    _ client: any Client,
    apiKey: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.authorization] = "Bearer \(apiKey)"
    let response = try await client.send(.post, headers: headers, to: "/internal/computer/preflight") { request in
        request.body = .init(string: "{}")
    }
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

private func rosterFingerprint(
    _ client: any Client,
    token: String,
    slug: String,
    machineName: String
) async throws -> String {
    let roster = try await adoptRoster(client, token: token, slug: slug)
    let entry = roster.entries.first { $0["machineName"] as? String == machineName }
    return (entry?["apiKeyFingerprint"] as? String) ?? ""
}

@Test func computerAdoptGateAndBodyShape() async throws {
    let f = makeAdoptFixture("a01")
    f.accounts.setComputerAttachEnabledForTesting(false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let disabled = try await adoptPost(client, token: f.ownerToken, body: #"{"legacyApiKey":"sk_machine_\#(String(repeating: "a", count: 64))"}"#)
            #expect(disabled.status == .notFound)
        }
    }

    f.accounts.setComputerAttachEnabledForTesting(nil)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let unauthenticated = try await adoptPost(client, token: nil, body: #"{"legacyApiKey":"sk_machine_\#(String(repeating: "a", count: 64))"}"#)
            #expect(unauthenticated.status == .unauthorized)
            #expect(unauthenticated.body["code"] as? String == "auth_required")

            let missingIdentity = try await adoptPost(client, token: f.ownerToken, body: #"{"name":"raft-computer"}"#)
            #expect(missingIdentity.status == .badRequest)
            #expect(missingIdentity.body["code"] as? String == "legacy_api_key_required")

            let emptyName = try await adoptPost(
                client,
                token: f.ownerToken,
                body: #"{"legacyApiKey":"sk_machine_\#(String(repeating: "a", count: 64))","name":""}"#
            )
            #expect(emptyName.status == .badRequest)
            #expect(emptyName.body["code"] as? String == "name_invalid")

            let longName = try await adoptPost(
                client,
                token: f.ownerToken,
                body: #"{"legacyApiKey":"sk_machine_\#(String(repeating: "a", count: 64))","name":"\#(String(repeating: "n", count: 201))"}"#
            )
            #expect(longName.status == .badRequest)
            #expect(longName.body["code"] as? String == "name_invalid")

            let malformedFingerprint = try await adoptPost(
                client,
                token: f.ownerToken,
                body: #"{"serverSlug":"\#(f.serverSlug)","legacyMachineId":"\#(UUID().uuidString)","apiKeyFingerprint":"sha256:deadbeef"}"#
            )
            #expect(malformedFingerprint.status == .unauthorized)
            #expect(malformedFingerprint.body["code"] as? String == "legacy_key_invalid")
        }
    }
}

@Test func computerAdoptRawKeyMintsComputerAndPreflightAcceptsIt() async throws {
    let f = makeAdoptFixture("a02")
    let machine = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "legacy-daemon")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let adopted = try await adoptPost(
                client,
                token: f.ownerToken,
                body: #"{"legacyApiKey":"\#(machine.apiKey)","name":"adopted-computer"}"#
            )
            #expect(adopted.status == .created)
            let apiKey = try #require(adopted.body["apiKey"] as? String)
            #expect(apiKey.hasPrefix("sk_computer_"))
            #expect(adopted.body["machineId"] as? String == machine.id)
            #expect(adopted.body["serverId"] as? String == f.serverId)
            #expect(adopted.body["resumed"] as? Bool == false)
            #expect(adopted.body["computerId"] as? String != nil)
            #expect(!adopted.raw.contains(machine.apiKey), "the raw legacy key is never echoed")

            let accepted = try await preflight(client, apiKey: apiKey)
            #expect(accepted.status == .ok)
            #expect(accepted.body["ok"] as? Bool == true)
            let principal = accepted.body["principal"] as? [String: Any]
            #expect(principal?["kind"] as? String == "computer")

            let roster = try await adoptRoster(client, token: f.ownerToken, slug: f.serverSlug)
            let entry = roster.entries.first { $0["machineName"] as? String == "legacy-daemon" }
            #expect(entry?["legacyKeyMigratedAt"] is String, "adoption marks the legacy row migrated")
            #expect(entry?["apiKeyFingerprint"] as? String == machine.fingerprint)
            #expect((entry?["apiKeyFingerprint"] as? String)?.count == 16, "wire fingerprint is sha256(apiKey)[0..15]")

            let replay = try await adoptPost(client, token: f.ownerToken, body: #"{"legacyApiKey":"\#(machine.apiKey)"}"#)
            #expect(replay.status == .conflict)
            #expect(replay.body["code"] as? String == "legacy_machine_key_migrated")

            let unknown = try await adoptPost(
                client,
                token: f.ownerToken,
                body: #"{"legacyApiKey":"sk_machine_\#(String(repeating: "f", count: 64))"}"#
            )
            #expect(unknown.status == .unauthorized)
            #expect(unknown.body["code"] as? String == "legacy_key_invalid")

            let wrongPrefix = try await adoptPost(
                client,
                token: f.ownerToken,
                body: #"{"legacyApiKey":"sk_computer_\#(String(repeating: "a", count: 64))"}"#
            )
            #expect(wrongPrefix.status == .unauthorized)
            #expect(wrongPrefix.body["code"] as? String == "legacy_key_invalid")
        }
    }
}

@Test func computerAdoptRosterIdentityIsUserScopedAndResumes() async throws {
    let f = makeAdoptFixture("a03")
    let machine = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "owner-daemon")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let fingerprint = try await rosterFingerprint(client, token: f.ownerToken, slug: f.serverSlug, machineName: "owner-daemon")
            #expect(fingerprint == machine.fingerprint)

            // A plain member of the same Server cannot select another user's
            // roster row: the identity is user-scoped, and the failure is the
            // same 401 as an unknown key so the roster cannot be probed.
            let outsider = try await adoptPost(
                client,
                token: f.memberToken,
                body: #"{"serverSlug":"\#(f.serverSlug)","legacyMachineId":"\#(machine.id)","apiKeyFingerprint":"\#(fingerprint)"}"#
            )
            #expect(outsider.status == .unauthorized)
            #expect(outsider.body["code"] as? String == "legacy_key_invalid")
            let untouched = try await adoptRoster(client, token: f.ownerToken, slug: f.serverSlug)
            let untouchedEntry = untouched.entries.first { $0["machineName"] as? String == "owner-daemon" }
            #expect(untouchedEntry?["legacyKeyMigratedAt"] is NSNull || untouchedEntry?["legacyKeyMigratedAt"] == nil)

            let identity = #""serverSlug":"\#(f.serverSlug)","legacyMachineId":"\#(machine.id)","apiKeyFingerprint":"\#(fingerprint)""#
            let first = try await adoptPost(client, token: f.ownerToken, body: "{\(identity),\"name\":\"adopted-computer\"}")
            #expect(first.status == .created)
            let firstKey = try #require(first.body["apiKey"] as? String)
            let computerId = try #require(first.body["computerId"] as? String)
            #expect(first.body["machineId"] as? String == machine.id)
            #expect(first.body["resumed"] as? Bool == false)

            // Retry with the roster identity (no raw key available on a second
            // Computer) resumes the same attachment and rotates its credential.
            let second = try await adoptPost(client, token: f.ownerToken, body: "{\(identity)}")
            #expect(second.status == .created)
            #expect(second.body["computerId"] as? String == computerId)
            #expect(second.body["machineId"] as? String == machine.id)
            #expect(second.body["resumed"] as? Bool == true)
            let secondKey = try #require(second.body["apiKey"] as? String)
            #expect(secondKey != firstKey, "resume rotates the Computer credential")
            #expect(secondKey.hasPrefix("sk_computer_"))

            // The rotated key, not the previous one, is the live principal.
            let rotated = try await preflight(client, apiKey: secondKey)
            #expect(rotated.status == .ok)
            let stale = try await preflight(client, apiKey: firstKey)
            #expect(stale.status == .unauthorized)
        }
    }
}

@Test func computerAdoptDaemonIdentityAuthority() async throws {
    let f = makeAdoptFixture("a04")
    let otherMachine = f.accounts.registerMachineWithKeyForTesting(serverId: f.otherServerId, userId: f.strangerId, name: "other-daemon")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            // The row creator keeps authority after being a plain member, but
            // that authority does not extend to enumerating other rows.
            let memberMachine = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.memberId, name: "member-daemon")
            f.accounts.nullMachineFingerprintForTesting(machineId: memberMachine.id)
            let ownRow = try await adoptPost(
                client,
                token: f.memberToken,
                body: #"{"serverSlug":"\#(f.serverSlug)","daemonId":"\#(memberMachine.id)"}"#
            )
            #expect(ownRow.status == .created)
            #expect(ownRow.body["machineId"] as? String == memberMachine.id)

            let unknownRow = try await adoptPost(
                client,
                token: f.memberToken,
                body: #"{"serverSlug":"\#(f.serverSlug)","daemonId":"\#(UUID().uuidString)"}"#
            )
            #expect(unknownRow.status == .forbidden)
            #expect(unknownRow.body["code"] as? String == "requires_admin")

            // An owner/admin can adopt another user's row on this Server.
            let ownerMachine = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "owner-daemon")
            let body = #"{"serverSlug":"\#(f.serverSlug)","daemonId":"\#(ownerMachine.id)","name":"admin-adopted"}"#
            let first = try await adoptPost(client, token: f.adminToken, body: body)
            #expect(first.status == .created)
            let firstKey = try #require(first.body["apiKey"] as? String)
            let computerId = try #require(first.body["computerId"] as? String)
            #expect(first.body["resumed"] as? Bool == false)

            let second = try await adoptPost(client, token: f.adminToken, body: body)
            #expect(second.status == .created)
            #expect(second.body["computerId"] as? String == computerId)
            #expect(second.body["resumed"] as? Bool == true)
            #expect((second.body["apiKey"] as? String) != firstKey)

            // A manager that cannot see the row (missing, or bound to another
            // Server) gets one typed not-found instead of an authorization probe.
            for daemonId in [UUID().uuidString, otherMachine.id] {
                let missing = try await adoptPost(
                    client,
                    token: f.ownerToken,
                    body: #"{"serverSlug":"\#(f.serverSlug)","daemonId":"\#(daemonId)"}"#
                )
                #expect(missing.status == .notFound)
                #expect(missing.body["code"] as? String == "legacy_machine_not_found")
            }

            let otherRow = try await adoptRoster(client, token: f.strangerToken, slug: f.otherServerSlug)
            let otherEntry = otherRow.entries.first { $0["machineName"] as? String == "other-daemon" }
            #expect(otherEntry?["legacyKeyMigratedAt"] is NSNull || otherEntry?["legacyKeyMigratedAt"] == nil, "wrong-server rows stay unmigrated")
        }
    }
}

@Test func computerAdoptDaemonIdentityMigratedRowWithoutComputerIsConflict() async throws {
    let f = makeAdoptFixture("a05")
    let machine = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "stale-daemon")
    f.accounts.markMachineLegacyMigratedForTesting(machineId: machine.id, at: Date())
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let stale = try await adoptPost(
                client,
                token: f.ownerToken,
                body: #"{"serverSlug":"\#(f.serverSlug)","daemonId":"\#(machine.id)"}"#
            )
            #expect(stale.status == .conflict)
            #expect(stale.body["code"] as? String == "legacy_machine_key_migrated")
        }
    }
}

@Test func computerAdoptRawKeyRequiresMembershipThenManageMachines() async throws {
    let f = makeAdoptFixture("a06")
    let machine = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "legacy-daemon")
    let body = #"{"legacyApiKey":"\#(machine.apiKey)"}"#
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let stranger = try await adoptPost(client, token: f.strangerToken, body: body)
            #expect(stranger.status == .forbidden)
            #expect(stranger.body["code"] as? String == "not_authorized")

            // Key possession alone is not authority: a plain member is refused
            // with the distinct capability code, not the cloak.
            f.accounts.oauth.addMember(serverId: f.serverId, userId: f.strangerId, role: "member")
            let plainMember = try await adoptPost(client, token: f.strangerToken, body: body)
            #expect(plainMember.status == .forbidden)
            #expect(plainMember.body["code"] as? String == "requires_admin")

            f.accounts.oauth.addMember(serverId: f.serverId, userId: f.strangerId, role: "admin")
            let promoted = try await adoptPost(client, token: f.strangerToken, body: body)
            #expect(promoted.status == .created)
            #expect(promoted.body["machineId"] as? String == machine.id)
        }
    }
}

@Test func computerAdoptAcceptsDaemonPrefixedLegacyKeys() async throws {
    let f = makeAdoptFixture("a07")
    let daemonKey = "sk_daemon_" + String(repeating: "ab", count: 32)
    let machine = f.accounts.registerMachineWithKeyForTesting(
        serverId: f.serverId,
        userId: f.ownerId,
        name: "legacy-sk-daemon",
        apiKey: daemonKey
    )
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let adopted = try await adoptPost(client, token: f.ownerToken, body: #"{"legacyApiKey":"\#(daemonKey)"}"#)
            #expect(adopted.status == .created)
            #expect((adopted.body["apiKey"] as? String)?.hasPrefix("sk_computer_") == true)
            #expect(adopted.body["machineId"] as? String == machine.id)
            #expect(adopted.body["serverId"] as? String == f.serverId)
        }
    }
}

@Test func computerAdoptConcurrentRawKeyHasExactlyOneWinner() async throws {
    let f = makeAdoptFixture("a08")
    let machine = f.accounts.registerMachineWithKeyForTesting(serverId: f.serverId, userId: f.ownerId, name: "legacy-daemon")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let body = #"{"legacyApiKey":"\#(machine.apiKey)"}"#
            let statuses = try await withThrowingTaskGroup(of: HTTPResponse.Status.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try await adoptPost(client, token: f.ownerToken, body: body).status
                    }
                }
                var values: [HTTPResponse.Status] = []
                for try await status in group { values.append(status) }
                return values.sorted { $0.code < $1.code }
            }
            #expect(statuses == [.created, .conflict], "exactly one concurrent adoption wins")
        }
    }
}
