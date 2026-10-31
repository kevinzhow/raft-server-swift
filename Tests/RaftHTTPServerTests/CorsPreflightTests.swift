import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func apiPreflightIsCachedForTwoHours() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.origin] = "http://localhost:5173"
            headers[HTTPField.Name("Access-Control-Request-Method")!] = "GET"
            headers[HTTPField.Name("Access-Control-Request-Headers")!] = "authorization,x-server-id"
            let response = try await client.send(.options, headers: headers, to: "/api/servers")
            #expect(response.status == .noContent)
            #expect(response.headers[.origin] == nil)
            #expect(response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == "http://localhost:5173")
            #expect(response.headers[HTTPField.Name("Access-Control-Max-Age")!] == "7200")
            #expect(WebCORS.preflightMaxAgeSeconds == 7200)
        }
    }
}
