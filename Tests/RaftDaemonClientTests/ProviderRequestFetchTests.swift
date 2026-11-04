import Foundation
import Testing
import RaftDaemonClient

@Test func reportsWaitingThenHeadersWithoutObservingTheBody() async throws {
    final class States: @unchecked Sendable { var items: [ProviderRequestActivity] = [] }
    let states = States()
    let request = ProviderRequest(url: "https://provider.test/private-path", method: "POST", body: Data("private-prompt".utf8))
    let response = ProviderHTTPResponse(
        status: 200, url: request.url, headers: ["content-type": "text/event-stream"],
        body: Data("original response bytes".utf8)
    )
    final class Seen: @unchecked Sendable { var request: ProviderRequest? }
    let seen = Seen()
    let result = try await ProviderRequestFetch.fetch(request, provider: "deepseek", observe: { states.items.append($0) }) { sent in
        seen.request = sent
        return response
    }
    #expect(states.items.map(\.phase) == ["waiting", "responding"])
    #expect(Set(states.items.map(\.requestId)).count == 1)
    #expect(states.items.first?.provider == "deepseek")
    #expect(result === response)
    #expect(seen.request == request, "the original body source and options are preserved")
    #expect(result.text() == "original response bytes")
    #expect(states.items.map(\.provider).contains("deepseek"))
    #expect(!String(describing: states.items).contains("private"), "no request or response body reaches diagnostics")
}

@Test func redirectResponseRetainsIdentityMetadataAndCloneableBody() async throws {
    let original = ProviderHTTPResponse(
        status: 200, url: "https://provider.test/final", redirected: true,
        headers: ["location": "/final"], body: Data("original bytes".utf8)
    )
    let result = try await ProviderRequestFetch.fetch(
        ProviderRequest(url: "https://provider.test/redirect"), provider: "custom"
    ) { _ in original }
    #expect(result === original)
    #expect(result.redirected)
    #expect(result.url == "https://provider.test/final")
    #expect(result.bodyLocked == false)
    let clone = result.clone()
    #expect(clone.text() == "original bytes")
    #expect(result.text() == "original bytes")
}

@Test func diagnosticsPreserveOptionsFailuresAndCancellationEvenIfObserverThrows() async throws {
    final class States: @unchecked Sendable { var items: [ProviderRequestActivity] = [] }
    let states = States()
    let request = ProviderRequest(url: "https://local-test.invalid", method: "POST", body: Data("original body".utf8))
    struct Boom: Error {}
    for status in [200, 401, 503] {
        let response = ProviderHTTPResponse(status: status, url: request.url, body: Data("original failure".utf8))
        let result = try await ProviderRequestFetch.fetch(
            request, provider: "custom",
            observe: { states.items.append($0); throw Boom() }
        ) { sent in
            #expect(sent == request)
            return response
        }
        _ = result
        #expect(states.items.last?.phase == (status == 200 ? "responding" : "failed"))
        #expect(states.items.last?.httpStatus == status)
    }
    let failure = Boom()
    await #expect(throws: Boom.self) {
        _ = try await ProviderRequestFetch.fetch(request, provider: "custom") { _ in throw failure }
    }
    var cancelledRequest = request
    cancelledRequest.cancelled = true
    await #expect(throws: Boom.self) {
        _ = try await ProviderRequestFetch.fetch(
            cancelledRequest, provider: "custom", observe: { states.items.append($0) }
        ) { _ in throw failure }
    }
    #expect(states.items.last?.phase == "cancelled")
}
