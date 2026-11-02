import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class AgentProfileEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(room: String, event: String, payload: String?)] = []
    func append(_ room: String, _ event: String, _ payload: String?) {
        lock.lock(); storage.append((room, event, payload)); lock.unlock()
    }
    var values: [(room: String, event: String, payload: String?)] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}

@Test func agentProfileShowNeedsReadAndProjectsUpdates() async throws {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000001023001"
    let ownerId = "11111111-1111-4111-8111-000001023001"
    let ownerEmail = "profile-owner@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "profile-show", name: "Profile Show", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "AgentApiAuthBot", runtime: "codex")
    let readKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "read")
    let sendKey = accounts.mintAgentCredential(agentId: agent, scopes: ["send"], name: "send")
    let broadKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read", "send"], name: "broad")
    let events = AgentProfileEvents()
    accounts.realtimeEmitter = { room, event, payload in events.append(room, event, payload) }

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func headers(_ key: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(key)"
                fields[.contentType] = "application/json"
                return fields
            }
            func get(_ key: String, target: String? = nil) async throws -> ClientResponse {
                let suffix = target.map { "?target=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" } ?? ""
                return try await client.get(URI(string: "/internal/agent-api/profile\(suffix)"), headers: headers(key))
            }
            func body(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }

            let own = try await get(readKey)
            #expect(own.status == .ok)
            #expect(body(own)["name"] as? String == "AgentApiAuthBot")

            let other = try await get(readKey, target: "@profile-owner")
            #expect(other.status == .ok)
            #expect(body(other)["name"] as? String == "profile-owner")

            let missing = try await get(readKey, target: "@no-such-member-anywhere")
            #expect(missing.status == .notFound)

            let denied = try await get(sendKey, target: "@profile-owner")
            #expect(denied.status == .forbidden)
            #expect(body(denied)["code"] as? String == "capability_not_authorized")

            let updated = try await client.send(.post, headers: headers(broadKey), to: "/internal/agent-api/profile") { request in
                request.body = .init(string: "{\"displayName\":\"Native Profile Bot\"}")
            }
            #expect(updated.status == .ok)
            #expect(body(updated)["displayName"] as? String == "Native Profile Bot")
            #expect(events.values.contains { $0.room == "server:\(serverId)" && $0.event == "agent:updated" })

            let after = try await get(readKey)
            #expect(body(after)["displayName"] as? String == "Native Profile Bot")
        }
    }
}
