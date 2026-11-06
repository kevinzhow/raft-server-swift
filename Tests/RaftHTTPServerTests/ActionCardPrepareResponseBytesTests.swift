import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

/// The app-config bodies were hand-built with a fixed member order before the
/// migration. These assertions lock the exact bytes (and `Content-Length`), not
/// just the decoded object, so a Linux `JSONEncoder` key order cannot drift the
/// reply.
private struct AppConfigBytesFixture {
    let accounts: EmailLoginDirectory
    let writeKey: String
}

private func makeAppConfigBytesFixture() -> AppConfigBytesFixture {
    let accounts = EmailLoginDirectory()
    let serverId = "33333333-3333-4333-8333-000000990001"
    let ownerId = "11111111-1111-4111-8111-000000990001"
    accounts.addAccount(id: ownerId, email: "app-config-bytes@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(
        id: serverId,
        slug: "app-config-bytes",
        name: "App Config Bytes",
        ownerId: ownerId
    )
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "ConfigBytes")
    let writeKey = accounts.mintAgentCredential(
        agentId: agent,
        scopes: ["read", "tasks"],
        name: "app-config-bytes-write"
    )
    return AppConfigBytesFixture(accounts: accounts, writeKey: writeKey)
}

private let schemaJSON = #"{"enabled":{"type":"boolean"},"threshold_bytes":{"type":"integer","minimum":4096,"maximum":1073741824},"interval_seconds":{"type":"integer","minimum":900,"maximum":604800}}"#
private let defaultsJSON = #"{"enabled":true,"threshold_bytes":65536,"interval_seconds":3600}"#

@Test func agentAppConfigRepliesKeepTheLegacyMemberOrderBytes() async throws {
    let fixture = makeAppConfigBytesFixture()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: fixture.accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(fixture.writeKey)"
            headers[.contentType] = "application/json"

            let initialBody = #"{"appId":"system.cleaner","revision":0,"schema":"#
                + schemaJSON
                + #","defaults":"#
                + defaultsJSON
                + #","overrides":{},"effective":"#
                + defaultsJSON
                + "}"
            let initial = try await client.get(
                URI(string: "/internal/agent-api/apps/system.cleaner/config"),
                headers: headers
            )
            #expect(initial.status == .ok)
            #expect(initial.body.string == initialBody)
            #expect(initial.headers[.contentLength] == String(initialBody.utf8.count))

            let patch = try await client.send(
                .patch,
                headers: headers,
                to: "/internal/agent-api/apps/system.cleaner/config"
            ) { request in
                request.body = .init(
                    string: #"{"expectedRevision":0,"set":{"enabled":false,"threshold_bytes":131072},"unset":[]}"#
                )
            }
            let patchedBody = #"{"appId":"system.cleaner","revision":1,"schema":"#
                + schemaJSON
                + #","defaults":"#
                + defaultsJSON
                + #","overrides":{"enabled":false,"threshold_bytes":131072},"effective":{"enabled":false,"threshold_bytes":131072,"interval_seconds":3600}}"#
            #expect(patch.status == .ok)
            #expect(patch.body.string == patchedBody)
            #expect(patch.headers[.contentLength] == String(patchedBody.utf8.count))

            let stale = try await client.send(
                .patch,
                headers: headers,
                to: "/internal/agent-api/apps/system.cleaner/config"
            ) { request in
                request.body = .init(
                    string: #"{"expectedRevision":0,"set":{"enabled":true},"unset":[]}"#
                )
            }
            let staleBody = #"{"error":"Config revision is stale; current revision is 1","errorCode":"RAP_APP_CONFIG_REVISION_STALE","currentRevision":1}"#
            #expect(stale.status == .conflict)
            #expect(stale.body.string == staleBody)
            #expect(stale.headers[.contentLength] == String(staleBody.utf8.count))

            let unknown = try await client.get(
                URI(string: "/internal/agent-api/apps/system.unknown/config"),
                headers: headers
            )
            let unknownBody = #"{"error":"Unknown app","errorCode":"RAP_APP_CONFIG_APP_UNKNOWN"}"#
            #expect(unknown.status == .notFound)
            #expect(unknown.body.string == unknownBody)

            // Authorization runs before the body shape, exactly like the
            // legacy handler: a malformed body without a credential is a 401.
            let anonymous = try await client.send(
                .patch,
                headers: [.contentType: "application/json"],
                to: "/internal/agent-api/apps/system.cleaner/config"
            ) { request in
                request.body = .init(string: "not json")
            }
            let anonymousBody = #"{"error":"Missing or invalid Authorization header","code":"auth_required"}"#
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body.string == anonymousBody)

            let malformed = try await client.send(
                .patch,
                headers: headers,
                to: "/internal/agent-api/apps/system.cleaner/config"
            ) { request in
                request.body = .init(string: "not json")
            }
            let malformedBody = #"{"error":"Invalid config request","errorCode":"RAP_APP_CONFIG_INVALID"}"#
            #expect(malformed.status == .badRequest)
            #expect(malformed.body.string == malformedBody)

            // A body sent without a JSON Content-Type stays accepted, because
            // the legacy handler parsed the raw request text.
            var headerless = HTTPFields()
            headerless[.authorization] = "Bearer \(fixture.writeKey)"
            let headerlessPatch = try await client.send(
                .patch,
                headers: headerless,
                to: "/internal/agent-api/apps/system.cleaner/config"
            ) { request in
                request.body = .init(string: #"{"expectedRevision":1,"set":{"interval_seconds":1800},"unset":[]}"#)
            }
            let headerlessBody = #"{"appId":"system.cleaner","revision":2,"schema":"#
                + schemaJSON
                + #","defaults":"#
                + defaultsJSON
                + #","overrides":{"enabled":false,"threshold_bytes":131072,"interval_seconds":1800},"effective":{"enabled":false,"threshold_bytes":131072,"interval_seconds":1800}}"#
            #expect(headerlessPatch.status == .ok)
            #expect(headerlessPatch.body.string == headerlessBody)
        }
    }
}
