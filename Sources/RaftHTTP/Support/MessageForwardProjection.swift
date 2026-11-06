import Foundation

/// Forwarded snapshots keep the source pointer policy and published member order.
public enum MessageForwardProjection {
    static func attachment(_ snap: ForwardAttachmentSnapshot) -> OrderedJSON {
        .object([
            OrderedJSONField("id", snap.id), OrderedJSONField("filename", snap.filename),
            OrderedJSONField("mimeType", snap.mimeType), OrderedJSONField("sizeBytes", snap.sizeBytes),
            OrderedJSONField("width", optional: snap.width), OrderedJSONField("height", optional: snap.height),
        ])
    }

    static func forwardAttachmentSnapshotsJSON(_ snapshots: [ForwardAttachmentSnapshot]) -> String {
        snapshots.map { attachment($0).render() }.joined(separator: ",")
    }

    static func forwardItemJSON(_ item: ForwardItemRecord) -> String {
        var body = OrderedJSONObject([
            OrderedJSONField("sourceMessageId", optional: item.exposesPointers ? item.sourceMessageId : nil),
            OrderedJSONField("sourceIsThreadParent", item.sourceIsThreadParent),
            OrderedJSONField("contentSnapshot", item.contentSnapshot),
            OrderedJSONField("sourceAuthorSnapshot", .object([OrderedJSONField("uniqueName", item.sourceAuthorUniqueName)])),
            OrderedJSONField("sourceTargetId", optional: item.sourceTargetId),
        ])
        if !item.exposesPointers {
            body.append("sourceMessageSeq", .null)
            body.append("sourceServerId", .null)
        }
        body.append("sourceThreadId", ifPresent: item.sourceThreadId)
        body.append("parentChannelId", ifPresent: item.parentChannelId)
        body.append("sourceTargetSnapshot", .object([
            OrderedJSONField("id", optional: item.snapshotId),
            OrderedJSONField("type", item.snapshotType), OrderedJSONField("label", item.snapshotLabel),
            OrderedJSONField("labelVisibility", item.snapshotLabelVisibility),
        ]))
        body.append("attachmentSnapshots", .array(item.attachments.map(attachment)))
        body.append("attachmentPolicy", item.attachmentPolicy)
        body.append("provenanceState", item.provenanceState)
        return body.json.render()
    }

    static func scrubbedForwardItemJSON(_ item: ForwardItemRecord) -> String {
        OrderedJSON.object([
            OrderedJSONField("sourceMessageId", .null),
            OrderedJSONField("sourceIsThreadParent", item.sourceIsThreadParent),
            OrderedJSONField("contentSnapshot", item.contentSnapshot),
            OrderedJSONField("sourceServerId", .null), OrderedJSONField("sourceTargetId", .null),
            OrderedJSONField("sourceThreadId", .null), OrderedJSONField("parentChannelId", .null),
            OrderedJSONField("sourceTargetSnapshot", .object([
                OrderedJSONField("id", .null), OrderedJSONField("type", item.snapshotType.isEmpty ? "channel" : item.snapshotType),
                OrderedJSONField("label", ""), OrderedJSONField("labelVisibility", "restricted"),
            ])),
            OrderedJSONField("attachmentSnapshots", .array(item.attachments.map(attachment))),
            OrderedJSONField("attachmentPolicy", item.attachmentPolicy),
            OrderedJSONField("provenanceState", "original_unavailable"),
        ]).render()
    }
}
