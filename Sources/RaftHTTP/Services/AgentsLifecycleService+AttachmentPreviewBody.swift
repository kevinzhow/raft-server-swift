import Foundation

extension AgentsLifecycleService {
    /// `GET /api/attachments/:id/preview`. Visibility and the attachment
    /// binding are checked before and after object I/O, exactly like the HTML
    /// preview path; the preview itself is built from the returned bytes.
    public func attachmentPreview(
        attachmentId: String, admission: AttachmentFlexAdmission
    ) async throws -> AttachmentPreviewResponse {
        guard ServerScope.isUUID(attachmentId) else { throw AttachmentPreviewError.invalidAttachmentId }
        do {
            let content = try await attachmentPreviewContent(attachmentId: attachmentId) { attachment in
                let mimeType = ChannelFileRules.resolveAttachmentMimeType(
                    filename: attachment.filename, stored: attachment.mimeType)
                return try authorizePreviewBody(admission: admission, attachment: attachment, mimeType: mimeType)
            }
            return AttachmentPreviewBuilder.build(
                filename: content.filename, storedMimeType: content.mimeType, bytes: content.bytes)
        } catch let error as AttachmentPreviewError {
            throw error
        } catch let error as AgentsLifecycleError {
            switch error {
            case .invalidAttachmentId: throw AttachmentPreviewError.invalidAttachmentId
            case .attachmentNotFound: throw AttachmentPreviewError.notFound
            default: throw error
            }
        } catch AttachmentContentError.downloadsNotConfigured {
            throw AttachmentPreviewError.storageNotConfigured
        } catch {
            throw AttachmentPreviewError.buildFailed
        }
    }
}
