import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func webPushSubscribeStoresOnlyPublicHTTPSEndpoints() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111253"
    accounts.addAccount(id: ownerId, email: "push-subscribe@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)

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
                request.body = .init(string: "{\"email\":\"push-subscribe@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            let anonymous = try await client.send(.post, headers: HTTPFields(), to: "/api/push/subscribe") { request in
                request.body = .init(string: "{}")
            }
            #expect(anonymous.status == .unauthorized)

            func subscribe(_ endpointLiteral: String) async throws -> ClientResponse {
                try await client.send(.post, headers: headers, to: "/api/push/subscribe") { request in
                    request.body = .init(string: "{\"endpoint\":\(endpointLiteral),\"keys\":{\"p256dh\":\"BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM\",\"auth\":\"tBHItJI5svbpez7KI4CCXg\"}}")
                }
            }

            let rejected = [
                "\"http://fcm.googleapis.com/fcm/send/plain-http\"",
                "\"https://8.8.8.8/push/ip-literal\"",
                "\"https://127.0.0.1:8080/push/loopback\"",
                "\"https://[::1]/push/loopback-v6\"",
                "\"https://10.0.0.5/push/private-range\"",
                "\"https://169.254.169.254/latest/meta-data\"",
                "\"https://localhost/push\"",
                "\"https://printer.local/push\"",
                "\"https://vault.internal/push\"",
                "\"https://user:secret@fcm.googleapis.com/fcm/send/userinfo\"",
                "\"not a url\"",
                "[\"https://fcm.googleapis.com/fcm/send/array\"]",
            ]
            for endpoint in rejected {
                let response = try await subscribe(endpoint)
                #expect(response.status == .badRequest)
            }
            #expect(accounts.webPushEndpoints(userId: ownerId).isEmpty)

            let accepted = [
                "https://fcm.googleapis.com/fcm/send/abc",
                "https://updates.push.services.mozilla.com/wpush/v2/abc",
                "https://web.push.apple.com/abc",
                "https://db5p.notify.windows.com/w/?token=abc",
            ]
            for endpoint in accepted {
                let response = try await subscribe("\"\(endpoint)\"")
                #expect(response.status == .ok)
            }
            #expect(accounts.webPushEndpoints(userId: ownerId).sorted() == accepted.sorted())
        }
    }
}
