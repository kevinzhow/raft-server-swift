import Testing
@testable import RaftHTTP

@Test func preflightMaxAgeIsChromesTwoHourCap() {
    #expect(WebCORS.preflightMaxAgeSeconds == 7200)
    #expect(WebCORS.origins(corsOrigin: nil, appURL: nil) == ["http://localhost:5173"])
}

@Test func allowedPreflightIs204WithTheRequestOrigin() {
    let reply = WebCORS.preflight(
        method: "OPTIONS",
        origin: "http://localhost:5173",
        requestMethod: "GET",
        allowed: WebCORS.origins(corsOrigin: nil, appURL: nil)
    )
    #expect(reply?.status == 204)
    #expect(reply?.value(for: "Access-Control-Allow-Origin") == "http://localhost:5173")
    #expect(reply?.value(for: "Access-Control-Max-Age") == "7200")
    #expect(reply?.value(for: "X-Robots-Tag") == nil)
    #expect(reply?.body.isEmpty == true)
}

@Test func aForeignOriginIsNotAPreflightSuccess() {
    let reply = WebCORS.preflight(
        method: "OPTIONS",
        origin: "https://evil.example",
        requestMethod: "GET",
        allowed: WebCORS.origins(corsOrigin: nil, appURL: nil)
    )
    #expect(reply == nil)
}
