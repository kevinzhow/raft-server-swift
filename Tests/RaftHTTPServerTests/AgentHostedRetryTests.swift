import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func hostedRetryRequeuesOnlyRetryableStatesAndHonorsModelChoice() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111704"
    let memberId = "11111111-1111-4111-8111-111111111705"
    let serverId = "33333333-3333-4333-8333-333333333709"
    for (id, email, role) in [
        (ownerId, "hosted-retry-owner@slock.test", "owner"),
        (memberId, "hosted-retry-member@slock.test", "member"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
        if role == "owner" {
            accounts.oauth.addOwnedServer(id: serverId, slug: "hosted-retry", name: "Hosted Retry", ownerId: id)
        } else {
            accounts.oauth.addMember(serverId: serverId, userId: id, role: role)
        }
    }
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "hosted-retry-agent", creatorUserId: ownerId)
    let plain = accounts.oauth.createAgent(serverId: serverId, name: "plain-retry-agent", creatorUserId: ownerId)
    accounts.setHostedModelForTesting(agentId: agent)

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
            func retry(_ bearer: String, _ agentId: String? = nil, body: String? = nil) async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(bearer)"
                headers[.contentType] = "application/json"
                headers[HTTPField.Name("X-Server-Id")!] = serverId
                return try await client.send(.post, headers: headers, to: "/api/agents/\(agentId ?? agent)/hosted-runtime/retry") { request in
                    if let body { request.body = .init(string: body) }
                }
            }
            func payload(_ response: ClientResponse) -> [String: Any] {
                (try? JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8))) as? [String: Any] ?? [:]
            }
            let owner = try await token("hosted-retry-owner@slock.test")
            let member = try await token("hosted-retry-member@slock.test")

            #expect((try await retry(owner, plain)).status == .notFound)
            #expect(payload(try await retry(owner, plain))["code"] as? String == "hosted_runtime_missing")

            accounts.setHostedRuntimeStateForTesting(agentId: agent, state: "active")
            #expect((try await retry(member)).status == .forbidden)
            let active = try await retry(owner)
            #expect(active.status == .conflict)
            #expect(payload(active)["code"] as? String == "hosted_runtime_nothing_to_retry")

            accounts.setHostedRuntimeStateForTesting(agentId: agent, state: "failed", retryNeedsModel: true)
            let needsModel = try await retry(owner)
            #expect(needsModel.status == .conflict)
            #expect(payload(needsModel)["code"] as? String == "hosted_runtime_model_required")
            #expect((try await retry(owner, body: "{\"model\":\"\"}")).status == .badRequest)

            let disabledPick = try await retry(owner, body: "{\"model\":\"gpt-5.6-luna\"}")
            #expect(disabledPick.status == .forbidden)
            #expect(payload(disabledPick)["code"] as? String == "model_picker_disabled")
            let defaultPick = try await retry(owner, body: "{\"model\":\"deepseek-flash\"}")
            #expect(defaultPick.status == .ok)
            let defaultBody = payload(defaultPick)["hostedRuntime"] as? [String: Any]
            #expect(defaultBody?["state"] as? String == "provisioning")
            #expect(defaultBody?["retryNeedsModel"] as? Bool == false)

            accounts.setHostedRuntimeStateForTesting(agentId: agent, state: "failed", retryNeedsModel: true)
            accounts.enableHostedModelPicker(serverId: serverId)
            let notOffered = try await retry(owner, body: "{\"model\":\"retired-model\"}")
            #expect(notOffered.status == HTTPResponse.Status(code: 422, reasonPhrase: "Unprocessable Entity"))
            #expect(payload(notOffered)["code"] as? String == "hosted_runtime_model_not_offered")

            accounts.setHostedModelForTesting(agentId: agent, model: "gpt-5.6-luna", label: "GPT-5.6 Luna", source: "admin", locked: true)
            let locked = try await retry(owner, body: "{\"model\":\"gpt-5.6-luna\"}")
            #expect(locked.status == .conflict)
            #expect(payload(locked)["code"] as? String == "hosted_runtime_model_locked")
            let resetToDefault = try await retry(owner, body: "{\"model\":null}")
            #expect(resetToDefault.status == .ok)

            accounts.setHostedRuntimeStateForTesting(agentId: agent, state: "failed", retryNeedsModel: false)
            let plainRetry = try await retry(owner)
            #expect(plainRetry.status == .ok)
            let plainBody = payload(plainRetry)["hostedRuntime"] as? [String: Any]
            #expect(plainBody?["state"] as? String == "provisioning")
            #expect(plainBody?["provider"] as? String == "antiproton")

            accounts.setHostedRuntimeStateForTesting(agentId: agent, state: "deleting")
            #expect((try await retry(owner)).status == .ok)
        }
    }
}
