import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func setupDeclarationRoundTripsThroughHTTPAndIsRevisionBound() async throws {
    let accounts = EmailLoginDirectory()
    let sourceId = "33333333-3333-4333-8333-000001078001"
    let targetId = "33333333-3333-4333-8333-000001078002"
    let ownerId = "11111111-1111-4111-8111-000001078001"
    accounts.addAccount(id: ownerId, email: "setup-route@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: sourceId, slug: "publisher", name: "Publisher", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: targetId, slug: "installed", name: "Installed", ownerId: ownerId)
    let created = try accounts.oauth.createClient(
        serverId: sourceId, createdByUserId: ownerId, name: "Setup App", clientId: "setup-route-app",
        returnUrl: "https://setup.example.test/callback",
        setupUrl: "https://setup.example.test/configure", setupDescription: "Choose a repository"
    )
    accounts.oauth.setClientAppType(clientRecordId: created.id, appType: "third_party_global")
    accounts.oauth.publishClient(clientRecordId: created.id, humanMarketplaceVisible: true)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        try await app.testing { client in
            var loginHeaders = HTTPFields()
            loginHeaders[.contentType] = "application/json"
            let login = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"setup-route@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = targetId
            let sourceHeaders: HTTPFields = {
                var value = headers
                value[HTTPField.Name("X-Server-Id")!] = sourceId
                return value
            }()

            let beforeInstall = try await client.get(URI(string: "/api/integrations/clients/\(created.id)/setup"), headers: headers)
            #expect(beforeInstall.status == .notFound)

            let install = try await client.post(URI(string: "/api/integrations/marketplace/\(created.id)/install"), headers: headers)
            #expect(install.status == .ok)
            let installed = try JSONSerialization.jsonObject(with: Data((install.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            let installationId = installed["id"] as? String ?? ""

            let read = try await client.get(URI(string: "/api/integrations/clients/\(created.id)/setup"), headers: headers)
            #expect(read.status == .ok)
            let first = try JSONSerialization.jsonObject(with: Data((read.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(first["status"] as? String == "pending")
            #expect(first["canConfigure"] as? Bool == true)
            #expect(first["revision"] as? Int == 1)
            let url = first["url"] as? String ?? ""
            #expect(url.contains("installation_id=\(installationId)"))
            #expect(url.contains("server_id=\(targetId)"))
            #expect(url.contains("setup_revision=1"))

            func report(_ revision: Int, _ status: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                var reportHeaders = HTTPFields()
                reportHeaders[.contentType] = "application/json"
                let response = try await client.send(.put, headers: reportHeaders, to: "/api/oauth/installations/\(installationId)/setup") { request in
                    request.body = .init(string: "{\"clientId\":\"setup-route-app\",\"clientSecret\":\"\(created.clientSecret)\",\"revision\":\(revision),\"status\":\"\(status)\"}")
                }
                return (response.status, (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:])
            }
            let staleReport = try await report(2, "complete")
            #expect(staleReport.0 == .conflict)
            let complete = try await report(1, "complete")
            #expect(complete.0 == .ok)
            #expect(complete.1["status"] as? String == "complete")
            let replay = try await report(1, "complete")
            #expect(replay.0 == .ok)
            #expect(accounts.oauth.integrationAuditEventCount(eventType: "installation.setup_updated") == 1)

            let patch = try await client.send(.patch, headers: sourceHeaders, to: "/api/integrations/clients/\(created.id)") { request in
                request.body = .init(string: "{\"setupUrl\":\"https://setup.example.test/revised\"}")
            }
            #expect(patch.status == .ok)
            let patched = try JSONSerialization.jsonObject(with: Data((patch.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(patched["setupRevision"] as? Int == 2)

            let afterPatch = try await client.get(URI(string: "/api/integrations/clients/\(created.id)/setup"), headers: headers)
            let pending = try JSONSerialization.jsonObject(with: Data((afterPatch.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            #expect(pending["status"] as? String == "pending")
            #expect(pending["revision"] as? Int == 2)
            #expect((try await report(1, "complete")).0 == .conflict)
            #expect((try await report(2, "complete")).0 == .ok)

            let uninstall = try await client.send(.delete, headers: headers, to: "/api/integrations/marketplace/\(created.id)/install")
            #expect(uninstall.status == .ok)
            #expect((try await client.get(URI(string: "/api/integrations/clients/\(created.id)/setup"), headers: headers)).status == .notFound)
            #expect((try await report(2, "complete")).0 == .notFound)
        }
    }
}
