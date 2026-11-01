import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private final class PresenceEventBox: @unchecked Sendable {
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

private struct PresenceFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let ownerEmail: String
    let externalId: String
    let managedId: String
    let externalKey: String
    let managedKey: String
}

private func makePresenceFixture(suffix: String) -> PresenceFixture {
    let accounts = EmailLoginDirectory()
    let serverId = String(format: "33333333-3333-4333-8333-%012d", 700_000 + (Int(suffix) ?? 0))
    let ownerId = String(format: "11111111-1111-4111-8111-%012d", 300_000 + (Int(suffix) ?? 0))
    let ownerEmail = "presence-owner-\(suffix)@slock.test"
    accounts.addAccount(id: ownerId, email: ownerEmail, password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "presence-\(suffix)", name: "Presence \(suffix)", ownerId: ownerId)
    let external = accounts.oauth.createAgent(serverId: serverId, name: "PresenceExt-\(suffix)", runtime: "external")
    let managed = accounts.oauth.createAgent(serverId: serverId, name: "PresenceManaged-\(suffix)", runtime: "codex")
    let externalKey = accounts.mintAgentCredential(agentId: external, scopes: ["read"], name: "presence-ext")
    let managedKey = accounts.mintAgentCredential(agentId: managed, scopes: ["read"], name: "presence-managed")
    return PresenceFixture(
        accounts: accounts,
        serverId: serverId,
        ownerEmail: ownerEmail,
        externalId: external,
        managedId: managed,
        externalKey: externalKey,
        managedKey: managedKey
    )
}

private func presenceLogin(_ client: any Client, email: String) async throws -> String {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
        request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
    }
    return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
}

private func agentApiCall(_ client: any Client, key: String) async throws {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(key)"
    let response = try await client.get("/internal/agent-api", headers: headers)
    #expect(response.status == .ok)
}

private func agentRows(_ client: any Client, token: String, serverId: String) async throws -> [[String: Any]] {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[HTTPField.Name("X-Server-Id")!] = serverId
    let response = try await client.get("/api/agents", headers: headers)
    #expect(response.status == .ok)
    return (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [[String: Any]] ?? []
}

@Test func credentialUseWritesAreThrottledPerCredential() async throws {
    let fixture = makePresenceFixture(suffix: "201")
    let accounts = fixture.accounts
    let events = PresenceEventBox()
    accounts.realtimeEmitter = { room, event, payload in
        events.append(room: room, event: event, payload: payload)
    }
    #expect(EmailLoginDirectory.agentCredentialUseDefaultThrottleMs == 60_000)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            try await agentApiCall(client, key: fixture.externalKey)
            let first = accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey)
            #expect(first != nil)

            try await agentApiCall(client, key: fixture.externalKey)
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey) == first)
            #expect(events.events.filter { $0.event == "agent:seen" }.count == 1)

            accounts.setAgentCredentialUseThrottleMsForTesting(50)
            try await Task.sleep(nanoseconds: 120_000_000)
            try await agentApiCall(client, key: fixture.externalKey)
            let second = accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey)
            #expect(second != nil)
            #expect((second ?? .distantPast) > (first ?? .distantFuture))
            try await agentApiCall(client, key: fixture.externalKey)
            #expect(accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey) == second)
            try await Task.sleep(nanoseconds: 120_000_000)
            try await agentApiCall(client, key: fixture.externalKey)
            let third = accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey)
            #expect((third ?? .distantPast) > (second ?? .distantFuture))
        }
    }
}

@Test func agentSeenIsPushedToTheServerRoomForExternalAgentsOnly() async throws {
    let fixture = makePresenceFixture(suffix: "202")
    let accounts = fixture.accounts
    let events = PresenceEventBox()
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
            try await agentApiCall(client, key: fixture.managedKey)
            try await agentApiCall(client, key: fixture.externalKey)
            try await Task.sleep(nanoseconds: 100_000_000)

            let seen = events.events.filter { $0.event == "agent:seen" }
            #expect(seen.count == 1)
            #expect(seen.first?.room == "server:\(fixture.serverId)")
            let payload = (seen.first?.payload.flatMap { $0.data(using: .utf8) })
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            #expect(payload?["agentId"] as? String == fixture.externalId)
            #expect(payload?["lastSeenAt"] is String)
        }
    }
}

@Test func agentListServesLastSeenAtForExternalAgentsOnly() async throws {
    let fixture = makePresenceFixture(suffix: "203")
    let accounts = fixture.accounts

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let token = try await presenceLogin(client, email: fixture.ownerEmail)
            let before = try await agentRows(client, token: token, serverId: fixture.serverId)
            let beforeExternal = before.first { $0["id"] as? String == fixture.externalId }
            let beforeManaged = before.first { $0["id"] as? String == fixture.managedId }
            #expect(beforeExternal?["lastSeenAt"] is NSNull)
            #expect(beforeManaged?["lastSeenAt"] == nil)

            try await agentApiCall(client, key: fixture.externalKey)
            try await agentApiCall(client, key: fixture.managedKey)
            let after = try await agentRows(client, token: token, serverId: fixture.serverId)
            let afterExternal = after.first { $0["id"] as? String == fixture.externalId }
            let afterManaged = after.first { $0["id"] as? String == fixture.managedId }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expected = accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey).map { formatter.string(from: $0) }
            #expect(afterExternal?["lastSeenAt"] as? String == expected)
            #expect(afterManaged?["lastSeenAt"] == nil)
        }
    }
}

@Test func openWakeHintStreamKeepsTheExternalAgentSeen() async throws {
    setenv("SLOCK_WAKE_STREAM_HEARTBEAT_MS", "100", 1)
    defer { unsetenv("SLOCK_WAKE_STREAM_HEARTBEAT_MS") }
    let fixture = makePresenceFixture(suffix: "204")
    let accounts = fixture.accounts
    accounts.setAgentCredentialUseThrottleMsForTesting(50)
    let events = PresenceEventBox()
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
        try await app.testing(.running) { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.externalKey)"
            var response = try await client.get("/internal/agent-api/wake-hints/stream", headers: headers)
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "text/event-stream")

            let opened = accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey)
            #expect(opened != nil)
            try await Task.sleep(nanoseconds: 450_000_000)
            let refreshed = accounts.agentCredentialLastUsedAtForTesting(apiKey: fixture.externalKey)
            #expect((refreshed ?? .distantPast) > (opened ?? .distantFuture))
            #expect(events.events.filter { $0.event == "agent:seen" }.count >= 2)

            let drained = try await response.body.collect() ?? Data()
            let text = String(decoding: drained, as: UTF8.self)
            #expect(text.contains(": connected"))
            #expect(text.contains(": heartbeat"))
        }
    }
}
