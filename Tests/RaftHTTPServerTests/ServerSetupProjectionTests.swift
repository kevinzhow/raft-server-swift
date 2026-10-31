import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func setupProjectionSplitsOwnerAndMemberSurfaces() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111387"
    let memberId = "11111111-1111-4111-8111-111111111388"
    let serverId = "33333333-3333-4333-8333-333333333526"
    accounts.addAccount(id: ownerId, email: "setup-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: memberId, email: "setup-member@slock.test", password: "password123")
    accounts.markEmailVerified(userId: memberId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "setup", name: "Setup", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("setup-owner@slock.test")
            let memberToken = try await login("setup-member@slock.test")
            func projection(_ token: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers(token), to: "/api/servers/\(serverId)/setup-projection")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func transition(_ token: String, _ action: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/servers/\(serverId)/setup-transition") { request in
                    request.body = .init(string: "{\"action\":\"\(action)\"}")
                }
            }

            let initial = try await projection(ownerToken)
            #expect(initial["surface"] as? String == "computer_runtime")
            #expect(initial["phase"] as? String == "not_started")
            #expect(initial["currentStep"] as? String == "computer_runtime")
            #expect(initial["blocksChat"] as? Bool == true)
            #expect(initial["allowedExits"] as? [String] == ["reset", "return_to_server"])
            #expect((initial["sideEffectState"] as? [String: Any])?["transitions"] as? String == "enabled")
            #expect(initial["gateReason"] as? String == "computer_offline")
            #expect(initial["computerStatus"] as? String == "offline")
            #expect(initial["runtimeStatus"] as? String == "unknown")
            #expect((initial["postSetup"] as? [String: Any])?["surveyPending"] as? Bool == false)

            let memberProjection = try await projection(memberToken)
            #expect(memberProjection["surface"] as? String == "none")
            #expect(memberProjection["phase"] == nil || memberProjection["phase"] is NSNull)
            #expect(memberProjection["blocksChat"] as? Bool == false)
            #expect(memberProjection["allowedExits"] as? [String] == ["return_to_server"])
            #expect(memberProjection["gateReason"] as? String == "insufficient_permission")
            #expect(memberProjection["computerStatus"] as? String == "unknown")

            let memberStart = try await transition(memberToken, "start")
            #expect(memberStart.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((memberStart.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "INSUFFICIENT_PERMISSION")

            let advance = try await transition(ownerToken, "advance")
            #expect(advance.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((advance.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "INVALID_SETUP_ACTION")

            let started = try await transition(ownerToken, "start")
            #expect(started.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((started.body.string ?? "").utf8)) as? [String: Any])?["phase"] as? String == "in_progress")

            let deferred = try await transition(ownerToken, "defer")
            #expect(deferred.status == .badRequest)
            #expect((try JSONSerialization.jsonObject(with: Data((deferred.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "INVALID_SETUP_ACTION")
        }
    }
}
