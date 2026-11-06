import Foundation
import Testing
@testable import RaftHTTP

private let isolationNow = Date(timeIntervalSince1970: 1_800_000_000)
private let isolationUser = "11111111-1111-4111-8111-000009000001"
private let isolationEmail = "mutex-auth@slock.test"

private func isolationStore() -> AuthProfileStore {
    let store = AuthProfileStore()
    store.accounts = [isolationEmail: Account(
        id: isolationUser, email: isolationEmail, passwordHash: "original",
        displayLanguage: nil, name: "mutex-auth", profileSetupSuggestedHandle: nil
    )]
    return store
}

private func raceAuthStore<T: Sendable>(
    count: Int = 48,
    _ operation: @escaping @Sendable (Int) -> T
) async -> [T] {
    await withTaskGroup(of: T.self) { group in
        for index in 0..<count { group.addTask { operation(index) } }
        var results: [T] = []
        for await result in group { results.append(result) }
        return results
    }
}

@Test func authStoreConcurrentPlainRefreshConsumesOnceAndPredecessorLogoutRevokesSuccessor() async throws {
    let store = isolationStore()
    let session = store.openSession(userId: isolationUser)
    let rotations = await raceAuthStore { _ in
        store.rotateRefreshToken(session.refreshToken, attemptId: nil, installationId: nil, now: isolationNow)
    }.compactMap { $0 }
    #expect(rotations.count == 1)
    #expect(store.sessions.count == 1)
    let successor = try #require(rotations.first)
    #expect(store.userId(forAccessToken: successor.accessToken) == isolationUser)
    store.revokeRefreshFamily(refreshToken: session.refreshToken, now: isolationNow)
    #expect(store.userId(forAccessToken: successor.accessToken) == nil)
    #expect(store.rotateRefreshToken(successor.refreshToken, attemptId: nil, installationId: nil, now: isolationNow) == nil)
}

@Test func authStoreConcurrentDurableRefreshReplaysOneSuccessorAndKeepsBinding() async throws {
    let store = isolationStore()
    let session = store.openSession(userId: isolationUser)
    let rotations = await raceAuthStore { _ in
        store.rotateRefreshToken(session.refreshToken, attemptId: "attempt", installationId: "installation", now: isolationNow)
    }.compactMap { $0 }
    #expect(rotations.count == 48)
    #expect(Set(rotations.map(\.refreshToken)).count == 1)
    #expect(Set(rotations.map(\.accessToken)).count == 48)
    #expect(store.rotationReceipts.count == 1)
    #expect(store.sessions.count == 1)
    #expect(store.rotateRefreshToken(session.refreshToken, attemptId: "other", installationId: "installation", now: isolationNow) == nil)
    store.revokeRefreshFamily(refreshToken: session.refreshToken, now: isolationNow)
    #expect(store.rotateRefreshToken(session.refreshToken, attemptId: "attempt", installationId: "installation", now: isolationNow) == nil)
}

@Test func authStoreConcurrentResetConsumesTokenAndWritesPasswordOnce() async throws {
    let store = isolationStore()
    store.setResetToken(hash: "reset", userId: isolationUser, expiresAt: isolationNow.addingTimeInterval(60))
    let results = await raceAuthStore { index in
        store.consumeResetToken(tokenHash: "reset", passwordHash: "replacement-\(index)", now: isolationNow)
    }
    #expect(results.filter { $0 == .reset }.count == 1)
    #expect(results.filter { $0 == .invalidOrExpiredToken }.count == 47)
    #expect(store.resetToken(hash: "reset") == nil)
    let account = try #require(store.account(userId: isolationUser))
    #expect(account.passwordHash.hasPrefix("replacement-"))
    #expect(account.passwordCredentialEstablishedAt == isolationNow)
}

