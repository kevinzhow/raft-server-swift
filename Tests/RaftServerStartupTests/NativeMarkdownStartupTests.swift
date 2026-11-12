import Foundation
#if canImport(Glibc)
import Glibc
#endif
import NIOCore
import NIOPosix
import Testing

/// The real executable runs its parser self-check before reporting readiness.
/// This proves startup no longer loads the JavaScript engine, independently of
/// parser-unit results or the release tool's declared dependency inventory.
@Test(.enabled(if: ProcessInfo.processInfo.environment["RAFT_E2E"] == "1"))
func nativeMarkdownServerStartsWithoutLoadingJavaScriptCore() async throws {
    #if os(Linux)
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binary = ProcessInfo.processInfo.environment["RAFT_SERVER_BIN"]
        ?? root.appendingPathComponent(".build/debug/RaftServer").path
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("native-markdown-startup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let log = temporary.appendingPathComponent("server.log")
    #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(channel.localAddress?.port)
    try await channel.close().get()
    try await group.shutdownGracefully()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.environment = [
        "NODE_ENV": "test", "PORT": String(port), "HTTP_HOST": "127.0.0.1", "SOCKET_PORT": "0",
        "DAEMON_CONNECT_PORT": "0", "JWT_SECRET": "native-parser-startup-test",
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
    var ready = false
    for _ in 0..<600 {
        let text = try String(contentsOf: log, encoding: .utf8)
        if text.contains("raft-server ready") { ready = true; break }
        if !process.isRunning { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let text = try String(contentsOf: log, encoding: .utf8)
    try #require(ready, "Native parser startup failed: \(text)")
    let mapFile = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/proc/\(process.processIdentifier)/maps"))
    defer { try? mapFile.close() }
    let mapData = try #require(try mapFile.readToEnd())
    let maps = try #require(String(data: mapData, encoding: .utf8))
    try #require(maps.contains("RaftServer") && maps.contains("r-xp"), "Process memory map probe returned no executable mappings")
    #expect(!maps.lowercased().contains("javascriptcore"))
    process.terminate()
    for _ in 0..<100 where process.isRunning {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!process.isRunning, "Native server did not shut down after SIGTERM")
    #endif
}
