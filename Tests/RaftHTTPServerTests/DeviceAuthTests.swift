import TestSupport
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

private func postJSON(_ client: any Client, _ path: String, body: String, authorization: String? = nil) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let authorization {
        headers[.authorization] = authorization
    }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

private func deviceApp(_ accounts: EmailLoginDirectory) -> FallbackServices {
    FallbackServices(
        nodeEnv: "test",
        tracker: DbLivenessTracker(ping: {}),
        pingDatabase: {},
        emailAccounts: accounts
    )
}

@Test func deviceLoginSurfaceFollowsTheExplicitKillSwitch() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "http://127.0.0.1:4173" }
    try await withApp { app in
        configure(app, services: deviceApp(accounts))
        try await app.testing { client in
            let unset = try await postJSON(client, "/api/auth/device/authorize", body: "{\"clientName\":\"test\"}")
            #expect(unset.status == .created)

            for kill in ["false", "0", "no", "off", "FALSE", "False"] {
                accounts.configureAuthCoreForTesting { $0.deviceLoginGate = kill }
                let response = try await postJSON(client, "/api/auth/device/authorize", body: "{}")
                #expect(response.status == .notFound)
            }

            for live in ["", "true", "1", "yes", "on"] {
                accounts.configureAuthCoreForTesting { $0.deviceLoginGate = live }
                let response = try await postJSON(client, "/api/auth/device/authorize", body: "{\"clientName\":\"test\"}")
                #expect(response.status == .created)
            }
        }
    }
}

@Test func deviceLoginLifecycleApprovesOnceThenRejectsASecondPoll() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "http://127.0.0.1:4173" }
    let userId = "cccccccc-cccc-4ccc-8ccc-ccccccccccc3"
    accounts.addAccount(id: userId, email: "device-user@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: deviceApp(accounts))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"device-user@slock.test\",\"password\":\"password123\"}")
            #expect(login.status == .ok)
            let bearer = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""

            let auth = try await postJSON(client, "/api/auth/device/authorize", body: "{\"clientName\":\"raft-computer\"}")
            #expect(auth.status == .created)
            let grant = try JSONSerialization.jsonObject(with: Data(bodyText(auth).utf8)) as? [String: Any]
            let deviceCode = grant?["deviceCode"] as? String ?? ""
            let userCode = grant?["userCode"] as? String ?? ""
            #expect(deviceCode.isEmpty == false)
            #expect(userCode.isEmpty == false)
            #expect(grant?["verificationUri"] as? String == "http://127.0.0.1:4173/login/device")
            let encoded = userCode.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.!~*'()"))) ?? userCode
            #expect(grant?["verificationUriComplete"] as? String == "http://127.0.0.1:4173/login/device?user_code=\(encoded)")

            let pending = try await postJSON(client, "/api/auth/device/token", body: "{\"deviceCode\":\(jsonFragment(deviceCode))}")
            #expect(pending.status == .badRequest)
            let pendingBody = try JSONSerialization.jsonObject(with: Data(bodyText(pending).utf8)) as? [String: Any]
            #expect(pendingBody?["code"] as? String == "authorization_pending")

            let noAuth = try await postJSON(client, "/api/auth/device/approve", body: "{\"userCode\":\(jsonFragment(userCode))}")
            #expect(noAuth.status == .unauthorized)

            let approve = try await postJSON(
                client,
                "/api/auth/device/approve",
                body: "{\"userCode\":\(jsonFragment(userCode))}",
                authorization: "Bearer \(bearer)"
            )
            #expect(approve.status == .ok)

            let tok = try await postJSON(client, "/api/auth/device/token", body: "{\"deviceCode\":\(jsonFragment(deviceCode))}")
            #expect(tok.status == .ok)
            let session = try JSONSerialization.jsonObject(with: Data(bodyText(tok).utf8)) as? [String: Any]
            #expect((session?["accessToken"] as? String)?.isEmpty == false)
            #expect((session?["refreshToken"] as? String)?.isEmpty == false)
            #expect(session?["userId"] as? String == userId)

            let again = try await postJSON(client, "/api/auth/device/token", body: "{\"deviceCode\":\(jsonFragment(deviceCode))}")
            #expect(again.status == .gone)
            let againBody = try JSONSerialization.jsonObject(with: Data(bodyText(again).utf8)) as? [String: Any]
            #expect(againBody?["code"] as? String == "device_code_consumed")
        }
    }
}

