import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func pushRegistrationsValidateTheTupleAndUpsertByInstallation() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111248"
    let otherId = "11111111-1111-4111-8111-111111111249"
    let serverId = "33333333-3333-4333-8333-333333333443"
    accounts.addAccount(id: ownerId, email: "push-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: otherId, email: "push-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: otherId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "push-api", name: "Push API", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: otherId, role: "member")

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
            let ownerToken = try await login("push-owner@slock.test")
            let otherToken = try await login("push-other@slock.test")

            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            func register(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers(token), to: "/api/push/registrations") { request in
                    request.body = .init(string: body)
                }
            }

            let missingEnv = try await register(ownerToken, "{\"installationId\":\"ios-install-1\",\"provider\":\"apns\",\"topic\":\"ai.slock.app\",\"deviceToken\":\"token-1\"}")
            #expect(missingEnv.status == .badRequest)
            let partial = try await register(ownerToken, "{\"installationId\":\"ios-install-1\",\"provider\":\"apns\",\"env\":\"sandbox\",\"topic\":\"ai.slock.app\"}")
            #expect(partial.status == .badRequest)
            let malicious = try await register(ownerToken, "{\"installationId\":\"alice@example.com secret marker\",\"provider\":\"apns\",\"env\":\"sandbox\",\"topic\":\"ai.slock.app.dev\",\"deviceToken\":\"token-1\"}")
            #expect(malicious.status == .badRequest)
            let oversized = try await register(ownerToken, "{\"installationId\":\"\(String(repeating: "i", count: 129))\",\"provider\":\"apns\",\"env\":\"sandbox\",\"topic\":\"ai.slock.app.dev\",\"deviceToken\":\"token-1\"}")
            #expect(oversized.status == .badRequest)

            let created = try await register(ownerToken, "{\"installationId\":\"ios-install-1\",\"provider\":\"apns\",\"env\":\"sandbox\",\"topic\":\"ai.slock.app.dev\",\"deviceToken\":\"token-1\",\"appVersion\":\"1.0.0\"}")
            #expect(created.status == .ok)
            let createBody = try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            let capability = createBody?["revoke_capability"] as? String ?? ""
            #expect(capability.isEmpty == false)

            let updated = try await register(ownerToken, "{\"installationId\":\"ios-install-1\",\"provider\":\"apns\",\"env\":\"production\",\"topic\":\"ai.slock.app\",\"deviceToken\":\"token-2\",\"appVersion\":\"1.0.1\"}")
            #expect(updated.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((updated.body.string ?? "").utf8)) as? [String: Any])?["revoke_capability"] as? String == capability)
            #expect(accounts.pushRegistration(installationId: "ios-install-1", provider: "apns")?.userId == ownerId)
            #expect(accounts.pushRegistration(installationId: "ios-install-1", provider: "apns")?.deviceToken == "token-2")

            let switched = try await register(otherToken, "{\"installationId\":\"ios-install-1\",\"provider\":\"apns\",\"env\":\"production\",\"topic\":\"ai.slock.app\",\"deviceToken\":\"token-3\"}")
            #expect(switched.status == .ok)
            #expect(accounts.pushRegistration(installationId: "ios-install-1", provider: "apns")?.userId == otherId)

            let unbind = try await client.send(.delete, headers: headers(otherToken), to: "/api/push/registrations/ios-install-1")
            #expect(unbind.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((unbind.body.string ?? "").utf8)) as? [String: Any])?["unbound"] as? Int == 1)
            #expect(accounts.pushRegistration(installationId: "ios-install-1", provider: "apns")?.userId == nil)

            let fcmSandbox = try await register(ownerToken, "{\"installationId\":\"android-install-1\",\"provider\":\"fcm\",\"env\":\"sandbox\",\"topic\":\"build.raft.app\",\"deviceToken\":\"dGVzdA:APA91b\(String(repeating: "x", count: 150))\"}")
            #expect(fcmSandbox.status == .badRequest)
            let fcmMalformed = try await register(ownerToken, "{\"installationId\":\"android-install-1\",\"provider\":\"fcm\",\"env\":\"production\",\"topic\":\"build.raft.app\",\"deviceToken\":\"token with spaces\"}")
            #expect(fcmMalformed.status == .badRequest)
            let apnsColon = try await register(ownerToken, "{\"installationId\":\"android-install-1\",\"provider\":\"apns\",\"env\":\"sandbox\",\"topic\":\"build.raft.app\",\"deviceToken\":\"dGVzdA:APA91b\(String(repeating: "x", count: 150))\"}")
            #expect(apnsColon.status == .badRequest)
            let fcm = try await register(ownerToken, "{\"installationId\":\"android-install-1\",\"provider\":\"fcm\",\"env\":\"production\",\"topic\":\"build.raft.app\",\"deviceToken\":\"dGVzdA:APA91b\(String(repeating: "x", count: 150))\"}")
            #expect(fcm.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((fcm.body.string ?? "").utf8)) as? [String: Any])?["registration"].flatMap { ($0 as? [String: Any])?["provider"] as? String } == "fcm")
        }
    }
}
