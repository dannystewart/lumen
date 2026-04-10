import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Vapor

// MARK: - LumenServiceAction

enum LumenServiceAction: String {
    case start
    case stop
    case restart
    case status

    var displayName: String {
        self.rawValue.capitalized
    }

    var pastTense: String {
        switch self {
        case .start: "started"
        case .stop: "stopped"
        case .restart: "restarted"
        case .status: "checked"
        }
    }
}

// MARK: - LumenServiceManager

struct LumenServiceManager {
    private let console: Console
    private let fileManager: FileManager = .default

    init(console: Console) throws {
        self.console = console
    }

    func run(action: LumenServiceAction) throws {
        let platform = InstallPlatform.current

        self.console.print("")
        self.console.printHeader("Lumen v\(lumenVersion) for \(platform.displayName) / \(action.displayName)")
        self.console.printNote("Manage the currently installed Lumen service.")
        self.console.print("")

        guard let install = InstallLocator().detectExistingInstall(on: platform) else {
            self.console.printWarning("No existing installation was found.")
            self.console.print("")
            return
        }

        switch action {
        case .status:
            try self.runStatus(for: install, platform: platform)

        case .start, .stop, .restart:
            try self.runLifecycleAction(action, install: install, platform: platform)
        }

        self.console.print("")
    }

    // MARK: Lifecycle Actions

    private func runLifecycleAction(
        _ action: LumenServiceAction,
        install: ExistingInstall,
        platform: InstallPlatform,
    ) throws {
        self.console.printSection("Detected installation")
        self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
        self.console.printLabelValue("Binary", value: install.binaryPath)
        self.console.printLabelValue("Service", value: install.serviceFilePath)
        self.console.print("")

        guard self.canManageService(install: install) else {
            self.console.printWarning("This service location needs extra permissions.")
            self.console.print("")
            self.console.printNote(self.permissionGuidance(for: install, platform: platform))
            self.console.print("")
            return
        }

        let beforeState = self.currentServiceState(for: install, platform: platform)

        switch action {
        case .start:
            if beforeState.isLoaded {
                self.console.printSuccess("Lumen is already running.")
                self.console.print("")
                self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
                self.console.printLabelValue("Service", value: install.serviceFilePath)
                return
            }

        case .stop:
            if beforeState.isLoaded == false {
                self.console.printSuccess("Lumen is already stopped.")
                self.console.print("")
                self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
                self.console.printLabelValue("Service", value: install.serviceFilePath)
                return
            }

        case .restart:
            if beforeState.isLoaded == false {
                self.console.printWarning("Lumen is not currently running.")
                self.console.printNote("Starting the service instead.")
            }

        case .status:
            return
        }

        let plan = self.commands(for: action, install: install, platform: platform)

        let result = self.runCommands(plan.commands)

        switch action {
        case .start:
            let afterState = self.currentServiceState(for: install, platform: platform)
            let settledState = if afterState.isLoaded {
                afterState
            } else {
                self.currentServiceState(for: install, platform: platform)
            }

            if settledState.isLoaded {
                if beforeState.isLoaded {
                    self.console.printSuccess("Lumen is already running.")
                    self.console.print("")
                    self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
                    self.console.printLabelValue("Service", value: install.serviceFilePath)
                } else {
                    self.printLifecycleSuccess(for: action, install: install)
                }
            } else {
                self.printLifecycleFailure(result, action: action, install: install, platform: platform)
            }

        case .stop:
            let afterState = self.currentServiceState(for: install, platform: platform)
            if result.succeeded, afterState.isLoaded == false {
                self.printLifecycleSuccess(for: action, install: install)
            } else if afterState.isLoaded == false {
                self.console.printSuccess("Lumen is already stopped.")
                self.console.print("")
                self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
                self.console.printLabelValue("Service", value: install.serviceFilePath)
            } else {
                self.printLifecycleFailure(result, action: action, install: install, platform: platform)
            }

        case .restart:
            let afterState = self.currentServiceState(for: install, platform: platform)
            if result.succeeded, afterState.isLoaded {
                self.printLifecycleSuccess(for: action, install: install)
            } else if beforeState.isLoaded == false, afterState.isLoaded {
                self.console.printSuccess("Lumen started successfully.")
                self.console.print("")
                self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
                self.console.printLabelValue("Service", value: install.serviceFilePath)
            } else {
                self.printLifecycleFailure(result, action: action, install: install, platform: platform)
            }

        case .status:
            break
        }
    }

