import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func communityServersDisableTheOwnerOnboardingWizardGate() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111377"
    let communityId = "33333333-3333-4333-8333-333333333520"
    let normalId = "33333333-3333-4333-8333-333333333521"
    accounts.addAccount(id: ownerId, email: "community-gate@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: communityId, slug: "community", name: "Community", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: normalId, slug: "normal", name: "Normal", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"community-gate@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[HTTPField.Name("X-Server-Id")!] = communityId
            func wizardEnabled(_ serverId: String) async throws -> Bool? {
                let response = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/onboarding-settings")
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return body?["onboardingWizardEnabled"] as? Bool
            }
            #expect(try await wizardEnabled(communityId) == false)
            #expect(try await wizardEnabled(normalId) == true)
        }
    }
}
