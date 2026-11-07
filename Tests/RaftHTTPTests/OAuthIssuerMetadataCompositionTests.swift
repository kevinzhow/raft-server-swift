import Testing
@testable import RaftHTTP

@Test func issuerMetadataFromMandatoryComposerSharesLiveDeploymentAndOAuthOwners() throws {
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
        profiles: profiles,
        notifications: notifications,
        productEvents: productEvents,
        inboxFacts: inboxFacts,
        threadFollows: threadFollows,
        messages: messages,
        agents: agents,
        tasks: tasks,
        machines: machines,
        channels: channels,
        cards: cards,
        feedback: feedback,
        oauth: oauth
    )
    let metadata = services.identity.issuerMetadata
    let flows = services.identity.oauthFlows
    let serverId = "33333333-3333-4333-8333-333333333671"
    let ownerId = "11111111-1111-4111-8111-111111111645"
    let slug = "composed-issuer-645"

    flows.configureDeployment(.init(serverURL: "https://composed.raft.test:8443/base/"))
    #expect(try metadata.discovery().issuer == "https://composed.raft.test:8443")
    guard case .failure(.notFound) = metadata.resolveServerScope(slug) else {
        Issue.record("unseeded actual OAuth owner must not resolve the scope")
        return
    }
    oauth.addOwnedServer(id: serverId, slug: slug, name: "Composed Issuer", ownerId: ownerId)
    guard case .resolved(let bySlug) = metadata.resolveServerScope(slug),
          case .resolved(let byId) = metadata.resolveServerScope(serverId) else {
        Issue.record("the composed metadata field must read the supplied OAuth owner")
        return
    }
    #expect(bySlug.serverId == serverId)
    #expect(bySlug.segment == slug)
    #expect(byId.serverId == serverId)
    #expect(byId.segment == serverId)
    #expect(try metadata.discovery(scope: bySlug).issuer == "https://composed.raft.test:8443/oidc/\(slug)")
    #expect(try metadata.discovery(scope: byId).issuer == "https://composed.raft.test:8443/oidc/\(serverId)")

    flows.configureSigningSecret("composed-issuer-first-key")
    #expect(oauth.jwtSecret == "composed-issuer-first-key")
    let firstKey = try metadata.jwks()
    flows.configureSigningSecret("composed-issuer-second-key")
    #expect(try metadata.jwks().kid != firstKey.kid)
    oauth.jwtSecret = "composed-issuer-first-key"
    #expect(try metadata.jwks() == firstKey)

    flows.configureDeployment(.init(serverURL: "invalid origin"))
    #expect(throws: OAuthLedgerError.self) { try metadata.discovery() }
    #expect(try metadata.jwks() == firstKey)
    oauth.jwtSecret = ""
    flows.configureDeployment(.init(serverURL: "https://reconfigured.raft.test/new/base/"))
    #expect(try metadata.discovery().issuer == "https://reconfigured.raft.test")
    #expect(throws: OAuthLedgerError.self) { try metadata.jwks() }

    oauth.deleteServer(id: serverId)
    guard case .failure(.notFound) = metadata.resolveServerScope(slug),
          case .failure(.notFound) = metadata.resolveServerScope(serverId) else {
        Issue.record("the composed field must observe deletion in the supplied OAuth owner")
        return
    }
    #expect(try metadata.discovery().issuer == "https://reconfigured.raft.test")
}
