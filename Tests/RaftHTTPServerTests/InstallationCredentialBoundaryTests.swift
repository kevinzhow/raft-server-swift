import Foundation
import HTTPTypes
@testable import RaftHTTP
import RaftHTTPServer
import TestSupport
import Testing
import Vapor
import VaporTesting

private let boundaryServerId = "33333333-3333-4333-8333-333333333667"
private let boundaryUserId = "11111111-1111-4111-8111-111111111642"

private func installationBoundarySetup(groups: [String]) throws -> (EmailLoginDirectory, CreatedOAuthClient, String) {
    let accounts = EmailLoginDirectory()
    accounts.oauth.addOwnedServer(id: boundaryServerId, slug: "installation-boundary-642", name: "安装 / Boundary", ownerId: boundaryUserId)
    let app = try accounts.oauth.createClient(
        serverId: boundaryServerId, createdByUserId: boundaryUserId,
        name: "Installation Boundary", clientId: "installation-boundary-642", appType: "third_party_global"
    )
    let installation = accounts.oauth.installClient(
        serverId: boundaryServerId, clientRecordId: app.id, installedByUserId: boundaryUserId, groups: groups
    )
    return (accounts, app, installation)
}

private func installationBoundaryHeaders(_ authorization: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.authorization] = authorization
    return headers
}

private func expectInstallationBoundary(
    _ response: ClientResponse, status: HTTPResponse.Status, body: String, cache: String?
) {
    #expect(response.status == status)
    #expect(response.body.string == body)
    #expect(response.headers[.contentType] == AppFallback.jsonContentType)
    #expect(response.headers[.contentLength] == String(body.utf8.count))
    #expect(response.headers[HTTPField.Name("X-Robots-Tag")!] == AppFallback.robotsTag)
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == cache)
}

private func installationBoundaryToken(_ response: ClientResponse) throws -> String {
    let object = try #require(JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
    return try #require(object["access_token"] as? String)
}

@Test func installationCredentialPublishedBytesKeepGroupsAndSeparateLiveServerRead() async throws {
    let (accounts, appClient, installation) = try installationBoundarySetup(groups: ["channel", "server", "channel"])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let basic = Data("\(appClient.clientId):\(appClient.clientSecret)".utf8).base64EncodedString()
            let minted = try await client.send(.post, headers: installationBoundaryHeaders("Basic \(basic)"), to: "/api/oauth/installation-token") {
                $0.body = .init(string: "{\"client_id\":\"wrong\",\"client_secret\":\"wrong\",\"installation_id\":\"wrong-first\",\"installation_id\":\"\(installation)\",\"installationId\":\"wrong-camel\"}")
            }
            let token = try installationBoundaryToken(minted)
            expectInstallationBoundary(minted, status: .ok,
                body: "{\"access_token\":\"\(token)\",\"token_type\":\"Bearer\",\"expires_in\":600,\"installation_id\":\"\(installation)\",\"server_id\":\"\(boundaryServerId)\",\"grant_revision\":1,\"groups\":[\"channel\",\"server\",\"channel\"],\"audience\":\"raft:app-installation-api\"}",
                cache: "private, no-store")
            let bearer = installationBoundaryHeaders("Bearer \(token)")
            let server = try await client.get("/api/app-installation/server", headers: bearer)
            expectInstallationBoundary(server, status: .ok,
                body: "{\"installation_id\":\"\(installation)\",\"server\":{\"id\":\"\(boundaryServerId)\",\"name\":\"安装 / Boundary\",\"slug\":\"installation-boundary-642\",\"avatar_url\":null}}",
                cache: "private, no-store")
            let channelsBody = "{\"installation_id\":\"\(installation)\",\"channels\":[]}"
            expectInstallationBoundary(try await client.get("/api/app-installation/channels", headers: bearer), status: .ok,
                body: channelsBody, cache: "private, no-store")
            accounts.oauth.deleteServer(id: boundaryServerId)
            expectInstallationBoundary(try await client.get("/api/app-installation/server", headers: bearer), status: .notFound,
                body: "{\"error\":\"Server not found\"}", cache: "private, no-store")
            expectInstallationBoundary(try await client.get("/api/app-installation/channels", headers: bearer), status: .ok,
                body: channelsBody, cache: "private, no-store")
        }
    }
}

