import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private final class ConnectionProviderStub: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (AgentConnectionProviderRequest) -> AgentConnectionProviderResult = { _ in .unavailable }
    private var storage: [AgentConnectionProviderRequest] = []

    func setHandler(_ handler: @escaping (AgentConnectionProviderRequest) -> AgentConnectionProviderResult) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func respond(_ request: AgentConnectionProviderRequest) -> AgentConnectionProviderResult {
        lock.lock()
        storage.append(request)
        let handler = self.handler
        lock.unlock()
        return handler(request)
    }

    var requests: [AgentConnectionProviderRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

private struct ConnectionFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerId: String
    let adminId: String
    let memberId: String
    let creatorId: String
    let guestId: String
    let agentId: String
    let plainAgentId: String

    func email(_ id: String) -> String {
        if id == ownerId { return "conn-owner-\(serverId.suffix(3))@slock.test" }
        if id == adminId { return "conn-admin-\(serverId.suffix(3))@slock.test" }
        if id == memberId { return "conn-member-\(serverId.suffix(3))@slock.test" }
        if id == creatorId { return "conn-creator-\(serverId.suffix(3))@slock.test" }
        return "conn-guest-\(serverId.suffix(3))@slock.test"
    }
}

private func makeConnectionFixture(suffix: String, agentCreator: String = "creator") -> ConnectionFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-333333333\(suffix)"
    let ownerId = "11111111-1111-4111-8111-111111111\(suffix)"
    let adminId = "11111111-1111-4111-8111-111111112\(suffix)"
    let memberId = "11111111-1111-4111-8111-111111113\(suffix)"
    let creatorId = "11111111-1111-4111-8111-111111114\(suffix)"
    let guestId = "11111111-1111-4111-8111-111111115\(suffix)"
    for (id, email, role) in [
        (ownerId, "conn-owner-\(suffix)@slock.test", "owner"),
        (adminId, "conn-admin-\(suffix)@slock.test", "admin"),
        (memberId, "conn-member-\(suffix)@slock.test", "member"),
        (creatorId, "conn-creator-\(suffix)@slock.test", "member"),
        (guestId, "conn-guest-\(suffix)@slock.test", "guest"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "conn-\(suffix)", name: "Connections \(suffix)", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let creatorUserId: String
    switch agentCreator {
    case "owner": creatorUserId = ownerId
    case "admin": creatorUserId = adminId
    case "member": creatorUserId = memberId
    case "guest": creatorUserId = guestId
    default: creatorUserId = creatorId
    }
    let agentId = accounts.oauth.createAgent(serverId: serverId, name: "conn-agent-\(suffix)", creatorUserId: creatorUserId)
    let plainAgentId = accounts.oauth.createAgent(serverId: serverId, name: "plain-agent-\(suffix)", creatorUserId: ownerId)
    return ConnectionFixture(
        accounts: accounts,
        serverId: serverId,
        ownerId: ownerId,
        adminId: adminId,
        memberId: memberId,
        creatorId: creatorId,
        guestId: guestId,
        agentId: agentId,
        plainAgentId: plainAgentId
    )
}

private func connectionTokens(_ client: any Client, fixture: ConnectionFixture) async throws -> [String: String] {
    var result: [String: String] = [:]
    for id in [fixture.ownerId, fixture.adminId, fixture.memberId, fixture.creatorId, fixture.guestId] {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
            request.body = .init(string: "{\"email\":\"\(fixture.email(id))\",\"password\":\"password123\"}")
        }
        result[id] = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
    }
    return result
}

