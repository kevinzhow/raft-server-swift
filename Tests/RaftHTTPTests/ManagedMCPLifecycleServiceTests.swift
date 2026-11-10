import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The store critical sections and the published bodies behind the managed MCP
/// lifecycle service. The HTTP tests lock the wire shape; these lock the single
/// critical section each decision now runs in.

private func lifecycleDirectory(slug: String, ownerId: String, serverId: String) -> EmailLoginDirectory {
    let directory = EmailLoginDirectory()
    directory.addAccount(id: ownerId, email: "\(slug)@slock.test", password: "password123")
    directory.markEmailVerified(userId: ownerId)
    directory.oauth.addOwnedServer(id: serverId, slug: slug, name: slug, ownerId: ownerId)
    return directory
}

// MARK: - Read mutations

@Test func readMutationAdmissionAdmitsExactlyOneConcurrentWriterPerId() async {
    let store = MessagesAndThreadsStore()
    let results = await withTaskGroup(of: ReadMutationAdmission.self) { group in
        for _ in 0..<16 {
            group.addTask {
                store.admitReadMutation(
                    key: "s\nu\nm1", sequenceKey: "s\nu", userId: "u", fingerprint: "global_read_all::"
                ) { seq in
                    ReadMutationRecord(
                        mutationId: "m1", serverId: "s", principalId: "u", kind: "global_read_all",
                        scopeId: nil, fingerprint: "global_read_all::", authoritySeq: seq, state: "admitted"
                    )
                }
            }
        }
        var collected: [ReadMutationAdmission] = []
        for await result in group { collected.append(result) }
        return collected
    }
    #expect(results.filter { $0 == .admitted(authoritySeq: 1) }.count == 1)
    #expect(results.filter { $0 == .replay(.alreadyAdmitted) }.count == 15)
    #expect(store.readMutationFrontier(userId: "u", scopeIds: nil).items.count == 1)
}

@Test func readMutationAuthoritySequenceHasNoGapsUnderConcurrency() async {
    let store = MessagesAndThreadsStore()
    let sequences = await withTaskGroup(of: Int.self) { group in
        for index in 0..<24 {
            group.addTask {
                let outcome = store.admitReadMutation(
                    key: "s\nu\nm\(index)", sequenceKey: "s\nu", userId: "u", fingerprint: "f"
                ) { seq in
                    ReadMutationRecord(
                        mutationId: "m\(index)", serverId: "s", principalId: "u", kind: "global_read_all",
                        scopeId: nil, fingerprint: "f", authoritySeq: seq, state: "admitted"
                    )
                }
                if case .admitted(let seq) = outcome { return seq }
                return -1
            }
        }
        var collected: [Int] = []
        for await seq in group { collected.append(seq) }
        return collected
    }
    #expect(Set(sequences) == Set(1...24))
    let frontier = store.readMutationFrontier(userId: "u", scopeIds: ["a"])
    #expect(frontier.snapshotUpperAuthoritySeq == 24)
    #expect(frontier.items.count == 24)
    #expect(frontier.scopeCursors?.map(\.scopeId) == ["a"])
}

@Test func conversationReadAllAdvancesTheChannelAndFollowedThreadsTogether() async {
    let store = MessagesAndThreadsStore()
    store.humanMessageRows = [
        StoredHumanMessage(id: "p1", channelId: "chan", senderId: "x", content: "parent", seq: 1),
        StoredHumanMessage(id: "m2", channelId: "chan", senderId: "x", content: "later", seq: 2),
        StoredHumanMessage(id: "t1", channelId: "thread", senderId: "x", content: "reply", seq: 3),
    ]
    store.threadFollows["s\nu\nthread"] = (serverId: "s", userId: "u", threadChannelId: "thread", parentMessageId: "p1")
    store.threadFollows["s\nother\nthread"] = (serverId: "s", userId: "other", threadChannelId: "thread", parentMessageId: "p1")

    let results = await withTaskGroup(of: [ReadAllScopeResult].self) { group in
        for _ in 0..<8 {
            group.addTask { store.advanceConversationReadAll(userId: "u", channelId: "chan") }
        }
        var collected: [[ReadAllScopeResult]] = []
        for await result in group { collected.append(result) }
        return collected
    }
    for scopes in results {
        #expect(scopes.map(\.scopeId) == ["chan", "thread"])
        #expect(scopes.map(\.maxReadSeq) == [2, 3])
    }
    #expect(store.userChannelReadCursors["u\nchan"] == 2)
    #expect(store.userChannelReadCursors["u\nthread"] == 3)
    #expect(store.userChannelReadCursors["other\nthread"] == nil)
}

