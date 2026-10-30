import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func joinCommunityAddsAMemberAndListsTheSlugAndRole() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111317"
    let joinerId = "11111111-1111-4111-8111-111111111318"
    accounts.addAccount(id: ownerId, email: "jc-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.addAccount(id: joinerId, email: "jc-joiner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: joinerId)
    let directory = PublicVisitDirectory()
    directory.addUser(PublicVisitUser(id: ownerId, shareUsageData: nil, analyticsId: nil))
    directory.addUser(PublicVisitUser(id: joinerId, shareUsageData: nil, analyticsId: nil))
    directory.addServer(id: "33333333-3333-4333-8333-333333333486", slug: "community", memberIds: [ownerId], name: "The Community")
    directory.addServer(id: "33333333-3333-4333-8333-333333333487", slug: "community-cn", memberIds: [ownerId], name: "中文社区")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: directory,
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
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                return fields
            }
            let joinerToken = try await login("jc-joiner@slock.test")
            let ownerToken = try await login("jc-owner@slock.test")
            directory.addToken(joinerToken, userId: joinerId)
            directory.addToken(ownerToken, userId: ownerId)

            let joined = try await client.send(.post, headers: headers(joinerToken), to: "/api/servers/join-community")
            #expect(joined.status == .ok)
            let joinedBody = try JSONSerialization.jsonObject(with: Data((joined.body.string ?? "").utf8)) as? [String: Any]
            #expect(joinedBody?["serverName"] as? String == "The Community")
            #expect((joinedBody?["serverId"] as? String)?.isEmpty == false)

            let list = try await client.send(.get, headers: headers(joinerToken), to: "/api/servers")
            #expect(list.status == .ok)
            let rows = try JSONSerialization.jsonObject(with: Data((list.body.string ?? "").utf8)) as? [[String: Any]] ?? []
            let community = rows.first { $0["slug"] as? String == "community" }
            #expect(community?["role"] as? String == "member")

            let cn = try await client.send(.post, headers: headers(joinerToken), to: "/api/servers/join-community") { request in
                request.body = .init(string: "{\"slug\":\"community-cn\"}")
            }
            #expect(cn.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((cn.body.string ?? "").utf8)) as? [String: Any])?["serverName"] as? String == "中文社区")

            let unsupported = try await client.send(.post, headers: headers(joinerToken), to: "/api/servers/join-community") { request in
                request.body = .init(string: "{\"slug\":\"not-community\"}")
            }
            #expect(unsupported.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((unsupported.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String)?.lowercased().contains("unsupported") == true)

            let already = try await client.send(.post, headers: headers(ownerToken), to: "/api/servers/join-community")
            #expect(already.status == .badRequest)
            #expect(((try JSONSerialization.jsonObject(with: Data((already.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String)?.lowercased().contains("already") == true)
        }
    }

    let empty = PublicVisitDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            publicVisits: empty,
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                request.body = .init(string: "{\"email\":\"jc-joiner@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            headers[.authorization] = "Bearer \(token)"
            let missing = try await client.send(.post, headers: headers, to: "/api/servers/join-community")
            #expect(missing.status == .notFound)
            #expect(((try JSONSerialization.jsonObject(with: Data((missing.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String)?.lowercased().contains("not available") == true)

            var unauth = HTTPFields()
            unauth[.contentType] = "application/json"
            let refused = try await client.send(.post, headers: unauth, to: "/api/servers/join-community")
            #expect(refused.status == .unauthorized || refused.status == .forbidden)
        }
    }
}