@Test func githubConnectionStartValidatesAuthorityAccessAndBindings() async throws {
    let fixture = makeConnectionFixture(suffix: "201")
    let accounts = fixture.accounts
    accounts.setHostedRuntimeStateForTesting(agentId: fixture.agentId, state: "provisioning")
    let stub = ConnectionProviderStub()
    stub.setHandler { request in
        switch request.action {
        case "start":
            return .response(status: 200, body: "{\"url\":\"https://github.com/login/oauth/authorize?state=abc\",\"expiresAt\":\"2026-09-29T00:10:00.000Z\",\"scopes\":[\"public_repo\"]}")
        default:
            return .response(status: 500, body: "{\"error\":{\"code\":\"unexpected\",\"message\":\"\(request.action)\"}}")
        }
    }
    accounts.agentConnectionRelay.install { stub.respond($0) }
    accounts.setAgentConnectionOriginForTesting(origin: "https://raft.example.test")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let tokens = try await connectionTokens(client, fixture: fixture)
            func request(_ method: HTTPRequest.Method, _ bearer: String, _ agent: String? = nil, body: String? = nil, provider: String = "github") async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
                return try await client.send(method, headers: headers, to: "/api/agents/\(agent ?? fixture.agentId)/connections/\(provider)") { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let owner = tokens[fixture.ownerId]!
            let admin = tokens[fixture.adminId]!
            let member = tokens[fixture.memberId]!
            let creator = tokens[fixture.creatorId]!
            let guest = tokens[fixture.guestId]!

            let notReady = try await request(.get, owner)
            #expect(notReady.status == .conflict)
            #expect(body(notReady)["code"] as? String == "agent_connection_agent_not_active")
            #expect(body(notReady)["state"] as? String == "provisioning")

            accounts.setHostedRuntimeStateForTesting(agentId: fixture.agentId, state: "active")
            #expect(try await request(.get, owner, provider: "gitlab").status == .notFound)
            #expect(try await request(.get, owner, "missing-agent").status == .notFound)
            let plain = try await request(.post, owner, fixture.plainAgentId, body: "{}")
            #expect(plain.status == .badRequest)
            #expect(body(plain)["code"] as? String == "agent_connection_not_provider_backed")

            for bearer in [member, guest] {
                for method in [HTTPRequest.Method.get, .post, .delete] {
                    #expect(try await request(method, bearer, body: method == .post ? "{}" : nil).status == .forbidden)
                }
            }
            // A guest who created the agent is still refused.
            let guestCreatorAgent = accounts.oauth.createAgent(serverId: fixture.serverId, name: "guest-owned", creatorUserId: fixture.guestId)
            accounts.setHostedRuntimeStateForTesting(agentId: guestCreatorAgent, state: "active")
            #expect(try await request(.post, guest, guestCreatorAgent, body: "{}").status == .forbidden)
            #expect(stub.requests.isEmpty)

            let started = try await request(.post, owner, body: "{}")
            #expect(started.status == .ok)
            #expect(started.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let startedBody = body(started)
            #expect(startedBody["url"] as? String == "https://github.com/login/oauth/authorize?state=abc")
            #expect(startedBody["expiresAt"] as? String == "2026-09-29T00:10:00.000Z")
            #expect(startedBody["scopes"] as? [String] == ["public_repo"])

            #expect(try await request(.post, admin, body: "{\"access\":\"private\"}").status == .ok)
            #expect(try await request(.post, creator, body: "{}").status == .ok)

            let starts = stub.requests.filter { $0.action == "start" }
            #expect(starts.count == 3)
            let bodies = starts.map { (try? JSONSerialization.jsonObject(with: Data(($0.body ?? "").utf8))) as? [String: Any] ?? [:] }
            #expect(bodies.allSatisfy { $0["returnUrl"] as? String == "https://raft.example.test/api/connections/callback/\(fixture.serverId)/\(fixture.agentId)" })
            #expect(bodies.map { ($0["initiatedBy"] as? [String: Any])?["raftUserId"] as? String } == [fixture.ownerId, fixture.adminId, fixture.creatorId])
            #expect(bodies[1]["access"] as? String == "private")
            #expect(bodies[0]["access"] == nil)

            let beforeInvalid = stub.requests.count
            let invalidAccess = try await request(.post, owner, body: "{\"access\":\"admin\"}")
            #expect(invalidAccess.status == .badRequest)
            #expect(body(invalidAccess)["code"] as? String == "agent_connection_invalid")
            #expect(stub.requests.count == beforeInvalid)
        }
    }
}

