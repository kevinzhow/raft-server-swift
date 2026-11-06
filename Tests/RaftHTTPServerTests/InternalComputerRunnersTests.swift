import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct RunnersFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let machineId: String
    let computerKey: String
    let agentId: String
    let otherMachineAgentId: String
    let otherServerAgentId: String
    let agentKey: String
}

private let runnersWhitelist = ["agentId", "name", "status", "model", "runtime"]
private let runnerSecretEnv = "ENVVAR-SECRET-do-not-leak-qqq"
private let runnerSecretSession = "session-RESUME-SECRET-do-not-leak-zzz"

private func makeRunnersFixture() -> RunnersFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111628"
    let serverId = "33333333-3333-4333-8333-333333333669"
    let serverSlug = "runners-co"
    accounts.addAccount(id: ownerId, email: "runners-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: serverSlug, name: "Runners Co", ownerId: ownerId)
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    let attach = accounts.attachComputer(
        authorization: "Bearer \(ownerToken)",
        body: "{\"serverSlug\":\"\(serverSlug)\",\"name\":\"runners-computer\"}"
    )
    let attachBody = (try? JSONSerialization.jsonObject(with: Data(attach.body.utf8))) as? [String: Any] ?? [:]
    let computerKey = attachBody["apiKey"] as? String ?? ""
    let machineId = attachBody["machineId"] as? String ?? ""
    let otherMachineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "other-machine")

    let agentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "RunnerBot",
        creatorUserId: ownerId,
        runtime: "claude",
        runtimeConfigJSON: "{\"version\":1,\"runtime\":\"claude\",\"model\":{\"kind\":\"preset\",\"id\":\"sonnet\"},\"sessionId\":\"\(runnerSecretSession)\"}",
        envVarsJSON: "{\"OPENAI_API_KEY\":\"\(runnerSecretEnv)\"}"
    )
    let otherMachineAgentId = accounts.oauth.createAgent(
        serverId: serverId,
        name: "OtherMachineBot",
        creatorUserId: ownerId,
        runtime: "claude",
        runtimeConfigJSON: "{\"version\":1,\"runtime\":\"claude\",\"model\":{\"kind\":\"preset\",\"id\":\"sonnet\"}}"
    )
    let otherServerId = "33333333-3333-4333-8333-333333333670"
    accounts.oauth.addOwnedServer(id: otherServerId, slug: "other-runners-co", name: "Other Co", ownerId: ownerId)
    let otherServerAgentId = accounts.oauth.createAgent(
        serverId: otherServerId,
        name: "OtherBot",
        creatorUserId: ownerId,
        runtime: "claude"
    )
    accounts.setAgentMachineForTesting(agentId: agentId, machineId: machineId)
    accounts.setAgentMachineForTesting(agentId: otherMachineAgentId, machineId: otherMachineId)
    accounts.setAgentStatusForTesting(agentId: agentId, status: "running")
    return RunnersFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: serverSlug,
        machineId: machineId,
        computerKey: computerKey,
        agentId: agentId,
        otherMachineAgentId: otherMachineAgentId,
        otherServerAgentId: otherServerAgentId,
        agentKey: accounts.mintAgentCredential(agentId: agentId, scopes: ["read"], name: "runners-agent")
    )
}

private func runnersRequest(
    _ client: any Client,
    key: String,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil
) async throws -> (status: HTTPResponse.Status, body: [String: Any], raw: String) {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    if body != nil { headers[.contentType] = "application/json" }
    let response = try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
    let raw = response.body.string ?? ""
    let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    return (response.status, json, raw)
}

