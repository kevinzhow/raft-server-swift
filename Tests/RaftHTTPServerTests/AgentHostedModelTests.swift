import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func hostedModelReadsAndPicksThroughTheServerGate() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111702"
    let memberId = "11111111-1111-4111-8111-111111111703"
    let serverId = "33333333-3333-4333-8333-333333333708"
    for (id, email, role) in [
        (ownerId, "hosted-model-owner@slock.test", "owner"),
        (memberId, "hosted-model-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "hosted-model", name: "Hosted Model", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "hosted-model-agent", creatorUserId: ownerId)
    let plain = accounts.oauth.createAgent(serverId: serverId, name: "plain-model-agent", creatorUserId: ownerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func token(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let login = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((login.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func read(_ bearer: String, _ agentId: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.get("/api/agents/\(agentId ?? agent)/hosted-runtime/model", headers: headers)
            }
            func write(_ bearer: String, _ body: String, _ agentId: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.put, headers: headers, to: "/api/agents/\(agentId ?? agent)/hosted-runtime/model") { request in
                    request.body = .init(string: body)
                }
            }
            func code(_ response: ClientResponse) -> String? {
                let object = (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any]
                return object?["code"] as? String
            }
            let owner = try await token("hosted-model-owner@slock.test")

            let missing = try await read(owner)
            #expect(missing.status == .notFound)
            #expect(code(missing) == "hosted_runtime_missing")
            #expect((try await write(owner, "{\"model\":null}")).status == .notFound)

            accounts.setHostedRuntimeForTesting(agentId: agent, provider: "antiproton", state: "provisioning")
            let notReady = try await read(owner)
            #expect(notReady.status == .conflict)
            #expect(code(notReady) == "hosted_runtime_model_not_ready")
            #expect((try await write(owner, "{\"model\":\"gpt-5.6-luna\"}")).status == .conflict)

            accounts.setHostedRuntimeForTesting(agentId: agent, provider: "antiproton", state: "active")
            let activeWithoutCatalog = try await read(owner)
            #expect(activeWithoutCatalog.status == .conflict)

            accounts.setHostedModelForTesting(agentId: agent)
            let member = try await token("hosted-model-member@slock.test")
            #expect((try await read(member)).status == .forbidden)
            #expect((try await write(member, "{\"model\":\"gpt-5.6-luna\"}")).status == .forbidden)

            let reading = try await read(owner)
            #expect(reading.status == .ok)
            #expect(reading.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let view = try JSONSerialization.jsonObject(with: Data((reading.body.string ?? "").utf8)) as? [String: Any]
            let models = view?["models"] as? [[String: Any]] ?? []
            #expect(models.map { $0["id"] as? String } == ["deepseek-flash", "gpt-5.6-luna"])
            #expect(models.map { $0["provider"] as? String } == ["deepseek", "openai"])
            #expect(view?["default"] as? String == "deepseek-flash")
            #expect(view?["defaultLabel"] as? String == "DeepSeek Flash")
            #expect(view?["model"] as? String == "deepseek-flash")
            #expect(view?["label"] as? String == "DeepSeek Flash")
            #expect(view?["source"] as? String == "default")
            #expect(view?["locked"] as? Bool == false)
            #expect(view?["picker"] as? Bool == false)

            let disabled = try await write(owner, "{\"model\":\"gpt-5.6-luna\"}")
            #expect(disabled.status == .forbidden)
            #expect(code(disabled) == "model_picker_disabled")
            for body in ["{}", "{\"model\":\"\"}", "{\"model\":3}", "{\"model\":\"\(String(repeating: "x", count: 201))\"}"] {
                let invalid = try await write(owner, body)
                #expect(invalid.status == .badRequest, "body \(body)")
                #expect(code(invalid) == "hosted_runtime_model_invalid")
            }

            accounts.enableHostedModelPicker(serverId: serverId)
            let picking = try await write(owner, "{\"model\":\"gpt-5.6-luna\"}")
            #expect(picking.status == .ok)
            #expect(picking.headers[HTTPField.Name("Cache-Control")!] == "no-store")
            let picked = try JSONSerialization.jsonObject(with: Data((picking.body.string ?? "").utf8)) as? [String: Any]
            #expect(picked?["model"] as? String == "gpt-5.6-luna")
            #expect(picked?["label"] as? String == "GPT-5.6 Luna")
            #expect(picked?["source"] as? String == "chosen")
            #expect(picked?["picker"] as? Bool == true)

            let notOffered = try await write(owner, "{\"model\":\"retired-model\"}")
            #expect(notOffered.status == HTTPResponse.Status(code: 422, reasonPhrase: "Unprocessable Entity"))
            #expect(code(notOffered) == "hosted_runtime_model_not_offered")

            let reset = try await write(owner, "{\"model\":null}")
            #expect(reset.status == .ok)
            let resetBody = try JSONSerialization.jsonObject(with: Data((reset.body.string ?? "").utf8)) as? [String: Any]
            #expect(resetBody?["model"] as? String == "deepseek-flash")
            #expect(resetBody?["source"] as? String == "default")

            let namedDefault = try await write(owner, "{\"model\":\"deepseek-flash\"}")
            #expect(namedDefault.status == .ok)
            #expect((try JSONSerialization.jsonObject(with: Data((namedDefault.body.string ?? "").utf8)) as? [String: Any])?["source"] as? String == "chosen")

            accounts.setHostedModelForTesting(agentId: agent, model: "gpt-5.6-luna", label: "GPT-5.6 Luna", source: "admin", locked: true)
            let lockedRead = try await read(owner)
            let lockedBody = try JSONSerialization.jsonObject(with: Data((lockedRead.body.string ?? "").utf8)) as? [String: Any]
            #expect(lockedBody?["locked"] as? Bool == true)
            #expect(lockedBody?["source"] as? String == "admin")
            let locked = try await write(owner, "{\"model\":\"deepseek-flash\"}")
            #expect(locked.status == .conflict)
            #expect(code(locked) == "hosted_runtime_model_locked")
            let defaultWhileLocked = try await write(owner, "{\"model\":null}")
            #expect(defaultWhileLocked.status == .ok)

            #expect((try await read(owner, plain)).status == .notFound)
            #expect((try await read(owner, "missing")).status == .notFound)
        }
    }
}