@Test func githubConnectionStatusConfirmAndDisconnectFollowProviderAnswers() async throws {
    let fixture = makeConnectionFixture(suffix: "202")
    let accounts = fixture.accounts
    accounts.setHostedRuntimeStateForTesting(agentId: fixture.agentId, state: "active")
    let stub = ConnectionProviderStub()
    accounts.agentConnectionRelay.install { stub.respond($0) }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let tokens = try await connectionTokens(client, fixture: fixture)
            func request(_ method: HTTPRequest.Method, _ bearer: String, suffix: String = "", body: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
                return try await client.send(method, headers: headers, to: "/api/agents/\(fixture.agentId)/connections/github\(suffix)") { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let owner = tokens[fixture.ownerId]!
            let admin = tokens[fixture.adminId]!
            let member = tokens[fixture.memberId]!
            let creator = tokens[fixture.creatorId]!

            stub.setHandler { request in
                if request.action == "status" {
                    return .response(status: 200, body: """
                    {"connected":true,"account":"octocat","connectedAt":"2026-09-29T00:00:00.000Z","connectedBy":"\(fixture.creatorId)","scopes":["public_repo"],"connectorId":"ctr_mine","token":"ghp_toplevelsecret0123456789","connectors":[{"id":"ctr_mine","account":"octocat","creatorRaftUserId":"\(fixture.creatorId)","createdAt":"2026-09-29T00:00:00.000Z","current":true,"accessToken":"ghp_mysecret0123456789"},{"id":"ctr_admin","account":"hubot","creatorRaftUserId":"\(fixture.adminId)","createdAt":"2026-09-28T00:00:00.000Z","current":false},{"id":"ctr_outsider","account":"ex","creatorRaftUserId":"11111111-1111-4111-8111-111111112998","createdAt":null,"current":false},{"id":"bad id/..","account":"x"}, "junk"]}
                    """)
                }
                return .response(status: 500, body: "{\"error\":{\"code\":\"unexpected\"}}")
            }

            let status = try await request(.get, admin)
            #expect(status.status == .ok)
            #expect(status.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let statusText = status.body.string ?? ""
            #expect(!statusText.contains("ghp_"))
            let statusBody = payload(status)
            #expect(statusBody["provider"] as? String == "github")
            #expect(statusBody["supported"] as? Bool == true)
            #expect(statusBody["connected"] as? Bool == true)
            #expect(statusBody["account"] as? String == "octocat")
            #expect((statusBody["connectedBy"] as? [String: Any])?["id"] as? String == fixture.creatorId)
            #expect((statusBody["connectedBy"] as? [String: Any])?["name"] as? String == "conn-creator-202")
            #expect(statusBody["scopes"] as? [String] == ["public_repo"])
            #expect(statusBody["connectorId"] as? String == "ctr_mine")
            let connectors = statusBody["connectors"] as? [[String: Any]] ?? []
            #expect(connectors.count == 3)
            #expect(connectors.map { $0["id"] as? String } == ["ctr_mine", "ctr_admin", "ctr_outsider"])
            #expect(connectors.map { $0["canManage"] as? Bool } == [true, true, true])
            #expect((connectors[2]["creator"] as? [String: Any])?["name"] is NSNull)
            let creatorView = try await request(.get, creator)
            let creatorConnectors = payload(creatorView)["connectors"] as? [[String: Any]] ?? []
            #expect(creatorConnectors.map { $0["canManage"] as? Bool } == [true, false, false])

            stub.setHandler { request in
                switch request.action {
                case "disconnect":
                    return .empty(status: 204)
                default:
                    return .response(status: 500, body: "{\"error\":{\"code\":\"unexpected\"}}")
                }
            }
            #expect(try await request(.delete, owner).status == .noContent)
            #expect(stub.requests.last?.action == "disconnect")

            // Connections 404 with an existing agent means the provider has no connections route.
            stub.setHandler { request in
                if request.action == "agentLookup" {
                    return .response(status: 200, body: "{\"providerAgentId\":\"raft_x\",\"status\":\"active\"}")
                }
                return .response(status: 404, body: "{\"error\":{\"code\":\"not_found\",\"message\":\"route is not part of raft-agent-provider.v1\"}}")
            }
            let unsupported = try await request(.get, owner)
            #expect(unsupported.status == .ok)
            #expect(payload(unsupported)["provider"] as? String == "github")
            #expect(payload(unsupported)["supported"] as? Bool == false)
            #expect(payload(unsupported).keys.count == 2)
            let unsupportedStart = try await request(.post, owner, body: "{}")
            #expect(unsupportedStart.status == .conflict)
            #expect(payload(unsupportedStart)["code"] as? String == "agent_connection_unsupported")

            stub.setHandler { request in
                if request.action == "agentLookup" {
                    return .response(status: 404, body: "{\"error\":{\"code\":\"not_found\",\"message\":\"no provisioned agent made from Raft agent \(fixture.agentId)\"}}")
                }
                return .response(status: 404, body: "{\"error\":{\"code\":\"not_found\",\"message\":\"route is not part of raft-agent-provider.v1\"}}")
            }
            let missing = try await request(.get, owner)
            #expect(missing.status == .conflict)
            #expect(payload(missing)["code"] as? String == "agent_connection_agent_missing_at_provider")
            #expect(payload(missing)["providerMessage"] as? String == "no provisioned agent made from Raft agent \(fixture.agentId)")

            stub.setHandler { request in
                if request.action == "agentLookup" {
                    return .response(status: 503, body: "{\"error\":{\"code\":\"down\",\"message\":\"later\"}}")
                }
                return .response(status: 404, body: "{\"error\":{\"code\":\"not_found\",\"message\":\"route\"}}")
            }
            #expect(try await request(.get, owner).status == .badGateway)

            // Confirm.
            stub.setHandler { request in
                if request.action == "confirm" {
                    return .response(status: 200, body: "{\"connected\":true,\"connectorId\":\"ctr_new\",\"account\":\"octocat\",\"connectedAt\":\"2026-09-29T00:00:00.000Z\",\"connectedBy\":\"\(fixture.creatorId)\"}")
                }
                return .response(status: 500, body: "{\"error\":{\"code\":\"unexpected\"}}")
            }
            stub.reset()
            #expect(try await request(.post, member, suffix: "/confirm", body: "{\"pending\":\"pnd_ok\"}").status == .forbidden)
            #expect(stub.requests.isEmpty)
            #expect(try await request(.post, owner, suffix: "/confirm", body: "{}").status == .badRequest)
            let malformed = try await request(.post, owner, suffix: "/confirm", body: "{\"pending\":\"bad id/../x\"}")
            #expect(malformed.status == .notFound)
            #expect(payload(malformed)["code"] as? String == "agent_connection_pending_invalid")
            #expect(stub.requests.isEmpty)
            let confirmed = try await request(.post, creator, suffix: "/confirm", body: "{\"pending\":\"pnd_ok\",\"raftUserId\":\"forged\"}")
            #expect(confirmed.status == .ok)
            let confirmRequest = stub.requests.last
            #expect(confirmRequest?.action == "confirm")
            let confirmBody = (try? JSONSerialization.jsonObject(with: Data((confirmRequest?.body ?? "").utf8))) as? [String: Any]
            #expect(confirmBody?["pending"] as? String == "pnd_ok")
            #expect(confirmBody?["raftUserId"] as? String == fixture.creatorId)
            #expect(payload(confirmed)["connectorId"] as? String == "ctr_new")

            stub.setHandler { _ in
                .response(status: 404, body: "{\"error\":{\"code\":\"pending_expired\",\"message\":\"The pending connection expired.\"}}")
            }
            let expired = try await request(.post, owner, suffix: "/confirm", body: "{\"pending\":\"pnd_old\"}")
            #expect(expired.status == .notFound)
            #expect(payload(expired)["code"] as? String == "agent_connection_pending_invalid")
            #expect(payload(expired)["providerCode"] as? String == "pending_expired")

            // A provider refusal keeps its reason but not the secret.
            stub.setHandler { _ in
                .response(status: 409, body: "{\"error\":{\"code\":\"github_mount_missing\",\"message\":\"Agent has no github plugin mount; add exactly one. token ghp_abcdef0123456789 Bearer secret-value\"}}")
            }
            let refused = try await request(.post, owner, body: "{}")
            #expect(refused.status == .conflict)
            let refusedText = refused.body.string ?? ""
            #expect(payload(refused)["code"] as? String == "agent_connection_provider_refused")
            #expect(payload(refused)["providerCode"] as? String == "github_mount_missing")
            #expect(!refusedText.contains("ghp_abcdef0123456789"))
            #expect(!refusedText.contains("secret-value"))
            #expect((payload(refused)["providerMessage"] as? String)?.hasPrefix("Agent has no github plugin mount; add exactly one.") == true)
            #expect(payload(refused)["error"] as? String == payload(refused)["providerMessage"] as? String)
        }
    }
}

