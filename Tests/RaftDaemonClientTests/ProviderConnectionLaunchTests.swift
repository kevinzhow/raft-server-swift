import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import RaftDaemonClient

private final class Mock: @unchecked Sendable {
    var status = 200
    var body = Data()
    var captured: URLRequest?
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        captured = request
        return (status, body)
    }
}

private func bodyJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func deps(_ mock: Mock) -> ProviderConnectionLaunchClient.Send {
    { request in try await mock.send(request) }
}

@Test func acceptsAnExactDeepSeekProjection() async throws {
    let mock = Mock()
    mock.body = bodyJSON([
        "envVars": ["DEEPSEEK_API_KEY": "spawn-only-secret"],
        "providerConnection": ["providerId": "deepseek", "endpointUrl": NSNull(), "supportsImageInput": false],
    ])
    let result = try await ProviderConnectionLaunchClient.request(
        serverUrl: "http://localhost:3001", daemonApiKey: "sk_machine_test",
        agentId: "agent-1", connectionId: "11111111-1111-4111-8111-111111111111", send: deps(mock)
    )
    #expect(result.envVars["DEEPSEEK_API_KEY"] == "spawn-only-secret")
    #expect(result.providerConnection.providerId == "deepseek")
    let request = try #require(mock.captured)
    #expect(request.url?.absoluteString == "http://localhost:3001/internal/computer/runners/agent-1/provider-connection")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_machine_test")
    #expect(request.value(forHTTPHeaderField: "X-Raft-Client") == "daemon-server-session-worker")
    let sent = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    #expect(sent["connectionId"] as? String == "11111111-1111-4111-8111-111111111111")
}

@Test func acceptsGeneratedPresetProviderEnvironmentKeys() async throws {
    let mock = Mock()
    mock.body = bodyJSON([
        "envVars": ["GEMINI_API_KEY": "spawn-only-google-secret"],
        "providerConnection": ["providerId": "google", "endpointUrl": NSNull(), "supportsImageInput": false],
    ])
    let result = try await ProviderConnectionLaunchClient.request(
        serverUrl: "http://localhost:3001", daemonApiKey: "k", agentId: "agent-1",
        connectionId: "c1", send: deps(mock)
    )
    #expect(result.envVars == ["GEMINI_API_KEY": "spawn-only-google-secret"])
    #expect(result.providerConnection.providerId == "google")
}

@Test func rejectsUnknownResponseFields() async {
    let mock = Mock()
    mock.body = bodyJSON([
        "envVars": ["DEEPSEEK_API_KEY": "spawn-only-secret"],
        "providerConnection": ["providerId": "deepseek", "endpointUrl": NSNull(), "supportsImageInput": false],
        "credentialAlias": "must-not-pass",
    ])
    do {
        _ = try await ProviderConnectionLaunchClient.request(
            serverUrl: "http://localhost:3001", daemonApiKey: "k", agentId: "agent-1",
            connectionId: "c1", send: deps(mock)
        )
        Issue.record("expected rejection")
    } catch let error as ProviderConnectionMaterializationError {
        #expect(error.kind == .invalidPayload)
        #expect(error.message.contains("invalid payload"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func rejectsInconsistentGatewayEnvironment() async {
    let mock = Mock()
    mock.body = bodyJSON([
        "envVars": [
            "OPENAI_COMPATIBLE_API_KEY": "spawn-only-secret",
            "OPENAI_COMPATIBLE_BASE_URL": "https://wrong.example.test/v1",
        ],
        "providerConnection": [
            "providerId": "openai-compatible",
            "endpointUrl": "https://gateway.example.test/v1",
            "supportsImageInput": true,
        ],
    ])
    do {
        _ = try await ProviderConnectionLaunchClient.request(
            serverUrl: "http://localhost:3001", daemonApiKey: "k", agentId: "agent-1",
            connectionId: "c1", send: deps(mock)
        )
        Issue.record("expected rejection")
    } catch let error as ProviderConnectionMaterializationError {
        #expect(error.kind == .invalidEnvironment)
        #expect(error.message.contains("invalid environment"))
    } catch {
        Issue.record("unexpected error \(error)")
    }
}
