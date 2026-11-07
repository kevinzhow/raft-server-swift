import Foundation
import RaftHTTP
import Vapor

/// The original public pixel-avatar route, shared by production registrations.
public struct PixelAvatarRoutes: Sendable {
    public init() {}

    public func register(routes: any RoutesBuilder) {
        let avatars = routes.grouped("api", "avatars")
        avatars.get("pixel", ":file") { request -> Response in
            let file = request.parameters.get("file") ?? ""
            guard file.hasSuffix(".svg") else {
                return pixelAvatarError(400, "Invalid pixel avatar key")
            }
            guard let key = PixelAvatars.decode(String(file.dropLast(4))) else {
                return pixelAvatarError(400, "Invalid pixel avatar key")
            }
            guard let svg = PixelAvatars.render(key: key) else {
                return pixelAvatarError(404, "Pixel avatar not found")
            }
            return routeResponse(HTTPReply(
                status: 200,
                headers: [
                    "X-Robots-Tag": AppFallback.robotsTag,
                    "Content-Type": "image/svg+xml; charset=utf-8",
                    "Cache-Control": "public, max-age=31536000, immutable",
                    "Content-Length": String(Data(svg.utf8).count),
                ],
                body: svg
            ))
        }
    }
}

private func pixelAvatarError(_ status: Int, _ error: String) -> Response {
    respond(status: UInt(status), rawJSON: OrderedJSON.object([OrderedJSONField("error", error)]).render())
}
