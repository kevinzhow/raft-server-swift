import Foundation
import HTTPTypes
import RaftShared
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting
@testable import RaftHTTP

/// Actual existing-owner codecs, read only. No coordinator, state injection or fake producer.
private func runtimeBoundarySnapshot(_ accounts: EmailLoginDirectory) throws -> [Data] {
    let bindings = try accounts.makeDurableBindings()
    try #require(bindings.count == 14 && Set(bindings.map(\.key)).count == 14)
    return try bindings.map { try $0.encode() }
}

@Test func ownedRuntimeMetadataDoesNotBypassMissingExecutionProducer() async throws {
    let accounts = EmailLoginDirectory()
    let owner = UUID().uuidString.lowercased()
    let server = UUID().uuidString.lowercased()
    accounts.addAccount(id: owner, email: "runtime-boundary@test.invalid", password: "password123")
    accounts.markEmailVerified(userId: owner)
    accounts.oauth.addOwnedServer(id: server, slug: "runtime-boundary", name: "Runtime boundary", ownerId: owner)
    let machine = accounts.registerMachine(serverId: server, userId: owner, name: "Actual owned metadata assignment")
    let token = accounts.mintAccessTokenForTesting(userId: owner)
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = server
    let requestHeaders = headers
    let codex: JSONValue = .object(["version": .integer(1), "runtime": .string("codex"),
        "model": .object(["kind": .string("preset"), "id": .string("gpt-5.3-codex")]), "mode": .object(["kind": .string("default")])])
    let claude: JSONValue = .object(["version": .integer(1), "runtime": .string("claude"),
        "model": .object(["kind": .string("preset"), "id": .string("sonnet")]), "mode": .object(["kind": .string("default")])])
    let fixturePath = FileManager.default.currentDirectoryPath + "/Tests/RaftHTTPServerTests/Fixtures/mobile-v1.12.0-save-requests.json"
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
    guard case .object(let root) = fixture, case .object(let samples)? = root["samples"],
          case .object(var builtinCreate)? = samples["create.builtin.gateway"], let builtin = builtinCreate["runtimeConfig"] else {
        Issue.record("Missing existing released gateway sample")
        return
    }
    builtinCreate["machineId"] = .string(machine)
    let builtinFields = builtinCreate
    try await withApp { app in
        // Natural existing unbound app: no persistence/execution producer is installed.
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: accounts))
        try await app.testing { client in
            func request(_ method: HTTPRequest.Method, _ path: String, fields: [String: JSONValue]? = nil) async throws -> ClientResponse {
                let data = try fields.map { try JSONEncoder().encode(JSONValue.object($0)) }
                return try await client.send(method, headers: requestHeaders, to: URI(string: path)) { request in
                    if let data { request.body = .init(data: data) }
                }
            }
            func object(_ response: ClientResponse) throws -> [String: JSONValue] {
                guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: Data((response.body.string ?? "").utf8)) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected published JSON object"))
                }
                return fields
            }
            let madeCodex = try await request(.post, "/api/agents", fields: ["name": .string("Runtime boundary codex"), "machineId": .string(machine), "runtimeConfig": codex])
            try #require(madeCodex.status == .ok)
            let codexObject = try object(madeCodex)
            guard case .string(let codexId)? = codexObject["id"] else { Issue.record("Expected actual created Codex identity"); return }
            let madeBuiltin = try await request(.post, "/api/agents", fields: builtinFields)
            try #require(madeBuiltin.status == .ok)
            let builtinObject = try object(madeBuiltin)
            guard case .string(let builtinId)? = builtinObject["id"] else { Issue.record("Expected actual created Builtin identity"); return }
            let cases: [(String, [String: JSONValue])] = [
                (codexId, ["runtimeConfig": codex, "restartMode": .string("restart")]),
                (codexId, ["runtimeConfig": builtin, "runtime": .string("builtin"), "restartMode": .string("restart")]),
                (builtinId, ["runtimeConfig": codex, "runtime": .string("codex"), "restartMode": .string("restart")]),
                (builtinId, ["runtimeConfig": claude, "runtime": .string("claude"), "restartMode": .string("restart")]),
            ]
            for (agent, fields) in cases {
                let beforeRead = try await request(.get, "/api/agents/\(agent)")
                try #require(beforeRead.status == .ok)
                let before = try runtimeBoundarySnapshot(accounts)
                var body = fields
                body["displayName"] = .string("Refused metadata must not commit")
                let refused = try await request(.patch, "/api/agents/\(agent)", fields: body)
                #expect(refused.status == .internalServerError)
                let errorOnly = try object(refused) == ["error": .string("Failed to update agent")]
                #expect(errorOnly)
                let after = try runtimeBoundarySnapshot(accounts)
                let allOwnerPayloadsUnchanged = before == after
                #expect(allOwnerPayloadsUnchanged)
                let afterRead = try await request(.get, "/api/agents/\(agent)")
                #expect(afterRead.status == .ok)
                let publishedProfileUnchanged = beforeRead.body.string == afterRead.body.string
                #expect(publishedProfileUnchanged)
            }
        }
    }
}