// MARK: - Profile completion

@Test func profileCompletionLetsExactlyOneConcurrentClaimantTakeAHandle() async {
    let directory = EmailLoginDirectory()
    let ids = (0..<6).map { "11111111-1111-4111-8111-00000117010\($0)" }
    for (index, id) in ids.enumerated() {
        directory.addAccount(id: id, email: "claim-\(index)@slock.test", password: "password123")
    }
    let store = directory.authProfileStore
    // `addAccount` seeds a completed profile; these accounts still have to claim one.
    var rows = store.accounts
    for key in rows.keys { rows[key]?.profileSetupCompletedAt = nil }
    store.accounts = rows
    let outcomes = await withTaskGroup(of: ProfileCompletionOutcome.self) { group in
        for id in ids {
            group.addTask {
                store.completeProfile(userId: id, name: "Shared-Handle", displayName: "Shared", now: Date())
            }
        }
        var collected: [ProfileCompletionOutcome] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }
    let completed = outcomes.filter { if case .completed = $0 { return true } else { return false } }
    #expect(completed.count == 1)
    #expect(outcomes.filter { $0 == .nameTaken }.count == ids.count - 1)
    // The winner replays its own pair and refuses a different one.
    let winner = ids.first { store.account(userId: $0)?.profileSetupCompletedAt != nil }!
    if case .replay = store.completeProfile(userId: winner, name: "Shared-Handle", displayName: "Shared", now: Date()) {} else {
        Issue.record("the same pair must replay")
    }
    #expect(store.completeProfile(userId: winner, name: "Other", displayName: "Shared", now: Date()) == .alreadyCompleted)
    #expect(store.completeProfile(userId: "missing", name: "n", displayName: "d", now: Date()) == .unknownAccount)
}

// MARK: - Push registration

@Test func pushRevokeCapabilityIsMintedOnceAndRevokedOnce() async {
    let store = AuthProfileStore()
    let capabilities = await withTaskGroup(of: String.self) { group in
        for _ in 0..<12 {
            group.addTask { store.ensurePushRevokeCapability(userId: "u", familyId: "fam-1").capability }
        }
        var collected: Set<String> = []
        for await capability in group { collected.insert(capability) }
        return collected
    }
    #expect(capabilities.count == 1)
    let nonce = String(capabilities.first!.split(separator: ".")[1])

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let outcomes = await withTaskGroup(of: PushFamilyRevocation.self) { group in
        for _ in 0..<8 {
            group.addTask { store.revokePushFamily(nonce: nonce, now: now) }
        }
        var collected: [PushFamilyRevocation] = []
        for await outcome in group { collected.append(outcome) }
        return collected
    }
    #expect(outcomes.filter { $0 == .revoked }.count == 1)
    #expect(outcomes.filter { $0 == .alreadyRevoked }.count == 7)
    // After the retention window the same capability is no longer valid.
    #expect(store.revokePushFamily(nonce: nonce, now: now.addingTimeInterval(31 * 24 * 60 * 60)) == .invalid)
    #expect(store.revokePushFamily(nonce: "unknown", now: now) == .invalid)
}

@Test func pushRegistrationUpsertKeepsOneRowPerInstallation() async {
    let store = NotificationsStore()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            group.addTask {
                store.upsertPushRegistration(PushRegistration(
                    installationId: "install-1", provider: "apns", env: "sandbox", topic: "t",
                    deviceToken: "token-\(index)", appVersion: nil, userId: "u", serverId: "s",
                    sessionFamilyId: "f", revokeCapability: "f.n"
                ))
            }
        }
    }
    #expect(store.pushRegistrations.filter { $0.installationId == "install-1" }.count == 1)
    #expect(store.unbindPushInstallation(installationId: "install-1") == 1)
    #expect(store.pushRegistrations.first?.userId == nil)
    #expect(store.isFcmActive(installationId: "install-1", userId: "u") == false)
}

// MARK: - Provider connections