@Test func installationCredentialInputRefusalsPreserveOrderAndCachePolicy() async throws {
    let (accounts, appClient, installation) = try installationBoundarySetup(groups: [])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let valid = "\"client_id\":\"\(appClient.clientId)\",\"client_secret\":\"\(appClient.clientSecret)\""
            let mintCases: [(String, HTTPResponse.Status, String)] = [
                ("{}", .unauthorized, "Client credentials are required"),
                ("{\"client_id\":\"wrong\",\"client_secret\":\"wrong\"}", .badRequest, "installation_id is required"),
                ("{\(valid),\"installation_id\":\"\",\"installationId\":\"\(installation)\"}", .badRequest, "installation_id is required"),
                ("{\"client_id\":\"wrong\",\"client_secret\":\"wrong\",\"installation_id\":\"absent\"}", .unauthorized, "Invalid client credentials"),
                ("{\(valid),\"installation_id\":\"absent\"}", .notFound, "Active installation not found"),
                ("{\(valid),\"installation_id\":\"\(installation)\"}", .badRequest, "Installation has no effective read groups"),
            ]
            for (body, status, message) in mintCases {
                let response = try await client.send(.post, headers: installationBoundaryHeaders(), to: "/api/oauth/installation-token") {
                    $0.body = .init(string: body)
                }
                expectInstallationBoundary(response, status: status, body: "{\"error\":\"\(message)\"}", cache: "private, no-store")
            }
            // The raw form parser runs independently of Content-Type; malformed Basic falls back to body fields.
            accounts.oauth.setClientOutboundGroupsForTesting(clientRecordId: appClient.id, groups: ["server"])
            accounts.oauth.state.withLock { state in
                let index = state.installations.firstIndex { $0.id == installation }!
                state.installations[index].approvedGroups = ["server"]
            }
            let form = try await client.send(.post, headers: installationBoundaryHeaders("Basic invalid"), to: "/api/oauth/installation-token") {
                $0.body = .init(string: " clientId=\(appClient.clientId)&clientSecret=\(appClient.clientSecret)&installationId=\(installation) ")
            }
            #expect(form.status == .ok)
            let token = try installationBoundaryToken(form)
            for authorization in ["bearer \(token)", "Bearer ", "Bearer slock_at_invalid", "Bearer raft_installation_invalid"] {
                let missing = !authorization.hasPrefix("Bearer ") || authorization == "Bearer "
                for path in ["/api/app-installation/server", "/api/app-installation/channels"] {
                    let response = try await client.get(URI(string: path), headers: installationBoundaryHeaders(authorization))
                    expectInstallationBoundary(response, status: .unauthorized,
                        body: missing ? "{\"error\":\"Installation bearer token is required\"}" : "{\"error\":\"Invalid, expired, or stale installation credential\"}", cache: nil)
                }
            }
            expectInstallationBoundary(try await client.get("/api/app-installation/channels", headers: installationBoundaryHeaders("Bearer \(token)")),
                status: .forbidden, body: "{\"error\":\"Installation credential lacks channel read authority\"}", cache: "private, no-store")
        }
    }
}

@Test(arguments: ["revision", "groups", "expiry", "audience", "disabled"])
func installationCredentialReadsRejectLiveChangesWithoutCaching(reason: String) async throws {
    let (accounts, appClient, installation) = try installationBoundarySetup(groups: ["server", "channel"])
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            let minted = try await client.send(.post, headers: installationBoundaryHeaders(), to: "/api/oauth/installation-token") {
                $0.body = .init(string: "{\"clientId\":\"\(appClient.clientId)\",\"clientSecret\":\"\(appClient.clientSecret)\",\"installationId\":\"\(installation)\"}")
            }
            #expect(minted.status == .ok)
            let token = try installationBoundaryToken(minted)
            accounts.oauth.state.withLock { state in
                switch reason {
                case "revision": state.installations[0].grantRevision += 1
                case "groups": state.clients[0].outboundGroups = ["server"]
                case "expiry": state.installationTokens[0].expiresAt = .distantPast
                case "audience": state.installationTokens[0].audience = "another-api"
                default: state.clients[0].enabled = false
                }
            }
            for path in ["/api/app-installation/server", "/api/app-installation/channels"] {
                expectInstallationBoundary(try await client.get(URI(string: path), headers: installationBoundaryHeaders("Bearer \(token)")),
                    status: .unauthorized, body: "{\"error\":\"Invalid, expired, or stale installation credential\"}", cache: nil)
            }
        }
    }
}
