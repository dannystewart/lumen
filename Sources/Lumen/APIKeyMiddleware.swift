import Vapor

struct APIKeyMiddleware: AsyncMiddleware {
    /// Compare two strings in constant time to prevent timing-based token enumeration. Uses XOR
    /// reduction over UTF-8 bytes so no byte mismatch causes early exit.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        return zip(aBytes, bBytes).reduce(into: UInt8(0)) { $0 |= $1.0 ^ $1.1 } == 0
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "Missing bearer token")
        }

        guard let expected = Environment.get("LUMEN_API_KEY"), !expected.isEmpty else {
            request.logger.critical("LUMEN_API_KEY is not set — refusing all requests")
            throw Abort(.internalServerError, reason: "Server API key is not configured")
        }

        guard Self.constantTimeEqual(token, expected) else {
            throw Abort(.unauthorized, reason: "Invalid API key")
        }

        return try await next.respond(to: request)
    }
}