    private func printLifecycleSuccess(
        for action: LumenServiceAction,
        install: ExistingInstall,
    ) {
        self.console.printSuccess("Lumen \(action.pastTense) successfully.")
        self.console.print("")
        self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
        self.console.printLabelValue("Service", value: install.serviceFilePath)
    }

    private func printLifecycleFailure(
        _ result: LifecycleCommandResult,
        action: LumenServiceAction,
        install _: ExistingInstall,
        platform: InstallPlatform,
    ) {
        self.console.printError("Lumen \(action.rawValue) failed.")
        self.console.print("")
        self.console.printLabelValue("Exit code", value: String(result.exitCode))

        let combinedOutput = result.combinedOutput

        if self.isServiceNotLoadedMessage(combinedOutput, platform: platform) {
            self.console.print("")
            self.console.printWarning("The service file exists, but Lumen is not currently loaded.")
            self.console.printNote(self.notLoadedGuidance(for: action))

            if combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                self.console.print("")
                self.console.printSection("Service manager output")
                self.console.print(combinedOutput)
            }
            return
        }

        if result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            self.console.print("")
            self.console.printSection("Error output")
            self.console.print(result.stderr)
        } else if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            self.console.print("")
            self.console.printSection("Output")
            self.console.print(result.stdout)
        }
    }

    private func runCommands(_ commands: [String]) -> LifecycleCommandResult {
        var stdoutChunks = [String]()
        var stderrChunks = [String]()

        for command in commands {
            let execution = self.runShellCommand(command)

            if execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                stdoutChunks.append(execution.stdout)
            }

            if execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                stderrChunks.append(execution.stderr)
            }

            if execution.exitCode != 0 {
                return LifecycleCommandResult(
                    succeeded: false,
                    stdout: stdoutChunks.joined(separator: "\n"),
                    stderr: stderrChunks.joined(separator: "\n"),
                    exitCode: execution.exitCode,
                )
            }
        }

        return LifecycleCommandResult(
            succeeded: true,
            stdout: stdoutChunks.joined(separator: "\n"),
            stderr: stderrChunks.joined(separator: "\n"),
            exitCode: 0,
        )
    }

    // MARK: - Status

    private func runStatus(
        for install: ExistingInstall,
        platform: InstallPlatform,
    ) throws {
        self.console.printSection("Detected installation")
        self.console.printLabelValue("Service type", value: install.runAsSystemService ? "system" : "user")
        self.console.printLabelValue("Binary", value: install.binaryPath)
        self.console.printLabelValue("Service", value: install.serviceFilePath)
        self.console.print("")

        let existingConfig = self.loadExistingConfig(from: install.serviceFilePath, platform: platform)
        let serviceState = self.currentServiceState(for: install, platform: platform)
        let liveInfo = serviceState.isLoaded ? self.fetchLiveInfo(config: existingConfig) : nil

        self.console.printSection("Service status")
        self.console.printLabelValue("Running", value: serviceState.isLoaded ? "yes" : "no")
        self.console.printLabelValue("Version", value: liveInfo.map { "v\($0.version)" } ?? (serviceState.isLoaded ? "unknown" : "unavailable"))
        self.console.printLabelValue("Hostname", value: liveInfo?.hostname ?? (serviceState.isLoaded ? "unknown" : "unavailable"))
        self.console.printLabelValue("Port", value: existingConfig.port.map(String.init) ?? "9069")
        self.console.print("")

        if serviceState.isLoaded {
            self.console.printSuccess("Lumen is currently running.")
        } else {
            self.console.printNote("The service file exists, but Lumen is not currently loaded.")
        }

        if serviceState.isLoaded, liveInfo == nil {
            self.console.print("")
            self.console.printWarning("Lumen appears to be running, but live info could not be retrieved.")
            self.console.printNote("Lumen may be running with elevated permissions. Try running again with sudo.")
        }
    }

    // MARK: - Service State

    private func currentServiceState(
        for install: ExistingInstall,
        platform: InstallPlatform,
    ) -> ServiceState {
        let plan = self.commands(for: .status, install: install, platform: platform)
        let result = self.runCommands(plan.commands)

        if result.succeeded == false {
            return ServiceState(isLoaded: false, rawOutput: result.combinedOutput)
        }

        let output = result.combinedOutput.lowercased()

        switch platform {
        case .macOS:
            let isLoaded =
                output.contains("state = running")
                    || output.contains("active count = 1")
                    || output.contains("pid = ")
            return ServiceState(isLoaded: isLoaded, rawOutput: result.combinedOutput)

        case .linux:
            let isLoaded =
                output.contains("active: active")
                    || output.contains("active (running)")
                    || output.contains("loaded: loaded")
            return ServiceState(isLoaded: isLoaded, rawOutput: result.combinedOutput)
        }
    }

    // MARK: - Commands

    private func commands(
        for action: LumenServiceAction,
        install: ExistingInstall,
        platform: InstallPlatform,
    ) -> LifecycleCommandPlan {
        switch platform {
        case .macOS:
            self.macOSCommands(for: action, install: install)
        case .linux:
            self.linuxCommands(for: action, install: install)
        }
    }

    private func macOSCommands(
        for action: LumenServiceAction,
        install: ExistingInstall,
    ) -> LifecycleCommandPlan {
        let target = if install.runAsSystemService {
            "system/\(InstallPlatform.macOS.serviceLabel)"
        } else {
            "gui/\(getuid())/\(InstallPlatform.macOS.serviceLabel)"
        }

        let commands = switch action {
        case .start:
            ["launchctl bootstrap \(self.targetPrefix(for: install)) \(shellQuote(install.serviceFilePath))"]

        case .stop:
            ["launchctl bootout \(self.targetPrefix(for: install)) \(shellQuote(install.serviceFilePath))"]

        case .restart:
            if install.runAsSystemService {
                ["launchctl kickstart -k \(target)"]
            } else {
                ["launchctl kickstart -k \(target)"]
            }

        case .status:
            ["launchctl print \(target)"]
        }

        return LifecycleCommandPlan(commands: commands)
    }

    private func linuxCommands(
        for action: LumenServiceAction,
        install: ExistingInstall,
    ) -> LifecycleCommandPlan {
        let base = install.runAsSystemService ? "systemctl" : "systemctl --user"

        let commands = switch action {
        case .start:
            ["\(base) start lumen.service"]
        case .stop:
            ["\(base) stop lumen.service"]
        case .restart:
            ["\(base) restart lumen.service"]
        case .status:
            ["\(base) status lumen.service --no-pager"]
        }

        return LifecycleCommandPlan(commands: commands)
    }

    private func targetPrefix(for install: ExistingInstall) -> String {
        if install.runAsSystemService {
            return "system"
        }
        return "gui/\(getuid())"
    }

    // MARK: - Permissions

    private func canManageService(install: ExistingInstall) -> Bool {
        if install.runAsSystemService {
            return self.canWritePath(install.serviceFilePath)
        }
        return true
    }

    private func canWritePath(_ path: String) -> Bool {
        if self.fileManager.fileExists(atPath: path) {
            return self.fileManager.isWritableFile(atPath: path)
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if parent == path || parent.isEmpty {
            return false
        }

        if self.fileManager.fileExists(atPath: parent) {
            return self.fileManager.isWritableFile(atPath: parent)
        }

        return self.canWritePath(parent)
    }

    private func permissionGuidance(for install: ExistingInstall, platform: InstallPlatform) -> String {
        switch platform {
        case .macOS:
            if install.runAsSystemService {
                "Run the command above with the appropriate administrator privileges."
            } else {
                "Make sure the current user owns the installed service file and binary."
            }

        case .linux:
            if install.runAsSystemService {
                "Run the command above with the appropriate administrator privileges."
            } else {
                "Make sure the current user can access the user service manager and installed files."
            }
        }
    }

    // MARK: - Installed Config Parsing

    private func loadExistingConfig(from path: String, platform: InstallPlatform) -> ExistingConfig {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ExistingConfig(apiKey: nil, port: nil, allowSudo: nil)
        }

        switch platform {
        case .macOS:
            return self.parseLaunchdConfig(contents)
        case .linux:
            return self.parseSystemdConfig(contents)
        }
    }

    private func parseLaunchdConfig(_ contents: String) -> ExistingConfig {
        func value(for key: String) -> String? {
            let pattern = "<key>\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*</key>\\s*<string>(.*?)</string>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                return nil
            }

            let range = NSRange(contents.startIndex..., in: contents)
            guard
                let match = regex.firstMatch(in: contents, options: [], range: range),
                let valueRange = Range(match.range(at: 1), in: contents) else
            {
                return nil
            }

            return self.xmlUnescaped(String(contents[valueRange])).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ExistingConfig(
            apiKey: value(for: "LUMEN_API_KEY"),
            port: value(for: "LUMEN_PORT").flatMap(Int.init),
            allowSudo: value(for: "LUMEN_ALLOW_SUDO").map { $0.lowercased() == "true" },
        )
    }

    private func parseSystemdConfig(_ contents: String) -> ExistingConfig {
        var apiKey: String?
        var port: Int?
        var allowSudo: Bool?

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("Environment=") else { continue }

            let remainder = String(line.dropFirst("Environment=".count))
            let unquoted = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let separator = unquoted.firstIndex(of: "=") else { continue }

            let key = String(unquoted[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(unquoted[unquoted.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "LUMEN_API_KEY":
                apiKey = value
            case "LUMEN_PORT":
                port = Int(value)
            case "LUMEN_ALLOW_SUDO":
                allowSudo = value.lowercased() == "true"
            default:
                continue
            }
        }

        return ExistingConfig(apiKey: apiKey, port: port, allowSudo: allowSudo)
    }

    private func fetchLiveInfo(config: ExistingConfig) -> LiveStatusInfo? {
        guard
            let apiKey = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey.isEmpty == false else
        {
            return nil
        }

        let port = config.port ?? 9069
        guard let url = URL(string: "http://127.0.0.1:\(port)/info") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        let box = LiveInfoBox()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                box.error = error
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else { return }
            guard httpResponse.statusCode == 200 else { return }
            guard let data else { return }

            do {
                box.info = try JSONDecoder().decode(LiveStatusInfo.self, from: data)
            } catch {
                box.error = error
            }
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        task.cancel()

        return box.info
    }

    private func xmlUnescaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func runShellCommand(_ command: String) -> ShellExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ShellExecutionResult(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: -1,
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ShellExecutionResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: Int(process.terminationStatus),
        )
    }

    private func isServiceNotLoadedMessage(_ output: String, platform: InstallPlatform) -> Bool {
        let normalized = output.lowercased()

        switch platform {
        case .macOS:
            return normalized.contains("could not find service")
                || normalized.contains("bad request.")
                || normalized.contains("boot-out failed: 5")

        case .linux:
            return normalized.contains("unit lumen.service could not be found")
                || normalized.contains("inactive (dead)")
                || normalized.contains("not loaded")
        }
    }

    private func notLoadedGuidance(for action: LumenServiceAction) -> String {
        switch action {
        case .start:
            "Try `lumen start` again after confirming the service file is installed in the expected location."
        case .stop:
            "There is nothing to stop right now because the service is not loaded."
        case .restart:
            "Try `lumen start` to load the service first, then use `lumen restart` once it is running."
        case .status:
            "Try `lumen start` if you want to load the installed service now."
        }
    }
}

// MARK: - LifecycleCommandPlan

private struct LifecycleCommandPlan {
    let commands: [String]
}

// MARK: - LifecycleCommandResult

private struct LifecycleCommandResult {
    let succeeded: Bool
    let stdout: String
    let stderr: String
    let exitCode: Int

    var combinedOutput: String {
        self.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.stdout : self.stderr
    }
}

// MARK: - ServiceState

private struct ServiceState {
    let isLoaded: Bool
    let rawOutput: String
}

// MARK: - ShellExecutionResult

private struct ShellExecutionResult {
    let stdout: String
    let stderr: String
    let exitCode: Int
}

// MARK: - LiveStatusInfo

private struct LiveStatusInfo: Decodable {
    let hostname: String
    let platform: String
    let version: String
}

// MARK: - LiveInfoBox

private final class LiveInfoBox: @unchecked Sendable {
    var info: LiveStatusInfo? = nil
    var error: Error? = nil
}
