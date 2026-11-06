import TestSupport
import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func pushDeliveryStatusReportsPerServerFCMAvailability() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111250"
    let otherId = "11111111-1111-4111-8111-111111111251"
    let serverA = "33333333-3333-4333-8333-333333333444"
    let serverB = "33333333-3333-4333-8333-333333333445"
    let foreign = "33333333-3333-4333-8333-333333333446"
    accounts.addAccount(id: ownerId, email: "push-status-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: otherId, email: "push-status-other@slock.test", password: "password123")
    accounts.markEmailVerified(userId: otherId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "push-status-a", name: "Push Status A", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "push-status-b", name: "Push Status B", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: foreign, slug: "push-status-foreign", name: "Push Status Foreign", ownerId: otherId)

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
                request.body = .init(string: "{\"email\":\"push-status-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"

            func status(_ installationId: String?) async throws -> ClientResponse {
                let suffix = installationId.map { "?installationId=\($0)" } ?? ""
                return try await client.send(.get, headers: headers, to: URI(string: "/api/push/delivery-status\(suffix)"))
            }
            func servers(_ installationId: String) async throws -> [String: [String: Bool]] {
                let response = try await status(installationId)
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return body?["servers"] as? [String: [String: Bool]] ?? [:]
            }

            let anonymous = try await client.send(.get, headers: HTTPFields(), to: "/api/push/delivery-status?installationId=a")
            #expect(anonymous.status == .unauthorized)
            #expect(try await status(nil).status == .badRequest)
            #expect(try await status("bad id with spaces").status == .badRequest)

            let before = try await servers("android-status-1")
            #expect(before[serverA]?["fcmActive"] == false)
            #expect(before[serverB]?["fcmActive"] == false)
            #expect(before[foreign] == nil)

            var registerHeaders = HTTPFields()
            registerHeaders[.authorization] = "Bearer \(token)"
            registerHeaders[.contentType] = "application/json"
            registerHeaders[HTTPField.Name("X-Server-Id")!] = serverA
            let register = try await client.send(.post, headers: registerHeaders, to: "/api/push/registrations") { request in
                request.body = .init(string: "{\"installationId\":\"android-status-1\",\"provider\":\"fcm\",\"env\":\"production\",\"topic\":\"build.raft.app\",\"deviceToken\":\"android-status-fid\"}")
            }
            #expect(register.status == .ok)

            let after = try await servers("android-status-1")
            #expect(after[serverA]?["fcmActive"] == true)
            #expect(after[serverB]?["fcmActive"] == true)
            let otherInstall = try await servers("android-status-other-install")
            #expect(otherInstall[serverA]?["fcmActive"] == false)
            #expect(otherInstall[serverB]?["fcmActive"] == false)

            accounts.setFCMPushAvailableForTesting(false)
            #expect(try await servers("android-status-1")[serverA]?["fcmActive"] == false)
        }
    }
}
