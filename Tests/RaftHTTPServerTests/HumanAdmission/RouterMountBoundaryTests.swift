import HTTPTypes
import Testing
@testable import RaftHTTPServer

@Test func routerMountBoundaryRejectsAliasesBeforeTheFirstDynamicComponent() {
    let mount = ["api", "servers"]
    for path in ["/%61pi/servers/id", "/api/%73ervers/id", "/api//servers/id", "//api/servers/id"] {
        #expect(RouterMountBoundaryPolicy.rejects(path: path, constantPrefix: mount))
    }
    for path in ["/api/servers/id", "/API/Servers/id", "/api/servers/id%2Fpart/runtime%2Dmodels/codex", "/api/servers/id/"] {
        #expect(!RouterMountBoundaryPolicy.rejects(path: path, constantPrefix: mount))
    }
    #expect(RouterMountBoundaryPolicy.rejects(path: "/internal/%63omputer/agent/reset", constantPrefix: ["internal", "computer"]))
    #expect(!RouterMountBoundaryPolicy.rejects(path: "/share/%61rtifact", constantPrefix: ["share"]))
    #expect(!RouterMountBoundaryPolicy.rejects(path: "/%61pi/unknown", constantPrefix: []))
}

@Test func routerMountBoundaryKeepsNarrowAttachmentRoutesSeparateFromDynamicServingRoutes() {
    #expect(RouterMountBoundaryPolicy.rejects(path: "/api/attachments/%75pload-capabilities", constantPrefix: ["api", "attachments", "upload-capabilities"]))
    #expect(!RouterMountBoundaryPolicy.rejects(path: "/api/attachments/id%2Fhtml-preview", constantPrefix: ["api", "attachments"]))
    #expect(!RouterMountBoundaryPolicy.rejects(path: "/api/attachments/id/html%2Dpreview", constantPrefix: ["api", "attachments"]))
}
