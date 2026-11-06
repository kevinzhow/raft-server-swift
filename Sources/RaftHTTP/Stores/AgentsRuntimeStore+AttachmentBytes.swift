import Foundation

extension AgentsRuntimeStore {
    /// Keeps the bytes an agent uploaded, keyed by the attachment id.
    func storeAgentAttachmentBytes(id: String, bytes: Data) {
        withState { state in
            state.agentAttachmentBytes[id] = bytes
        }
    }
}
