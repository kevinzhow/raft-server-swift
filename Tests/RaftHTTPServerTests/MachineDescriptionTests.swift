import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func machineDescriptionIsTrimmedAndClearedWhenBlank() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111379"
    let serverId = "33333333-3333-4333-8333-333333333522"
    accounts.addAccount(id: ownerId, email: "machine-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "machine-description", name: "Machine Description", ownerId: ownerId)
    let machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "described-machine")

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
                request.body = .init(string: "{\"email\":\"machine-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"
            headers[HTTPField.Name("X-Server-Id")!] = serverId

            let update = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/machines/\(machineId)") { request in
                request.body = .init(string: "{\"description\":\"  Runs the staging smoke tests  \"}")
            }
            #expect(update.status == .ok)
            let updateBody = try JSONSerialization.jsonObject(with: Data((update.body.string ?? "").utf8)) as? [String: Any]
            #expect(updateBody?["name"] as? String == "described-machine")
            #expect(updateBody?["description"] as? String == "Runs the staging smoke tests")

            let list = try await client.send(.get, headers: headers, to: "/api/servers/\(serverId)/machines")
            let listBody = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [String: Any]
            let machines = listBody?["machines"] as? [[String: Any]] ?? []
            #expect(machines.first { $0["id"] as? String == machineId }?["description"] as? String == "Runs the staging smoke tests")

            let clear = try await client.send(.patch, headers: headers, to: "/api/servers/\(serverId)/machines/\(machineId)") { request in
                request.body = .init(string: "{\"description\":\"   \"}")
            }
            #expect(clear.status == .ok)
            let clearBody = try JSONSerialization.jsonObject(with: Data((clear.body.string ?? "").utf8)) as? [String: Any]
            #expect(clearBody?["description"] == nil || clearBody?["description"] is NSNull)
        }
    }
}
