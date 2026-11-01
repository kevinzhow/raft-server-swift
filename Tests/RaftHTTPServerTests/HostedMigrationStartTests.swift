import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct MigrationStartFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let memberId: String
    let agentId: String
}

private func makeMigrationStartFixture(suffix: String) -> MigrationStartFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-33333333\(suffix)"
    let ownerId = "11111111-1111-4111-8111-11111111\(suffix)"
    let memberId = "11111111-1111-4111-8111-22222222\(suffix)"
    accounts.addAccount(id: ownerId, email: "migrate-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "migrate-member-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "migrate-\(suffix)", name: "Migrate \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "migrate-source-\(suffix)")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "migrate-agent-\(suffix)", creatorUserId: ownerId)
    accounts.setAgentMachineForTesting(agentId: agent, machineId: machine)
    return MigrationStartFixture(accounts: accounts, serverId: serverId, ownerId: ownerId, memberId: memberId, agentId: agent)
}

@Test func hostedMigrationStartsWithASourceOnlyTargetAndRefusesAReplay() async throws {
    let fixture = makeMigrationStartFixture(suffix: "301")
    let accounts = fixture.accounts
    accounts.enableAgentMigrationForTesting(serverId: fixture.serverId)
    accounts.enableHostedMigrationForTesting(serverId: fixture.serverId)
    accounts.enableHostedRuntimeForTesting(serverId: fixture.serverId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"migrate-owner-301@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            func migrate(_ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/agents/\(fixture.agentId)/migrate") { request in
                    request.body = .init(string: body)
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            let started = try await migrate("{\"target\":{\"kind\":\"hosted\"}}")
            #expect(started.status == .ok)
            let body = payload(started)
            #expect(body["targetKind"] as? String == "hosted")
            #expect(body["targetMachineId"] is NSNull)
            #expect(body["sourceMachineId"] as? String != nil)
            #expect(body["state"] as? String == "preparing")
            #expect(body["prepDeadlineAt"] is String)
            #expect(body["transferDeadlineAt"] is String)
            #expect(body["arrivalDeadlineAt"] is String)

            let again = try await migrate("{\"target\":{\"kind\":\"hosted\"}}")
            #expect(again.status == .conflict)
            #expect(payload(again)["code"] as? String == "MIGRATION_ALREADY_IN_PROGRESS")
        }
    }
}

@Test func hostedMigrationRefusesAnAgentThatAlreadyRanInTheCloud() async throws {
    let fixture = makeMigrationStartFixture(suffix: "302")
    let accounts = fixture.accounts
    accounts.enableAgentMigrationForTesting(serverId: fixture.serverId)
    accounts.enableHostedMigrationForTesting(serverId: fixture.serverId)
    accounts.enableHostedRuntimeForTesting(serverId: fixture.serverId)
    accounts.setHostedRuntimeStateForTesting(agentId: fixture.agentId, state: "deleted")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"migrate-owner-302@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let response = try await client.send(.post, headers: headers, to: "/api/agents/\(fixture.agentId)/migrate") { request in
                request.body = .init(string: "{\"target\":{\"kind\":\"hosted\"}}")
            }
            #expect(response.status == .conflict)
            let body = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
            #expect(body?["code"] as? String == "HOSTED_TARGET_ALREADY_USED")
        }
    }
}

@Test func hostedMigrationNeedsItsOwnGateAndAValidModel() async throws {
    let fixture = makeMigrationStartFixture(suffix: "303")
    let accounts = fixture.accounts
    accounts.enableAgentMigrationForTesting(serverId: fixture.serverId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func post(_ bearer: String, _ path: String, _ body: String) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
                return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let owner = try await token("migrate-owner-303@slock.test")
            let member = try await token("migrate-member-303@slock.test")
            let migratePath = "/api/agents/\(fixture.agentId)/migrate"

            #expect(try await post(member, migratePath, "{\"target\":{\"kind\":\"hosted\"}}").status == .forbidden)
            let off = try await post(owner, migratePath, "{\"target\":{\"kind\":\"hosted\"}}")
            #expect(off.status == .forbidden)
            #expect(payload(off)["code"] as? String == "HOSTED_TARGET_UNAVAILABLE")

            accounts.enableHostedMigrationForTesting(serverId: fixture.serverId)
            let runtimeOff = try await post(owner, migratePath, "{\"target\":{\"kind\":\"hosted\"}}")
            #expect(runtimeOff.status == .conflict)
            #expect(payload(runtimeOff)["code"] as? String == "HOSTED_TARGET_UNAVAILABLE")
            accounts.enableHostedRuntimeForTesting(serverId: fixture.serverId)
            let badModel = try await post(owner, migratePath, "{\"target\":{\"kind\":\"hosted\",\"hostedModel\":42}}")
            #expect(badModel.status == .badRequest)
            #expect(payload(badModel)["code"] as? String == "HOSTED_TARGET_MODEL_INVALID")
            let unknownProvider = try await post(owner, migratePath, "{\"target\":{\"kind\":\"hosted\",\"provider\":\"other\"}}")
            #expect(unknownProvider.status == HTTPResponse.Status(code: 422, reasonPhrase: "Unprocessable Entity"))
            #expect(payload(unknownProvider)["code"] as? String == "HOSTED_TARGET_UNAVAILABLE")

            let accepted = try await post(owner, migratePath, "{\"target\":{\"kind\":\"hosted\",\"hostedModel\":\"deepseek-flash\"}}")
            #expect(accepted.status == .ok)
            #expect(payload(accepted)["targetKind"] as? String == "hosted")

        }
    }
}

@Test func hostedMigrationAndConfirmationStayOffWithoutTheHostedGate() async throws {
    let fixture = makeMigrationStartFixture(suffix: "304")
    let accounts = fixture.accounts
    accounts.enableAgentMigrationForTesting(serverId: fixture.serverId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"migrate-owner-304@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            func post(_ path: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                    request.body = .init(string: body)
                }
            }
            let migrated = try await post("/api/agents/\(fixture.agentId)/migrate", "{\"target\":{\"kind\":\"hosted\"}}")
            #expect(migrated.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((migrated.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "HOSTED_TARGET_UNAVAILABLE")
            let confirmed = try await post(
                "/api/agents/\(fixture.agentId)/migration/confirm-hosted",
                "{\"migrationRef\":\"mig_abcdefghijklmnopqrstuv\",\"expectedRevision\":1}"
            )
            #expect(confirmed.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((confirmed.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "HOSTED_TARGET_UNAVAILABLE")
        }
    }
}
