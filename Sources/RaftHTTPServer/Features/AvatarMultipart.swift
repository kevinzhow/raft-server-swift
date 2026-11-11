import Foundation
import RaftHTTP
import Vapor

/// The `avatar` multipart part the profile, server and integration-app routes
/// read. A missing part is the pinned 400, a non-image content type is the
/// pinned bad-format 400 and the 5 MB limit is enforced from the same parsed
/// bytes the route stores.
func singleAvatarUploadFile(_ request: Request) async throws -> AttachmentUploadContent {
    let parsed = try await AttachmentMultipartDecoder.decode(request)
    guard let file = parsed.files.first else { throw AgentAvatarUploadError.noAvatarFile }
    _ = try AgentAvatarUploadError.validatedMimeType(file.mimeType)
    guard file.bytes.count <= AgentAvatarUploadError.maximumBytes else {
        throw AgentPrivateSurfaceError.avatarTooLarge(maxBytes: AgentAvatarUploadError.maximumBytes)
    }
    return file
}
