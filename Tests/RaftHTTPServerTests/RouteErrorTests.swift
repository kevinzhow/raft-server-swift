import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private struct QueryLeak: Error {
    var message: String
}

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

private func jsonObject(_ response: ClientResponse) throws -> [String: Any] {
    let data = Data(bodyText(response).utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}

private func services() -> FallbackServices {
    FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {})
}

@Test func uncaughtRouteFailureIsASanitized500() async throws {
    let leaked = "Failed query: select * from \"server_members\" where \"server_members\".\"server_id\" = $1 params: private-server-id"
    try await withApp { app in
        configure(app, services: services())
        app.get("boom") { _ async throws -> Response in
            throw QueryLeak(message: leaked)
        }
        try await app.testing { client in
            let res = try await client.get("/boom")
            #expect(res.status == .internalServerError)
            let errorId = res.headers[HTTPField.Name("X-Slock-Error-Id")!]
            #expect(errorId?.isEmpty == false)
            let body = try jsonObject(res)
            #expect(body.keys.sorted() == ["code", "correlationId", "error"])
            #expect(body["error"] as? String == "Internal server error")
            #expect(body["code"] as? String == "internal_server_error")
            #expect(body["correlationId"] as? String == errorId)
            let serialized = bodyText(res)
            #expect(serialized.contains("Failed query") == false)
            #expect(serialized.contains("server_members") == false)
            #expect(serialized.contains("params:") == false)
            #expect(serialized.contains("private-server-id") == false)
            #expect(res.headers[HTTPField.Name("X-Robots-Tag")!] == "noindex, nofollow")
        }
    }
}

@Test func explicitTypedRouteResponseIsNotRewritten() async throws {
    let body = "{\"error\":\"Machine has assigned agents\",\"code\":\"MACHINE_HAS_ASSIGNED_AGENTS\"}"
    try await withApp { app in
        configure(app, services: services())
        app.get("typed-conflict") { _ in
            routeResponse(HTTPReply(
                status: 409,
                headers: [
                    "Content-Type": AppFallback.jsonContentType,
                    "Content-Length": String(Data(body.utf8).count),
                ],
                body: body
            ))
        }
        try await app.testing { client in
            let res = try await client.get("/typed-conflict")
            #expect(res.status == .conflict)
            #expect(res.headers[HTTPField.Name("X-Slock-Error-Id")!] == nil)
            #expect(bodyText(res) == body)
        }
    }
}

@Test func risingWaveOverloadIs503OnEveryErrorPath() async throws {
    let detail = "timeout exceeded when trying to connect"
    let expected = "{\"error\":\"Temporarily overloaded, retry shortly\",\"code\":\"rw_overloaded\",\"retryable\":true}"
    try await withApp { app in
        configure(app, services: services())
        app.get("rw-overloaded") { _ async throws -> Response in
            throw RisingWaveOverloadedError(detail)
        }
        app.get("rw-overloaded-handled") { _ in
            let err = CausalRouteError(
                "load failed",
                cause: RisingWaveOverloadedError(detail)
            )
            return routeResponse(JsonServerError.send(
                error: "Failed to get inbox",
                status: 500,
                err: err
            ))
        }
        app.get("rw-overloaded-bare-catch") { _ in
            let err = RisingWaveOverloadedError(detail)
            if let reply = JsonServerError.respondToRisingWaveOverload(err) {
                return routeResponse(reply)
            }
            return routeResponse(HTTPReply(status: 500, headers: [:], body: "{\"error\":\"Failed to get unread counts\"}"))
        }
        try await app.testing { client in
            for path in ["/rw-overloaded", "/rw-overloaded-handled", "/rw-overloaded-bare-catch"] {
                let res = try await client.get(URI(string: path))
                #expect(res.status == .serviceUnavailable)
                #expect(res.headers[HTTPField.Name("Retry-After")!] == "2")
                #expect(bodyText(res) == expected)
            }
        }
    }
}

@Test func removedAppAdminRouteIs404() async throws {
    try await withApp { app in
        configure(app, services: services())
        try await app.testing { client in
            let res = try await client.get("/api/app-admin/me")
            #expect(res.status == .notFound)
            #expect(bodyText(res) == "{\"error\":\"Not found\",\"code\":\"not_found\",\"path\":\"/api/app-admin/me\"}")
        }
    }
}
