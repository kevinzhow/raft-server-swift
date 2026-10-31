import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverSwitcherOrderPersistsSanitizesAndBumpsVersionOnChange() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111363"
    let serverA = "33333333-3333-4333-8333-333333333510"
    let serverB = "33333333-3333-4333-8333-333333333511"
    accounts.addAccount(id: ownerId, email: "order-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverA, slug: "order-a", name: "Order A", ownerId: ownerId)
    accounts.oauth.addOwnedServer(id: serverB, slug: "order-b", name: "Order B", ownerId: ownerId)

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
                request.body = .init(string: "{\"email\":\"order-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            func list() async throws -> [[String: Any]] {
                let response = try await client.send(.get, headers: headers, to: "/api/servers")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            }
            func order() async throws -> (ids: [String], version: Int) {
                let response = try await client.send(.get, headers: headers, to: "/api/servers/order")
                #expect(response.status == .ok)
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["serverOrder"] as? [String] ?? [], body?["serverOrderVersion"] as? Int ?? -1)
            }
            func patch(_ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers, to: "/api/servers/order") { request in
                    request.body = .init(string: body)
                }
            }

            let initialList = try await list()
            #expect(initialList.compactMap { $0["id"] as? String } == [serverA, serverB])
            #expect(initialList.allSatisfy { $0["serverOrderVersion"] as? Int == 0 })
            #expect(try await order().ids == [serverA, serverB])
            #expect(try await order().version == 0)

            let firstPatch = try await patch("{\"serverOrder\":[\"\(serverB)\",\"not-a-server\",\"\(serverA)\",\"\(serverB)\"]}")
            #expect(firstPatch.status == .ok)
            let firstBody = try JSONSerialization.jsonObject(with: Data((firstPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(firstBody?["serverOrder"] as? [String] == [serverB, serverA])
            #expect(firstBody?["serverOrderVersion"] as? Int == 1)

            #expect(try await order().ids == [serverB, serverA])
            #expect(try await order().version == 1)
            #expect(try await list().compactMap { $0["id"] as? String } == [serverB, serverA])
            #expect(try await list().allSatisfy { $0["serverOrderVersion"] as? Int == 1 })

            let noOp = try await patch("{\"serverOrder\":[\"\(serverB)\",\"\(serverA)\"]}")
            let noOpBody = try JSONSerialization.jsonObject(with: Data((noOp.body.string ?? "").utf8)) as? [String: Any]
            #expect(noOpBody?["serverOrderVersion"] as? Int == 1)

            let secondPatch = try await patch("{\"serverOrder\":[\"\(serverA)\",\"\(serverB)\"]}")
            let secondBody = try JSONSerialization.jsonObject(with: Data((secondPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(secondBody?["serverOrder"] as? [String] == [serverA, serverB])
            #expect(secondBody?["serverOrderVersion"] as? Int == 2)

            let invalid = try await patch("{\"serverOrder\":\"\(serverA)\"}")
            #expect(invalid.status == .badRequest)
        }
    }
}

@Test func serverOrderVersionStaysMonotonicAfterLosingAMembership() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111364"
    let serverA = "33333333-3333-4333-8333-333333333512"
    let serverB = "33333333-3333-4333-8333-333333333513"
    let serverC = "33333333-3333-4333-8333-333333333514"
    accounts.addAccount(id: ownerId, email: "order-mono-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    for (id, slug) in [(serverA, "mono-a"), (serverB, "mono-b"), (serverC, "mono-c")] {
        accounts.oauth.addOwnedServer(id: id, slug: slug, name: slug, ownerId: ownerId)
    }
    accounts.seedServerSwitcherOrder(userId: ownerId, ids: [serverA, serverB, serverC], version: 7)

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
                request.body = .init(string: "{\"email\":\"order-mono-owner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            headers[.contentType] = "application/json"

            func order() async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers, to: "/api/servers/order")
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            let seeded = try await order()
            #expect(seeded["serverOrder"] as? [String] == [serverA, serverB, serverC])
            #expect(seeded["serverOrderVersion"] as? Int == 7)

            accounts.oauth.removeMember(serverId: serverA, userId: ownerId)
            let patched = try await client.send(.patch, headers: headers, to: "/api/servers/order") { request in
                request.body = .init(string: "{\"serverOrder\":[\"\(serverC)\",\"\(serverB)\"]}")
            }
            #expect(patched.status == .ok)
            let patchedBody = try JSONSerialization.jsonObject(with: Data((patched.body.string ?? "").utf8)) as? [String: Any]
            #expect(patchedBody?["serverOrder"] as? [String] == [serverC, serverB])
            #expect(patchedBody?["serverOrderVersion"] as? Int == 8)

            let listed = try await client.send(.get, headers: headers, to: "/api/servers")
            let rows = try JSONSerialization.jsonObject(with: Data((listed.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            #expect(rows.compactMap { $0["id"] as? String } == [serverC, serverB])
            #expect(rows.allSatisfy { $0["serverOrderVersion"] as? Int == 8 })
        }
    }
}
