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
    func boot(routes: RoutesBuilder) throws {
        routes.post("exec", use: self.execute)
    }

    @Sendable
    func execute(req: Request) async throws -> ExecResponse {
        let body = try req.content.decode(ExecRequest.self)
        req.logger.info("exec: \(body.command)")
        return try await runCommand(
            command: body.command,
            workingDirectory: body.workingDirectory,
            environment: body.environment,
            timeout: body.timeout,
        )
    }
}

// MARK: - Process Execution

private func runCommand(
    command: String,
    workingDirectory: String?,
    environment: [String: String]?,
    timeout: Double?,
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

        // Kick off the kill task only after we know the process is running
        if let timeout {
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                guard process.isRunning else { return }
                didTimeout.setValue(true)
                process.terminate()
            }
        }
    }

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    if let timeout, didTimeout.value {
        throw ExecError.timeout(timeout)
    }

    return ExecResponse(
        stdout: stdout,
        stderr: stderr,
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
