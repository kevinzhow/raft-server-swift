import Foundation
import Testing
@testable import RaftHTTP

// node-argon2 upstream test.cjs at 23b62102615421ef49618ed3307870f868a38852.
// The upstream pins the same official Argon2 reference 62358ba2123abd17fccf2a108a301d4b52c01a7c.
// https://github.com/ranisalt/node-argon2/blob/23b62102615421ef49618ed3307870f868a38852/test.cjs
private let nodePasswordPHC = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$rBWULD5jOGpQy32rLvGcmvQMVqIVNAmrCtekWvUA8bw"
private let nodeNullPasswordPHC = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$NqchDOxwWbcBzA+0gtsCtyspEQxqKFf4/PO/AoIvo+Q"

@Test func authPasswordMatchesNodeArgon2idGoldenAndBinaryPassword() throws {
    #expect(PasswordCredential.verify("password", encoded: nodePasswordPHC))
    #expect(!PasswordCredential.verify("wrong-password", encoded: nodePasswordPHC))
    #expect(PasswordCredential.verify("pass\0word", encoded: nodeNullPasswordPHC))
    #expect(!PasswordCredential.verify("pass", encoded: nodeNullPasswordPHC))
    #expect(try PasswordCredential.encode("password", salt: Array("saltsaltsaltsalt".utf8)) == nodePasswordPHC)
    let first = try PasswordCredential.hash("synthetic-password")
    let second = try PasswordCredential.hash("synthetic-password")
    #expect(first != second)
    #expect(first.hasPrefix("$argon2id$v=19$m=65536,t=3,p=4$"))
    #expect(PasswordCredential.verify("synthetic-password", encoded: first))
}

@Test func authPasswordRejectsMalformedAndUnsafePHCBeforeAllocation() {
    let unsafe = [
        AuthTokenCodec.sha256("password"), "", nodePasswordPHC + "\0ignored",
        nodePasswordPHC.replacingOccurrences(of: "m=65536", with: "m=1048576"),
        nodePasswordPHC.replacingOccurrences(of: "t=3", with: "t=500"),
        nodePasswordPHC.replacingOccurrences(of: "p=4", with: "p=255"),
        nodePasswordPHC.replacingOccurrences(of: "m=65536", with: "m=0"),
        nodePasswordPHC.replacingOccurrences(of: "v=19", with: "v=16"),
        nodePasswordPHC.replacingOccurrences(of: "argon2id", with: "argon2d"),
        nodePasswordPHC.replacingOccurrences(of: "p=4", with: "p=04"),
        nodePasswordPHC.replacingOccurrences(of: "c2FsdHNhbHRzYWx0c2FsdA", with: "bad=salt"),
        String(nodePasswordPHC.dropLast())
    ]
    for phc in unsafe { #expect(!PasswordCredential.verify("password", encoded: phc)) }
}

private func passwordStore() -> AuthProfileStore {
    let store = AuthProfileStore()
    store.state.withLock { state in
        state.accountSurface.accounts["cas@example.com"] = Account(
            id: "synthetic-cas-user", email: "cas@example.com", passwordHash: nodePasswordPHC,
            displayLanguage: nil, name: "synthetic-cas", profileSetupSuggestedHandle: nil
        )
    }
    return store
}

@Test func authStalePasswordProofCannotOpenSessionOrConsumePendingLink() throws {
    let store = passwordStore()
    let moment = Date()
    let old = try #require(store.passwordCandidate(email: "cas@example.com"))
    store.setResetToken(hash: "synthetic-reset-hash", userId: old.userId, expiresAt: moment.addingTimeInterval(60))
    store.state.withLock { state in
        state.accountSurface.pendingSocialLinks["synthetic-link"] = PendingSocialLink(
            token: "synthetic-link", provider: "google", providerUserId: "synthetic-google-id",
            email: old.email, returnTo: nil, returnUri: nil, expiresAt: moment.addingTimeInterval(60)
        )
    }
    #expect(store.commitPasswordReset(candidate: old, tokenHash: "synthetic-reset-hash", newHash: nodeNullPasswordPHC, now: moment) != nil)
    if case .rejected = store.authenticate(email: old.email, passwordHash: old.encodedHash, expectedUserId: old.userId,
                                           pendingLinkToken: "synthetic-link", now: moment) {} else {
        Issue.record("A stale password proof must reject before link consume/session creation")
    }
    let current = try #require(store.passwordCandidate(email: old.email))
    guard case .authenticated(_, _, let provider) = store.authenticate(
        email: current.email, passwordHash: current.encodedHash, expectedUserId: current.userId,
        pendingLinkToken: "synthetic-link", now: moment
    ) else { Issue.record("The still-live pending link must remain consumable by the current credential"); return }
    #expect(provider == "google")
}

@Test func authResetCandidateCannotChangeARetiredAccount() throws {
    let store = passwordStore()
    let moment = Date()
    let candidate = try #require(store.passwordCandidate(email: "cas@example.com"))
    store.setResetToken(hash: "synthetic-reset-hash", userId: candidate.userId, expiresAt: moment.addingTimeInterval(60))
    store.state.withLock { $0.accountSurface.accounts[candidate.email]?.retiredAt = moment }
    #expect(store.commitPasswordReset(candidate: candidate, tokenHash: "synthetic-reset-hash", newHash: nodeNullPasswordPHC, now: moment) == nil)
    #expect(store.passwordCandidate(email: candidate.email) == nil)
}
