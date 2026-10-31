import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func sendJSON(
    _ client: any Client,
    method: HTTPRequest.Method,
    path: String,
    body: String? = nil,
    authorization: String
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.authorization] = authorization
    return try await client.send(method, headers: headers, to: URI(string: path)) { request in
        if let body {
            request.body = .init(string: body)
        }
    }
}

@Test func featureFlagAdminRoutesStayAbsentWhileEvaluateRemainsMounted() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    accounts.addAccount(id: userId, email: "ff-admin-removed@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let flagKey = "removed_probe_aaaaaaaaaaaa"
    let ruleId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2"
    let removed: [(HTTPRequest.Method, String, String?)] = [
        (.get, "/api/feature-flags/admin/flags", nil),
        (.post, "/api/feature-flags/admin/flags", "{\"key\":\"removed_create_aaaaaaaaaaaa\",\"randomizationUnit\":\"server\",\"defaultEnabled\":false}"),
        (.get, "/api/feature-flags/admin/flags/\(flagKey)", nil),
        (.patch, "/api/feature-flags/admin/flags/\(flagKey)", "{\"description\":\"removed route fixture\"}"),
        (.post, "/api/feature-flags/admin/flags/\(flagKey)/kill-switch", "{\"killSwitch\":true}"),
        (.post, "/api/feature-flags/admin/flags/\(flagKey)/rules", "{\"stage\":\"server\",\"decision\":\"allow\",\"values\":[]}"),
        (.patch, "/api/feature-flags/admin/flags/\(flagKey)/rules/\(ruleId)", "{\"priority\":1}"),
        (.delete, "/api/feature-flags/admin/flags/\(flagKey)/rules/\(ruleId)", nil),
        (.delete, "/api/feature-flags/admin/flags/\(flagKey)", nil),
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await sendJSON(
                client,
                method: .post,
                path: "/api/auth/login",
                body: "{\"email\":\"ff-admin-removed@slock.test\",\"password\":\"password123\"}",
                authorization: ""
            )
            #expect(login.status == .ok)
            let token = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let bearer = "Bearer \(token)"

            let evaluate = try await sendJSON(
                client,
                method: .post,
                path: "/api/feature-flags/evaluate",
                body: "{\"keys\":[]}",
                authorization: bearer
            )
            #expect(evaluate.status != .notFound)
            #expect(evaluate.status == .badRequest)
            let evaluateBody = try JSONSerialization.jsonObject(with: Data(bodyText(evaluate).utf8)) as? [String: Any]
            #expect(evaluateBody?["error"] as? String == "keys must contain 1-50 valid feature flag keys")

            for (method, path, body) in removed {
                let response = try await sendJSON(client, method: method, path: path, body: body, authorization: bearer)
                #expect(response.status == .notFound)
                #expect(bodyText(response) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"\(path)\"}")
            }
        }
    }
}

@Test func removedOperatorFeatureFlagRoutesStay404() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
    accounts.addAccount(id: userId, email: "ff-operator-removed@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)

    let paths = [
        "/api/oauth/operator/feature-flags/removed_operator/evaluate-preview",
        "/api/oauth/operator/feature-flags/removed_operator/server-allowlist/rules",
        "/api/oauth/operator/feature-flags/apple_web_login_v0/platform-allowlist/web/rules",
    ]
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let login = try await sendJSON(
                client,
                method: .post,
                path: "/api/auth/login",
                body: "{\"email\":\"ff-operator-removed@slock.test\",\"password\":\"password123\"}",
                authorization: "Bearer ignored"
            )
            let token = (try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            for path in paths {
                let response = try await sendJSON(
                    client,
                    method: .post,
                    path: path,
                    body: "{}",
                    authorization: "Bearer \(token)"
                )
                #expect(response.status == .notFound)
            }
        }
    }
}
