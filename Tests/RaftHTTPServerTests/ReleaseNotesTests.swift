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

private func services(_ notes: [ReleaseNoteRecord] = []) -> FallbackServices {
    FallbackServices(nodeEnv: "test", tracker: DbLivenessTracker(ping: {}), pingDatabase: {}, releaseNotes: notes)
}

private func entry(_ id: String, _ revision: Int, _ ordinal: Int, _ text: String) -> ReleaseNoteEntry {
    ReleaseNoteEntry(entryId: id, type: "fix", text: text, ordinal: ordinal, revision: revision)
}

@Test func releaseNotesListIsAnonymousAndRejectsBadPagination() async throws {
    try await withApp { app in
        configure(app, services: services())
        try await app.testing { client in
            let ok = try await client.get("/api/release-notes")
            #expect(ok.status == .ok)
            #expect(bodyText(ok) == "{\"items\":[],\"nextCursor\":null}")
            #expect(ok.headers[HTTPField.Name("Cache-Control")!] == "public, max-age=30")

            let badLimit = try await client.get("/api/release-notes?limit=101")
            #expect(badLimit.status == .badRequest)
            #expect(bodyText(badLimit) == "{\"code\":\"invalid_limit\"}")

            let badCursor = try await client.get("/api/release-notes?cursor=%21%21")
            #expect(badCursor.status == .badRequest)
            #expect(bodyText(badCursor) == "{\"code\":\"invalid_cursor\"}")
        }
    }
}

@Test func publishedReleaseNotesArePublicAndDraftsAreHidden() async throws {
    let published = "11111111-1111-4111-8111-111111111111"
    let retracted = "22222222-2222-4222-8222-222222222222"
    let notes = [
        ReleaseNoteRecord(id: published, releaseKey: "rn-1.0.0", version: "1.0.0", tag: "v1.0.0", date: "2026-09-01", currentRevision: 1, snapshotHash: String(repeating: "a", count: 64)),
        ReleaseNoteRecord(id: retracted, releaseKey: "rn-1.0.1", version: "1.0.1", tag: "v1.0.1", date: "2026-09-02", currentRevision: 1, retracted: true, snapshotHash: String(repeating: "b", count: 64)),
        ReleaseNoteRecord(id: "33333333-3333-4333-8333-333333333333", releaseKey: "rn-2.0.0", version: "2.0.0", tag: "v2.0.0", date: "2026-09-03", currentRevision: nil, snapshotHash: ""),
    ]
    try await withApp { app in
        configure(app, services: services(notes))
        try await app.testing { client in
            let response = try await client.get("/api/release-notes?limit=10")
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            let items = body?["items"] as? [[String: Any]] ?? []
            #expect(items.count == 2)
            let byKey = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, [String: Any])? in
                guard let key = item["releaseKey"] as? String else { return nil }
                return (key, item)
            })
            #expect(byKey["rn-2.0.0"] == nil)
            #expect(byKey["rn-1.0.0"]?["state"] as? String == "published")
            #expect(byKey["rn-1.0.1"]?["state"] as? String == "retracted")
        }
    }
}