@Test func providerCredentialRotationCountsEveryConcurrentRotation() async throws {
    let store = ManagedMCPAndCardsStore()
    let masterKey = Data((0..<32).map { UInt8($0) })
    let vault = try ProviderCredentialVault(masterKey: masterKey)
    let credential = try vault.seal("initial-provider-credential", serverId: "s", connectionId: "c1")
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    try store.insertProviderConnection(ProviderConnection(
        id: "c1", serverId: "s", name: "n", providerId: "deepseek", endpointUrl: nil,
        supportsImageInput: false, status: "verified", configVersion: 1, credentialVersion: 1,
        hasCredential: true, createdAt: created, updatedAt: created
    ), credential: credential)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                let rotated = try ProviderCredentialVault(masterKey: masterKey).seal(
                    "rotated-provider-credential", serverId: "s", connectionId: "c1"
                )
                _ = try store.rotateProviderCredential(
                    id: "c1", serverId: "s", credential: rotated, now: created
                )
            }
        }
        try await group.waitForAll()
    }
    let row = store.providerConnections(serverId: "s").first
    #expect(row?.credentialVersion == 11)
    #expect(row?.status == "unchecked")
    let otherCredential = try vault.seal("other-provider-credential", serverId: "other", connectionId: "c1")
    #expect(try store.rotateProviderCredential(id: "c1", serverId: "other", credential: otherCredential, now: created) == nil)
}

// MARK: - Channels

@Test func jointChannelPairIsCreatedAndAcceptedAsOneSection() async {
    let store = ServersAndChannelsStore()
    store.createJointChannelPair(
        hostServerId: "hs", hostChannelId: "hc", hostUserId: "hu",
        targetServerId: "ts", targetChannelId: "tc", targetOwnerId: "to",
        name: "joint-room", inviteId: "inv"
    )
    #expect(store.postableChannel(id: "hc")?.memberIds == ["hu"])
    #expect(store.postableChannel(id: "tc")?.memberIds == [])
    #expect(store.state.jointProjections.map(\.localChannelId) == ["hc", "tc"])
    #expect(store.jointInvite(id: "inv")?.status == "pending")
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask { _ = store.acceptJointInvite(id: "inv", userId: "to") }
        }
    }
    #expect(store.jointInvite(id: "inv")?.status == "accepted")
    #expect(store.postableChannel(id: "tc")?.memberIds == ["to"])
    #expect(store.acceptJointInvite(id: "missing", userId: "to") == nil)
}

@Test func guestFlagsAndVisibilityChangeApplyTogether() {
    let store = ServersAndChannelsStore()
    store.addPostableChannel(serverId: "s", channelId: "c", memberId: "u", name: "room")
    store.addThreadChannel(serverId: "s", threadChannelId: "t", parentChannelId: "c", parentMessageId: "m", memberId: "u")
    let first = store.applyGuestFlags(channelId: "c", visible: true, joinable: nil)
    #expect(first.visible && !first.joinable)
    let second = store.applyGuestFlags(channelId: "c", visible: nil, joinable: true)
    #expect(second.visible && second.joinable)
    let change = store.applyChannelVisibility(channelId: "c", kind: "private")
    #expect(change.memberIds == ["u"])
    #expect(change.threadChannelIds == ["t"])
    #expect(store.postableKind(channelId: "c") == "private")
    #expect(store.channelNameCollision(serverId: "s", name: "room", userId: "u") == false)
    #expect(store.channelNameCollision(serverId: "s", name: "absent", userId: "u") == nil)
}

@Test func followCleanupKeepsMembersAndDropsTheRest() {
    let store = MessagesAndThreadsStore()
    store.threadFollows["s\nkeep\nt"] = (serverId: "s", userId: "keep", threadChannelId: "t", parentMessageId: "m")
    store.threadFollows["s\ndrop\nt"] = (serverId: "s", userId: "drop", threadChannelId: "t", parentMessageId: "m")
    store.threadFollows["s\ndrop\nother"] = (serverId: "s", userId: "drop", threadChannelId: "other", parentMessageId: "m")
    store.removeThreadFollows(inThreads: ["t"], exceptUsers: ["keep"])
    #expect(Set(store.threadFollows.keys) == ["s\nkeep\nt", "s\ndrop\nother"])
}

// MARK: - Published bodies

