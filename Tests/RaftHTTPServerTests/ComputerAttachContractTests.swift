import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private struct AttachFixture {
    let accounts: EmailLoginDirectory
    let serverId: String
    let serverSlug: String
    let ownerToken: String
    let adminToken: String
    let memberToken: String
    let strangerToken: String
}

private func makeAttachFixture(_ suffix: String) -> AttachFixture {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-000001370\(suffix)"
    let adminId = "11111111-1111-4111-8111-000001371\(suffix)"
    let memberId = "11111111-1111-4111-8111-000001372\(suffix)"
    let strangerId = "11111111-1111-4111-8111-000001373\(suffix)"
    let serverId = "33333333-3333-4333-8333-000001370\(suffix)"
    let serverSlug = "attach-co-\(suffix)"
    for (id, email) in [
        (ownerId, "attach-owner-\(suffix)@slock.test"),
        (adminId, "attach-admin-\(suffix)@slock.test"),
        (memberId, "attach-member-\(suffix)@slock.test"),
        (strangerId, "attach-stranger-\(suffix)@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: serverSlug, name: "Attach Co \(suffix)", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    return AttachFixture(
        accounts: accounts,
        serverId: serverId,
        serverSlug: serverSlug,
        ownerToken: accounts.mintAccessTokenForTesting(userId: ownerId),
        adminToken: accounts.mintAccessTokenForTesting(userId: adminId),
        memberToken: accounts.mintAccessTokenForTesting(userId: memberId),
        strangerToken: accounts.mintAccessTokenForTesting(userId: strangerId)
    )
}

private func attachPost(
    _ client: any Client,
    token: String?,
    body: String
) async throws -> (status: HTTPResponse.Status, body: [String: Any]) {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let token { headers[.authorization] = "Bearer \(token)" }
    let response = try await client.send(.post, headers: headers, to: "/api/computer/attach") { request in
        request.body = .init(string: body)
    }
    let json = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
    return (response.status, json)
}

@Test func computerAttachGateAndAuthBoundary() async throws {
    let f = makeAttachFixture("901")
    // Disabled gate: the surface answers 404.
    f.accounts.setComputerAttachEnabledForTesting(false)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let disabled = try await attachPost(client, token: f.ownerToken, body: #"{"serverSlug":"\#(f.serverSlug)"}"#)
            #expect(disabled.status == .notFound)
        }
    }

    // Default-on gate: mounted, and an unknown slug collapses to 403.
    f.accounts.setComputerAttachEnabledForTesting(nil)
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let mounted = try await attachPost(client, token: f.ownerToken, body: #"{"serverSlug":"\#(UUID().uuidString)"}"#)
            #expect(mounted.status == .forbidden)
            #expect(mounted.body["code"] as? String == "not_authorized")

            let unauthenticated = try await attachPost(client, token: nil, body: #"{"serverSlug":"\#(f.serverSlug)"}"#)
            #expect(unauthenticated.status == .unauthorized)

            let missingSlug = try await attachPost(client, token: f.ownerToken, body: #"{"serverId":"\#(f.serverId)","name":"raft-computer"}"#)
            #expect(missingSlug.status == .badRequest)
            #expect(missingSlug.body["code"] as? String == "server_slug_required")
        }
    }
}

@Test func computerAttachCollapsesEnumerationAndGatesOnRole() async throws {
    let f = makeAttachFixture("902")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let nonMember = try await attachPost(client, token: f.strangerToken, body: #"{"serverSlug":"\#(f.serverSlug)","name":"raft-computer"}"#)
            #expect(nonMember.status == .forbidden)
            #expect(nonMember.body["code"] as? String == "not_authorized")

            let ghost = try await attachPost(client, token: f.strangerToken, body: #"{"serverSlug":"\#(UUID().uuidString)","name":"raft-computer"}"#)
            #expect(ghost.status == .forbidden)
            #expect(ghost.body["code"] as? String == "not_authorized")

            let plainMember = try await attachPost(client, token: f.memberToken, body: #"{"serverSlug":"\#(f.serverSlug)","name":"raft-computer"}"#)
            #expect(plainMember.status == .forbidden)
            #expect(plainMember.body["code"] as? String == "requires_admin")

            let admin = try await attachPost(client, token: f.adminToken, body: #"{"serverSlug":"\#(f.serverSlug)","name":"raft-computer"}"#)
            #expect(admin.status == .created)
            #expect(admin.body["serverSlug"] as? String == f.serverSlug)
        }
    }
}

@Test func computerAttachMintsCredentialAndRejectsNameCollision() async throws {
    let f = makeAttachFixture("903")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let first = try await attachPost(client, token: f.ownerToken, body: #"{"serverSlug":"\#(f.serverSlug)","name":"raft-computer"}"#)
            #expect(first.status == .created)
            let apiKey = try #require(first.body["apiKey"] as? String)
            #expect(apiKey.hasPrefix("sk_computer_"))
            #expect((first.body["serverMachineId"] as? String)?.isEmpty == false)
            #expect(first.body["serverId"] as? String == f.serverId)
            #expect(first.body["serverSlug"] as? String == f.serverSlug)
            #expect(first.body["resumed"] as? Bool == false)

            // The same (server, user, name) does not prove identity: it collides.
            let collision = try await attachPost(client, token: f.ownerToken, body: #"{"serverSlug":"\#(f.serverSlug)","name":"raft-computer"}"#)
            #expect(collision.status == .conflict)
            #expect(collision.body["code"] as? String == "COMPUTER_NAME_COLLISION")

            // A different name is a different Computer.
            let second = try await attachPost(client, token: f.ownerToken, body: #"{"serverSlug":"\#(f.serverSlug)","name":"raft-computer-2"}"#)
            #expect(second.status == .created)
            #expect((second.body["apiKey"] as? String) != apiKey)

            // The rejected duplicate did not rotate the original credential.
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(apiKey)"
            headers[.contentType] = "application/json"
            let preflight = try await client.send(.post, headers: headers, to: "/internal/computer/preflight") { request in
                request.body = .init(string: "{}")
            }
            #expect(preflight.status == .ok)
            let preflightBody = (try? JSONSerialization.jsonObject(with: Data((preflight.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(preflightBody["ok"] as? Bool == true)
            #expect(preflightBody["serverSlug"] as? String == f.serverSlug)
            #expect((preflightBody["principal"] as? [String: Any])?["kind"] as? String == "computer")

            // The attach links the machine into the roster: includeAll exposes it
            // without a fingerprint until the daemon handshake writes one.
            let roster = try await client.get(
                URI(string: "/api/computer/legacy-machines?serverSlug=\(f.serverSlug)&includeAll=1"),
                headers: { var h = HTTPFields(); h[.authorization] = "Bearer \(f.ownerToken)"; return h }()
            )
            #expect(roster.status == .ok)
            let rosterBody = (try? JSONSerialization.jsonObject(with: Data((roster.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let rosterRows = rosterBody["entries"] as? [[String: Any]] ?? []
            #expect(rosterRows.contains { row in
                (row["daemonId"] as? String) == (first.body["machineId"] as? String)
                    && (row["machineName"] as? String) == "raft-computer"
                    && (row["hasFingerprint"] as? Bool) == false
            }, "the attached Computer appears in the adoption roster")

            // Without includeAll the fingerprint-less attached rows stay hidden.
            let defaultRoster = try await client.get(
                URI(string: "/api/computer/legacy-machines?serverSlug=\(f.serverSlug)"),
                headers: { var h = HTTPFields(); h[.authorization] = "Bearer \(f.ownerToken)"; return h }()
            )
            let defaultBody = (try? JSONSerialization.jsonObject(with: Data((defaultRoster.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            let defaultRows = defaultBody["entries"] as? [[String: Any]] ?? []
            #expect(!defaultRows.contains { ($0["machineName"] as? String) == "raft-computer" })

            // A UUID-shaped value is a slug, never a serverId compatibility alias.
            let byId = try await attachPost(client, token: f.ownerToken, body: #"{"serverSlug":"\#(f.serverId)","name":"uuid-shaped"}"#)
            #expect(byId.status == .forbidden)
            #expect(byId.body["code"] as? String == "not_authorized")
            let bySlug = try await attachPost(client, token: f.ownerToken, body: #"{"serverSlug":"\#(f.serverSlug)","name":"uuid-shaped"}"#)
            #expect(bySlug.status == .created)
        }
    }
}
