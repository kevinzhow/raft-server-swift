import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

@Test func experimentalInternalSurfacesShareAnOperatorKillSwitch() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111112001"
    let serverId = "33333333-3333-4333-8333-333333334001"
    accounts.addAccount(id: ownerId, email: "kill-switch-owner@slock.test", password: "password123")
    accounts.markEmailVerified(userId: ownerId)
    accounts.oauth.addOwnedServer(id: serverId, slug: "kill-switch", name: "Kill Switch", ownerId: ownerId)
    let agent = accounts.oauth.createAgent(serverId: serverId, name: "KillSwitchBot", runtime: "claude")
    let channel = accounts.oauth.createChannel(serverId: serverId, name: "kill-switch-room", creatorUserId: ownerId)
    accounts.addPostableChannel(serverId: serverId, channelId: channel, memberId: ownerId, name: "kill-switch-room")
    accounts.oauth.addChannelHuman(channelId: channel, userId: ownerId)
    accounts.oauth.addChannelAgent(channelId: channel, agentId: agent)
    let machine = accounts.registerMachine(serverId: serverId, userId: ownerId, name: "kill-switch-machine")
    let machineKey = accounts.machineAPIKey(machineId: machine) ?? ""
    let agentKey = accounts.mintAgentCredential(agentId: agent, scopes: ["read"], name: "kill-switch-agent")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func agentApi() async throws -> ClientResponse {
                var headers = HTTPFields()
                headers[.authorization] = "Bearer \(agentKey)"
                return try await client.get("/internal/agent-api", headers: headers)
            }
            let enabled = try await agentApi()
            #expect(enabled.status == .ok)

            accounts.setExperimentalSurfacesDisabledForTesting(true)
            let disabled = try await agentApi()
            #expect(disabled.status == .serviceUnavailable)
            #expect(disabled.headers[HTTPField.Name("Sec-Slock-Api-Version")!] == "1")
            #expect(try JSONSerialization.jsonObject(with: Data((disabled.body.string ?? "").utf8)) as? NSDictionary == [
                "error": "Experimental internal surface is disabled",
                "code": "experimental_surface_disabled",
                "retry_after": NSNull(),
            ] as NSDictionary)

            var computerHeaders = HTTPFields()
            computerHeaders[.authorization] = "Bearer \(machineKey)"
            computerHeaders[.contentType] = "application/json"
            let computer = try await client.send(.post, headers: computerHeaders, to: "/internal/computer/runners/\(agent)/credentials") { request in
                request.body = .init(string: "{\"scopes\":[\"read\"]}")
            }
            #expect(computer.status == .serviceUnavailable)
            #expect(computer.headers[HTTPField.Name("Sec-Slock-Api-Version")!] == "1")
            #expect(try JSONSerialization.jsonObject(with: Data((computer.body.string ?? "").utf8)) as? NSDictionary == [
                "error": "Experimental internal surface is disabled",
                "code": "experimental_surface_disabled",
                "retry_after": NSNull(),
            ] as NSDictionary)

            let publicSurface = try await client.get(URI(string: "/api/public/feature-flags?keys=kill_switch_probe_v0"))
            #expect(publicSurface.status == .ok)

            accounts.setExperimentalSurfacesDisabledForTesting(false)
            let reenabled = try await agentApi()
            #expect(reenabled.status == .ok)
        }
    }
}
