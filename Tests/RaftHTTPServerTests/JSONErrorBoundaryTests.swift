import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func sanitizesUncaught5xxRouteFailures() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        app.get("boom") { _ -> Response in
            struct Boom: Error {}
            throw Boom()
        }
        try await app.testing { client in
            let response = try await client.get("/boom")
            #expect(response.status == .internalServerError)
            let correlationId = response.headers[JSONErrorBoundaryMiddleware.errorHeader]
            #expect((correlationId ?? "").isEmpty == false)
            let body = try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
            #expect(Set(body.keys) == ["error", "code", "correlationId"])
            #expect(body["error"] as? String == "Internal server error")
            #expect(body["code"] as? String == "internal_server_error")
            #expect(body["correlationId"] as? String == correlationId)
        }
    }
}

@Test func doesNotRewriteExplicitTypedRouteResponses() async throws {
    let accounts = EmailLoginDirectory()
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts
        ))
        app.get("typed-conflict") { _ -> Response in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .conflict, headers: headers, body: .init(string: #"{"error":"Machine has assigned agents","code":"MACHINE_HAS_ASSIGNED_AGENTS"}"#))
        }
        try await app.testing { client in
            let response = try await client.get("/typed-conflict")
            #expect(response.status == .conflict)
            #expect(response.headers[JSONErrorBoundaryMiddleware.errorHeader] == nil)
            let body = try #require(try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])
            #expect(body["error"] as? String == "Machine has assigned agents")
            #expect(body["code"] as? String == "MACHINE_HAS_ASSIGNED_AGENTS")
        }
    }
}
