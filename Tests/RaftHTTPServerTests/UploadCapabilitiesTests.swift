import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func uploadCapabilitiesReportThePlanLimit() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111529"
    let serverId = "33333333-3333-4333-8333-333333333610"
    accounts.addAccount(id: ownerId, email: "upload-cap-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "upload-cap", name: "Upload Cap", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"upload-cap-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let free = try await client.send(.get, headers: headers, to: "/api/attachments/upload-capabilities")
            #expect(free.status == .ok)
            let freeBody = try JSONSerialization.jsonObject(with: Data((free.body.string ?? "").utf8)) as? [String: Any]
            #expect(freeBody?["directUploadEnabled"] as? Bool == false)
            #expect(freeBody?["directUploadThresholdBytes"] == nil || freeBody?["directUploadThresholdBytes"] is NSNull)
            #expect(freeBody?["maxBytes"] as? Int == 50 * 1024 * 1024)
            #expect(freeBody?["sessionExpiresInSeconds"] == nil || freeBody?["sessionExpiresInSeconds"] is NSNull)

            accounts.oauth.setServerPlan(id: serverId, plan: "pro")
            let pro = try await client.send(.get, headers: headers, to: "/api/attachments/upload-capabilities")
            let proBody = try JSONSerialization.jsonObject(with: Data((pro.body.string ?? "").utf8)) as? [String: Any]
            #expect(proBody?["maxBytes"] as? Int == 90 * 1024 * 1024)

            var unauth = HTTPFields()
            unauth[HTTPField.Name("X-Server-Id")!] = serverId
            #expect(try await client.send(.get, headers: unauth, to: "/api/attachments/upload-capabilities").status == .unauthorized)
        }
    }
}
