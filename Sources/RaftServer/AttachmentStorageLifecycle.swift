import RaftObjectStorage
import Vapor

/// The actor owns the Soto and HTTP clients for the process lifetime. Its port is
/// transient; durable messages contain only authenticated encrypted references.
struct AttachmentStorageLifecycle: LifecycleHandler {
    let storage: S3AttachmentStorage

    func shutdown(_ application: Application) async {
        try? await storage.shutdown()
    }
}
