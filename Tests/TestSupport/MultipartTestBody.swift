import Foundation

/// One multipart/form-data body builder for the avatar and logo routes.
///
/// The pinned handlers read the `avatar` file part and any text fields (the
/// integration logo route reads `clientKey`), so the fixture keeps CRLF framing
/// and disposition quoting exactly as an HTTP client would send it.
public struct MultipartTestBody: Sendable {
    public let contentType: String
    public let body: Data

    public init(
        boundary: String = "raft-test-boundary",
        fields: [(name: String, value: String)] = [],
        fileField: String = "avatar",
        filename: String,
        mimeType: String?,
        bytes: Data
    ) {
        var text = ""
        for field in fields {
            text += "--\(boundary)\r\n"
            text += "Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n"
            text += "\(field.value)\r\n"
        }
        text += "--\(boundary)\r\n"
        text += "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n"
        if let mimeType {
            text += "Content-Type: \(mimeType)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(bytes)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        self.contentType = "multipart/form-data; boundary=\(boundary)"
        self.body = data
    }
}
