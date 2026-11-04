import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private let rawSecrets = ["sk-example", "sk-new-example"]

private func loadSample(_ name: String) throws -> [String: Any] {
    let path = FileManager.default.currentDirectoryPath + "/Tests/RaftHTTPServerTests/Fixtures/mobile-v1.12.0-save-requests.json"
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let samples = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["samples"] as? [String: [String: Any]] ?? [:]
    return try #require(samples[name])
}

private struct MobileFixture {
    let accounts = EmailLoginDirectory()
    let serverId: String
    let ownerId: String
    let machineId: String
    let token: String

    init(slug: String, serverId: String, ownerId: String) {
        accounts.addAccount(id: ownerId, email: "\(slug)-owner@v1120.test", password: "password123")
        accounts.markEmailVerified(userId: ownerId)
        accounts.oauth.addOwnedServer(id: serverId, slug: slug, name: "V1120 \(slug)", ownerId: ownerId)
        machineId = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "\(slug)-machine")
        token = accounts.mintAccessTokenForTesting(userId: ownerId)
        self.serverId = serverId
        self.ownerId = ownerId
    }
}

private func headers(_ fixture: MobileFixture) -> HTTPFields {
    var headers = HTTPFields()
    headers[.authorization] = "Bearer \(fixture.token)"
    headers[.contentType] = "application/json"
    headers[HTTPField.Name("X-Server-Id")!] = fixture.serverId
    return headers
}

private typealias Perform = (HTTPRequest.Method, String, String?) async throws -> (HTTPResponse.Status, String)

private func create(_ perform: Perform, _ fixture: MobileFixture, _ name: String) async throws -> (id: String, runtimeConfig: [String: Any]) {
    var body = try loadSample(name)
    body["machineId"] = fixture.machineId
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    let (status, text) = try await perform(.post, "/api/agents", payload)
    #expect(status == .ok, Comment(rawValue: text))
    for secret in rawSecrets { #expect(!text.contains(secret)) }
    let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    let id = try #require(json["id"] as? String)
    let config = json["runtimeConfig"] as? [String: Any] ?? [:]
    return (id, config)
}

private func patch(_ perform: Perform, _ fixture: MobileFixture, _ id: String, _ name: String) async throws -> [String: Any] {
    let body = try loadSample(name)
    let payload = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    let (status, text) = try await perform(.patch, "/api/agents/\(id)", payload)
    #expect(status == .ok)
    for secret in rawSecrets { #expect(!text.contains(secret)) }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

private func readBack(_ perform: Perform, _ fixture: MobileFixture, _ id: String) async throws -> (summary: [String: Any], config: [String: Any]) {
    let (status, text) = try await perform(.get, "/api/agents/\(id)", nil)
    #expect(status == .ok)
    for secret in rawSecrets { #expect(!text.contains(secret)) }
    let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    return (json, json["runtimeConfig"] as? [String: Any] ?? [:])
}

@Test func releasedMobileSaveRequestsRemainAcceptedAndSecretsStayWriteOnly() async throws {
    let presetFixture = MobileFixture(slug: "v1120-preset", serverId: "33333333-3333-4333-8333-000001089101", ownerId: "11111111-1111-4111-8111-000001089101")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: presetFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(presetFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let created = try await create(perform, presetFixture, "create.builtin.preset")
            #expect((created.runtimeConfig["provider"] as? [String: Any])?["apiKey"] as? String == "")
            let stored = try await readBack(perform, presetFixture, created.id)
            #expect(stored.summary["runtime"] as? String == "builtin")
            #expect(stored.summary["model"] as? String == "deepseek/deepseek-v4-pro")
            let provider = try #require(stored.config["provider"] as? [String: Any])
            #expect(provider["kind"] as? String == "preset")
            #expect(provider["providerId"] as? String == "deepseek")
            #expect(provider["apiKey"] as? String == "")
            let rawConfig = try #require(presetFixture.accounts.agentRuntimeConfigForTesting(agentId: created.id))
            let rawJSON = (try? JSONSerialization.jsonObject(with: Data(rawConfig.utf8))) as? [String: Any] ?? [:]
            #expect((rawJSON["provider"] as? [String: Any])?["apiKey"] as? String == "sk-example")
            #expect(stored.config["loadLocalPlugins"] as? Bool == false)
            #expect(stored.config["hostUserState"] as? String == "forbidden")
        }
    }
}

@Test func releasedGatewayAndKimiSaveRequestsPersistTheirConfig() async throws {
    let gatewayFixture = MobileFixture(slug: "v1120-gateway", serverId: "33333333-3333-4333-8333-000001089102", ownerId: "11111111-1111-4111-8111-000001089102")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: gatewayFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(gatewayFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let created = try await create(perform, gatewayFixture, "create.builtin.gateway")
            let stored = try await readBack(perform, gatewayFixture, created.id)
            let provider = try #require(stored.config["provider"] as? [String: Any])
            #expect(provider["kind"] as? String == "gateway")
            #expect(provider["baseUrl"] as? String == "https://gateway.example.test/v1")
            #expect(provider["supportsImageInput"] as? Bool == true)
            #expect(stored.config["loadLocalPlugins"] as? Bool == true)
            #expect((stored.config["envVars"] as? [String: Any])?["EXAMPLE_FLAG"] as? String == "1")
            #expect(stored.config["hostUserState"] as? String == "forbidden")
        }
    }

    let kimiFixture = MobileFixture(slug: "v1120-kimi", serverId: "33333333-3333-4333-8333-000001089103", ownerId: "11111111-1111-4111-8111-000001089103")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: kimiFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(kimiFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let explicit = try await create(perform, kimiFixture, "create.kimi-sdk.explicit-effort")
            let explicitStored = try await readBack(perform, kimiFixture, explicit.id)
            #expect(explicitStored.summary["runtime"] as? String == "kimi-sdk")
            #expect(explicitStored.summary["model"] as? String == "k2")
            #expect(explicitStored.config["reasoningEffort"] as? String == "high")
        }
    }
    let kimiDefaultFixture = MobileFixture(slug: "v1120-kimi-default", serverId: "33333333-3333-4333-8333-000001089104", ownerId: "11111111-1111-4111-8111-000001089104")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: kimiDefaultFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(kimiDefaultFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let defaultEffort = try await create(perform, kimiDefaultFixture, "create.kimi-sdk.default-effort")
            let defaultStored = try await readBack(perform, kimiDefaultFixture, defaultEffort.id)
            #expect((defaultStored.config["reasoningEffort"] as? String) == nil)
        }
    }
}

