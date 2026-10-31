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
        do {
            let handshake = try await DaemonClient.connect(host: host, port: port, apiKey: key)
            FileHandle.standardOutput.write(
                Data("daemon connected machine=\(handshake.context.machineId) server=\(handshake.context.serverId)\n".utf8)
            )
        } catch {
            fail("daemon connect failed: \(error)")
        }
    }
}