@Test func providerConnectionBodyIsByteExact() {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let connection = ProviderConnection(
        id: "c1", serverId: "s", name: "Conn \"A\"", providerId: "deepseek", endpointUrl: "https://e.test",
        supportsImageInput: true, status: "unchecked", configVersion: 1, credentialVersion: 2,
        hasCredential: true, createdAt: created, updatedAt: created
    )
    #expect(ProviderConnectionBody(connection: connection).jsonBody.render()
        == "{\"id\":\"c1\",\"name\":\"Conn \\\"A\\\"\",\"providerId\":\"deepseek\",\"authMethod\":\"api_key\",\"endpointUrl\":\"https://e.test\",\"supportsImageInput\":true,\"enabled\":true,\"status\":\"unchecked\",\"configVersion\":1,\"credentialVersion\":2,\"hasCredential\":true,\"assignedAgentCount\":0,\"latestVerified\":null,\"lastCheckedAt\":null,\"lastErrorCategory\":null,\"createdAt\":\"2023-11-14T22:13:20Z\",\"updatedAt\":\"2023-11-14T22:13:20Z\"}")
    let list = ProviderConnectionListResponse(
        connections: [],
        options: [.init(id: "openai-compatible", label: "OpenAI compatible"), .init(id: "xai", label: "Xai")]
    )
    #expect(list.jsonBody.render()
        == "{\"connections\":[],\"providerOptions\":[{\"id\":\"openai-compatible\",\"label\":\"OpenAI compatible\",\"providerKind\":\"gateway\"},{\"id\":\"xai\",\"label\":\"Xai\",\"providerKind\":\"preset\"}]}")
    #expect(ManagedMCPProviderConnectionsService.providerConnectionLabel("zai-coding-cn") == "Z.ai Coding CN")
}

@Test func unreadSummaryAndRouteBodiesAreByteExact() {
    let summary = ChannelUnreadResponse.summary(
        entries: [
            .init(channelId: "c1", unreadCount: 2, hasMention: true, maxReadSeq: 4,
                  latestMessageId: "m9", latestSeq: 6, parentChannelId: "p", parentMessageId: "pm"),
            .init(channelId: "c2", unreadCount: 1, hasMention: false, maxReadSeq: 0,
                  latestMessageId: nil, latestSeq: nil, parentChannelId: nil, parentMessageId: nil),
        ],
        threadUnread: [
            .init(parentChannelId: "z", count: 1, hasMention: false),
            .init(parentChannelId: "p", count: 2, hasMention: true),
        ]
    )
    #expect(summary.jsonBody.render()
        == "{\"channels\":{\"c1\":{\"unreadCount\":2,\"hasMention\":true,\"hasAnyMention\":true,\"readState\":{\"kind\":\"present\",\"readStateVersion\":0,\"maxReadSeq\":\"4\",\"latestActivity\":{\"messageId\":\"m9\",\"seq\":\"6\"}},\"parentChannelId\":\"p\",\"parentMessageId\":\"pm\"},\"c2\":{\"unreadCount\":1,\"hasMention\":false,\"hasAnyMention\":false,\"readState\":{\"kind\":\"present\",\"readStateVersion\":0,\"maxReadSeq\":\"0\",\"latestActivity\":null}}},\"threadUnread\":{\"p\":{\"count\":2,\"hasMention\":true},\"z\":{\"count\":1,\"hasMention\":false}}}")
    #expect(ChannelUnreadResponse.counts([(channelId: "a", count: 3)]).jsonBody.render() == "{\"a\":3}")
    #expect(ManagedMCPChannelRouteResponse.jointCreated(id: "h", name: "n", targetServerSlug: "slug", inviteId: "i").jsonBody.render()
        == "{\"id\":\"h\",\"name\":\"n\",\"type\":\"joint\",\"targetServerSlug\":\"slug\",\"jointInvite\":{\"id\":\"i\",\"status\":\"pending\"},\"joined\":true}")
    #expect(ReadMutationResponse.alreadyTerminal(scopeId: "s", cursor: 7).jsonBody.render()
        == "{\"outcome\":\"ALREADY_TERMINAL\",\"ack\":{\"terminalReason\":\"completed\",\"capturedBoundary\":[{\"scopeId\":\"s\",\"throughSeq\":7}],\"scopes\":[{\"scopeId\":\"s\",\"maxReadSeq\":7}]}}")
    #expect(ReadMutationResponse.alreadyAdmitted.status == 200)
    #expect(ReadMutationResponse.admitted(serverId: "s", principalId: "p", authoritySeq: 3, mutationId: "m").status == 201)
    let text = AgentUserChannelsResponse(
        name: "u", uncheckedCount: 2,
        page: [.init(id: "1", name: "alpha", type: "channel", joined: true, channelRole: "admin")],
        total: 1, offset: 0, limit: 50
    )
    #expect(text.text == "#alpha\nSkipped 2 visible channel roster checks because the server rejected them.")
    #expect(text.jsonBody.render()
        == "{\"kind\":\"human\",\"name\":\"u\",\"uncheckedCount\":2,\"memberships\":[{\"id\":\"1\",\"name\":\"alpha\",\"type\":\"channel\",\"joined\":true,\"channelRole\":\"admin\"}],\"page\":{\"total\":1,\"offset\":0,\"limit\":50}}")
}

