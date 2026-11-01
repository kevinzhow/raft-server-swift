import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func agentCredentialMintRouteIsMountedAndAuthenticated() async throws {
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
            headers[.contentType] = "application/json"
            let mint = try await client.send(.post, headers: headers, to: "/api/agents/agent-unknown/credentials") { request in
                request.body = .init(string: "{}")
            }
            #expect(mint.status != .notFound)
            #expect(mint.status == .unauthorized || mint.status == .forbidden)

            let read = try await client.send(.get, headers: headers, to: "/api/agents/agent-unknown/credentials")
            #expect(read.status == .unauthorized)
            let remove = try await client.send(.delete, headers: headers, to: "/api/agents/agent-unknown/credentials/credential-unknown")
            #expect(remove.status == .unauthorized)
        }
    }
}