@Test func authStoreConcurrentVerificationConsumeAndResendKeepSingleWinner() async {
    let store = isolationStore()
    store.issueVerificationToken(userId: isolationUser, token: "token", tokenHash: "hash", now: isolationNow)
    let consumed = await raceAuthStore { _ in
        store.consumeVerificationToken(tokenHash: "hash", now: isolationNow)
    }.compactMap { $0 }
    #expect(consumed == [isolationUser])
    let resent = await raceAuthStore { index in
        store.issueVerificationTokenIfAllowed(
            userId: isolationUser, token: "new-\(index)", tokenHash: "new-hash-\(index)",
            now: isolationNow.addingTimeInterval(120), ttl: 600, hourlyLimit: 2, cooldown: 60
        )
    }
    #expect(resent.filter { $0 == .issued }.count == 1)
    #expect(resent.filter { $0 == .tooManyRequests }.count == 47)
    #expect(store.emailVerifications == 1)
}

@Test func authStoreConcurrentPasswordLoginConsumesPendingLinkWithItsSession() async {
    let store = isolationStore()
    store.pendingSocialLinks = ["pending": PendingSocialLink(
        token: "pending", provider: "github", providerUserId: "subject", email: isolationEmail,
        returnTo: "/", returnUri: nil, expiresAt: isolationNow.addingTimeInterval(60)
    )]
    let winners = await raceAuthStore { _ -> Bool in
        if case .authenticated = store.authenticate(
            email: isolationEmail, passwordHash: "original", pendingLinkToken: "pending", now: isolationNow
        ) { return true }
        return false
    }
    #expect(winners.filter { $0 }.count == 1)
    #expect(store.sessions.count == 1)
    #expect(store.linkedIdentities.count == 1)
    #expect(store.pendingSocialLinks["pending"]?.consumed == true)
}

@Test func authStoreConcurrentMobileHandoffCommitsAccountLegalIdentityAndSessionTogether() async {
    let store = AuthProfileStore()
    let flows = OAuthFlowsStore(profiles: store)
    let verifier = String(repeating: "v", count: 43)
    flows.insertMobileRequest(MobileOAuthRequest(
        id: "request", provider: "github", mode: "login", status: "provider_completed",
        codeChallenge: AuthTokenCodec.pkceS256(verifier), returnUri: "raft://oauth/callback", nonce: "nonce",
        expiresAt: isolationNow.addingTimeInterval(60), handoffCode: "handoff", profileEmail: isolationEmail,
        profileUserId: "subject", profileName: "Auth User"
    ))
    let winners = await raceAuthStore { _ -> Bool in
        if case .signedIn = flows.completeMobile(
            code: "handoff", verifier: verifier, pendingLinkToken: nil, acceptTerms: true,
            termsVersion: AuthLegalPolicy.termsVersion, privacyVersion: AuthLegalPolicy.privacyVersion, now: isolationNow
        ) { return true }
        return false
    }
    #expect(winners.filter { $0 }.count == 1)
    #expect(store.accounts.count == 1)
    #expect(store.state.withLock { $0.legalAcceptances.count } == 1)
    #expect(store.linkedIdentities.count == 1)
    #expect(store.sessions.count == 1)
    #expect(store.consumedHandoffs == ["handoff"])
}

@Test func authStoreConcurrentFinalIdentityUnlinksLeaveOneCredential() async {
    let store = isolationStore()
    var account = store.accounts[isolationEmail]!
    account.passwordCredentialEstablishedAt = nil
    store.accounts = [isolationEmail: account]
    store.appendIdentity(userId: isolationUser, provider: "github", providerEmail: isolationEmail)
    store.appendIdentity(userId: isolationUser, provider: "apple", providerEmail: isolationEmail)
    let outcomes = await raceAuthStore(count: 2) { index -> Bool in
        if case .unlinked = store.unlinkIdentity(userId: isolationUser, provider: index == 0 ? "github" : "apple") {
            return true
        }
        return false
    }
    #expect(outcomes.filter { $0 }.count == 1)
    #expect(store.identityCount(userId: isolationUser) == 1)
}
