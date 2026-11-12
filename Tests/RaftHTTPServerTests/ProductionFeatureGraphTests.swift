import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import TestSupport
import Vapor
import VaporTesting

private let graphOwnerId = "11111111-1111-4111-8111-111111111660"
private let graphServerId = "33333333-3333-4333-8333-333333333680"

private func addVerifiedGraphOwner(_ accounts: EmailLoginDirectory, email: String) {
    accounts.addAccount(id: graphOwnerId, email: email, password: "password123")
    accounts.markEmailVerified(userId: graphOwnerId)
    accounts.oauth.addOwnedServer(
        id: graphServerId,
        slug: "production-feature-graph",
        name: "Production Feature Graph",
        ownerId: graphOwnerId
    )
}

private func graphHeaders(_ token: String, serverId: String? = nil) -> HTTPFields {
    var fields = HTTPFields()
    fields[.authorization] = "Bearer \(token)"
    if let serverId {
        fields[HTTPField.Name("X-Server-Id")!] = serverId
    }
    return fields
}

/// A Fallback directory with no accounts must still mount the three production
/// Feature families when `configure` receives an explicit graph. Factory-backed
/// mounts would answer 401 here, so the accepted responses prove the mount
/// consumes the supplied same-owner services.
@Test func productionConfigureMountsAuthOAuthIntegrationsFromExplicitGraph() async throws {
    let graphAccounts = EmailLoginDirectory()
    addVerifiedGraphOwner(graphAccounts, email: "explicit-graph@slock.test")
    graphAccounts.oauthFlows.configureDeployment(.init(
        configuredSocialAuthProviders: ["github"],
        serverURL: "https://graph.example.test",
        appURL: "https://app.example.test"
    ))
    let token = graphAccounts.mintAccessTokenForTesting(userId: graphOwnerId)
    let graph = graphAccounts.productionFeatureGraph()
    let unusedAccounts = EmailLoginDirectory()

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: unusedAccounts,
            featureGraph: graph
        ))
        try await app.testing { client in
            let me = try await client.get("/api/auth/me", headers: graphHeaders(token))
            #expect(me.status == .ok)
            #expect(me.body.string?.contains(graphOwnerId) == true)

            let providers = try await client.get("/api/auth/providers")
            #expect(providers.status == .ok)
            #expect(providers.body.string?.contains(#"{"id":"github","label":"GitHub","enabled":true}"#) == true)

            let clients = try await client.get(
                "/api/integrations/clients",
                headers: graphHeaders(token, serverId: graphServerId)
            )
            #expect(clients.status == .ok)
        }
    }
}

/// The graph keeps the retained owners, not a construction-time snapshot:
/// accounts and servers seeded after composition are visible, deployment
/// changes made through the directory are read live by the OAuth feature, and
/// the briefing hook observes the same server/account rows.
@Test func productionFeatureGraphObservesLiveOwnerConfigurationAndBriefing() async throws {
    let accounts = EmailLoginDirectory()
    let graph = accounts.productionFeatureGraph()
    addVerifiedGraphOwner(accounts, email: "live-graph@slock.test")
    let token = accounts.mintAccessTokenForTesting(userId: graphOwnerId)

    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts,
            featureGraph: graph
        ))
        try await app.testing { client in
            let me = try await client.get("/api/auth/me", headers: graphHeaders(token))
            #expect(me.status == .ok)
            #expect(me.body.string?.contains(graphOwnerId) == true)

            let before = try await client.get("/api/auth/providers")
            #expect(before.status == .ok)
            #expect(before.body.string?.contains(#"{"id":"github","label":"GitHub","enabled":false}"#) == true)

            accounts.oauthFlows.configureDeployment(.init(
                configuredSocialAuthProviders: ["github"],
                serverURL: "https://live.example.test",
                appURL: "https://app.example.test"
            ))
            let after = try await client.get("/api/auth/providers")
            #expect(after.status == .ok)
            #expect(after.body.string?.contains(#"{"id":"github","label":"GitHub","enabled":true}"#) == true)
        }
    }

    let outcome = await graph.onboardingBriefing.trigger(serverId: graphServerId)
    #expect(outcome == .surveyPending)
}
