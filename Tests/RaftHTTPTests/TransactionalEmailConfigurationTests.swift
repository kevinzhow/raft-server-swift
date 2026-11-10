import Foundation
import Testing
@testable import RaftHTTP

private func cloudflareEnvironment() -> [String: String] {
    [
        "RAFT_EMAIL_PROVIDER": "cloudflare",
        "CLOUDFLARE_ACCOUNT_ID": String(repeating: "a", count: 32),
        "CLOUDFLARE_EMAIL_API_TOKEN": "synthetic-cloudflare-token",
        "FROM_EMAIL": "Raft <noreply@mail.example.com>",
        "APP_URL": "https://raft.example.com"
    ]
}

@Test func cloudflareEmailConfigurationAcceptsAccountTokenAndSender() throws {
    let configuration = try TransactionalEmailConfiguration.fromEnvironment(cloudflareEnvironment())
    #expect(configuration.from == "Raft <noreply@mail.example.com>")
    #expect(configuration.webURL.absoluteString == "https://raft.example.com")
    #expect(!configuration.description.contains("synthetic-cloudflare-token"))
    #expect(!configuration.debugDescription.contains("synthetic-cloudflare-token"))
}

@Test func cloudflareEmailConfigurationRefusesIncompleteOrInjectedCredentials() {
    for key in ["CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_EMAIL_API_TOKEN", "FROM_EMAIL", "APP_URL"] {
        var values = cloudflareEnvironment()
        values[key] = ""
        #expect(throws: TransactionalEmailError.self) {
            try TransactionalEmailConfiguration.fromEnvironment(values)
        }
    }
    for invalid in ["../other", "a?token=unsafe", "a/b", String(repeating: "z", count: 32), " aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] {
        var values = cloudflareEnvironment()
        values["CLOUDFLARE_ACCOUNT_ID"] = invalid
        #expect(throws: TransactionalEmailError.self) {
            try TransactionalEmailConfiguration.fromEnvironment(values)
        }
    }
    var values = cloudflareEnvironment()
    values["CLOUDFLARE_EMAIL_API_TOKEN"] = "unsafe\r\nAuthorization: other"
    #expect(throws: TransactionalEmailError.self) {
        try TransactionalEmailConfiguration.fromEnvironment(values)
    }
}

@Test func emailConfigurationKeepsResendDefaultAndRejectsUnknownProviders() throws {
    let configuration = try TransactionalEmailConfiguration.fromEnvironment([
        "RESEND_API_KEY": "synthetic-resend-key",
        "FROM_EMAIL": "noreply@mail.example.com",
        "APP_URL": "https://raft.example.com"
    ])
    #expect(configuration.from == "noreply@mail.example.com")
    var values = cloudflareEnvironment()
    values["RAFT_EMAIL_PROVIDER"] = "unknown"
    #expect(throws: TransactionalEmailError.self) {
        try TransactionalEmailConfiguration.fromEnvironment(values)
    }
}
