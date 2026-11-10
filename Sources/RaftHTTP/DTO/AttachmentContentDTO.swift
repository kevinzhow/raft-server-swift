import Foundation

/// A parsed file carries its actual bytes. The byte count used for admission and
/// persisted metadata is derived from these bytes rather than a caller's claim.
public struct AttachmentUploadContent: Sendable, Equatable {
    public let filename: String
    public let mimeType: String?
    public let bytes: Data

    public init(filename: String, mimeType: String?, bytes: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.bytes = bytes
    }

    var uploadFile: AttachmentUploadFile {
        AttachmentUploadFile(filename: filename, mimeType: mimeType, sizeBytes: bytes.count)
    }
}

/// Content is released only after the ordinary attachment authorization checks
/// and authenticated object decryption succeed. HTTP transport chooses ranges and headers.
public struct AttachmentBinaryContent: Sendable, Equatable {
    public let bytes: Data
    public let filename: String
    public let mimeType: String?

    public init(bytes: Data, filename: String, mimeType: String?) {
        self.bytes = bytes
        self.filename = filename
        self.mimeType = mimeType
    }
}
