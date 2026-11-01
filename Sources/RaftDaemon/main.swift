import Foundation
import RaftDaemonClient

#if canImport(Glibc)
import Glibc
#endif

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@main
enum Entrypoint {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["SERVER_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let components = URLComponents(string: rawURL),
              let host = components.host
        else {
            fail("RaftDaemon requires SERVER_URL")
        }
        let key = (environment["MACHINE_KEY"] ?? environment["RAFT_MACHINE_KEY"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            fail("RaftDaemon requires MACHINE_KEY")
        }
        let port = components.port ?? (components.scheme == "https" ? 443 : 80)
        let loop = DaemonReconnectLoop(
            connect: {
                try await DaemonClient.connect(host: host, port: port, apiKey: key)
            },
            onConnected: { handshake, _ in
                FileHandle.standardOutput.write(
                    Data("daemon connected machine=\(handshake.context.machineId) server=\(handshake.context.serverId)\n".utf8)
                )
            },
            onScheduled: { delay, attempt in
                FileHandle.standardOutput.write(
                    Data("daemon reconnecting in \(delay)ms (attempt \(attempt))\n".utf8)
                )
            }
        )
        await loop.run()
        if loop.lastStop == .migratedKey {
            fail("daemon stopped: this machine key cannot authenticate again")
        }
    }
}
