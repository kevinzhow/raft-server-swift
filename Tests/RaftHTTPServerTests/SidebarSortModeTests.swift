import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sidebarSortModesPersistAndSanitize() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111473"
    let serverId = "33333333-3333-4333-8333-333333333580"
    accounts.addAccount(id: ownerId, email: "sidebar-modes@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "sidebar-modes", name: "Sidebar Modes", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"sidebar-modes@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            func patch(_ body: String) async throws -> ([String: Any], Int) {
                let response = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/sidebar-order") { request in
                    request.body = .init(string: body)
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:], response.status.code)
            }

            let updated = try await patch("{\"channelSortMode\":\"recent\",\"jointChannelSortMode\":\"az\",\"dmSortMode\":\"az\",\"pinnedSortMode\":\"recent\",\"channelPanelTabOrder\":[\"files\",\"tasks\",\"chat\"],\"agentPanelTabOrder\":[\"activity\",\"permissions\",\"integrations\",\"profile\"]}")
            #expect(updated.1 == 200)
            #expect(updated.0["channelSortMode"] as? String == "recent")
            #expect(updated.0["jointChannelSortMode"] as? String == "az")
            #expect(updated.0["dmSortMode"] as? String == "az")
            #expect(updated.0["pinnedSortMode"] as? String == "recent")
            #expect(updated.0["channelPanelTabOrder"] as? [String] == ["files", "tasks", "chat"])
            #expect(updated.0["agentPanelTabOrder"] as? [String] == ["activity", "integrations", "profile"])

            let get = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/sidebar-order")
            let getBody = try JSONSerialization.jsonObject(with: Data((get.body.string ?? "").utf8)) as? [String: Any]
            #expect(getBody?["channelSortMode"] as? String == "recent")
            #expect(getBody?["agentPanelTabOrder"] as? [String] == ["activity", "integrations", "profile"])

            #expect(try await patch("{\"channelSortMode\":\"newest\"}").1 == 400)
            #expect(try await patch("{\"jointChannelSortMode\":\"newest\"}").1 == 400)
            #expect(try await patch("{\"pinnedSortMode\":\"newest\"}").1 == 400)
            #expect(try await patch("{\"channelPanelTabOrder\":\"files\"}").1 == 400)
        }
    }
}
