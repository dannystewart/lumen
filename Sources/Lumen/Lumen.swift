import Vapor

// MARK: - Entrypoint

@main
struct Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)
        do {
            try configure(app)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.execute()
        try await app.asyncShutdown()
    }
}

func configure(_ app: Application) throws {
    let port = Int(Environment.get("LUMEN_PORT") ?? "9069") ?? 9069
    app.http.server.configuration.port = port
    app.http.server.configuration.hostname = "0.0.0.0"

    try routes(app)

    app.logger.info("Lumen configured on port \(port)")
}

func routes(_ app: Application) throws {
    // Unprotected — just confirms the server is reachable
    app.get("health") { _ in HealthResponse.current }

    // Authenticated routes — require a valid bearer token
    let protected = app.grouped(APIKeyMiddleware())
    protected.get("info") { _ in InfoResponse.current }
    try protected.register(collection: ExecController())
}
