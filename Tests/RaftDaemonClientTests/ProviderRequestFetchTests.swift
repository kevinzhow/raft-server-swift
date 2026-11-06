import Foundation
import Synchronization
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

@Test func concurrentResponseBodyUpdatesProduceWholeIndependentClones() {
    let firstText = String(repeating: "a", count: 8_192)
    let secondText = String(repeating: "b", count: 8_192)
    let first = Data(firstText.utf8)
    let second = Data(secondText.utf8)
    let response = ProviderHTTPResponse(status: 200, url: "https://provider.test/final", redirected: true,
                                        headers: ["content-type": "text/plain"], body: first)
    let readers = Mutex(3)
    let invalid = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: 4) { worker in
        if worker == 0 {
            while readers.withLock({ $0 > 0 }) {
                response.body = first
                response.body = second
                response.body = nil
            }
        } else {
            defer { readers.withLock { $0 -= 1 } }
            for _ in 0..<500 {
                let text = response.text()
                let clone = response.clone()
                let clonedText = clone.text()
                let validText = ["", firstText, secondText].contains(text)
                let validClone = ["", firstText, secondText].contains(clonedText)
                if !validText || !validClone || clone === response || clone.status != 200
                    || clone.url != response.url || clone.headers != response.headers || !clone.redirected {
                    invalid.withLock { $0 += 1 }
                }
                clone.body = Data("clone only".utf8)
                if clone.text() != "clone only" || response.text() == "clone only" {
                    invalid.withLock { $0 += 1 }
                }
            }
        }
    }
    #expect(invalid.withLock { $0 } == 0)
}

@Test func responseObserverCanUpdateTheOriginalBodyBeforeItIsReturned() async throws {
    let response = ProviderHTTPResponse(status: 200, url: "https://provider.test", body: Data("before".utf8))
    let result = try await ProviderRequestFetch.fetch(
        ProviderRequest(url: response.url), provider: "custom", observe: { activity in
            if activity.phase == "responding" { response.body = Data("after headers".utf8) }
        }, send: { _ in response }
    )
    #expect(result === response)
    #expect(result.text() == "after headers")
    let clone = result.clone()
    result.body = Data("later".utf8)
    #expect(clone.text() == "after headers")
    #expect(result.text() == "later")
}

// Keep the fixture's temporary Data out of the caller so that the response
// owns the last storage reference when the caller replaces body.
@inline(never)
private func installCustomResponseBody(
    _ response: ProviderHTTPResponse,
    didDeallocate: @escaping @Sendable () -> Void
) {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 8_192, alignment: 1)
    bytes.initializeMemory(as: UInt8.self, repeating: 120, count: 8_192)
    response.body = Data(bytesNoCopy: bytes, count: 8_192, deallocator: .custom { bytes, _ in
        didDeallocate()
        bytes.deallocate()
    })
}

@Test func replacingResponseBodyReleasesCustomStorageAfterUnlocking() {
    let response = ProviderHTTPResponse(status: 200, url: "https://provider.test")
    let readerFinished = DispatchSemaphore(value: 0)
    let readerExited = DispatchSemaphore(value: 0)
    let deallocatorFinished = DispatchSemaphore(value: 0)
    let observed = Mutex((deallocations: 0, readBeforeDeallocationReturned: false, body: Data?.none, text: String?.none))
    installCustomResponseBody(response) {
        Thread.detachNewThread {
            defer { readerExited.signal() }
            let body = response.body
            let text = response.text()
            observed.withLock { $0.body = body; $0.text = text }
            readerFinished.signal()
        }
        let completed = readerFinished.wait(timeout: .now() + 2) == .success
        observed.withLock {
            $0.deallocations += 1
            $0.readBeforeDeallocationReturned = completed
        }
        deallocatorFinished.signal()
    }
    #expect(observed.withLock { $0.deallocations } == 0, "the fixture must not copy/free the no-copy storage before replacement")
    response.body = nil
    #expect(deallocatorFinished.wait(timeout: .now() + 2) == .success)
    #expect(readerExited.wait(timeout: .now() + 2) == .success, "drain the real reader even when the deallocator's bounded wait times out")
    let result = observed.withLock { $0 }
    #expect(result.deallocations == 1)
    #expect(result.readBeforeDeallocationReturned, "a deallocator waiting for another thread to read body/text must not hold the response mutex")
    #expect(result.body == nil)
    #expect(result.text == "")
}
