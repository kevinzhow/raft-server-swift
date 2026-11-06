import Foundation
import Testing
@testable import RaftHTTP
import TestSupport

private func ledgerFixture() throws -> (OAuthLedger, String, String, String) {
    let ledger = OAuthLedger()
    let serverId = "33333333-3333-4333-8333-000001077001"
    let ownerId = "11111111-1111-4111-8111-000001077001"
    ledger.addOwnedServer(id: serverId, slug: "publisher", name: "Publisher", ownerId: ownerId)
    let created = try ledger.createClient(
        serverId: serverId, createdByUserId: ownerId, name: "Setup App",
        clientId: "setup-app", returnUrl: "https://setup.example.test/callback",
        setupUrl: "https://setup.example.test/configure", setupDescription: "Choose a repository"
    )
    return (ledger, serverId, ownerId, created.id)
}

@Test func creatingAClientStoresTheSetupDeclarationAtRevisionOne() throws {
    let (ledger, _, _, client) = try ledgerFixture()
    let declaration = try #require(ledger.clientSetupDeclaration(clientRecordId: client))
    #expect(declaration.url == "https://setup.example.test/configure")
    #expect(declaration.description == "Choose a repository")
    #expect(declaration.revision == 1)
}

@Test func setupURLValidationFailsClosedAtCreation() {
    let ledger = OAuthLedger()
    let serverId = "33333333-3333-4333-8333-000001077002"
    ledger.addOwnedServer(id: serverId, slug: "p", name: "P", ownerId: "u-owner")
    for url in ["javascript:alert(1)", "https://user:pass@example.test/s", "http://example.test/s", "https://example.test/s#frag"] {
        #expect(throws: AppSetupValidationError.self) {
            _ = try ledger.createClient(
                serverId: serverId, createdByUserId: "u-owner", name: "Bad", clientId: "bad-\(UUID().uuidString.prefix(4))",
                setupUrl: url
            )
        }
    }
}

@Test func changedSetupURLIsANewRevisionAndInvalidatesCompletion() throws {
    let (ledger, serverId, _, client) = try ledgerFixture()
    let installation = ledger.installClient(serverId: serverId, clientRecordId: client, installedByUserId: "u-owner", groups: [])
    #expect(try ledger.updateAppInstallationSetup(clientRecordId: client, installationId: installation, revision: 1, status: "complete")?.status == .complete)
    #expect(try ledger.updateClientSetupDeclaration(clientRecordId: client, setupUrl: "https://setup.example.test/revised", setupDescription: nil))
    let declaration = try #require(ledger.clientSetupDeclaration(clientRecordId: client))
    #expect(declaration.revision == 2)
    #expect(try ledger.getAppInstallationSetup(clientRecordId: client, serverId: serverId)?.status == .pending)
}

@Test func wordingOnlyChangeKeepsTheRevisionAndCompletion() throws {
    let (ledger, serverId, _, client) = try ledgerFixture()
    let installation = ledger.installClient(serverId: serverId, clientRecordId: client, installedByUserId: "u-owner", groups: [])
    _ = try ledger.updateAppInstallationSetup(clientRecordId: client, installationId: installation, revision: 1, status: "complete")
    #expect(try ledger.updateClientSetupDeclaration(
        clientRecordId: client, setupUrl: "https://setup.example.test/configure", setupDescription: "Clarified instructions"
    ))
    let declaration = try #require(ledger.clientSetupDeclaration(clientRecordId: client))
    #expect(declaration.revision == 1)
    #expect(try ledger.getAppInstallationSetup(clientRecordId: client, serverId: serverId)?.status == .complete)
}

