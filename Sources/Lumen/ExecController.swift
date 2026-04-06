import Foundation
import Vapor

// MARK: - ExecError

enum ExecError: Error {
    case timeout(Double)
}

// MARK: AbortError

extension ExecError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .timeout: .requestTimeout
        }
    }

    var reason: String {
        switch self {
        case let .timeout(seconds):
            "Command timed out after \(Int(seconds))s"
        }
    }
}

// MARK: - ExecController

struct ExecController: RouteCollection {
    /// Server-enforced maximum timeout in seconds. No command can run longer than this.
    static let maxTimeout: Double = 60

    /// Default timeout when the client doesn't specify one.
    static let defaultTimeout: Double = 30

    /// Maximum output size per stream (stdout/stderr) in bytes. Prevents memory exhaustion from
    /// commands that produce unbounded output.
    static let maxOutputBytes = 1_000_000 // 1 MB

    /// Environment variables that cannot be overridden by the client. These control process loading
    /// behavior and could be used for privilege escalation.
    static let blockedEnvironmentKeys: Set<String> = [
        "PATH",
        "HOME",
        "USER",
        "SHELL",
        "LOGNAME",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "LUMEN_API_KEY",
    ]

    /// Privilege escalation commands blocked by default. Set LUMEN_ALLOW_SUDO=true in the
    /// environment to permit them.
    static let escalationCommands: [String] = ["sudo", "su", "pkexec", "doas", "runuser"]

    /// Returns true if the command contains a privilege escalation call.
    static func containsPrivilegeEscalation(_ command: String) -> Bool {
        self.escalationCommands.contains { cmd in
            command.range(of: "\\b\(NSRegularExpression.escapedPattern(for: cmd))\\b", options: .regularExpression) != nil
        }
    }

    func boot(routes: RoutesBuilder) throws {
        routes.post("exec", use: self.execute)
    }

    @Sendable
    func execute(req: Request) async throws -> ExecResponse {
        let body = try req.content.decode(ExecRequest.self)
        req.logger.info("exec: \(body.command)")

        if Environment.get("LUMEN_ALLOW_SUDO") != "true", Self.containsPrivilegeEscalation(body.command) {
            throw Abort(.forbidden, reason: "Privilege escalation commands (sudo, su, etc.) are blocked. Set LUMEN_ALLOW_SUDO=true to permit.")
        }

        let effectiveTimeout = min(body.timeout ?? Self.defaultTimeout, Self.maxTimeout)

        let sanitizedEnv = body.environment.map { env in
            env.filter { !Self.blockedEnvironmentKeys.contains($0.key) }
        }

        return try await runCommand(
            command: body.command,
            workingDirectory: body.workingDirectory,
            environment: sanitizedEnv,
            timeout: effectiveTimeout,
            maxOutputBytes: Self.maxOutputBytes,
        )
    }
}

// MARK: - Process Execution

private func runCommand(
    command: String,
    workingDirectory: String?,
    environment: [String: String]?,
    timeout: Double,
    maxOutputBytes: Int,
) async throws -> ExecResponse {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]

    if let wd = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: wd)
    }

    if let env = environment {
        var merged = ProcessInfo.processInfo.environment
        merged.merge(env) { _, new in new }
        process.environment = merged
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Set the termination handler before running so we never miss a fast exit
    let didTimeout = LockIsolated(false)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in
            continuation.resume()
        }
        do {
            try process.run()
        } catch {
            continuation.resume(throwing: error)
            return
        }

        // Timeout is always enforced — kill the process if it exceeds the limit
        Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard process.isRunning else { return }
            didTimeout.setValue(true)
            process.terminate()
        }
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    if didTimeout.value {
        throw ExecError.timeout(timeout)
    }

    let stdoutTruncated = stdoutData.count > maxOutputBytes
    let stderrTruncated = stderrData.count > maxOutputBytes

    let stdout = String(data: stdoutData.prefix(maxOutputBytes), encoding: .utf8) ?? ""
    let stderr = String(data: stderrData.prefix(maxOutputBytes), encoding: .utf8) ?? ""

    return ExecResponse(
        stdout: stdoutTruncated ? stdout + "\n[truncated — output exceeded \(maxOutputBytes / 1_000_000) MB]" : stdout,
        stderr: stderrTruncated ? stderr + "\n[truncated — output exceeded \(maxOutputBytes / 1_000_000) MB]" : stderr,
        exitCode: Int(process.terminationStatus),
    )
}

// MARK: - LockIsolated

/// A simple wrapper that provides Sendable-safe read/write access to a value via a lock. Used here
/// to safely share a flag across the process termination handler and the kill task.
final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock: NSLock = .init()

    var value: Value {
        self.lock.withLock { self._value }
    }

    init(_ value: Value) {
        self._value = value
    }

    func setValue(_ newValue: Value) {
        self.lock.withLock { self._value = newValue }
    }
}