@Test func deviceLoginAuthorizeFailsClosedWhenTheAppURLIsEmpty() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "" }
    try await withApp { app in
        configure(app, services: deviceApp(accounts))
        try await app.testing { client in
            let response = try await postJSON(client, "/api/auth/device/authorize", body: "{\"clientName\":\"raft-computer\"}")
            #expect(response.status == .serviceUnavailable)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "DEVICE_LOGIN_URL_UNAVAILABLE")
        }
    }
}

@Test func deviceLoginDenialMakesTheTokenPollReturnAccessDenied() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "http://127.0.0.1:4173" }
    accounts.addAccount(id: "dddddddd-dddd-4ddd-8ddd-ddddddddddd4", email: "device-deny@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: deviceApp(accounts))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"device-deny@slock.test\",\"password\":\"password123\"}")
            let bearer = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let auth = try await postJSON(client, "/api/auth/device/authorize", body: "{}")
            let grant = try JSONSerialization.jsonObject(with: Data(bodyText(auth).utf8)) as? [String: Any]
            let deviceCode = grant?["deviceCode"] as? String ?? ""
            let userCode = grant?["userCode"] as? String ?? ""
            let deny = try await postJSON(
                client,
                "/api/auth/device/approve",
                body: "{\"userCode\":\(jsonFragment(userCode)),\"approve\":false}",
                authorization: "Bearer \(bearer)"
            )
            #expect(deny.status == .ok)
            let tok = try await postJSON(client, "/api/auth/device/token", body: "{\"deviceCode\":\(jsonFragment(deviceCode))}")
            #expect(tok.status == .forbidden)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(tok).utf8)) as? [String: Any]
            #expect(body?["code"] as? String == "access_denied")
        }
    }
}

@Test func deviceLoginUnknownCodesStayUniform() async throws {
    let accounts = EmailLoginDirectory()
    accounts.configureOAuthForTesting { $0.appURL = "http://127.0.0.1:4173" }
    accounts.addAccount(id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee5", email: "device-unknown@slock.test", password: "password123")
    try await withApp { app in
        configure(app, services: deviceApp(accounts))
        try await app.testing { client in
            let login = try await postJSON(client, "/api/auth/login", body: "{\"email\":\"device-unknown@slock.test\",\"password\":\"password123\"}")
            let bearer = ((try JSONSerialization.jsonObject(with: Data(bodyText(login).utf8)) as? [String: Any])?["accessToken"] as? String) ?? ""
            let tok = try await postJSON(client, "/api/auth/device/token", body: "{\"deviceCode\":\"dvc_does-not-exist\"}")
            #expect(tok.status == .badRequest)
            let tokBody = try JSONSerialization.jsonObject(with: Data(bodyText(tok).utf8)) as? [String: Any]
            #expect(tokBody?["code"] as? String == "device_code_invalid")
            let approve = try await postJSON(
                client,
                "/api/auth/device/approve",
                body: "{\"userCode\":\"ZZZZ-ZZZZ\"}",
                authorization: "Bearer \(bearer)"
            )
            #expect(approve.status == .notFound)
            let approveBody = try JSONSerialization.jsonObject(with: Data(bodyText(approve).utf8)) as? [String: Any]
            #expect(approveBody?["code"] as? String == "user_code_invalid")
        }
    }
}

private func jsonFragment(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[]".utf8)
    let text = String(decoding: data, as: UTF8.self)
    return String(text.dropFirst().dropLast())
}