@Test func errorBodiesAndHeadersAreByteExact() {
    #expect(ManagedMCPOAuthError.capabilityNotAuthorized.publishedErrorBody.render()
        == "{\"error\":\"Agent credential is not authorized for this capability\",\"code\":\"capability_not_authorized\",\"requiredCapability\":\"read\"}")
    #expect(ManagedMCPOAuthError.missingScope("server:read").publishedErrorBody.render()
        == "{\"error\":\"missing required scope\",\"requiredScope\":\"server:read\",\"reason\":\"missing_scope\"}")
    #expect(ManagedMCPOAuthError.channelNameExists(name: "x", canUnarchive: true).publishedErrorBody.render()
        == "{\"error\":\"A channel named #x already exists\",\"canUnarchiveArchivedChannel\":true}")
    #expect(ManagedMCPOAuthError.channelArchived.publishedErrorBody.render()
        == ChannelMembershipError.channelArchived.publishedErrorBody.render())
    #expect(ManagedMCPOAuthError.channelArchived.status == ChannelMembershipError.channelArchived.status)
    #expect(ManagedMCPOAuthError.avatarNotFound.publishedErrorBody.render() == "Not found")
    #expect(ManagedMCPOAuthError.avatarStorageUnavailable.status == 503)
    #expect(ManagedMCPOAuthError.avatarNotFound.errorHeaders == .exact(["Content-Type": "text/plain; charset=utf-8"]))
    #expect(ManagedMCPOAuthError.announcementImageStorageUnavailable.publishedErrorBody.render()
        == "{\"error\":\"Announcement image storage unavailable\"}")
    #expect(ManagedMCPLifecycleError.invalidMutationId.publishedErrorBody.render()
        == "{\"error\":\"Invalid mutation id\",\"code\":\"INVALID_MUTATION_ID\"}")
    #expect(ManagedMCPLifecycleError.providerConnectionsDisabled.publishedErrorBody.render()
        == "{\"error\":\"Provider connections are not enabled\",\"code\":\"provider_connections_disabled\"}")
    #expect(ManagedMCPLifecycleError.providerProbeRetired.status == 410)
}

// MARK: - Service wiring

@Test func lifecycleServiceRefusesAnonymousAndServesTheOwner() throws {
    let ownerId = "11111111-1111-4111-8111-000001170201"
    let serverId = "33333333-3333-4333-8333-000001170201"
    let directory = lifecycleDirectory(slug: "lifecycle-svc", ownerId: ownerId, serverId: serverId)
    let service = directory.managedMCPLifecycle
    #expect(throws: ManagedMCPLifecycleError.unauthorized) {
        _ = try service.serverDetails(authorization: nil, serverId: serverId)
    }
    let token = "lifecycle-token-1"
    directory.authProfileStore.accessTokens[token] = ownerId
    let details = try service.serverDetails(authorization: "Bearer \(token)", serverId: serverId)
    #expect(details.jsonBody.render().hasPrefix("{\"id\":\"\(serverId)\",\"ownerId\":\"\(ownerId)\""))
    #expect(throws: ManagedMCPLifecycleError.notAMember) {
        _ = try service.serverDetails(authorization: "Bearer \(token)", serverId: "33333333-3333-4333-8333-0000011702ff")
    }
}
