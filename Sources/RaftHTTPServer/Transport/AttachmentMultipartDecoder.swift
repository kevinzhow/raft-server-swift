import Foundation
import HTTPTypes
import MultipartKit
import RaftHTTP
import Vapor

struct AttachmentMultipartBody: Sendable {
    let channelId: String
    let files: [AttachmentUploadContent]
}

/// MultipartKit handles MIME boundaries and disposition quoting. Both metadata
/// size and storage bytes come from the same parsed binary body.
enum AttachmentMultipartDecoder {
    static func decode(_ request: Request) async throws -> AttachmentMultipartBody {
        guard let type = request.headers.contentType,
              type.type.lowercased() == "multipart", type.subType.lowercased() == "form-data",
              let boundary = type.parameters["boundary"], !boundary.isEmpty,
              let body = try await request.body.collect(max: .specified(ByteCount(value: 300 * 1024 * 1024))) else {
            throw AttachmentContentError.invalidMultipart
        }
        let parts: [MultipartKit.MultipartPart<Data>]
        do { parts = try MultipartParser<Data>(boundary: boundary).parse(body) }
        catch { throw AttachmentContentError.invalidMultipart }
        var channelId = ""
        var files: [AttachmentUploadContent] = []
        for part in parts {
            let disposition = part.headerFields.contentDisposition
            if disposition?.name == "channelId", disposition?.filename == nil {
                channelId = String(decoding: part.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let filename = disposition?.filename, !filename.isEmpty {
                let normalized = filename.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? filename
                guard !normalized.isEmpty else { continue }
                let mediaType = part.headerFields.contentType.map { "\($0.type)/\($0.subType)" }
                files.append(AttachmentUploadContent(filename: normalized, mimeType: mediaType, bytes: Data(part.body)))
            }
        }
        return AttachmentMultipartBody(channelId: channelId, files: files)
    }
}
