import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func activeAnnouncementIsOldestUnreadAndDismissalPersists() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111455"
    accounts.addAccount(id: userId, email: "announcement@slock.test", password: "password123")
    accounts.markEmailVerified(userId: userId)
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let first = accounts.addAnnouncementForTesting(title: "First", pages: ["page one"], startsAt: firstDate)
    let second = accounts.addAnnouncementForTesting(title: "Second", pages: ["body1", "body2"], startsAt: firstDate.addingTimeInterval(1))

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
                request.body = .init(string: "{\"email\":\"announcement@slock.test\",\"password\":\"password123\"}")
            }
            let token = (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(token)"
            func active(_ query: String = "") async throws -> ClientResponse {
                try await client.send(.get, headers: headers, to: URI(string: "/api/announcements/active\(query)"))
            }
            func ids(_ response: ClientResponse) throws -> [String] {
                let body = try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
                return (body?["announcements"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }

            let initial = try await active()
            #expect(initial.status == .ok)
            #expect(try ids(initial) == [first])
            let initialBody = try JSONSerialization.jsonObject(with: Data((initial.body.string ?? "").utf8)) as? [String: Any]
            #expect((initialBody?["announcements"] as? [[String: Any]])?.first?["pages"] is [Any])

            let advanced = try await active("?after=\(first)")
            #expect(try ids(advanced) == [second])
            #expect(try await active("?after=not-a-uuid").status == .badRequest)

            let dismissed = try await client.send(.post, headers: headers, to: "/api/announcements/\(first)/dismiss")
            #expect(dismissed.status == .ok)
            #expect(try ids(try await active()) == [second])
            #expect(try await client.send(.post, headers: headers, to: "/api/announcements/\(UUID().uuidString.lowercased())/dismiss").status == .notFound)
            #expect(try await client.send(.get, headers: HTTPFields(), to: "/api/announcements/active").status == .unauthorized)
        }
    }
}
