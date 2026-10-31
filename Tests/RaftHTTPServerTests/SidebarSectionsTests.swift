import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sidebarCustomSectionsSanitizeAndVersion() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111474"
    let serverId = "33333333-3333-4333-8333-333333333581"
    accounts.addAccount(id: ownerId, email: "sidebar-sections@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "sidebar-sections", name: "Sidebar Sections", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"sidebar-sections@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId
            let channel = try await client.send(.post, headers: headers, to: "/api/channels") { request in
                request.body = .init(string: "{\"name\":\"sidebar-custom-section\"}")
            }
            let channelId = (try JSONSerialization.jsonObject(with: Data((channel.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            let staleId = UUID().uuidString.lowercased()
            func patch(_ body: String) async throws -> ([String: Any], Int) {
                let response = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/sidebar-order") { request in
                    request.body = .init(string: body)
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:], response.status.code)
            }
            let update = try await patch("{\"customSections\":[{\"id\":\"project\",\"name\":\" Project \",\"emoji\":\"📁\",\"sortMode\":\"manual\"}],\"sectionOrder\":[\"project\",\"system:pinned\"],\"sectionPlacements\":[{\"kind\":\"channel\",\"id\":\"\(channelId)\",\"sectionId\":\"project\",\"position\":9},{\"kind\":\"channel\",\"id\":\"\(staleId)\",\"sectionId\":\"project\",\"position\":10}],\"sectionsVersion\":0}")
            #expect(update.1 == 200)
            let sections = update.0["customSections"] as? [[String: Any]] ?? []
            #expect(sections.count == 1)
            #expect(sections.first?["name"] as? String == "Project")
            #expect(sections.first?["emoji"] as? String == "📁")
            #expect(update.0["sectionOrder"] as? [String] == ["project", "system:pinned", "system:joint", "system:channels", "system:dms"])
            let placements = update.0["sectionPlacements"] as? [[String: Any]] ?? []
            #expect(placements.count == 1)
            #expect(placements.first?["id"] as? String == channelId)
            #expect(placements.first?["position"] as? Int == 0)
            #expect(update.0["sectionsVersion"] as? Int == 1)

            let conflict = try await patch("{\"customSections\":[],\"sectionsVersion\":0}")
            #expect(conflict.1 == 409)
            #expect(conflict.0["code"] as? String == "SIDEBAR_SECTIONS_VERSION_CONFLICT")

            let get = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/sidebar-order")
            let getBody = try JSONSerialization.jsonObject(with: Data((get.body.string ?? "").utf8)) as? [String: Any]
            #expect((getBody?["customSections"] as? [[String: Any]])?.count == 1)
            #expect((getBody?["sectionPlacements"] as? [[String: Any]])?.count == 1)
            #expect(getBody?["sectionsVersion"] as? Int == 1)
        }
    }
}
