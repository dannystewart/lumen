import Vapor

struct APIKeyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "Missing bearer token")
        }

        guard let expected = Environment.get("LUMEN_API_KEY"), !expected.isEmpty else {
            request.logger.critical("LUMEN_API_KEY is not set — refusing all requests")
            throw Abort(.internalServerError, reason: "Server API key is not configured")
        }

        guard token == expected else {
            throw Abort(.unauthorized, reason: "Invalid API key")
        }

        return try await next.respond(to: request)
    }
}
