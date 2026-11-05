import Foundation
import HTTPTypes
import NIOCore
import NIOPosix
import RaftHTTP
import RaftHTTPServer
import RaftRealtime
import Testing
import Vapor
import VaporTesting

private func rbacHeaders(_ token: String, _ serverId: String) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    return headers
}

private func rbacBody(_ response: ClientResponse) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
}

private func rbacFixture(_ suffix: String) -> (EmailLoginDirectory, ownerId: String, relatedId: String, serverId: String) {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001040\(suffix)"
    let relatedId = "11111111-1111-4111-8111-000001041\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001040\(suffix)"
    accounts.addAccount(id: ownerId, email: "rbac3-owner-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: relatedId, email: "rbac3-related-\(suffix)@slock.test", password: "password123")
    accounts.markEmailVerified(userId: relatedId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "rbac3-\(suffix)", name: "RBAC3 \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: relatedId, role: "member")
    return (accounts, ownerId, relatedId, serverId)
}

private func rbacDepart(
    _ client: any Client,
    how: String,
    serverId: String,
    relatedId: String,
    ownerToken: String,
    relatedToken: String
) async throws {
    let path = how == "removed"
        ? "/api/servers/\(serverId)/members/\(relatedId)"
        : "/api/servers/\(serverId)/leave"
    let method: HTTPRequest.Method = how == "removed" ? .delete : .post
    let token = how == "removed" ? ownerToken : relatedToken
    let response = try await client.send(method, headers: rbacHeaders(token, serverId), to: URI(string: path)) { request in
        if method == .post { request.body = .init(string: "{}") }
    }
    #expect(response.status == .ok, "\(how) must succeed")
}

@Test func machineRegistrantLosesExactMachineAuthorityOnDeparture() async throws {
    for how in ["removed", "left"] {
        let (accounts, ownerId, relatedId, serverId) = rbacFixture(how == "removed" ? "001" : "002")
        let machine = accounts.registerMachine(serverId: serverId, userId: relatedId, name: "p3-machine-\(how)")
        let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
        let relatedToken = accounts.mintAccessTokenForTesting(userId: relatedId)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts
            ))
            try await app.testing { client in
                func machinePath(_ suffix: String = "") -> String {
                    "/api/servers/\(serverId)/machines/\(machine)\(suffix)"
                }
                let before = try await client.send(.patch, headers: rbacHeaders(relatedToken, serverId), to: URI(string: machinePath())) { request in
                    request.body = .init(string: "{\"description\":\"before departure\"}")
                }
                #expect(before.status == .ok, "\(how): registrant may edit before departure")

                try await rbacDepart(client, how: how, serverId: serverId, relatedId: relatedId, ownerToken: ownerToken, relatedToken: relatedToken)

                let denied: [(HTTPRequest.Method, String, String?)] = [
                    (.patch, "", "{\"description\":\"after departure\"}"),
                    (.post, "/rotate-key", "{}"),
                    (.post, "/computer/restart", "{}"),
                    (.get, "/workspaces", nil),
                    (.delete, "", nil),
                ]
                for (method, suffix, body) in denied {
                    let response = try await client.send(method, headers: rbacHeaders(relatedToken, serverId), to: URI(string: machinePath(suffix))) { request in
                        if let body { request.body = .init(string: body) }
                    }
                    #expect(response.status == .forbidden, "\(how): \(method) \(suffix) must deny a departed registrant")
                    #expect(try rbacBody(response)["error"] as? String == "Not a member of this server")
                }

                #expect(accounts.machineDescriptionForTesting(machineId: machine) == "before departure", "\(how): no denied write committed")
                #expect(accounts.machineRegistrantForTesting(machineId: machine) == relatedId, "\(how): registrant relation row is untouched")

                let ownerPatch = try await client.send(.patch, headers: rbacHeaders(ownerToken, serverId), to: URI(string: machinePath())) { request in
                    request.body = .init(string: "{\"description\":\"owner after departure\"}")
                }
                #expect(ownerPatch.status == .ok, "\(how): an authorized actor is unaffected")
                #expect(accounts.machineDescriptionForTesting(machineId: machine) == "owner after departure")
            }
        }
    }
}

