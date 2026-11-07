import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

@Test func principalFromMandatoryComposerSharesG5MintLiveProfilesAndOAuthFacts() throws {
    let profiles = AuthProfileStore()
    let notifications = NotificationsStore()
    let productEvents = ProductEventStore()
    let inboxFacts = InboxFactStore()
    let threadFollows = ThreadFollowStore()
    let messages = MessagesAndThreadsStore()
    let agents = AgentsRuntimeStore()
    let tasks = TasksAndRemindersStore()
    let machines = MachinesAndComputersStore()
    let channels = ServersAndChannelsStore()
    let cards = ManagedMCPAndCardsStore()
    let feedback = FeedbackStore()
    let oauth = OAuthLedger()
    let services = composeServices(
        profiles: profiles, notifications: notifications, productEvents: productEvents,
        inboxFacts: inboxFacts, threadFollows: threadFollows, messages: messages,
        agents: agents, tasks: tasks, machines: machines, channels: channels,
        cards: cards, feedback: feedback, oauth: oauth
    )
    let principal = services.identity.principal
    let authorization = services.identity.authorization
    let flows = services.identity.oauthFlows
    let ownerId = "11111111-1111-4111-8111-111111111647"
    let serverId = "33333333-3333-4333-8333-333333333673"
    let email = "composed-principal-647@test.invalid"
    profiles.state.withLock { owned in
        owned.accountSurface.accounts[email] = Account(
            id: ownerId, email: email, passwordHash: AuthTokenCodec.sha256("password123"),
            displayLanguage: nil, name: "Granted identity", profileSetupSuggestedHandle: nil,
            avatarUrl: "/api/avatars/users/cafe.webp"
        )
    }
    let session = profiles.openSession(userId: ownerId).accessToken
    let snapshot = authorization.beginSession(authorization: "Bearer \(session)")
    guard case .user(let human) = snapshot else { Issue.record("G5 must read the supplied profile owner"); return }
    #expect(human.id == ownerId)
    oauth.addOwnedServer(id: serverId, slug: "composed-principal-647", name: "Before projection", ownerId: ownerId)
    let app = try oauth.createClient(serverId: serverId, createdByUserId: ownerId,
        name: "Composed Principal App", clientId: "composed-principal-client-647", allowedScopes: ["profile", "agent:read"])
    let issued = try authorization.issueHumanAuthorization(session: snapshot,
        body: "{\"clientId\":\"\(app.clientId)\",\"serverId\":\"\(serverId)\",\"scopes\":[\"profile\",\"agent:read\"]}")
    let minted = try authorization.exchangeToken(authorization: nil,
        body: "{\"clientId\":\"\(app.clientId)\",\"clientSecret\":\"\(app.clientSecret)\",\"grantType\":\"authorization_code\",\"code\":\"\(issued.code)\"}",
        context: authorization.tokenContext())
    let bearer = "Bearer \(minted.accessToken)"
    // Only the supplied owners are mutated after composition and G5 mint.
    profiles.state.withLock { $0.accountSurface.accounts[email]?.name = "Current identity" }
    oauth.addMember(serverId: serverId, userId: ownerId, role: "admin")
    oauth.updateServer(id: serverId, name: "Live projection", avatarUrl: "/server.svg")
    oauth.setServerPlan(id: serverId, plan: "partner")
    let zeta = oauth.createAgent(serverId: serverId, name: "zeta", avatarUrl: "/zeta.svg")
    let alpha = oauth.createAgent(serverId: serverId, name: "Alpha", avatarUrl: "HTTPS://cdn.test/alpha.svg", runtime: "external")
    oauth.removeAgentMember(serverId: serverId, agentId: alpha)
    flows.configureSigningSecret("")
    flows.configureDeployment(.init(serverURL: " raw composed///"))
    func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    let user = try object(principal.userinfo(authorization: bearer).jsonBody.render())
    #expect(user["name"] as? String == "Granted identity")
    #expect(user["server_role"] as? String == "admin")
    #expect(user["picture"] as? String == " raw composed///api/avatars/users/cafe.webp")
    #expect(user["email"] == nil && user["email_verified"] == nil)
    let server = try object(principal.serverinfo(authorization: bearer).jsonBody.render())
    #expect(server["id"] as? String == serverId)
    #expect(server["name"] as? String == "Live projection")
    #expect(server["picture"] as? String == " raw composed///server.svg")
    #expect(server["plan_tier"] as? String == "paid")
    let directory = try principal.agentDirectory(authorization: bearer)
    #expect(directory.agents.map(\.id) == [alpha, zeta])
    #expect(directory.agents.first?.picture == nil)
    #expect(directory.agents.last?.picture == " raw composed///zeta.svg")
    // A later deployment read must use the same live profile owner again.
    flows.configureDeployment(.init(serverURL: "https://second.principal.test/base/"))
    #expect(try principal.serverinfo(authorization: bearer).picture == "https://second.principal.test/base/server.svg")
    oauth.setClientEnabled(clientRecordId: app.id, enabled: false)
    #expect(try principal.userinfo(authorization: bearer).sub == ownerId)
    #expect(try principal.serverinfo(authorization: bearer).id == serverId)
    #expect(throws: OAuthLedgerError(.agentReadRequired, cacheControl: "no-store")) {
        try principal.agentDirectory(authorization: bearer)
    }
    oauth.setClientEnabled(clientRecordId: app.id, enabled: true)
    oauth.removeAuthorizationCodeForTesting(id: issued.code)
    #expect(throws: OAuthLedgerError(.invalidOrExpiredAccessToken)) {
        try principal.userinfo(authorization: bearer)
    }
    #expect(try principal.serverinfo(authorization: bearer).id == serverId)
    #expect(try principal.agentDirectory(authorization: bearer).agents.map(\.id) == [alpha, zeta])
}
