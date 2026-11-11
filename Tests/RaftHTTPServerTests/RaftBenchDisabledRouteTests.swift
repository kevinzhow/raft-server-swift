import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let raftbenchPilotServerId = "4fc662e7-6626-4f59-a16d-3a224cd54acf"
private let raftbenchChannelId = "66666666-6666-4666-8666-666666666001"
private let raftbenchAgentId = "77777777-7777-4777-8777-777777777001"

private func raftbenchJSON(_ response: ClientResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func raftbenchLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return raftbenchJSON(response)["accessToken"] as? String ?? ""
}

private func raftbenchHeaders(_ token: String, serverId: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    if let serverId { headers[HTTPField.Name("X-Server-Id")!] = serverId }
    return headers
}

private func raftbenchSend(
    _ client: any Client, _ method: HTTPRequest.Method, _ path: String,
    headers: HTTPFields, body: String? = nil
) async throws -> ClientResponse {
    try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func raftbenchFixture(serverId: String) -> EmailLoginDirectory {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-611111111001"
    let memberId = "11111111-1111-4111-8111-611111111002"
    let outsiderId = "11111111-1111-4111-8111-611111111003"
    for (id, email) in [
        (ownerId, "raftbench-owner@slock.test"),
        (memberId, "raftbench-member@slock.test"),
        (outsiderId, "raftbench-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "raftbench-gap", name: "RaftBench Gap", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    return accounts
}

// MARK: - Disabled / non-pilot behavior

/// `routes/raftbench.ts` valid requests run `requirePilot` first
/// (`raftbench/service.ts:31-33`): a production deployment answers 403
/// `raftbench_server_not_allowed` for owner and member alike. Body/page
/// validation still precedes that gate, exactly as the handlers do.
@Test func raftbenchAnswersTheUpstreamDisabledContract() async throws {
    let serverId = "33333333-3333-4333-8333-611111111001"
    let accounts = raftbenchFixture(serverId: serverId)
    let outsiderServerId = "33333333-3333-4333-8333-611111111002"
    accounts.oauth.addOwnedServer(
        id: outsiderServerId, slug: "raftbench-outsider", name: "RaftBench Outsider",
        ownerId: "11111111-1111-4111-8111-611111111003"
    )

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await raftbenchLogin(client, email: "raftbench-owner@slock.test")
            let member = try await raftbenchLogin(client, email: "raftbench-member@slock.test")

            let anonymous = try await client.get("/api/raftbench", headers: HTTPFields())
            #expect(anonymous.status == .unauthorized)

            let missingServer = try await client.get("/api/raftbench", headers: raftbenchHeaders(owner))
            #expect(missingServer.status == .badRequest)
            #expect(raftbenchJSON(missingServer)["error"] as? String == "Missing X-Server-Id header")

            let nonMember = try await client.get(
                "/api/raftbench", headers: raftbenchHeaders(owner, serverId: outsiderServerId)
            )
            #expect(nonMember.status == .forbidden)
            #expect(raftbenchJSON(nonMember)["error"] as? String == "Not a member of this server")

            for token in [owner, member] {
                let dashboard = try await client.get(
                    "/api/raftbench", headers: raftbenchHeaders(token, serverId: serverId)
                )
                #expect(dashboard.status == .forbidden)
                #expect(raftbenchJSON(dashboard)["error"] as? String
                    == "RaftBench is unavailable on this server or deployment.")
                #expect(raftbenchJSON(dashboard)["code"] as? String == "raftbench_server_not_allowed")

                let agents = try await client.get(
                    "/api/raftbench/agents", headers: raftbenchHeaders(token, serverId: serverId)
                )
                #expect(agents.status == .forbidden)
                #expect(raftbenchJSON(agents)["code"] as? String == "raftbench_server_not_allowed")
            }

            let invalidPage = try await client.get(
                "/api/raftbench?page=0", headers: raftbenchHeaders(owner, serverId: serverId)
            )
            #expect(invalidPage.status == .badRequest)
            #expect(raftbenchJSON(invalidPage)["error"] as? String == "Invalid result page")

            let invalidSettings = try await raftbenchSend(
                client, .put, "/api/raftbench", headers: raftbenchHeaders(owner, serverId: serverId),
                body: #"{"enabled":true}"#
            )
            #expect(invalidSettings.status == .badRequest)
            #expect(raftbenchJSON(invalidSettings)["error"] as? String == "Invalid RaftBench settings")

            let invalidAgentSettings = try await raftbenchSend(
                client, .post, "/api/raftbench/agents", headers: raftbenchHeaders(owner, serverId: serverId),
                body: #"{"providerTarget":"bogus"}"#
            )
            #expect(invalidAgentSettings.status == .badRequest)
            #expect(raftbenchJSON(invalidAgentSettings)["error"] as? String == "Invalid RaftBench agent settings")

            let invalidAssignment = try await raftbenchSend(
                client, .put, "/api/raftbench/assignment", headers: raftbenchHeaders(owner, serverId: serverId),
                body: "{}"
            )
            #expect(invalidAssignment.status == .badRequest)
            #expect(raftbenchJSON(invalidAssignment)["error"] as? String == "Invalid RaftBench assignment")

            // A valid body reaches the pilot gate, not a validation failure.
            let validSettings = try await raftbenchSend(
                client, .put, "/api/raftbench", headers: raftbenchHeaders(owner, serverId: serverId),
                body: #"{"enabled":true,"channelIds":["\#(raftbenchChannelId)"],"expectedRevision":0}"#
            )
            #expect(validSettings.status == .forbidden)
            #expect(raftbenchJSON(validSettings)["code"] as? String == "raftbench_server_not_allowed")

            let validAgent = try await raftbenchSend(
                client, .post, "/api/raftbench/agents", headers: raftbenchHeaders(owner, serverId: serverId)
            )
            #expect(validAgent.status == .forbidden)
            #expect(raftbenchJSON(validAgent)["code"] as? String == "raftbench_server_not_allowed")

            let validAssignment = try await raftbenchSend(
                client, .put, "/api/raftbench/assignment", headers: raftbenchHeaders(owner, serverId: serverId),
                body: #"{"agentId":"\#(raftbenchAgentId)","expectedRevision":0,"channelIds":["\#(raftbenchChannelId)"]}"#
            )
            #expect(validAssignment.status == .forbidden)
            #expect(raftbenchJSON(validAssignment)["code"] as? String == "raftbench_server_not_allowed")
        }
    }
}

/// Even the fixed staging pilot server cannot run the unported engine (D19):
/// the route answers the typed `raftbench_disabled` instead of inventing a
/// dashboard.
@Test func raftbenchPilotStagingServerStaysDisabled() async throws {
    let accounts = raftbenchFixture(serverId: raftbenchPilotServerId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {},
            releaseEnvironment: ["DEPLOYMENT_ENV": "staging"],
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let owner = try await raftbenchLogin(client, email: "raftbench-owner@slock.test")
            let dashboard = try await client.get(
                "/api/raftbench", headers: raftbenchHeaders(owner, serverId: raftbenchPilotServerId)
            )
            #expect(dashboard.status == .forbidden)
            #expect(raftbenchJSON(dashboard)["code"] as? String == "raftbench_disabled")
        }
    }
}
