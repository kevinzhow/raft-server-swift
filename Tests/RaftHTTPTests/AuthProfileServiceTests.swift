import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The profile service owns the four published account-profile operations. The
/// HTTP route tests lock the wire shape; these tests lock the store contract the
/// routes now depend on.

@Test func authProfileForgotPasswordRejectsMissingEmailButAcceptsEveryAddress() throws {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111401"
    directory.addAccount(id: userId, email: "Profile@Example.Test", password: "password123")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let service = AuthProfileService(
        store: directory.authProfileStore,
        now: { now },
        makeToken: { "profile-reset-token" }
    )

    #expect(throws: AuthProfileError.emailRequired) {
        try service.forgotPassword(ForgotPasswordRequest())
    }
    #expect(throws: AuthProfileError.emailRequired) {
        try service.forgotPassword(ForgotPasswordRequest(email: ""))
    }

    // The lookup normalizes first, so the published case/whitespace tolerance
    // still finds the row.
    let known = try service.forgotPassword(ForgotPasswordRequest(email: "  PROFILE@example.test "))
    #expect(known.ok)
    let stored = directory.authProfileStore.resetToken(
        hash: EmailLoginDirectory.sha256("profile-reset-token")
    )
    #expect(stored?.userId == userId)
    #expect(stored?.expiresAt == now.addingTimeInterval(60 * 60))

    // An unknown address answers the same acceptance and grows no token.
    let unknown = try service.forgotPassword(ForgotPasswordRequest(email: "missing@example.test"))
    #expect(unknown.ok)
    #expect(directory.authProfileStore.resetToken(hash: EmailLoginDirectory.sha256("profile-reset-token"))?.userId == userId)
}

@Test func authProfileResetPasswordConsumesTheTokenOnceAndWritesTheCredential() throws {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111402"
    directory.addAccount(id: userId, email: "reset@profile.test", password: "password123")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    directory.addPasswordResetTokenForTesting(
        userId: userId,
        token: "profile-reset-token",
        expiresAt: now.addingTimeInterval(600)
    )
    let service = AuthProfileService(store: directory.authProfileStore, now: { now })

    #expect(throws: AuthProfileError.missingResetCredentials) {
        try service.resetPassword(ResetPasswordRequest(token: nil, password: "new-password-123"))
    }
    #expect(throws: AuthProfileError.missingResetCredentials) {
        try service.resetPassword(ResetPasswordRequest(token: "profile-reset-token", password: ""))
    }

    let ok = try service.resetPassword(
        ResetPasswordRequest(token: "profile-reset-token", password: "new-password-123")
    )
    #expect(ok.ok)
    let account = directory.authProfileStore.accounts[EmailLoginDirectory.normalize("reset@profile.test")]
    #expect(account?.passwordHash == EmailLoginDirectory.sha256("new-password-123"))
    #expect(account?.passwordCredentialEstablishedAt == now)

    // The token was spent by the first success; the replay writes nothing.
    #expect(throws: AuthProfileError.invalidOrExpiredResetToken) {
        try service.resetPassword(ResetPasswordRequest(token: "profile-reset-token", password: "second-password"))
    }
    #expect(account?.passwordHash == EmailLoginDirectory.sha256("new-password-123"))
}