@Test func githubConnectorAssignmentNeedsTheConnectorsCreatorOrAnAdmin() async throws {
    let fixture = makeConnectionFixture(suffix: "203")
    let accounts = fixture.accounts
    accounts.setHostedRuntimeStateForTesting(agentId: fixture.agentId, state: "active")
    let stub = ConnectionProviderStub()
    accounts.agentConnectionRelay.install { stub.respond($0) }
    let connectorsJSON = """
    {"connected":false,"connectorId":null,"account":null,"connectors":[
      {"id":"ctr_creator","account":"octocat","creatorRaftUserId":"\(fixture.creatorId)","createdAt":"2026-09-29T00:00:00.000Z","current":false},
      {"id":"ctr_admin","account":"hubot","creatorRaftUserId":"\(fixture.adminId)","createdAt":"2026-09-29T00:00:00.000Z","current":false},
      {"id":"ctr_guest","account":"ghost","creatorRaftUserId":"\(fixture.guestId)","createdAt":"2026-09-29T00:00:00.000Z","current":false}
    ]}
    """

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let tokens = try await connectionTokens(client, fixture: fixture)
            func call(_ method: HTTPRequest.Method, _ bearer: String, suffix: String = "", body: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
                return try await client.send(method, headers: headers, to: "/api/agents/\(fixture.agentId)/connections/github\(suffix)") { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let owner = tokens[fixture.ownerId]!
            let admin = tokens[fixture.adminId]!
            let member = tokens[fixture.memberId]!
            let creator = tokens[fixture.creatorId]!
            let guest = tokens[fixture.guestId]!

            stub.setHandler { request in
                switch request.action {
                case "status":
                    return .response(status: 200, body: connectorsJSON)
                case "assign":
                    return .response(status: 200, body: "{}")
                case "disconnectConnector":
                    return .empty(status: 204)
                default:
                    return .response(status: 500, body: "{\"error\":{\"code\":\"unexpected\"}}")
                }
            }
            func mutations() -> [AgentConnectionProviderRequest] {
                stub.requests.filter { $0.action == "assign" || $0.action == "disconnectConnector" }
            }

            let foreignAssign = try await call(.put, creator, body: "{\"connectorId\":\"ctr_admin\"}")
            #expect(foreignAssign.status == .forbidden)
            #expect(payload(foreignAssign)["code"] as? String == "agent_connection_connector_forbidden")
            #expect(try await call(.delete, creator, suffix: "/connectors/ctr_admin").status == .forbidden)
            #expect(try await call(.put, member, body: "{\"connectorId\":\"ctr_creator\"}").status == .forbidden)
            #expect(try await call(.put, owner, body: "{}").status == .badRequest)
            #expect(payload(try await call(.put, owner, body: "{}"))["code"] as? String == "agent_connection_invalid")
            let unknown = try await call(.put, owner, body: "{\"connectorId\":\"ctr_nope\"}")
            #expect(unknown.status == .notFound)
            #expect(payload(unknown)["code"] as? String == "agent_connection_connector_not_found")
            #expect(try await call(.put, guest, body: "{\"connectorId\":\"ctr_guest\"}").status == .forbidden)
            #expect(mutations().isEmpty)

            let creatorAssign = try await call(.put, creator, body: "{\"connectorId\":\"ctr_creator\"}")
            #expect(creatorAssign.status == .ok)
            let assignRequest = stub.requests.last { $0.action == "assign" }
            let assignBody = (try? JSONSerialization.jsonObject(with: Data((assignRequest?.body ?? "").utf8))) as? [String: Any]
            #expect(assignBody?["connectorId"] as? String == "ctr_creator")
            #expect(assignBody?["actingRaftUserId"] as? String == fixture.creatorId)
            #expect(assignBody?["actingRole"] as? String == "creator")

            let adminAssign = try await call(.put, admin, body: "{\"connectorId\":\"ctr_creator\"}")
            #expect(adminAssign.status == .ok)
            let adminBody = (try? JSONSerialization.jsonObject(with: Data((stub.requests.last { $0.action == "assign" }?.body ?? "").utf8))) as? [String: Any]
            #expect(adminBody?["actingRole"] as? String == "admin")
            #expect(adminBody?["actingRaftUserId"] as? String == fixture.adminId)

            #expect(try await call(.delete, creator, suffix: "/connectors/ctr_creator").status == .noContent)
            let connectorRequest = stub.requests.last { $0.action == "disconnectConnector" }
            let connectorBody = (try? JSONSerialization.jsonObject(with: Data((connectorRequest?.body ?? "").utf8))) as? [String: Any]
            #expect(connectorBody?["actingRole"] as? String == "creator")

            stub.setHandler { request in
                switch request.action {
                case "status":
                    return .response(status: 200, body: connectorsJSON)
                case "disconnectConnector":
                    return .response(status: 502, body: "{\"failed\":[\"agent-a\",\"agent-b\"]}")
                default:
                    return .response(status: 500, body: "{\"error\":{\"code\":\"unexpected\"}}")
                }
            }
            let partial = try await call(.delete, owner, suffix: "/connectors/ctr_admin")
            #expect(partial.status == .badGateway)
            #expect(payload(partial)["code"] as? String == "agent_connection_connector_disconnect_partial")
            #expect(payload(partial)["failedCount"] as? Int == 2)
        }
    }
}

