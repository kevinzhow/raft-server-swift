import Foundation
import HTTPTypes
import RaftHTTP
import RaftHTTPServer
import Testing
import Vapor
import VaporTesting

private func bodyText(_ response: ClientResponse) -> String {
    response.body.string ?? ""
}

@Test func visibleAndOneClickUnsubscribeShareASignedURLAndPersistOneLocalOptOut() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111180"
    accounts.addAccount(id: userId, email: "mobile-opt-out@example.com", password: "password123")
    let token = accounts.createMobileAppEmailUnsubscribeToken(userId: userId)
    let endpoint = "/api/email/mobile-app/unsubscribe?token=\(token)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let confirmation = try await client.get(URI(string: endpoint))
            #expect(confirmation.status == .ok)
            #expect(bodyText(confirmation).contains("Unsubscribe from mobile-app emails?"))
            #expect(accounts.mobileAppEmailContacts().isEmpty)

            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            let oneClick = try await client.send(.post, headers: headers, to: URI(string: endpoint)) { request in
                request.body = .init(string: "List-Unsubscribe=One-Click")
            }
            #expect(oneClick.status == .ok)
            #expect(bodyText(oneClick).isEmpty)

            let visible = try await client.send(.post, headers: headers, to: URI(string: "\(endpoint)&source=visible")) { request in
                request.body = .init(string: "List-Unsubscribe=One-Click")
            }
            #expect(visible.status == .ok)
            #expect(bodyText(visible).contains("You are unsubscribed"))

            let rows = accounts.mobileAppEmailContacts().filter { $0.audienceId == "mobile-app-lifecycle" }
            #expect(rows.count == 1)
            #expect(rows.first?.userId == userId)
            #expect(rows.first?.email == "mobile-opt-out@example.com")
            #expect(rows.first?.status == "unsubscribed")
            #expect(rows.first?.optedOutAt != nil)
        }
    }
}

@Test func tamperedUnsubscribeTokensFailClosedWithoutWritingContactState() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111180"
    accounts.addAccount(id: userId, email: "mobile-opt-out@example.com", password: "password123")
    let token = accounts.createMobileAppEmailUnsubscribeToken(userId: userId)
    let tampered = String(token.dropLast()) + "x"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            let response = try await client.send(.post, headers: headers, to: URI(string: "/api/email/mobile-app/unsubscribe?token=\(tampered)")) { request in
                request.body = .init(string: "List-Unsubscribe=One-Click")
            }
            #expect(response.status == .badRequest)
            #expect(accounts.mobileAppEmailContacts().isEmpty)
        }
    }
}

@Test func signedLocaleKeepsConfirmationAndSuccessInSimplifiedChinese() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111181"
    accounts.addAccount(id: userId, email: "mobile-opt-out@example.com", password: "password123")
    let token = accounts.createMobileAppEmailUnsubscribeToken(userId: userId, locale: "zh-CN")
    let endpoint = "/api/email/mobile-app/unsubscribe?token=\(token)"
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let confirmation = try await client.get(URI(string: endpoint))
            let confirmationHTML = bodyText(confirmation)
            #expect(confirmation.status == .ok)
            #expect(confirmationHTML.contains("<html lang=\"zh-CN\">"))
            #expect(confirmationHTML.contains("要退订移动端应用邮件吗？"))
            #expect(confirmationHTML.contains(">退订</button>"))

            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            let success = try await client.send(.post, headers: headers, to: URI(string: "\(endpoint)&source=visible")) { request in
                request.body = .init(string: "List-Unsubscribe=One-Click")
            }
            let successHTML = bodyText(success)
            #expect(success.status == .ok)
            #expect(successHTML.contains("<html lang=\"zh-CN\">"))
            #expect(successHTML.contains("你已退订。"))
        }
    }
}

@Test func oneClickPostFailsClosedWithoutTheRfc8058ConfirmationBody() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111182"
    accounts.addAccount(id: userId, email: "mobile-opt-out@example.com", password: "password123")
    let token = accounts.createMobileAppEmailUnsubscribeToken(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            let response = try await client.send(.post, to: URI(string: "/api/email/mobile-app/unsubscribe?token=\(token)"))
            #expect(response.status == .badRequest)
            #expect(accounts.mobileAppEmailContacts().isEmpty)
        }
    }
}

@Test func oneClickUnsubscribeCancelsAScheduledMobileAppEmail() async throws {
    let accounts = EmailLoginDirectory()
    let userId = "11111111-1111-4111-8111-111111111183"
    accounts.addAccount(id: userId, email: "mobile-opt-out@example.com", password: "password123")
    accounts.addMobileAppEmailJourney(
        userId: userId,
        email: "mobile-opt-out@example.com",
        journeyKey: "first_computer_mobile_app_48h",
        day1Status: "scheduled",
        day1EmailId: "scheduled-mobile-email"
    )
    let canceled = CancelLog()
    accounts.cancelMobileAppEmail = { canceled.ids.append($0) }
    let token = accounts.createMobileAppEmailUnsubscribeToken(userId: userId)
    try await withApp { app in
        configure(app, services: FallbackServices(
            nodeEnv: "test",
            tracker: DbLivenessTracker(ping: {}),
            pingDatabase: {},
            emailAccounts: accounts
        ))
        try await app.testing { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/x-www-form-urlencoded"
            let response = try await client.send(.post, headers: headers, to: URI(string: "/api/email/mobile-app/unsubscribe?token=\(token)")) { request in
                request.body = .init(string: "List-Unsubscribe=One-Click")
            }
            #expect(response.status == .ok)
            #expect(canceled.ids == ["scheduled-mobile-email"])
            let journeys = accounts.mobileAppEmailJourneys()
            #expect(journeys.count == 1)
            #expect(journeys.first?.day1Status == "skipped")
            #expect(journeys.first?.suppressedReason == "unsubscribed")
            #expect(journeys.first?.canceledAt != nil)
        }
    }
}

private final class CancelLog: @unchecked Sendable {
    var ids: [String] = []
}
