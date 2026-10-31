import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

@Test func onboardingSettingsSplitServerAndMemberFieldsByRole() async throws {
    let accounts = EmailLoginDirectory()
    let ownerId = "11111111-1111-4111-8111-111111111374"
    let adminId = "11111111-1111-4111-8111-111111111375"
    let memberId = "11111111-1111-4111-8111-111111111376"
    let serverId = "33333333-3333-4333-8333-333333333519"
    for (id, email) in [
        (ownerId, "onboarding-owner@slock.test"),
        (adminId, "onboarding-admin@slock.test"),
        (memberId, "onboarding-member@slock.test"),
    ] {
        accounts.addAccount(id: id, email: email, password: "password123")
        accounts.markEmailVerified(userId: id)
    }
    accounts.oauth.addOwnedServer(id: serverId, slug: "onboarding", name: "Onboarding", ownerId: ownerId)
    accounts.oauth.addMember(serverId: serverId, userId: adminId, role: "admin")
    accounts.oauth.addMember(serverId: serverId, userId: memberId, role: "member")
    let ownerAgent = accounts.oauth.createAgent(serverId: serverId, name: "owner-onboarding-agent")
    let adminAgent = accounts.oauth.createAgent(serverId: serverId, name: "admin-onboarding-agent")

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            func login(_ email: String) async throws -> String {
                var headers = HTTPFields()
                headers[.contentType] = "application/json"
                let response = try await client.send(.post, headers: headers, to: "/api/auth/login") { request in
                    request.body = .init(string: "{\"email\":\"\(email)\",\"password\":\"password123\"}")
                }
                return (try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any])?["accessToken"] as? String ?? ""
            }
            func headers(_ token: String) -> HTTPFields {
                var fields = HTTPFields()
                fields[.authorization] = "Bearer \(token)"
                fields[.contentType] = "application/json"
                fields[HTTPField.Name("X-Server-Id")!] = serverId
                return fields
            }
            let ownerToken = try await login("onboarding-owner@slock.test")
            let adminToken = try await login("onboarding-admin@slock.test")
            let memberToken = try await login("onboarding-member@slock.test")
            let base = "/api/servers/\(serverId)/onboarding-settings"
            func get(_ token: String) async throws -> [String: Any] {
                let response = try await client.send(.get, headers: headers(token), to: URI(string: base))
                #expect(response.status == .ok)
                return try JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any] ?? [:]
            }
            func patch(_ token: String, _ body: String) async throws -> ClientResponse {
                try await client.send(.patch, headers: headers(token), to: URI(string: base)) { request in
                    request.body = .init(string: body)
                }
            }

            let initial = try await get(ownerToken)
            #expect(initial["agentAllChannelGreetingEnabled"] as? Bool == true)
            #expect(initial["onboardingWizardEnabled"] as? Bool == true)
            #expect(initial["onboardingAgentId"] == nil || initial["onboardingAgentId"] is NSNull)
            #expect(initial["setupModalReminderOptOut"] as? Bool == false)
            #expect(initial["onboardingWizardCurrentStep"] == nil || initial["onboardingWizardCurrentStep"] is NSNull)

            let ownerPatch = try await patch(ownerToken, "{\"onboardingAgentId\":\"\(ownerAgent)\",\"agentAllChannelGreetingEnabled\":false}")
            #expect(ownerPatch.status == .ok)
            let ownerBody = try JSONSerialization.jsonObject(with: Data((ownerPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(ownerBody?["onboardingAgentId"] as? String == ownerAgent)
            #expect(ownerBody?["agentAllChannelGreetingEnabled"] as? Bool == false)

            let adminPatch = try await patch(adminToken, "{\"onboardingAgentId\":\"\(adminAgent)\",\"agentAllChannelGreetingEnabled\":true}")
            #expect(adminPatch.status == .ok)
            let adminBody = try JSONSerialization.jsonObject(with: Data((adminPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(adminBody?["onboardingAgentId"] as? String == adminAgent)

            let memberPatch = try await patch(memberToken, "{\"setupModalReminderOptOut\":true,\"dismissedAddComputerStep\":true,\"dismissedCreateAgentStep\":true,\"dismissedInviteStep\":true,\"dismissedCommunityStep\":true,\"dismissedNotificationStep\":true,\"onboardingWizardCurrentStep\":\"invite-teammates\"}")
            #expect(memberPatch.status == .ok)
            let memberBody = try JSONSerialization.jsonObject(with: Data((memberPatch.body.string ?? "").utf8)) as? [String: Any]
            #expect(memberBody?["setupModalReminderOptOut"] as? Bool == true)
            for key in ["dismissedAddComputerStepAt", "dismissedCreateAgentStepAt", "dismissedInviteStepAt", "dismissedCommunityStepAt", "dismissedNotificationStepAt"] {
                #expect(memberBody?[key] is String)
            }
            #expect(memberBody?["onboardingWizardCurrentStep"] as? String == "invite-teammates")

            let cleared = try await patch(memberToken, "{\"onboardingWizardCurrentStep\":null}")
            #expect(cleared.status == .ok)
            let clearedBody = try JSONSerialization.jsonObject(with: Data((cleared.body.string ?? "").utf8)) as? [String: Any]
            #expect(clearedBody?["onboardingWizardCurrentStep"] == nil || clearedBody?["onboardingWizardCurrentStep"] is NSNull)

            let memberAgent = try await patch(memberToken, "{\"onboardingAgentId\":\"\(ownerAgent)\"}")
            #expect(memberAgent.status == .forbidden)
            #expect((try JSONSerialization.jsonObject(with: Data((memberAgent.body.string ?? "").utf8)) as? [String: Any])?["error"] as? String == "Only server owners and admins can update onboarding settings")

            #expect(try await patch(memberToken, "{\"agentAllChannelGreetingEnabled\":false}").status == .forbidden)
            #expect(try await patch(ownerToken, "{\"agentAllChannelGreetingEnabled\":\"nope\"}").status == .badRequest)
            #expect(try await patch(memberToken, "{\"onboardingWizardCurrentStep\":\"bogus\"}").status == .badRequest)

            let settings = try await client.send(.get, headers: headers(ownerToken), to: URI(string: "/api/servers/\(serverId)/settings"))
            #expect(settings.status == .ok)
            let settingsBody = try JSONSerialization.jsonObject(with: Data((settings.body.string ?? "").utf8)) as? [String: Any]
            let wrapped = (settingsBody?["settings"] as? [String: Any])?["onboardSettings"] as? [String: Any]
            #expect(wrapped?["onboardingAgentId"] as? String == adminAgent)
            #expect(((settingsBody?["settings"] as? [String: Any])?["feedbackSettings"] as? [String: Any])?["enabled"] as? Bool == true)
            let legacy = try await get(ownerToken)
            #expect(Set(legacy.keys) == Set(wrapped?.keys ?? [:].keys))
            #expect(legacy["onboardingAgentId"] as? String == wrapped?["onboardingAgentId"] as? String)
            #expect(legacy["agentAllChannelGreetingEnabled"] as? Bool == wrapped?["agentAllChannelGreetingEnabled"] as? Bool)
        }
    }
}
