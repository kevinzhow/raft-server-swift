import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import RaftDaemonClient

private func attestationJSON() -> [String: Any] {
    [
        "attestation": "signed-cap", "scope": "upload", "audience": "worker-1",
        "resource": "attachment/1", "expiresAt": "2026-10-02T00:00:00.000Z",
    ]
}
private func createJSON() -> [String: Any] {
    ["upload": ["method": "PUT", "url": "https://worker.test/blob/1", "headers": ["x-signed": "1"]]]
}

private final class Transport: @unchecked Sendable {
    var calls: [(url: String, method: String, headers: [String: String], body: String)] = []
    var responder: (Int) -> (Int, Data, [String: String]) = { index in
        switch index {
        case 0: return (200, try! JSONSerialization.data(withJSONObject: attestationJSON()), [:])
        case 1: return (200, try! JSONSerialization.data(withJSONObject: createJSON()), [:])
        default: return (200, Data(), [:])
        }
    }

    func send(_ request: URLRequest) async throws -> (Int, Data, [String: String]) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        calls.append((request.url?.absoluteString ?? "", request.httpMethod ?? "", request.allHTTPHeaderFields ?? [:], body))
        return responder(calls.count - 1)
    }
}

@Test func pullsASignedCapabilityFromTheServer() async throws {
    let transport = Transport()
    let capability = try await DirectUploadCapability.requestDaemonScopeAttestation(
        serverUrl: "https://server.test/", apiKey: "sk_machine", scope: "upload",
        send: { request in try await transport.send(request) }
    )
    #expect(capability.attestation == "signed-cap")
    #expect(capability.audience == "worker-1")
    #expect(capability.resource == "attachment/1")
    #expect(transport.calls.count == 1)
    #expect(transport.calls[0].url == "https://server.test/internal/machine/scope-attestation")
    #expect(transport.calls[0].method == "POST")
    #expect(transport.calls[0].headers["Authorization"] == "Bearer sk_machine")
    let body = try #require(try JSONSerialization.jsonObject(with: Data(transport.calls[0].body.utf8)) as? [String: Any])
    #expect(body["scope"] as? String == "upload")
}

@Test func forwardsCallerMetadataForServerSigning() async throws {
    let transport = Transport()
    _ = try await DirectUploadCapability.requestDaemonScopeAttestation(
        serverUrl: "https://server.test", apiKey: "k", scope: "upload",
        metadata: ["attachmentKind": "text", "size": "12"],
        send: { request in try await transport.send(request) }
    )
    let body = try #require(try JSONSerialization.jsonObject(with: Data(transport.calls[0].body.utf8)) as? [String: Any])
    let metadata = try #require(body["metadata"] as? [String: String])
    #expect(metadata == ["attachmentKind": "text", "size": "12"])
}

@Test func uploadKeepsTheServerOutOfTheDataPlane() async throws {
    let transport = Transport()
    let result = try await DirectUploadCapability.uploadWithSignedCapability(
        serverUrl: "https://server.test", apiKey: "k", workerUrl: "https://worker.test",
        scope: "upload", createBody: ["filename": "a.txt"], uploadBody: Data("bytes".utf8),
        send: { request in try await transport.send(request) }
    )
    #expect(result.uploadStatus == 200)
    #expect(transport.calls.count == 3)
    #expect(transport.calls[0].url == "https://server.test/internal/machine/scope-attestation")
    #expect(transport.calls[1].url == "https://worker.test/api/uploads")
    let createBody = try #require(try JSONSerialization.jsonObject(with: Data(transport.calls[1].body.utf8)) as? [String: Any])
    #expect(createBody["attestation"] as? String == "signed-cap")
    #expect(createBody["filename"] as? String == "a.txt")
    #expect(transport.calls[2].url == "https://worker.test/blob/1")
    #expect(transport.calls[2].method == "PUT")
    let signedHeader = transport.calls[2].headers.first { $0.key.lowercased() == "x-signed" }?.value
    #expect(signedHeader == "1")
    #expect(transport.calls[2].body == "bytes")
    #expect(!transport.calls[2].headers.keys.contains { $0.lowercased() == "authorization" },
            "the signed URL carries no server credentials")
}

@Test func classifiesAnHTML413FromTheServer() async {
    let transport = Transport()
    transport.responder = { _ in (413, Data("<html>too large</html>".utf8), ["Content-Type": "text/html"]) }
    do {
        _ = try await DirectUploadCapability.uploadWithSignedCapability(
            serverUrl: "https://server.test", apiKey: "k", workerUrl: "https://worker.test",
            scope: "upload", createBody: [:], uploadBody: Data(), send: { request in try await transport.send(request) }
        )
        Issue.record("expected failure")
    } catch {
        let failure = DirectUploadCapability.classify(error)
        #expect(failure.stage == .attestation)
        #expect(failure.httpStatus == 413)
        #expect(failure.httpClass == "4xx")
    }
}
