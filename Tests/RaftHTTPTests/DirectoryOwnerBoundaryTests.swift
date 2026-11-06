import Foundation
import Synchronization
import Testing
import TestSupport
@testable import RaftHTTP

@Test func cUnsubscribeCallbackSeesOptOutBeforeJourneysAndCanReenterAuthOwner() {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111642"
    let email = "owner-callback@example.test"
    directory.addAccount(id: userId, email: email, password: "password123")
    directory.addMobileAppEmailJourney(userId: userId, email: email, journeyKey: "first_computer_mobile_app_48h", day1Status: "scheduled", day1EmailId: "scheduled-c")
    directory.setMobileEmailCancellationForTesting { emailId in
        #expect(emailId == "scheduled-c")
        #expect(directory.mobileAppEmailContacts().map(\.status) == ["unsubscribed"])
        #expect(directory.mobileAppEmailJourneys().map(\.day1Status) == ["scheduled"])
        // A row inserted during the callback must be re-matched by phase two.
        directory.addMobileAppEmailJourney(userId: userId, email: email, journeyKey: "first_computer_mobile_app_48h", day1Status: "scheduled", day1EmailId: emailId)
    }
    let token = directory.createMobileAppEmailUnsubscribeToken(userId: userId)
    let result = MobileAppEmailUnsubscribe(notifications: directory.nativeNotifications).mobileAppEmailUnsubscribeSubmit(token: token, source: nil, body: "List-Unsubscribe=One-Click")
    if case .oneClick = result {} else { Issue.record("Expected the published one-click outcome") }
    let journeys = directory.mobileAppEmailJourneys()
    #expect(journeys.count == 2)
    #expect(journeys.allSatisfy { $0.day1Status == "skipped" && $0.suppressedReason == "unsubscribed" && $0.canceledAt != nil })
}

@Test func cLegacyProfileReadKeepsItsScopeOnlyPredicateForRevokedCredentials() {
    let directory = EmailLoginDirectory()
    let key = directory.mintAgentCredential(agentId: "agent-c", scopes: ["read"], name: "legacy-read")
    directory.revokeAgentCredentialForTesting(apiKey: key)
    let helper = AgentCredentialLookup(agents: directory.agentsRuntimeStore, channels: directory.agentChannels, credentialUse: directory.agentCredentialUse)
    if case .success(let agentId) = helper.profileReadOutcome("Bearer " + key) {
        #expect(agentId == "agent-c")
    } else { Issue.record("Legacy read predicate must remain independent of revocation") }
    #expect(directory.agentsRuntimeStore.credentialUsage(agentId: "agent-c").lastUsedAt == nil)
    let withoutRead = directory.mintAgentCredential(agentId: "agent-c", scopes: ["write"], name: "no-read")
    if case .invalidCredential = helper.profileReadOutcome("Bearer " + withoutRead) {} else { Issue.record("Read scope remains required") }
    #expect(helper.agentCredentialAgent("Bearer " + key) == nil)
}

@Test func explicitSupportInstancesObserveLaterPolicyAndSecretChanges() {
    let directory = EmailLoginDirectory()
    let policy = DirectoryRuntimePolicy(auth: directory.authCore)
    directory.setExperimentalSurfacesDisabledForTesting(false)
    #expect(policy.experimentalSurfacesDisabled == false)
    directory.setExperimentalSurfacesDisabledForTesting(true)
    #expect(policy.experimentalSurfacesDisabled)

    let userId = "11111111-1111-4111-8111-111111111644"
    directory.addAccount(id: userId, email: "live-unsubscribe@slock.test", password: "password123")
    let email = MobileAppEmailUnsubscribe(notifications: directory.nativeNotifications)
    let oldToken = directory.createMobileAppEmailUnsubscribeToken(userId: userId)
    let updater = MobileAppEmailUnsubscribe(notifications: directory.nativeNotifications)
    updater.configureDeployment(.init(secret: "rotated-credential-boundary-secret"))
    let freshToken = directory.createMobileAppEmailUnsubscribeToken(userId: userId)
    if case .confirmation = email.mobileAppEmailUnsubscribePage(token: freshToken) {} else {
        Issue.record("Existing email workflow must read the updated signing configuration")
    }
    if case .invalidLink = email.mobileAppEmailUnsubscribePage(token: oldToken) {} else {
        Issue.record("The previous signing key must stop validating after rotation")
    }
}

@Test func cDeploymentConfigurationPublishesOneCoherentOAuthValue() async {
    let service = EmailLoginDirectory().oauthFlows
    let first = OAuthFlowsService.DeploymentConfiguration(serverURL: "https://first.test/api", appURL: "https://first.test/app")
    let second = OAuthFlowsService.DeploymentConfiguration(serverURL: "https://second.test/api", appURL: "https://second.test/app")
    service.configureDeployment(first)
    let consistent = await withTaskGroup(of: Bool.self) { group in
        for index in 0..<64 {
            group.addTask {
                for _ in 0..<50 {
                    if index.isMultiple(of: 2) { service.configureDeployment(index.isMultiple(of: 4) ? first : second) }
                    let value = service.deploymentConfiguration
                    if value != first && value != second { return false }
                }
                return true
            }
        }
        var allConsistent = true
        for await result in group { allConsistent = allConsistent && result }
        return allConsistent
    }
    #expect(consistent)
}