@Test func reportingSetupIsRevisionBoundAndIdempotent() throws {
    let (ledger, serverId, _, client) = try ledgerFixture()
    let installation = ledger.installClient(serverId: serverId, clientRecordId: client, installedByUserId: "u-owner", groups: [])
    #expect(throws: OAuthLedger.AppSetupConflictError.self) {
        try ledger.updateAppInstallationSetup(clientRecordId: client, installationId: installation, revision: 2, status: "complete")
    }
    let first = try #require(try ledger.updateAppInstallationSetup(
        clientRecordId: client, installationId: installation, revision: 1, status: "complete"
    ))
    let replay = try #require(try ledger.updateAppInstallationSetup(
        clientRecordId: client, installationId: installation, revision: 1, status: "complete"
    ))
    #expect(first == replay)
    #expect(first.status == .complete)
    #expect(first.completedAt != nil)
    #expect(ledger.integrationAuditEventCount(eventType: "installation.setup_updated") == 1)
    #expect(try ledger.updateAppInstallationSetup(
        clientRecordId: client, installationId: installation, revision: 1, status: "pending"
    )?.status == .pending)
    #expect(ledger.integrationAuditEventCount(eventType: "installation.setup_updated") == 2)
}

@Test func reportingRequiresAnActiveInstallationOfTheOwningApp() throws {
    let (ledger, serverId, _, client) = try ledgerFixture()
    let installation = ledger.installClient(serverId: serverId, clientRecordId: client, installedByUserId: "u-owner", groups: [])
    let other = try ledger.createClient(
        serverId: serverId, createdByUserId: "u-owner", name: "Other", clientId: "other-app",
        setupUrl: "https://other.example.test/setup"
    )
    #expect(try ledger.updateAppInstallationSetup(
        clientRecordId: other.id, installationId: installation, revision: 1, status: "complete"
    ) == nil)
    ledger.setInstallationStatusForTesting(clientRecordId: client, serverId: serverId, status: "suspended")
    #expect(ledger.getAppInstallationSetup(clientRecordId: client, serverId: serverId) == nil)
    #expect(try ledger.updateAppInstallationSetup(
        clientRecordId: client, installationId: installation, revision: 1, status: "complete"
    ) == nil)
}

@Test func appsWithoutSetupURLAreNotRequiredAndCannotReport() throws {
    let ledger = OAuthLedger()
    let serverId = "33333333-3333-4333-8333-000001077003"
    ledger.addOwnedServer(id: serverId, slug: "p", name: "P", ownerId: "u-owner")
    let created = try ledger.createClient(
        serverId: serverId, createdByUserId: "u-owner", name: "No Setup", clientId: "no-setup"
    )
    let installation = ledger.installClient(serverId: serverId, clientRecordId: created.id, installedByUserId: "u-owner", groups: [])
    #expect(ledger.getAppInstallationSetup(clientRecordId: created.id, serverId: serverId)?.status == .notRequired)
    #expect(throws: OAuthLedger.AppSetupConflictError.self) {
        try ledger.updateAppInstallationSetup(clientRecordId: created.id, installationId: installation, revision: 1, status: "complete")
    }
}

@Test func uninstallDropsTheInstallationAndReinstallIsFresh() throws {
    let (ledger, serverId, _, client) = try ledgerFixture()
    let firstInstallation = ledger.installClient(serverId: serverId, clientRecordId: client, installedByUserId: "u-owner", groups: [])
    _ = try ledger.updateAppInstallationSetup(clientRecordId: client, installationId: firstInstallation, revision: 1, status: "complete")
    #expect(ledger.uninstallClient(serverId: serverId, clientRecordId: client))
    #expect(ledger.getAppInstallationSetup(clientRecordId: client, serverId: serverId) == nil)
    #expect(try ledger.updateAppInstallationSetup(
        clientRecordId: client, installationId: firstInstallation, revision: 1, status: "complete"
    ) == nil)
    let secondInstallation = ledger.installClient(serverId: serverId, clientRecordId: client, installedByUserId: "u-owner", groups: [])
    #expect(secondInstallation != firstInstallation)
    #expect(try ledger.getAppInstallationSetup(clientRecordId: client, serverId: serverId)?.status == .pending)
}
