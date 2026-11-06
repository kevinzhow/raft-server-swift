import Foundation

extension MessagesAndThreadsStore {
    /// Attachment chip counts for one replayed message, in request order.
    struct AttachmentCommentSummary {
        let attachmentId: String
        let commentCount: Int
    }

    func attachmentCommentSummaries(ids: [String], commentsVisible: Bool) -> [AttachmentCommentSummary] {
        lock.lock()
        defer { lock.unlock() }
        return ids.map { id in
            AttachmentCommentSummary(
                attachmentId: id,
                commentCount: commentsVisible ? (storage.attachmentCommentRecords[id]?.count ?? 0) : 0
            )
        }
    }

    /// Scoped comment chip anchored on `messageId`, as one locked snapshot.
    struct AttachmentCommentRef {
        let attachmentId: String
        let hostMessageId: String
        let hostChannelId: String
        let threadChannelId: String?
    }

    func commentRef(messageId: String) -> AttachmentCommentRef? {
        lock.lock()
        defer { lock.unlock() }
        for (attachmentId, records) in storage.attachmentCommentRecords {
            guard let record = records.first(where: { $0.id == messageId }),
                  let hostMessageId = record.hostMessageId,
                  let hostChannelId = record.hostChannelId
            else { continue }
            return AttachmentCommentRef(
                attachmentId: attachmentId,
                hostMessageId: hostMessageId,
                hostChannelId: hostChannelId,
                threadChannelId: record.threadChannelId
            )
        }
        return nil
    }

    /// One critical section for an attachment comment: the comment row and the
    /// host-thread message row it posts as. The sequence is the server-wide
    /// `rows.count + 1` the shared append stamps, so a concurrent comment can
    /// never take the same sequence or land between the two writes. Returns the
    /// stamped sequence.
    func appendAttachmentComment(_ record: AttachmentCommentRecord, message: StoredHumanMessage) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.attachmentCommentRecords[record.attachmentId, default: []].append(record)
        var stored = message
        stored.seq = storage.humanMessageRows.count + 1
        storage.humanMessageRows.append(stored)
        return stored.seq
    }

    // MARK: - Message send: attachment URL and thread-follower undo ledger

    /// The row and the presigner `GET /api/attachments/:id/url` needs, read as
    /// one snapshot so the mime type and the injected presigner cannot come
    /// from two different configurations.
    struct AttachmentDownloadRecord {
        let attachment: ChannelAttachment
        let presign: (@Sendable (_ attachmentId: String, _ mimeType: String?, _ ttlSeconds: Int) -> String)?
    }

    func attachmentDownloadRecord(attachmentId: String) -> AttachmentDownloadRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let attachment = storage.channelAttachments[attachmentId] else { return nil }
        return AttachmentDownloadRecord(attachment: attachment, presign: storage.attachmentPresign)
    }
}

extension MessagesAndThreadsStore {
    /// Stores one uploaded file row. The row carries its final uploader type, so
    /// no reader can observe an agent upload as a user upload.
    func insertAttachment(_ attachment: ChannelAttachment) {
        lock.lock()
        storage.channelAttachments[attachment.id] = attachment
        lock.unlock()
    }
}
