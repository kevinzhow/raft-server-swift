import Testing
@testable import RaftDaemonClient

@Test func webSocketProxyAgentIsSelectedFromTheHttpsProxy() {
    let proxy = DaemonProxy.webSocketProxyURL(
        "wss://api.slock.ai/daemon/connect?key=test",
        environment: ["HTTPS_PROXY": "http://proxy.internal:8080"]
    )
    #expect(proxy == "http://proxy.internal:8080")
}

@Test func webSocketProxyBypassesLocalhostAndInternalDomains() {
    #expect(DaemonProxy.webSocketProxyURL(
        "ws://localhost:3001/daemon/connect?key=test",
        environment: ["HTTP_PROXY": "http://proxy.internal:8080", "NO_PROXY": "localhost,.internal"]
    ) == nil)
    #expect(DaemonProxy.webSocketProxyURL(
        "wss://api.corp.internal/daemon/connect?key=test",
        environment: ["HTTPS_PROXY": "http://proxy.internal:8080", "NO_PROXY": "localhost,.internal"]
    ) == nil)
}

@Test func fetchProxyIsSelectedAndBypassedTheSameWay() {
    #expect(DaemonProxy.fetchProxyURL(
        "https://api.slock.ai/internal/agent/123/receive",
        environment: ["HTTPS_PROXY": "http://proxy.internal:8080"]
    ) == "http://proxy.internal:8080")
    #expect(DaemonProxy.fetchProxyURL(
        "http://localhost:3001/internal/agent/123/receive",
        environment: ["HTTP_PROXY": "http://proxy.internal:8080", "NO_PROXY": "localhost,.internal"]
    ) == nil)
    #expect(DaemonProxy.fetchProxyURL(
        "https://api.corp.internal/internal/agent/123/receive",
        environment: ["HTTPS_PROXY": "http://proxy.internal:8080", "NO_PROXY": "localhost,.internal"]
    ) == nil)
}

@Test func socksProxyIsRejectedWithoutEchoingTheProxy() throws {
    let rejection = #expect(throws: ProviderProxyRejection.self) {
        try DaemonProxy.validateProviderProxy(environment: ["ALL_PROXY": "socks5://proxy.internal:1080"])
    }
    #expect(rejection?.code == "PI_PROVIDER_PROXY_PROTOCOL_UNSUPPORTED")
    let message = rejection?.message ?? ""
    #expect(!message.localizedCaseInsensitiveContains("proxy.internal"))
    #expect(!message.contains("1080"))
    #expect(!message.localizedCaseInsensitiveContains("socks5"))
}

@Test func httpsServerBecomesAwssDaemonConnectUrl() {
    #expect(DaemonProxy.webSocketURL(serverUrl: "https://api.slock.ai") == "wss://api.slock.ai/daemon/connect")
    #expect(DaemonProxy.webSocketURL(serverUrl: "http://localhost:9999") == "ws://localhost:9999/daemon/connect")
}

@Test func connectionPassesTheProxyIntoTheSocketOpen() {
    let link = DaemonLink(
        serverUrl: "http://localhost:9999",
        apiKey: "sk_machine_test",
        proxyEnvironment: ["HTTP_PROXY": "http://proxy.internal:8080"],
        delayFor: { $0 }
    )
    link.connect()
    #expect(link.socketOpens == [
        DaemonSocketOpen(
            url: "ws://localhost:9999/daemon/connect",
            proxyURL: "http://proxy.internal:8080",
            authorization: "Bearer sk_machine_test"
        ),
    ])
    #expect(!link.socketOpens[0].url.contains("sk_machine_test"))
}

@Test func connectionBypassesTheProxyWhenNoProxyMatches() {
    let link = DaemonLink(
        serverUrl: "http://localhost:9999",
        apiKey: "sk_machine_test",
        proxyEnvironment: ["HTTP_PROXY": "http://proxy.internal:8080", "NO_PROXY": "localhost"],
        delayFor: { $0 }
    )
    link.connect()
    #expect(link.socketOpens == [
        DaemonSocketOpen(
            url: "ws://localhost:9999/daemon/connect",
            proxyURL: nil,
            authorization: "Bearer sk_machine_test"
        ),
    ])
}

@Test func connectionUsesBearerOnTheWssUrl() {
    let link = DaemonLink(
        serverUrl: "https://api.slock.ai",
        apiKey: "sk_machine_test",
        delayFor: { $0 }
    )
    link.connect()
    #expect(link.socketOpens == [
        DaemonSocketOpen(
            url: "wss://api.slock.ai/daemon/connect",
            proxyURL: nil,
            authorization: "Bearer sk_machine_test"
        ),
    ])
    #expect(link.socketOpens[0].url.contains("sk_machine_test") == false)
}
