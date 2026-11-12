import Foundation

extension AgentsLifecycleService {
    /// `GET /api/attachments/:id/preview`. Visibility and the attachment
    /// binding are checked before and after object I/O, exactly like the HTML
    /// preview path; the preview itself is built from the returned bytes.
    public func attachmentPreview(
        attachmentId: String, admission: AttachmentFlexAdmission,
        transaction: AttachmentTransactionMode = .legacy
    ) async throws -> AttachmentPreviewResponse {
        guard ServerScope.isUUID(attachmentId) else { throw AttachmentPreviewError.invalidAttachmentId }
        do {
            let content = try await attachmentPreviewContent(
                attachmentId: attachmentId, transaction: transaction
            ) { attachment in
                let mimeType = ChannelFileRules.resolveAttachmentMimeType(
                    filename: attachment.filename, stored: attachment.mimeType)
                return try authorizePreviewBody(admission: admission, attachment: attachment, mimeType: mimeType)
            }
            return AttachmentPreviewBuilder.build(
                filename: content.filename, storedMimeType: content.mimeType, bytes: content.bytes)
        } catch let error as AttachmentPersistenceUnavailable {
            // The outer writer boundary publishes this exact 503; the preview
            // builder's generic failure mapping must not turn it into a 500.
            throw error
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