@Test func agentCreatorLosesExactAgentAuthorityOnLeave() async throws {
    let (accounts, ownerId, relatedId, serverId) = rbacFixture("003")
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "leaver-agent", creatorUserId: relatedId, runtime: "managed")
    let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
    let relatedToken = accounts.mintAccessTokenForTesting(userId: relatedId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let before = try await client.send(.patch, headers: rbacHeaders(relatedToken, serverId), to: URI(string: "/api/agents/\(agent)")) { request in
                request.body = .init(string: "{\"description\":\"before departure\"}")
            }
            #expect(before.status == .ok)

            try await rbacDepart(client, how: "left", serverId: serverId, relatedId: relatedId, ownerToken: ownerToken, relatedToken: relatedToken)

            let after = try await client.send(.patch, headers: rbacHeaders(relatedToken, serverId), to: URI(string: "/api/agents/\(agent)")) { request in
                request.body = .init(string: "{\"description\":\"after departure\"}")
            }
            #expect(after.status == .forbidden)
            #expect(try rbacBody(after)["error"] as? String == "Not a member of this server")

            let credentials = try await client.send(.post, headers: rbacHeaders(relatedToken, serverId), to: URI(string: "/api/agents/\(agent)/credentials")) { request in
                request.body = .init(string: "{}")
            }
            #expect(credentials.status == .notFound)
            #expect(try rbacBody(credentials)["code"] as? String == "agent_missing")
        }
    }
}

private struct AccountsRealtimeAuth: RealtimeAuthorizing {
    let accounts: EmailLoginDirectory

    func userId(forAccessToken token: String) -> String? {
        accounts.sessionIdentity(accessToken: token)?.userId
    }

    func sessionFamilyId(forAccessToken token: String) -> String? {
        accounts.sessionIdentity(accessToken: token)?.familyId
    }

    func serverRole(serverId: String, userId: String) -> String? {
        accounts.oauth.memberRole(serverId: serverId, userId: userId)
    }

    func visibleChannelIds(serverId: String, userId: String) -> [String] {
        accounts.oauth.channelsForServer(serverId: serverId, userId: userId).filter(\.joined).map(\.id)
    }
}

@Test func departedCreatorSocketStopsReceivingServerEvents() async throws {
    for how in ["removed", "left"] {
        let suffix = how == "removed" ? "004" : "005"
        let (accounts, ownerId, relatedId, serverId) = rbacFixture(suffix)
        let agent = accounts.oauth.createAgent(serverId: serverId, name: "socket-agent-\(suffix)", creatorUserId: relatedId, runtime: "codex")
        let machine = accounts.registerMachine(serverId: serverId, userId: relatedId, name: "socket-machine-\(suffix)")
        let ownerToken = accounts.mintAccessTokenForTesting(userId: ownerId)
        let relatedToken = accounts.mintAccessTokenForTesting(userId: relatedId)
        let realtime = try await RealtimeServer.start(auth: AccountsRealtimeAuth(accounts: accounts))
        let departed = try await SocketIOTestClient(port: realtime.port)
        let control = try await SocketIOTestClient(port: realtime.port)
        defer {
            departed.close()
            control.close()
            Task { try? await realtime.close() }
        }
        _ = await departed.waitForText { $0.hasPrefix("0") }
        departed.send("40{\"token\":\"\(relatedToken)\",\"serverId\":\"\(serverId)\"}")
        _ = await departed.waitForText { $0 == "42[\"rooms:joined\"]" }
        _ = await control.waitForText { $0.hasPrefix("0") }
        control.send("40{\"token\":\"\(ownerToken)\",\"serverId\":\"\(serverId)\"}")
        _ = await control.waitForText { $0 == "42[\"rooms:joined\"]" }

        realtime.hub.emit(room: "server:\(serverId)", event: "agent:session", payloadJSON: "{\"agentId\":\"\(agent)\",\"sessionId\":\"before-departure\"}")
        #expect(await departed.waitForText { $0.contains("before-departure") } != nil, "\(how): creator receives Agent events before departure")
        #expect(await control.waitForText { $0.contains("before-departure") } != nil)

        try await withApp { app in
            configure(app, services: FallbackServices(
                nodeEnv: "test",
                tracker: DbLivenessTracker(ping: {}),
                pingDatabase: {},
                emailAccounts: accounts,
                realtime: realtime.hub
            ))
            try await app.testing { client in
                try await rbacDepart(client, how: how, serverId: serverId, relatedId: relatedId, ownerToken: ownerToken, relatedToken: relatedToken)
            }
        }
        #expect(await departed.waitForClose(), "\(how): departed socket must be closed")

        realtime.hub.emit(room: "server:\(serverId)", event: "agent:session", payloadJSON: "{\"sessionId\":\"agent-after-departure\"}")
        realtime.hub.emit(room: "server:\(serverId)", event: "machine:status", payloadJSON: "{\"machineId\":\"\(machine)\",\"status\":\"machine-after-departure\"}")
        #expect(await control.waitForText { $0.contains("agent-after-departure") } != nil, "\(how): an authorized member still receives Agent events")
        #expect(await control.waitForText { $0.contains("machine-after-departure") } != nil, "\(how): an authorized member still receives Machine events")
        #expect(departed.textFrames.allSatisfy { !$0.contains("agent-after-departure") }, "\(how): departed creator must not receive Agent events")
        #expect(departed.textFrames.allSatisfy { !$0.contains("machine-after-departure") }, "\(how): departed registrant must not receive Machine events")
    }
}