private func rawConfig(_ fixture: MobileFixture, _ agentId: String) throws -> [String: Any] {
    let raw = try #require(fixture.accounts.agentRuntimeConfigForTesting(agentId: agentId))
    return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
}

@Test func releasedMobileEditRequestsKeepOrReplaceSecretsAndEffort() async throws {
    let keepFixture = MobileFixture(slug: "v1120-keep", serverId: "33333333-3333-4333-8333-000001089105", ownerId: "11111111-1111-4111-8111-000001089105")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: keepFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(keepFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let base = try await create(perform, keepFixture, "create.builtin.gateway")
            let edited = try await patch(perform, keepFixture, base.id, "edit.builtin.keep-secret")
            #expect((edited["runtimeConfig"] as? [String: Any])?["provider"].flatMap { ($0 as? [String: Any])?["apiKey"] } as? String == "")
            let stored = try await readBack(perform, keepFixture, base.id)
            let provider = try #require(stored.config["provider"] as? [String: Any])
            #expect(provider["apiKey"] as? String == "")
            let raw = try rawConfig(keepFixture, base.id)
            #expect((raw["provider"] as? [String: Any])?["apiKey"] as? String == "sk-example")
            #expect(provider["kind"] as? String == "gateway")
            #expect(provider["baseUrl"] as? String == "https://gateway.example.test/v1")
            #expect((stored.config["envVars"] as? [String: Any])?["EXAMPLE_FLAG"] as? String == "1")
            #expect(stored.config["loadLocalPlugins"] as? Bool == false)
            #expect(stored.summary["model"] as? String == "example-model")
        }
    }

    let replaceFixture = MobileFixture(slug: "v1120-replace", serverId: "33333333-3333-4333-8333-000001089106", ownerId: "11111111-1111-4111-8111-000001089106")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: replaceFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(replaceFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let base = try await create(perform, replaceFixture, "create.builtin.gateway")
            _ = try await patch(perform, replaceFixture, base.id, "edit.builtin.replace-secret")
            let raw = try rawConfig(replaceFixture, base.id)
            #expect((raw["provider"] as? [String: Any])?["apiKey"] as? String == "sk-new-example")
            let stored = try await readBack(perform, replaceFixture, base.id)
            #expect((stored.config["provider"] as? [String: Any])?["baseUrl"] as? String == "https://gateway.example.test/v1")
        }
    }

    let effortFixture = MobileFixture(slug: "v1120-effort", serverId: "33333333-3333-4333-8333-000001089107", ownerId: "11111111-1111-4111-8111-000001089107")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: effortFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(effortFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let base = try await create(perform, effortFixture, "create.kimi-sdk.default-effort")
            _ = try await patch(perform, effortFixture, base.id, "edit.kimi-sdk.effort-picked")
            let stored = try await readBack(perform, effortFixture, base.id)
            #expect(stored.summary["runtime"] as? String == "kimi-sdk")
            #expect(stored.summary["model"] as? String == "k2")
            #expect(stored.config["reasoningEffort"] as? String == "high")
        }
    }

    let untouchedFixture = MobileFixture(slug: "v1120-untouched", serverId: "33333333-3333-4333-8333-000001089108", ownerId: "11111111-1111-4111-8111-000001089108")
    try await withApp { app in
        configure(app, services: FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, emailAccounts: untouchedFixture.accounts))
        try await app.testing { client in
            let perform: Perform = { method, path, body in
                let response = try await client.send(method, headers: headers(untouchedFixture), to: URI(string: path)) { request in
                    if let body { request.body = .init(string: body) }
                }
                return (response.status, response.body.string ?? "")
            }
            let base = try await create(perform, untouchedFixture, "create.kimi-sdk.default-effort")
            _ = try await patch(perform, untouchedFixture, base.id, "edit.kimi-sdk.untouched")
            let stored = try await readBack(perform, untouchedFixture, base.id)
            #expect(stored.summary["runtime"] as? String == "kimi-sdk")
            #expect(stored.summary["model"] as? String == "k2")
            #expect((stored.config["reasoningEffort"] as? String) == nil)
        }
    }
}
