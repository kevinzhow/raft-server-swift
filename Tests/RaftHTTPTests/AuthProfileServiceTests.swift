import Foundation
import Testing
import TestSupport
@testable import RaftHTTP

/// The profile service owns the four published account-profile operations. The
/// HTTP route tests lock the wire shape; these tests lock the store contract the
/// routes now depend on.

@Test func authProfileForgotPasswordRejectsMissingEmailButAcceptsEveryAddress() throws {
    let scene = AuthServicesUnitFixture()
    let userId = "11111111-1111-4111-8111-111111111401"
    scene.addAccount(id: userId, email: "Profile@Example.Test", password: "password123")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let service = scene.makeProfileService(
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
    let stored = scene.resetToken(
        hash: AuthTokenCodec.sha256("profile-reset-token")
    )
    #expect(stored?.userId == userId)
    #expect(stored?.expiresAt == now.addingTimeInterval(60 * 60))

    // An unknown address answers the same acceptance and grows no token.
    let unknown = try service.forgotPassword(ForgotPasswordRequest(email: "missing@example.test"))
    #expect(unknown.ok)
    #expect(scene.resetToken(hash: AuthTokenCodec.sha256("profile-reset-token"))?.userId == userId)
}

@Test func authProfileResetPasswordConsumesTheTokenOnceAndWritesTheCredential() throws {
    let scene = AuthServicesUnitFixture()
    let userId = "11111111-1111-4111-8111-111111111402"
    scene.addAccount(id: userId, email: "reset@profile.test", password: "password123")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    scene.addPasswordResetTokenForTesting(
        userId: userId,
        token: "profile-reset-token",
        expiresAt: now.addingTimeInterval(600)
    )
    let service = scene.makeProfileService(now: { now })

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
    let account = scene.passwordCredentialFacts(email: "reset@profile.test")
    let encoded = try #require(account?.passwordHash)
    #expect(encoded.hasPrefix("$argon2id$v=19$m=65536,t=3,p=4$"))
    #expect(PasswordCredential.verify("new-password-123", encoded: encoded))
    #expect(account?.passwordCredentialEstablishedAt == now)

    // The token was spent by the first success; the replay writes nothing.
    #expect(throws: AuthProfileError.invalidOrExpiredResetToken) {
        try service.resetPassword(ResetPasswordRequest(token: "profile-reset-token", password: "second-password"))
    }
    #expect(scene.passwordCredentialFacts(email: "reset@profile.test")?.passwordHash == encoded)
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
    let scene = AuthServicesUnitFixture()
    let userId = "11111111-1111-4111-8111-111111111403"
    scene.addAccount(id: userId, email: "cancel@profile.test", password: "password123")
    let token = scene.issuePendingSocialLinkForTesting(
        provider: "google",
        providerUserId: "profile-cancel",
        email: "cancel@profile.test"
    )
    let service = scene.makeProfileService()

    _ = service.cancelPendingLink(CancelPendingLinkRequest(pendingLinkToken: token))
    #expect(scene.pendingSocialLinkCancelled(token: token) == true)

    // A repeat cancel and an unknown token are the same no-op.
    _ = service.cancelPendingLink(CancelPendingLinkRequest(pendingLinkToken: token))
    _ = service.cancelPendingLink(CancelPendingLinkRequest(pendingLinkToken: "unknown-token"))
    _ = service.cancelPendingLink(CancelPendingLinkRequest())
    #expect(scene.pendingSocialLinkCancelled(token: token) == true)
}

@Test func authProfileTimezoneObservationKeepsTheFirstPairAndValidatesTheShape() throws {
    let scene = AuthServicesUnitFixture()
    let userId = "11111111-1111-4111-8111-111111111404"
    scene.addAccount(id: userId, email: "timezone@profile.test", password: "password123")
    let token = scene.mintAccessTokenForTesting(userId: userId)
    let firstNow = Date(timeIntervalSince1970: 1_700_000_000)
    let secondNow = firstNow.addingTimeInterval(60)
    let first = scene.makeProfileService(now: { firstNow })
    let second = scene.makeProfileService(now: { secondNow })
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

    // Pinned `lib/ianaTimezone.ts` publishes one sentence per failure.
    #expect(throws: AuthProfileError.timezoneEmpty) {
        try first.observeTimezone(
            authorization: authorization,
            TimezoneObservationRequest(timezone: "   ")
        )
    }
    #expect(throws: AuthProfileError.timezoneTooLong) {
        try first.observeTimezone(
            authorization: authorization,
            TimezoneObservationRequest(timezone: String(repeating: "A", count: 129))
        )
    }
    #expect(throws: AuthProfileError.timezoneNotIana) {
        try first.observeTimezone(
            authorization: authorization,
            TimezoneObservationRequest(timezone: "Not/A_Timezone")
        )
    }
    for raw in ["PST", "+08:00", "GMT", "UTC+0"] {
        #expect(throws: raw == "UTC+0" ? AuthProfileError.timezoneNotIana : AuthProfileError.timezoneNotCanonical) {
            try first.observeTimezone(
                authorization: authorization,
                TimezoneObservationRequest(timezone: raw)
            )
        }
    }
    // A body that misses the strict schema publishes the zod issue list instead
    // of the zone-value refusal.
    #expect(throws: AuthProfileError.invalidTimezoneObservationBody([
        AuthRequestIssue(path: "timezone", message: "Invalid input: expected string, received undefined"),
    ])) {
        try first.observeTimezone(authorization: authorization, TimezoneObservationRequest())
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

@Test func timezoneObservationRequestDecodesStrictSchemaIssues() throws {
    let decoder = JSONDecoder()
    let extra = try decoder.decode(
        TimezoneObservationRequest.self,
        from: Data(#"{"timezone":"UTC","source":"client-controlled"}"#.utf8)
    )
    #expect(extra.issues == [
        AuthRequestIssue(path: "", message: #"Unrecognized key: "source""#),
    ])
    let missing = try decoder.decode(TimezoneObservationRequest.self, from: Data("{}".utf8))
    #expect(missing.issues == [
        AuthRequestIssue(path: "timezone", message: "Invalid input: expected string, received undefined"),
    ])

    let accepted = try decoder.decode(
        TimezoneObservationRequest.self,
        from: Data(#"{"timezone":" Asia/Shanghai "}"#.utf8)
    )
    #expect(accepted.timezone == " Asia/Shanghai ")
    #expect(accepted.issues.isEmpty)
    let nullValue = try decoder.decode(
        TimezoneObservationRequest.self,
        from: Data(#"{"timezone":null}"#.utf8)
    )
    #expect(nullValue.timezone == nil)
    #expect(nullValue.issues == [
        AuthRequestIssue(path: "timezone", message: "Invalid input: expected string, received null"),
    ])
}

private extension ISO8601DateFormatter {
    static func profileTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