@Test func runnersListDefaultsToThisMachineWithServerSideWhitelist() async throws {
    let f = makeRunnersFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let listed = try await runnersRequest(client, key: f.computerKey, method: .get, path: "/internal/computer/runners")
            #expect(listed.status == .ok)
            #expect(listed.body["whitelist"] as? [String] == runnersWhitelist)

            // The whitelist is enforced by the server: recognizable secrets in
            // the agent record cannot reach the serialized payload.
            #expect(!listed.raw.contains(runnerSecretEnv), "an envVars secret leaked")
            #expect(!listed.raw.contains(runnerSecretSession), "the runtime session secret leaked")

            let runners = (listed.body["runners"] as? [[String: Any]]) ?? []
            let mine = runners.first { $0["agentId"] as? String == f.agentId }
            let runner = try #require(mine, "this machine's agent must be listed")
            #expect(Array(runner.keys.sorted()) == runnersWhitelist.sorted(), "runner keys are exactly the whitelist")
            #expect(runner["name"] as? String == "RunnerBot")
            #expect(runner["status"] as? String == "running")
            #expect(runner["model"] as? String == "sonnet")
            #expect(runner["runtime"] as? String == "claude")

            // Default scope is the precise Computer/machine view.
            #expect(!runners.contains { $0["agentId"] as? String == f.otherMachineAgentId })
            #expect(!runners.contains { $0["agentId"] as? String == f.otherServerAgentId })
        }
    }
}

@Test func runnersListScopeServerKeepsTheServerWideView() async throws {
    let f = makeRunnersFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let listed = try await runnersRequest(client, key: f.computerKey, method: .get, path: "/internal/computer/runners?scope=server")
            #expect(listed.status == .ok)
            #expect(listed.body["whitelist"] as? [String] == runnersWhitelist)
            let runners = (listed.body["runners"] as? [[String: Any]]) ?? []
            #expect(runners.contains { $0["agentId"] as? String == f.agentId })
            #expect(runners.contains { $0["agentId"] as? String == f.otherMachineAgentId }, "server-wide scope includes other machines on the same server")
            #expect(!runners.contains { $0["agentId"] as? String == f.otherServerAgentId }, "server-wide scope stays isolated to the Computer's server")
        }
    }
}

@Test func runnersStopBindsToTheComputersMachine() async throws {
    let f = makeRunnersFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let stopped = try await runnersRequest(
                client, key: f.computerKey, method: .post,
                path: "/internal/computer/runners/\(f.agentId)/stop", body: "{}"
            )
            #expect(stopped.status == .ok)
            #expect(stopped.body["agentId"] as? String == f.agentId)

            for agentId in [f.otherMachineAgentId, f.otherServerAgentId] {
                let refused = try await runnersRequest(
                    client, key: f.computerKey, method: .post,
                    path: "/internal/computer/runners/\(agentId)/stop", body: "{}"
                )
                #expect(refused.status == .notFound)
                #expect(refused.body["code"] as? String == "agent_missing", "no existence leak across machines or servers")
            }
        }
    }
}

@Test func runnersRejectNonComputerPrincipals() async throws {
    let f = makeRunnersFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let list = try await runnersRequest(client, key: f.agentKey, method: .get, path: "/internal/computer/runners")
            #expect(list.status != .ok)
            #expect(list.status == .unauthorized || list.status == .forbidden)

            let stop = try await runnersRequest(
                client, key: f.agentKey, method: .post,
                path: "/internal/computer/runners/\(f.agentId)/stop", body: "{}"
            )
            #expect(stop.status != .ok)
            #expect(stop.status == .unauthorized || stop.status == .forbidden)
        }
    }
}

@Test func runnersCannotOperateAnotherMachinesRunner() async throws {
    let f = makeRunnersFixture()
    let credential = f.accounts.mintAgentCredential(agentId: f.otherMachineAgentId, scopes: ["read"], name: "audit-target")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let mint = try await runnersRequest(
                client, key: f.computerKey, method: .post,
                path: "/internal/computer/runners/\(f.otherMachineAgentId)/credentials", body: "{}"
            )
            #expect(mint.status == .notFound)

            let stop = try await runnersRequest(
                client, key: f.computerKey, method: .post,
                path: "/internal/computer/runners/\(f.otherMachineAgentId)/stop", body: "{}"
            )
            #expect(stop.status == .notFound)

            let principalId = credential
            let revoke = try await runnersRequest(
                client, key: f.computerKey, method: .delete,
                path: "/internal/computer/runners/\(f.otherMachineAgentId)/credentials/\(principalId)"
            )
            #expect(revoke.status == .notFound)
        }
    }
}
