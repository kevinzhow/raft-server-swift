import Foundation
import RaftHTTP
import Testing

@Test func databaseHealthWithoutAURLStaysUnconfigured() async {
    let health = DatabaseHealth(databaseURL: "  \n ")
    #expect(!health.isConfigured)
    await #expect(throws: DatabaseHealthError.notConfigured) {
        try await health.ping()
    }
}

@Test func databaseHealthRejectsMalformedURLs() async {
    for raw in ["not-a-url", "http://localhost:5432/raft", "postgres:///raft"] {
        let health = DatabaseHealth(databaseURL: raw)
        #expect(health.isConfigured)
        await #expect(throws: DatabaseHealthError.invalidURL) {
            try await health.ping()
        }
    }
}

@Test func databaseHealthRejectsRequiredTLSWithoutAContext() async {
    let health = DatabaseHealth(databaseURL: "postgres://raft:raft@127.0.0.1:5432/raft?sslmode=require")
    await #expect(throws: DatabaseHealthError.tlsRequiresConfiguration) {
        try await health.ping()
    }
}

@Test func databaseHealthRunsSelectOneAgainstConfiguredPostgres() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RAFT_PG_INTEGRATION"] == "1",
          let url = environment["DATABASE_URL"], !url.isEmpty
    else { return }
    let health = DatabaseHealth(databaseURL: url)
    try await health.ping()
}
