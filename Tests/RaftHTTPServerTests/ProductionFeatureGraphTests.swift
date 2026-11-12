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

/// Asserts the exact issuer plus the endpoints it anchors and the public
/// discovery cache policy. A snapshotting issuer-metadata service would keep
/// the construction-time URL here.
private func expectGraphDiscovery(_ response: ClientResponse, issuer: String) throws {
    #expect(response.status == .ok)
    #expect(response.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=300")
    #expect(response.headers[.contentType] == AppFallback.jsonContentType)
    let document = try #require(
        JSONSerialization.jsonObject(with: Data((response.body.string ?? "").utf8)) as? [String: Any]
    )
    #expect(document["issuer"] as? String == issuer)
    #expect(document["authorization_endpoint"] as? String == "\(issuer)/api/oauth/authorize")
    #expect(document["token_endpoint"] as? String == "\(issuer)/api/oauth/token")
    #expect(document["userinfo_endpoint"] as? String == "\(issuer)/api/oauth/userinfo")
    #expect(document["jwks_uri"] as? String == "\(issuer)/api/oauth/jwks")
    #expect(document["agents_endpoint"] as? String == "\(issuer)/api/oauth/agents")
    #expect(document["serverinfo_endpoint"] as? String == "\(issuer)/api/oauth/serverinfo")
    let scopes = document["scopes_supported"] as? [String]
    let expectedScopes: [String] = [
        "openid", "profile", "email", "identity", "agent:read",
        "agent:event:write", "agent:notification:write",
    ]
    #expect(scopes == expectedScopes)
    let grants = document["grant_types_supported"] as? [String]
    let expectedGrants: [String] = ["authorization_code", "urn:slock:grant-type:agent_request"]
    #expect(grants == expectedGrants)
}

/// A Fallback directory with no accounts must still mount the three production
/// Feature families when `configure` receives an explicit graph. Factory-backed
/// mounts would answer 401 here, so the accepted responses prove the mount
/// consumes the supplied same-owner services. OAuth discovery and the scoped
/// `/oidc/:server` lookup are served from that graph too, not from the fallback
/// directory, and the issuer profile is read per request.
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
    // A server that only the fallback directory knows: scoped discovery served
    // by the supplied graph must not resolve it.
    unusedAccounts.oauth.addOwnedServer(
        id: "33333333-3333-4333-8333-333333333681",
        slug: "fallback-only-graph",
        name: "Fallback Only Graph",
        ownerId: graphOwnerId
    )

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

            // Actual configure HTTP proof for the fourth family: the mounted
            // OAuthFeature reads the supplied graph's deployment profile. The
            // fallback directory has no deployment URL, so a factory-backed
            // mount could not answer 200 with this issuer.
            let discovery = try await client.get("/api/oauth/.well-known/openid-configuration")
            try expectGraphDiscovery(discovery, issuer: "https://graph.example.test")

            let scoped = try await client.get(
                "/oidc/production-feature-graph/.well-known/openid-configuration"
            )
            try expectGraphDiscovery(
                scoped,
                issuer: "https://graph.example.test/oidc/production-feature-graph"
            )

            // Scope resolution is a live OAuth-ledger lookup in the supplied
            // graph; the fallback directory's own server is invisible.
            let fallbackOnly = try await client.get(
                "/oidc/fallback-only-graph/.well-known/openid-configuration"
            )
            #expect(fallbackOnly.status == .notFound)
            #expect(fallbackOnly.body.string == #"{"error":"Not found"}"#)
            #expect(fallbackOnly.headers[HTTPField.Name("Cache-Control")!] == nil)

            // The graph retains the profiles owner rather than a snapshot: a
            // deployment change after composition moves both issuers.
            graphAccounts.oauthFlows.configureDeployment(.init(
                serverURL: "https://graph-live.example.test:8443/"
            ))
            let live = try await client.get("/api/oauth/.well-known/openid-configuration")
            try expectGraphDiscovery(live, issuer: "https://graph-live.example.test:8443")
            let liveScoped = try await client.get(
                "/oidc/production-feature-graph/.well-known/openid-configuration"
            )
            try expectGraphDiscovery(
                liveScoped,
                issuer: "https://graph-live.example.test:8443/oidc/production-feature-graph"
            )
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