@Test func authProfileResetPasswordKeepsTheTypedRequestLenient() throws {
    // The retired raw parser read `token` and `password` with `as? String`, so
    // a non-string alias key must not reject an otherwise valid body.
    let body = Data(#"{"token":"t","password":"p","newPassword":42}"#.utf8)
    let request = try JSONDecoder().decode(ResetPasswordRequest.self, from: body)
    #expect(request.token == "t")
    #expect(request.password == "p")
    #expect(request.newPassword == nil)
}

@Test func authProfileCancelPendingLinkMarksTheTokenCancelled() {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111403"
    directory.addAccount(id: userId, email: "cancel@profile.test", password: "password123")
    let token = directory.issuePendingSocialLinkForTesting(
        provider: "google",
        providerUserId: "profile-cancel",
        email: "cancel@profile.test"
    )
    let service = AuthProfileService(store: directory.authProfileStore)

    _ = service.cancelPendingLink(CancelPendingLinkRequest(pendingLinkToken: token))
    #expect(directory.authProfileStore.accountState.pendingSocialLinks[token]?.cancelled == true)

    // A repeat cancel and an unknown token are the same no-op.
    _ = service.cancelPendingLink(CancelPendingLinkRequest(pendingLinkToken: token))
    _ = service.cancelPendingLink(CancelPendingLinkRequest(pendingLinkToken: "unknown-token"))
    _ = service.cancelPendingLink(CancelPendingLinkRequest())
    #expect(directory.authProfileStore.accountState.pendingSocialLinks[token]?.cancelled == true)
}

@Test func authProfileTimezoneObservationKeepsTheFirstPairAndValidatesTheShape() throws {
    let directory = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111404"
    directory.addAccount(id: userId, email: "timezone@profile.test", password: "password123")
    let token = directory.mintAccessTokenForTesting(userId: userId)
    let firstNow = Date(timeIntervalSince1970: 1_700_000_000)
    let secondNow = firstNow.addingTimeInterval(60)
    let first = AuthProfileService(store: directory.authProfileStore, now: { firstNow })
    let second = AuthProfileService(store: directory.authProfileStore, now: { secondNow })
    let authorization = "Bearer \(token)"

    #expect(throws: AuthProfileError.unauthenticated) {
        try first.observeTimezone(
            authorization: nil,
            TimezoneObservationRequest(timezone: "UTC")
        )
    }
    #expect(throws: AuthProfileError.unauthenticated) {
        try first.observeTimezone(
            authorization: "Bearer unknown-token",
            TimezoneObservationRequest(timezone: "UTC")
        )
    }

    let invalid = [
        "{}", "Not/A_Timezone", "PST", "+08:00", String(repeating: "A", count: 129),
    ]
    for raw in invalid {
        #expect(throws: AuthProfileError.invalidTimezoneObservation) {
            try first.observeTimezone(
                authorization: authorization,
                TimezoneObservationRequest(timezone: raw)
            )
        }
    }

    // The alias canonicalizes to the IANA zone, and the first pair survives the
    // second observation.
    let observedFirst = try first.observeTimezone(
        authorization: authorization,
        TimezoneObservationRequest(timezone: "  US/Pacific  ")
    )
    #expect(observedFirst.firstObservedTimezone == "America/Los_Angeles")
    #expect(observedFirst.lastObservedTimezone == "America/Los_Angeles")
    #expect(observedFirst.firstObservedTimezoneAt == observedFirst.lastObservedTimezoneAt)

    let observedSecond = try second.observeTimezone(
        authorization: authorization,
        TimezoneObservationRequest(timezone: "Asia/Tokyo")
    )
    #expect(observedSecond.firstObservedTimezone == "America/Los_Angeles")
    #expect(observedSecond.firstObservedTimezoneAt == observedFirst.firstObservedTimezoneAt)
    #expect(observedSecond.lastObservedTimezone == "Asia/Tokyo")
    #expect(observedSecond.lastObservedTimezoneAt == ISO8601DateFormatter.profileTimestamp(secondNow))
}

@Test func timezoneObservationRequestRejectsUnknownKeys() throws {
    let decoder = JSONDecoder()
    #expect(throws: (any Error).self) {
        try decoder.decode(
            TimezoneObservationRequest.self,
            from: Data(#"{"timezone":"UTC","source":"client-controlled"}"#.utf8)
        )
    }
    #expect(throws: (any Error).self) {
        try decoder.decode(TimezoneObservationRequest.self, from: Data("{}".utf8))
    }

    let accepted = try decoder.decode(
        TimezoneObservationRequest.self,
        from: Data(#"{"timezone":" Asia/Shanghai "}"#.utf8)
    )
    #expect(accepted.timezone == " Asia/Shanghai ")
    let nullValue = try decoder.decode(
        TimezoneObservationRequest.self,
        from: Data(#"{"timezone":null}"#.utf8)
    )
    #expect(nullValue.timezone == nil)
}

private extension ISO8601DateFormatter {
    static func profileTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
