import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let migrationControlMaxBytes = 512 * 1024 + 64 * 1024

private func controlBody(bytes: Int) -> String {
    let json = "{\"control\":{\"schemaVersion\":0}}"
    let padding = String(repeating: " ", count: bytes - Data(json.utf8).count)
    return json + padding
}

private func controlPath(_ migrationId: String = UUID().uuidString) -> String {
    "/internal/computer/agent-migrations/by-id/\(migrationId)/resumable/control"
}

private func controlFixture() -> (accounts: EmailLoginDirectory, computerKey: String) {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111636"
    let serverId = "33333333-3333-4333-8333-333333333676"
    accounts.addAccount(id: ownerId, email: "control-body-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "control-body", name: "Control Body", ownerId: ownerId)
    let attach = accounts.attachComputer(
        authorization: "Bearer \(accounts.mintAccessTokenForTesting(userId: ownerId))",
        body: "{\"serverSlug\":\"control-body\",\"name\":\"control-body-computer\"}"
    )
    let body = (try? JSONSerialization.jsonObject(with: Data(attach.body.utf8))) as? [String: Any] ?? [:]
    return (accounts, body["apiKey"] as? String ?? "")
}

private func controlPost(
    _ client: any Client,
    path: String,
    body: String,
    apiKey: String?
) async throws -> ClientResponse {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Raft-Migration-Token")!] = "not-a-real-token"
    if let apiKey { headers[.authorization] = "Bearer \(apiKey)" }
    return try await client.send(.post, headers: headers, to: URI(string: path)) { request in
        request.body = .init(string: body)
    }
}

@Test func migrationControlAcceptsTheManifestAllowanceAndRejectsOneByteOver() async throws {
    let f = controlFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for bytes in [180 * 1024, migrationControlMaxBytes] {
                let res = try await controlPost(client, path: controlPath(), body: controlBody(bytes: bytes), apiKey: f.computerKey)
                #expect(res.status != .init(code: 413, reasonPhrase: "Content Too Large"), "\(bytes) bytes must reach the route; got \(res.status) headers=\(res.headers) body=\(res.body.string ?? "")")
                #expect((res.headers[.contentType] ?? "").contains("application/json"))
            }

            let over = try await controlPost(client, path: controlPath(), body: controlBody(bytes: migrationControlMaxBytes + 1), apiKey: f.computerKey)
            #expect(over.status == .init(code: 413, reasonPhrase: "Content Too Large"))
            #expect((over.headers[.contentType] ?? "").contains("application/json"))
            let overBody = (try? JSONSerialization.jsonObject(with: Data((over.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            #expect(overBody["code"] as? String == "migration_control_body_too_large")
            #expect((overBody["limitBytes"] as? NSNumber)?.intValue == migrationControlMaxBytes)
        }
    }
}

@Test func everyOtherJSONRouteKeepsTheGlobalLimit() async throws {
    let f = controlFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            let big = controlBody(bytes: 180 * 1024)
            let sibling = try await controlPost(client, path: controlPath() + "-other", body: big, apiKey: f.computerKey)
            #expect(sibling.status == .init(code: 413, reasonPhrase: "Content Too Large"), "a look-alike control path is not the raised surface")
            let send = try await controlPost(client, path: "/internal/agent-api/send", body: big, apiKey: nil)
            #expect(send.status == .init(code: 413, reasonPhrase: "Content Too Large"))
        }
    }
}

@Test func computerAuthRunsBeforeTheLargerParser() async throws {
    let f = controlFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: f.accounts))
        try await app.testing { client in
            for bytes in [180 * 1024, migrationControlMaxBytes + 1] {
                let unauthenticated = try await controlPost(client, path: controlPath(), body: controlBody(bytes: bytes), apiKey: nil)
                #expect(unauthenticated.status == .unauthorized, "\(bytes) bytes without auth must not be parsed")
                let badKey = try await controlPost(client, path: controlPath(), body: controlBody(bytes: bytes), apiKey: "sk_computer_not-a-real-key")
                #expect(badKey.status == .unauthorized)
            }
        }
    }
}
