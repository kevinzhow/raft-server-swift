import Foundation
import Testing
@testable import RaftHTTP

@Test func safeReturnURLRulesMatchOAuth() {
    #expect(AppSetupContract.isSafeOAuthReturnURL("https://setup.example.test/configure"))
    #expect(AppSetupContract.isSafeOAuthReturnURL("http://localhost:3000/setup"))
    #expect(AppSetupContract.isSafeOAuthReturnURL("http://127.0.0.1/setup"))
    #expect(!AppSetupContract.isSafeOAuthReturnURL("http://example.test/setup"))
    #expect(!AppSetupContract.isSafeOAuthReturnURL("https://user:pass@example.test/setup"))
    #expect(!AppSetupContract.isSafeOAuthReturnURL("https://example.test/setup#token"))
    #expect(!AppSetupContract.isSafeOAuthReturnURL("javascript:alert(1)"))
    #expect(!AppSetupContract.isSafeOAuthReturnURL("not a url"))
}

@Test func setupURLNormalizationFailsClosed() throws {
    #expect(try AppSetupContract.normalizeSetupUrl(nil) == nil)
    #expect(try AppSetupContract.normalizeSetupUrl("") == nil)
    #expect(try AppSetupContract.normalizeSetupUrl("   ") == nil)
    #expect(try AppSetupContract.normalizeSetupUrl("https://setup.example.test/configure") == "https://setup.example.test/configure")
    #expect(throws: AppSetupValidationError.self) { try AppSetupContract.normalizeSetupUrl("javascript:alert(1)") }
    #expect(throws: AppSetupValidationError.self) { try AppSetupContract.normalizeSetupUrl("https://user:pass@example.test/setup") }
    #expect(throws: AppSetupValidationError.self) { try AppSetupContract.normalizeSetupUrl("https://example.test/setup#token") }
    #expect(throws: AppSetupValidationError.self) {
        try AppSetupContract.normalizeSetupUrl("https://example.test/" + String(repeating: "a", count: 2001))
    }
}

@Test func setupDescriptionMustBeASingleLine() throws {
    #expect(try AppSetupContract.normalizeSetupDescription(nil) == nil)
    #expect(try AppSetupContract.normalizeSetupDescription("  Select a repository  ") == "Select a repository")
    #expect(throws: AppSetupValidationError.self) { try AppSetupContract.normalizeSetupDescription("two\nlines") }
    #expect(throws: AppSetupValidationError.self) { try AppSetupContract.normalizeSetupDescription("tab\there") }
    #expect(throws: AppSetupValidationError.self) {
        try AppSetupContract.normalizeSetupDescription(String(repeating: "x", count: 501))
    }
}

@Test func installationIdMustBeAUUID() throws {
    let id = "0f8fad5b-d9cb-469f-a165-70867728950e"
    #expect(try AppSetupContract.normalizeInstallationId(id) == id)
    #expect(throws: AppSetupValidationError.self) { try AppSetupContract.normalizeInstallationId("not-a-uuid") }
    #expect(throws: AppSetupValidationError.self) { try AppSetupContract.normalizeInstallationId("../other-server.json") }
}

@Test func projectionCarriesExactContextAndRevision() throws {
    let installationId = "0f8fad5b-d9cb-469f-a165-70867728950e"
    let pending = try AppSetupContract.project(
        setupUrl: "https://setup.example.test/configure?from=raft&server_id=untrusted",
        setupDescription: "Choose a repository", setupRevision: 1,
        installationId: installationId, serverId: "server-target",
        completedRevision: nil, completedAt: nil
    )
    #expect(pending.status == .pending)
    #expect(pending.revision == 1)
    #expect(pending.description == "Choose a repository")
    #expect(pending.completedAt == nil)
    let components = try #require(pending.url.flatMap { URLComponents(string: $0) })
    #expect(components.host == "setup.example.test")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["installation_id"] == installationId)
    #expect(query["server_id"] == "server-target")
    #expect(query["setup_revision"] == "1")
    #expect(query["from"] == "raft")

    let complete = try AppSetupContract.project(
        setupUrl: "https://setup.example.test/configure", setupDescription: nil, setupRevision: 2,
        installationId: installationId, serverId: "server-target",
        completedRevision: 2, completedAt: Date(timeIntervalSince1970: 0)
    )
    #expect(complete.status == .complete)
    #expect(complete.completedAt == "1970-01-01T00:00:00.000Z")
}

@Test func notRequiredWhenNoSetupURL() throws {
    let state = try AppSetupContract.project(
        setupUrl: nil, setupDescription: "ignored", setupRevision: 3,
        installationId: "0f8fad5b-d9cb-469f-a165-70867728950e", serverId: "s",
        completedRevision: 3, completedAt: Date()
    )
    #expect(state.status == .notRequired)
    #expect(state.url == nil)
    #expect(state.description == nil)
    #expect(state.completedAt == nil)
}
