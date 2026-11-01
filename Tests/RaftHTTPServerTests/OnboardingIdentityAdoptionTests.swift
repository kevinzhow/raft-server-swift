import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class AgentUpdateEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []

    func append(room: String, event: String, payload: String?) {
        lock.lock()
        storage.append((room, event, payload))
        lock.unlock()
    }

    var events: [(room: String, event: String, payload: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Test func onboardingIdentityAdoptionPreviewsThenApplies() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111695"
    let memberId = "11111111-1111-4111-8111-111111111696"
    let serverId = "33333333-3333-4333-8333-333333333704"
    for (id, email, role) in [
        (ownerId, "adopt-owner@slock.test", "owner"),
        (memberId, "adopt-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "adopt", name: "Adopt", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let agent = accounts.oauth.createAgent(
        serverId: serverId,
        name: "SetupGuide",
        displayName: "Setup Guide",
        avatarUrl: "pixel:finch",
        description: "Custom setup guide",
        creatorUserId: ownerId
    )
    accounts.addServerAgent(serverId: serverId, id: agent, name: "SetupGuide", avatarUrl: "pixel:finch", status: "inactive")
    let other = accounts.oauth.createAgent(serverId: serverId, name: "OtherAgent", creatorUserId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: other, name: "OtherAgent", avatarUrl: nil, status: "inactive")
    let events = AgentUpdateEvents()
    accounts.realtimeEmitter = { room, event, payload in
        events.append(room: room, event: event, payload: payload)
    }

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
            let owner = try await token("adopt-owner@slock.test")
            let member = try await token("adopt-member@slock.test")
            func request(_ method: HTTPRequest.Method, _ path: String, _ bearer: String, body: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(method, headers: headers, to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            let settings = try await request(.patch, "/api/servers/\(serverId)/onboarding-settings", owner, body: "{\"onboardingAgentId\":\"\(agent)\"}")
            #expect(settings.status == .ok)
            let endpoint = "/api/agents/\(agent)/onboarding-identity-adoption"

            #expect(try await request(.get, endpoint, member).status == .forbidden)
            let preview = try await request(.get, endpoint, owner)
            #expect(preview.status == .ok)
            let previewBody = try JSONSerialization.jsonObject(with: Data((preview.body.string ?? "").utf8)) as? [String: Any]
            #expect(previewBody?["canAdopt"] as? Bool == true)
            let changes = previewBody?["changes"] as? [[String: Any]] ?? []
            #expect(changes.map { $0["field"] as? String } == ["name", "displayName", "role", "serverRole", "avatarUrl"])
            #expect(changes.map { $0["before"] as? String } == ["SetupGuide", "Setup Guide", "Custom setup guide", "member", "pixel:finch"])
            #expect(changes.map { $0["after"] as? String } == ["Cindy", "Cindy", "Onboarding Assistant", "admin", "pixel:mug"])

            let adopted = try await request(.post, endpoint, owner)
            #expect(adopted.status == .ok)
            let adoptedBody = try JSONSerialization.jsonObject(with: Data((adopted.body.string ?? "").utf8)) as? [String: Any]
            #expect(adoptedBody?["canAdopt"] as? Bool == false)
            let adoptedAgent = adoptedBody?["agent"] as? [String: Any]
            #expect(adoptedAgent?["name"] as? String == "Cindy")
            #expect(adoptedAgent?["displayName"] as? String == "Cindy")
            #expect(adoptedAgent?["description"] as? String == "Onboarding Assistant")
            #expect(adoptedAgent?["avatarUrl"] as? String == "pixel:mug")
            #expect(adoptedAgent?["serverRole"] as? String == "admin")
            #expect(accounts.oauth.agentRole(serverId: serverId, agentId: agent) == "admin")
            #expect(events.events.last?.room == "server:\(serverId)")
            #expect(events.events.last?.event == "agent:updated")

            let second = try await request(.post, endpoint, owner)
            let secondBody = try JSONSerialization.jsonObject(with: Data((second.body.string ?? "").utf8)) as? [String: Any]
            #expect((secondBody?["changes"] as? [[String: Any]] ?? []).isEmpty)
            #expect((secondBody?["appliedChanges"] as? [[String: Any]] ?? []).isEmpty)
            #expect(events.events.count == 1)

            #expect(try await request(.get, "/api/agents/\(other)/onboarding-identity-adoption", owner).status == .badRequest)
            #expect(try await request(.get, "/api/agents/missing/onboarding-identity-adoption", owner).status == .notFound)
        }
    }
}

@Test func onboardingIdentityAdoptionRefusesAnExistingCindyHandle() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111697"
    let serverId = "33333333-3333-4333-8333-333333333705"
    accounts.addAccount(id: ownerId, email: "adopt-conflict@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "adopt-conflict", name: "Adopt Conflict", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "SetupGuide", creatorUserId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: agent, name: "SetupGuide", avatarUrl: nil, status: "inactive")
    let cindy = accounts.oauth.createAgent(serverId: serverId, name: "Cindy", creatorUserId: ownerId)
    accounts.addServerAgent(serverId: serverId, id: cindy, name: "Cindy", avatarUrl: nil, status: "inactive")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"adopt-conflict@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            _ = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/onboarding-settings") { request in
                request.body = .init(string: "{\"onboardingAgentId\":\"\(agent)\"}")
            }
            let response = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/onboarding-identity-adoption")
            #expect(response.status == .conflict)
            #expect(accounts.oauth.agentRuntimeInfo(id: agent)?.name == "SetupGuide")
        }
    }
}
