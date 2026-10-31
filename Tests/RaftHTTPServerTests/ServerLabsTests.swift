import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func serverLabsEnforceOwnerAccessAdminEnrollmentAndVersionCAS() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111337"
    let adminId = "11111111-1111-4111-8111-111111111338"
    let memberId = "11111111-1111-4111-8111-111111111339"
    let outsiderId = "11111111-1111-4111-8111-111111111340"
    let serverId = "33333333-3333-4333-8333-333333333501"
    for (id, email) in [
        (ownerId, "labs-owner@slock.test"),
        (adminId, "labs-admin@slock.test"),
        (memberId, "labs-member@slock.test"),
        (outsiderId, "labs-outsider@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "labs", name: "Labs", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String, server: String = serverId) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = server
                return fields
            }
            let ownerToken = try await login("labs-owner@slock.test")
            let adminToken = try await login("labs-admin@slock.test")
            let memberToken = try await login("labs-member@slock.test")
            let outsiderToken = try await login("labs-outsider@slock.test")
            let base = "/api/servers/\(serverId)/labs"
            func json(_ response: ClientResponse) throws -> [String: Any] {
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }

            var noAuth = HTTPFields()
            noAuth[HTTPField.Name("X-Server-Id")!] = serverId
            #expect(try await client.send(.get, headers: noAuth, to: URI(string: base)).status == .unauthorized)
            #expect(try await client.send(.get, headers: headers(ownerToken, server: UUID().uuidString.lowercased()), to: URI(string: base)).status != .ok)
            #expect(try await client.send(.get, headers: headers(outsiderToken), to: URI(string: base)).status == .forbidden)

            let memberRead = try await client.send(.get, headers: headers(memberToken), to: URI(string: base))
            #expect(memberRead.status == .ok)
            let memberBody = try json(memberRead)
            #expect(memberBody["accessEnabled"] as? Bool == false)
            #expect(memberBody["version"] as? Int == 0)
            #expect(memberBody["canManageAccess"] as? Bool == false)
            #expect(memberBody["canManageEnrollments"] as? Bool == false)
            let labs = memberBody["labs"] as? [[String: Any]] ?? []
            #expect(labs.compactMap { $0["labKey"] as? String } == ["open_lab", "paused_lab"])

            let adminMaster = try await client.send(.patch, headers: headers(adminToken), to: "\(base)/access") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":0}")
            }
            #expect(adminMaster.status == .forbidden)

            let ownerMaster = try await client.send(.patch, headers: headers(ownerToken), to: "\(base)/access") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":0}")
            }
            #expect(ownerMaster.status == .ok)
            let ownerBody = try json(ownerMaster)
            #expect(ownerBody["applied"] as? Bool == true)
            #expect(ownerBody["version"] as? Int == 1)

            let sameMaster = try await client.send(.patch, headers: headers(ownerToken), to: "\(base)/access") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":1}")
            }
            #expect(try json(sameMaster)["applied"] as? Bool == false)

            let staleMaster = try await client.send(.patch, headers: headers(ownerToken), to: "\(base)/access") { request in
                request.body = .init(string: "{\"enabled\":false,\"expectedVersion\":0}")
            }
            #expect(staleMaster.status == .conflict)
            let staleBody = try json(staleMaster)
            #expect(staleBody["code"] as? String == "server_labs_version_conflict")
            #expect(staleBody["currentVersion"] as? Int == 1)

            let memberEnroll = try await client.send(.put, headers: headers(memberToken), to: "\(base)/open_lab") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":1}")
            }
            #expect(memberEnroll.status == .forbidden)

            let adminEnroll = try await client.send(.put, headers: headers(adminToken), to: "\(base)/open_lab") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":1}")
            }
            #expect(adminEnroll.status == .ok)
            let adminBody = try json(adminEnroll)
            #expect(adminBody["applied"] as? Bool == true)
            #expect(adminBody["version"] as? Int == 2)
            let enrolled = (adminBody["labs"] as? [[String: Any]] ?? []).first { $0["labKey"] as? String == "open_lab" }
            #expect(enrolled?["enrolled"] as? Bool == true)
            #expect(enrolled?["effective"] as? Bool == true)
            #expect(enrolled?["updatedAt"] is String)

            let sameEnroll = try await client.send(.put, headers: headers(adminToken), to: "\(base)/open_lab") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":2}")
            }
            #expect(try json(sameEnroll)["applied"] as? Bool == false)

            let staleEnroll = try await client.send(.put, headers: headers(adminToken), to: "\(base)/open_lab") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":1}")
            }
            #expect(staleEnroll.status == .conflict)
            #expect(try json(staleEnroll)["currentVersion"] as? Int == 2)

            let paused = try await client.send(.put, headers: headers(adminToken), to: "\(base)/paused_lab") { request in
                request.body = .init(string: "{\"enabled\":true,\"expectedVersion\":2}")
            }
            #expect(paused.status == .conflict)
            #expect(try json(paused)["code"] as? String == "lab_not_open")

            let masterOff = try await client.send(.patch, headers: headers(ownerToken), to: "\(base)/access") { request in
                request.body = .init(string: "{\"enabled\":false,\"expectedVersion\":2}")
            }
            #expect(try json(masterOff)["version"] as? Int == 3)
            let offLabs = (try json(masterOff)["labs"] as? [[String: Any]] ?? [])
            #expect(offLabs.first { $0["labKey"] as? String == "open_lab" }?["enrolled"] as? Bool == true)
            #expect(offLabs.first { $0["labKey"] as? String == "open_lab" }?["effective"] as? Bool == false)

            let disabledEnroll = try await client.send(.put, headers: headers(adminToken), to: "\(base)/open_lab") { request in
                request.body = .init(string: "{\"enabled\":false,\"expectedVersion\":3}")
            }
            #expect(disabledEnroll.status == .conflict)
            #expect(try json(disabledEnroll)["code"] as? String == "server_labs_access_disabled")
        }
    }
}
