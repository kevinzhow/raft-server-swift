import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentArchiveOnlyAcceptsKeepOrDeleteWorkspace() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111561"
    let serverId = "33333333-3333-4333-8333-333333333628"
    accounts.addAccount(id: ownerId, email: "archive-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "archive", name: "Archive", ownerId: ownerId)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "archive-machine")

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
                request.body = .init(string: "{\"email\":\"archive-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let created = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"ArchiveBot\",\"machineId\":\"\(machine)\"}")
            }
            #expect(created.status == .ok)
            let agent = (try JSONSerialization.jsonObject(with: Data((created.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            for workspace in ["backup", "shred"] {
                let response = try await client.send(.delete, headers: headers, to: "/api/agents/\(agent)") { request in
                    request.body = .init(string: "{\"workspace\":\"\(workspace)\"}")
                }
                #expect(response.status == .badRequest)
                #expect((try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["code"] as? String == "archive_workspace_choice_invalid")
                var checkHeaders = headers
                checkHeaders[.authorization] = "Bearer \(token)"
                #expect(try await client.send(.get, headers: checkHeaders, to: "/api/agents/\(agent)").status == .ok)
            }
            let archived = try await client.send(.delete, headers: headers, to: "/api/agents/\(agent)") { request in
                request.body = .init(string: "{\"workspace\":\"keep\"}")
            }
            #expect(archived.status == .ok)
            #expect(try await client.send(.get, headers: headers, to: "/api/agents/\(agent)").status == .notFound)
            let memberId = "11111111-1111-4111-8111-111111111571"
            accounts.addAccount(id: memberId, email: "archive-member@slock.test", password: "password123")
            accounts.markEmailVerified(userId: memberId)
            accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
            let memberLogin = try await client.send(.post, headers: loginHeaders, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"archive-member@slock.test\",\"password\":\"password123\"}")
            }
            let memberToken = (try JSONSerialization.jsonObject(with: Data((memberLogin.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var memberHeaders = headers
            memberHeaders[.authorization] = "Bearer \(memberToken)"
            #expect(try await client.send(.get, headers: memberHeaders, to: "/api/agents/\(agent)/archive").status == .forbidden)

            let archive = try await client.send(.get, headers: headers, to: "/api/agents/\(agent)/archive")
            #expect(archive.status == .ok)
            let archiveBody = try JSONSerialization.jsonObject(with: Data((archive.body.string ?? "").utf8)) as? [String: Any]
            let snapshot = archiveBody?["archive"] as? [String: Any]
            #expect(snapshot?["workspaceState"] as? String == "on_computer")
            #expect(snapshot?["machineName"] as? String == "archive-machine")
            #expect(try await client.send(.post, headers: memberHeaders, to: "/api/agents/\(agent)/archive/workspace") { request in
                request.body = .init(string: "{\"action\":\"delete\"}")
            }.status == .forbidden)
            let workspaceAction = try await client.send(.post, headers: headers, to: "/api/agents/\(agent)/archive/workspace") { request in
                request.body = .init(string: "{\"action\":\"delete\"}")
            }
            #expect(workspaceAction.status == .ok)
            let afterAction = try await client.send(.get, headers: headers, to: "/api/agents/\(agent)/archive")
            let afterSnapshot = (try JSONSerialization.jsonObject(with: Data((afterAction.body.string ?? "").utf8)) as? [String: Any])?["archive"] as? [String: Any]
            #expect(afterSnapshot?["workspaceState"] as? String == "on_computer")
            #expect(afterSnapshot?["pendingOp"] as? String == "delete")

            let second = try await client.send(.post, headers: headers, to: "/api/agents") { request in
                request.body = .init(string: "{\"name\":\"DeleteBot\",\"machineId\":\"\(machine)\"}")
            }
            let secondId = (try JSONSerialization.jsonObject(with: Data((second.body.string ?? "").utf8)) as? [String: Any])?["id"] as? String ?? ""
            #expect(try await client.send(.delete, headers: headers, to: "/api/agents/\(secondId)") { request in
                request.body = .init(string: "{\"workspace\":\"delete\"}")
            }.status == .ok)
            let deletedView = try await client.send(.get, headers: headers, to: "/api/agents/\(secondId)/archive")
            let deletedSnapshot = (try JSONSerialization.jsonObject(with: Data((deletedView.body.string ?? "").utf8)) as? [String: Any])?["archive"] as? [String: Any]
            #expect(deletedSnapshot?["workspaceState"] as? String == "on_computer")
            #expect(deletedSnapshot?["pendingOp"] as? String == "delete")
        }
    }
}