@Test func connectionProviderCanUninstallItselfDuringAnHTTPRequest() async throws {
    let fixture = makeConnectionFixture(suffix: "204")
    let accounts = fixture.accounts
    accounts.setHostedRuntimeStateForTesting(agentId: fixture.agentId, state: "active")
    let relay = accounts.agentConnectionRelay
    relay.install { _ in
        relay.install(nil)
        return .response(status: 200, body: "{\"url\":\"https://github.com/login/oauth/authorize?state=reentrant\",\"scopes\":[\"public_repo\"]}")
    }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let tokens = try await connectionTokens(client, fixture: fixture)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(try #require(tokens[fixture.ownerId]))"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
            let path = "/api/agents/\(fixture.agentId)/connections/github"
            let first = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{}")
            }
            #expect(first.status == .ok)
            let firstBody = try JSONSerialization.jsonObject(with: Data((first.body.string ?? "").utf8)) as? [String: Any]
            #expect(firstBody?["url"] as? String == "https://github.com/login/oauth/authorize?state=reentrant")

            let second = try await client.send(.post, headers: headers, to: URI(string: path)) { request in
                request.body = .init(string: "{}")
            }
            #expect(second.status == .badGateway)
            let secondBody = try JSONSerialization.jsonObject(with: Data((second.body.string ?? "").utf8)) as? [String: Any]
            #expect(secondBody?["code"] as? String == "agent_connection_provider_error")
        }
    }
}