@Test func releaseNoteEntriesUseTheCurrentRevisionInOrdinalOrder() async throws {
    let a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let r = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let notes = [
        ReleaseNoteRecord(
            id: a, releaseKey: "rn-3.0.0", version: "3.0.0", tag: "v3.0.0", date: "2026-09-10",
            currentRevision: 2, snapshotHash: String(repeating: "d", count: 64),
            entries: [entry("old", 1, 0, "a old revision"), entry("second", 2, 1, "a second"), entry("first", 2, 0, "a first")]
        ),
        ReleaseNoteRecord(
            id: b, releaseKey: "rn-3.0.1", version: "3.0.1", tag: "v3.0.1", date: "2026-09-11",
            currentRevision: 1, snapshotHash: String(repeating: "e", count: 64),
            entries: [entry("only", 1, 0, "b only")]
        ),
        ReleaseNoteRecord(
            id: r, releaseKey: "rn-3.0.2", version: "3.0.2", tag: "v3.0.2", date: "2026-09-12",
            currentRevision: 1, retracted: true, snapshotHash: String(repeating: "f", count: 64),
            entries: [entry("hidden", 1, 0, "retracted hidden")]
        ),
    ]
    try await withApp { app in
        configure(app, services: services(notes))
        try await app.testing { client in
            let response = try await client.get("/api/release-notes?limit=10")
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(response).utf8)) as? [String: Any]
            let items = body?["items"] as? [[String: Any]] ?? []
            func texts(_ key: String) -> [String] {
                let item = items.first { $0["releaseKey"] as? String == key }
                let entries = item?["entries"] as? [[String: Any]] ?? []
                return entries.compactMap { $0["text"] as? String }
            }
            #expect(texts("rn-3.0.0") == ["a first", "a second"])
            #expect(texts("rn-3.0.1") == ["b only"])
            #expect(texts("rn-3.0.2") == [])
            let sample = (items.first { $0["releaseKey"] as? String == "rn-3.0.1" }?["entries"] as? [[String: Any]])?.first
            #expect(sample?.keys.sorted() == ["emphasis", "entryId", "ordinal", "text", "type"])
        }
    }
}

@Test func releaseNoteDetailServesPublishedHidesUnknownAndRejectsBadIds() async throws {
    let id = "44444444-4444-4444-8444-444444444444"
    let notes = [
        ReleaseNoteRecord(id: id, releaseKey: "rn-detail", version: "3.3.1", tag: "t-detail", date: "2026-09-01", currentRevision: 1, snapshotHash: String(repeating: "e", count: 64)),
    ]
    try await withApp { app in
        configure(app, services: services(notes))
        try await app.testing { client in
            let bad = try await client.get("/api/release-notes/not-an-id")
            #expect(bad.status == .badRequest)
            #expect(bodyText(bad) == "{\"code\":\"invalid_release_id\"}")
            let missing = try await client.get("/api/release-notes/00000000-0000-4000-8000-000000000000")
            #expect(missing.status == .notFound)
            #expect(bodyText(missing) == "{\"code\":\"not_found\"}")
            let detail = try await client.get("/api/release-notes/\(id)")
            #expect(detail.status == .ok)
            let body = try JSONSerialization.jsonObject(with: Data(bodyText(detail).utf8)) as? [String: Any]
            #expect(body?["state"] as? String == "published")
        }
    }
}

@Test func onlyReleaseNoteIdentityUniquesAreReleaseExists() {
    #expect(ReleaseNotes.isReleaseIdentityUnique(DatabaseConstraintError(code: "23505", constraint: "release_notes_version_unique")))
    #expect(ReleaseNotes.isReleaseIdentityUnique(DatabaseConstraintError(code: "23505", constraint: "release_notes_tag_unique")))
    #expect(ReleaseNotes.isReleaseIdentityUnique(DatabaseConstraintError(code: "23505", constraint: "release_notes_release_key_unique")))
    #expect(ReleaseNotes.isReleaseIdentityUnique(DatabaseConstraintError(code: "23505", constraint: "release_note_mutation_receipts_actor_id_client_id_key_pk")) == false)
    #expect(ReleaseNotes.isReleaseIdentityUnique(DatabaseConstraintError(code: "23505", constraint: "release_note_audit_id_pk")) == false)
    #expect(ReleaseNotes.isReleaseIdentityUnique(DatabaseConstraintError(code: "23505", constraint: "users_email_unique")) == false)
    #expect(ReleaseNotes.isReleaseIdentityUnique(DatabaseConstraintError(code: "23503", constraint: "release_notes_version_unique")) == false)
    #expect(ReleaseNotes.isReleaseIdentityUnique(URLError(.badURL)) == false)
    #expect(ReleaseNotes.isReleaseIdentityUnique(nil) == false)
}
