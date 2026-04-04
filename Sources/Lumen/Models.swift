import Foundation
import Vapor

// MARK: - ExecRequest

struct ExecRequest: Content {
    let command: String
    let workingDirectory: String?
    let environment: [String: String]?
    let timeout: Double?
}

// MARK: - ExecResponse

struct ExecResponse: Content {
    let stdout: String
    let stderr: String
    let exitCode: Int
}

// MARK: - HealthResponse

struct HealthResponse: Content {
    static var current: HealthResponse {
        HealthResponse(
            status: "ok",
            hostname: ProcessInfo.processInfo.hostName,
        )
    }

    let status: String
    let hostname: String
}
