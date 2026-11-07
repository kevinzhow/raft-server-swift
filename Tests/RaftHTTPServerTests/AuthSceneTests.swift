import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func authSceneDirectSeedLoginAndMeReadOneOwnerGraph() async throws {
    let scene = AuthScene()
    let userId = UUID().uuidString.lowercased()
    scene.auth.addAccount(id: userId, email: "  Auth.Scene@seed.test  ", password: "password123", passwordCredentialEstablished: false)
    #expect(scene.auth.userCount == 1)
    #expect(scene.auth.userId(forEmail: "AUTH.SCENE@SEED.TEST") == userId)
    #expect(scene.auth.analyticsId(userId: userId) != nil)
    #expect(!scene.auth.passwordCredentialEstablished(userId: userId))
    #expect(scene.auth.sessionCount == 0)

    try await withAuthSceneApp(scene) { client in
        let login = try await authScenePost(client, "/api/auth/login", body: #"{"email":"auth.scene@seed.test","password":"password123"}"#)
        #expect(login.status == .ok)
        #expect(login.headers[.contentType] == "application/json; charset=utf-8")
        #expect(login.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
        #expect(login.headers[.contentLength] == String((login.body.string ?? "").utf8.count))
        let session = try authSceneJSON(login)
        let user = try #require(session["user"] as? [String: Any])
        #expect(user["id"] as? String == userId)
        #expect(user["email"] as? String == "auth.scene@seed.test")
        let token = try #require(session["accessToken"] as? String)
        #expect(!(session["refreshToken"] as? String ?? "").isEmpty)
        #expect(scene.auth.sessionCount == 1)
        #expect(scene.auth.passwordCredentialEstablished(userId: userId))
        let me = try await client.get("/api/auth/me", headers: authSceneHeaders(token: token))
        #expect(me.status == .ok)
        let profile = try authSceneJSON(me)
        #expect(profile["id"] as? String == userId)
        #expect(profile["name"] as? String == "auth.scene")
        #expect(profile["profileSetupCompletedAt"] is String)
        let observed = try await authScenePost(client, "/api/auth/me/timezone-observation", token: token, body: #"{"timezone":"Asia/Tokyo"}"#)
        #expect(observed.status == .ok)
        #expect(observed.headers[HTTPField.Name("Cache-Control")!] == "private, no-store")
        let observedMe = try await client.get("/api/auth/me", headers: authSceneHeaders(token: token))
        #expect(try authSceneJSON(observedMe)["firstObservedTimezone"] as? String == "Asia/Tokyo")
        #expect(try authSceneJSON(observedMe)["lastObservedTimezone"] as? String == "Asia/Tokyo")

        // This is a service DomainError rendered by the production Feature's
        // respond boundary, not an uncaught decoder/global-middleware failure.
        let denied = try await authScenePost(client, "/api/auth/login", body: #"{"email":"auth.scene@seed.test","password":"wrong-password"}"#)
        #expect(denied.status == .unauthorized)
        #expect(try authSceneJSON(denied)["error"] as? String == "Invalid email or password")
        #expect(scene.auth.sessionCount == 1)
    }

    let isolated = AuthScene()
    #expect(isolated.auth.userCount == 0)
    #expect(isolated.auth.sessionCount == 0)
}

@Test func authSceneRegisteredServicesObserveLaterVerificationAndProviderConfiguration() async throws {
    let scene = AuthScene()
    let userId = UUID().uuidString.lowercased()
    scene.auth.addAccount(id: userId, email: "auth.scene.live@seed.test", password: "password123")
    scene.auth.configureOAuthForTesting { $0.configuredSocialAuthProviders = [] }
    let token = scene.auth.mintAccessTokenForTesting(userId: userId)
    #expect(scene.auth.sessionCount == 1)

    try await withAuthSceneApp(scene) { client in
        let before = try await client.get("/api/auth/me", headers: authSceneHeaders(token: token))
        #expect(try authSceneJSON(before)["emailVerified"] as? Bool == false)
        let resend = try await authScenePost(client, "/api/auth/resend-verification", token: token, body: "{}")
        #expect(resend.status == .ok)
        #expect(scene.auth.emailVerificationCount == 1)
        scene.auth.markEmailVerified(userId: userId)
        let after = try await client.get("/api/auth/me", headers: authSceneHeaders(token: token))
        #expect(try authSceneJSON(after)["emailVerified"] as? Bool == true)
        let verified = try await authScenePost(client, "/api/auth/resend-verification", token: token, body: "{}")
        #expect(verified.status == .badRequest)
        #expect(verified.body.string == #"{"error":"Email is already verified"}"#)
        #expect(scene.auth.emailVerificationCount == 1)

        func enabled(_ provider: String) async throws -> Bool? {
            let response = try await client.get("/api/auth/providers?platform=web")
            #expect(response.status == .ok)
            let providers = try authSceneJSON(response)["providers"] as? [[String: Any]] ?? []
            return providers.first { $0["id"] as? String == provider }?["enabled"] as? Bool
        }
        #expect(try await enabled("google") == false)
        scene.auth.configureOAuthForTesting { $0.configuredSocialAuthProviders = ["google"] }
        #expect(try await enabled("google") == true)
        #expect(try await enabled("github") == false)
        scene.auth.configureOAuthForTesting { $0.configuredSocialAuthProviders = ["github"] }
        #expect(try await enabled("google") == false)
        #expect(try await enabled("github") == true)
    }
}

@Test func authSceneRegisterAndCompleteProfileUseTheSuppliedLifecycleOwner() async throws {
    let scene = AuthScene()
    #expect(scene.auth.userCount == 0)
    try await withAuthSceneApp(scene) { client in
        // Registration is the action under test, not a replacement seed helper.
        let registered = try await authScenePost(client, "/api/auth/register", body: #"{"email":"auth.scene.profile@seed.test","password":"password123","acceptTerms":true,"termsVersion":"2026-05-12","privacyVersion":"2026-05-12"}"#)
        #expect(registered.status == .ok)
        let session = try authSceneJSON(registered)
        let user = try #require(session["user"] as? [String: Any])
        let userId = try #require(user["id"] as? String)
        let token = try #require(session["accessToken"] as? String)
        #expect(user["profileSetupCompletedAt"] is NSNull)
        #expect(scene.auth.userId(forEmail: "auth.scene.profile@seed.test") == userId)
        #expect(scene.auth.userCount == 1)
        #expect(scene.auth.sessionCount == 1)
        scene.auth.markEmailVerified(userId: userId)
        let completed = try await authScenePost(client, "/api/auth/me/complete-profile", token: token, body: #"{"name":"auth-scene-complete","displayName":"Scene Complete"}"#)
        #expect(completed.status == .ok)
        #expect(try authSceneJSON(completed)["name"] as? String == "auth-scene-complete")
        let me = try await client.get("/api/auth/me", headers: authSceneHeaders(token: token))
        let profile = try authSceneJSON(me)
        #expect(profile["name"] as? String == "auth-scene-complete")
        #expect(profile["displayName"] as? String == "Scene Complete")
        #expect(profile["profileSetupCompletedAt"] is String)
        #expect(scene.auth.userCount == 1)
        #expect(scene.auth.sessionCount == 1)
    }
}
