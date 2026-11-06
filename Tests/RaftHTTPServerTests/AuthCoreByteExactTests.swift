import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

/// Locks the bytes and header set of the session-core routes after they moved
/// behind `AuthCoreService` and `respond`.

private func post(
    _ client: any Client,
    _ path: String,
    body: String?,
    contentType: String? = "application/json",
    bearer: String? = nil
) async throws -> ClientResponse {
    var headers = HTTPFields()
    if let contentType { headers[.contentType] = contentType }
    if let bearer { headers[.authorization] = "Bearer \(bearer)" }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        if let body { request.body = .init(string: body) }
    }
}

private func expectStandard(_ response: ClientResponse) {
    let length = response.body.string?.utf8.count ?? 0
    #expect(response.headers[HTTPField.Name("Content-Type")!] == "application/json; charset=utf-8")
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] != nil)
    #expect(response.headers[HTTPField.Name("Content-Length")!] == String(length))
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == nil)
}

private func services(_ accounts: EmailLoginDirectory) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: accounts
    )
}

@Test func authCoreRoutesPublishTheLegacyErrorBytes() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    try await withApp { app in
        configure(app, services: services(accounts))
        try await app.testing { client in
            let register = try await post(client, "/api/auth/register", body: "[1]")
            #expect(register.status == .badRequest)
            #expect(register.body.string == #"{"error":"Invalid email registration body","code":"email_register_body_invalid","issues":[{"path":"","message":"Expected object, received string"}]}"#)
            expectStandard(register)

            let typed = try await post(client, "/api/auth/register", body: #"{"email":1,"password":"","name":null}"#)
            #expect(typed.body.string == #"{"error":"Invalid email registration body","code":"email_register_body_invalid","issues":[{"path":"email","message":"Expected string, received boolean"},{"path":"password","message":"String must contain at least 1 character(s)"},{"path":"name","message":"Expected string, received null"}]}"#)

            // A body sent without a JSON Content-Type is still read as JSON.
            let rawRefresh = try await post(client, "/api/auth/refresh", body: "{}", contentType: "text/plain")
            #expect(rawRefresh.status == .badRequest)
            #expect(rawRefresh.body.string == #"{"error":"Refresh token is required"}"#)
            expectStandard(rawRefresh)

            let unknownRefresh = try await post(client, "/api/auth/refresh", body: #"{"refreshToken":"nope"}"#)
            #expect(unknownRefresh.status == .unauthorized)
            #expect(unknownRefresh.body.string == #"{"error":"Invalid or expired refresh token"}"#)

            let logout = try await post(client, "/api/auth/logout", body: "not json", contentType: nil)
            #expect(logout.status == .ok)
            #expect(logout.body.string == #"{"ok":true}"#)
            expectStandard(logout)

            let social = try await post(client, "/api/auth/google/complete", body: "{}")
            #expect(social.body.string == #"{"error":"Sign-in completion code is required"}"#)
            let unknownProvider = try await post(client, "/api/auth/mastodon/complete", body: "{}")
            #expect(unknownProvider.status == .notFound)

            let retire = try await post(client, "/api/auth/staging-self-account/retire", body: "{}")
            #expect(retire.status == .unauthorized)
            #expect(retire.body.string == #"{"error":"Invalid or expired token","code":"auth_required"}"#)
        }
    }
}

@Test func authCoreDeviceRoutesPublishTheLegacyBytes() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "https://app.raft.test" }
    let userId = "11111111-1111-4111-8111-000003100002"
    accounts.addAccount(id: userId, email: "device-bytes@slock.test", password: "password123")
    let bearer = accounts.mintAccessTokenForTesting(userId: userId)
    try await withApp { app in
        configure(app, services: services(accounts))
        try await app.testing { client in
            let authorize = try await post(client, "/api/auth/device/authorize", body: #"{"clientName":7}"#)
            #expect(authorize.status == .badRequest)
            #expect(authorize.body.string == #"{"error":"clientName must be a string up to 200 chars","code":"client_name_invalid"}"#)

            let created = try await post(client, "/api/auth/device/authorize", body: #"{"clientName":null}"#)
            #expect(created.status == .created)
            expectStandard(created)
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any]
            )
            let deviceCode = try #require(object["deviceCode"] as? String)
            let userCode = try #require(object["userCode"] as? String)
            #expect((created.body.string ?? "").hasSuffix(",\"expiresIn\":600,\"interval\":5}"))

            let pending = try await post(client, "/api/auth/device/token", body: "{\"deviceCode\":\"\(deviceCode)\"}")
            #expect(pending.status == .badRequest)
            #expect(pending.body.string == #"{"error":"Device authorization not ready","code":"authorization_pending"}"#)

            let anonymous = try await post(client, "/api/auth/device/approve", body: "{\"userCode\":\"\(userCode)\"}")
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body.string == #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#)

            // `approve: null` denies, exactly as the raw parser read it.
            let denied = try await post(
                client, "/api/auth/device/approve",
                body: "{\"userCode\":\"\(userCode)\",\"approve\":null}", bearer: bearer
            )
            #expect(denied.body.string == #"{"ok":true,"action":"denied"}"#)
            expectStandard(denied)
            let again = try await post(
                client, "/api/auth/device/approve", body: "{\"userCode\":\"\(userCode)\"}", bearer: bearer
            )
            #expect(again.status == .conflict)
            #expect(again.body.string == #"{"error":"Device authorization could not be updated","code":"already_resolved"}"#)

            let blocked = try await post(client, "/api/auth/device/token", body: "{\"deviceCode\":\"\(deviceCode)\"}")
            #expect(blocked.status == .forbidden)
            #expect(blocked.body.string == #"{"error":"Device authorization not ready","code":"access_denied"}"#)
        }
    }
}
