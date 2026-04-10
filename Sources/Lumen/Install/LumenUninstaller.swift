import Vapor

// MARK: - LumenUninstaller

struct LumenUninstaller {
    private let console: Console
    private let fileManager: FileManager = .default

    init(console: Console) throws {
        self.console = console
    }

    func run() throws {
        let platform = InstallPlatform.current

        self.console.print("")
        self.console.printHeader("Lumen v\(lumenVersion) for \(platform.displayName) • Uninstaller")
        self.console.printNote("Remove the existing service and installed binary below.")
        self.console.print("")

        guard let existingInstall = InstallLocator().detectExistingInstall(on: platform) else {
            self.console.printWarning("No existing installation was found.")
            self.console.print("")
            return
        }

        self.console.printSection("Existing installation detected")
        self.console.printLabelValue("Service type", value: existingInstall.runAsSystemService ? "system" : "user")
        self.console.printLabelValue("Binary", value: existingInstall.binaryPath)
        self.console.printLabelValue("Service", value: existingInstall.serviceFilePath)
        self.console.print("")

        guard self.canWriteRemovalTargets(for: existingInstall) else {
            self.console.printError("Uninstall requires elevated permissions. Re-run the uninstaller with sudo.")
            self.console.print("")
            return
        }

        if !self.askBool(prompt: "Remove this installation?", defaultValue: true) {
            self.console.printWarning("Uninstall cancelled.")
            self.console.print("")
            return
        }

        self.console.print("")

        guard self.canWriteRemovalTargets(for: existingInstall) else {
            self.console.printError("Uninstall requires elevated permissions. Re-run the uninstaller with sudo.")
            self.console.print("")
            return
        }

        try self.uninstall(existingInstall, platform: platform)
        self.console.print("")
        self.console.printSuccess("Lumen uninstalled successfully.")
        self.console.print("")
    }

    private func uninstall(_ install: ExistingInstall, platform: InstallPlatform) throws {
        for command in self.stopCommands(for: install, platform: platform) {
            try self.runShellCommand(command)
        }

        try self.removeItemIfExists(at: install.serviceFilePath)
        try self.removeItemIfExists(at: install.binaryPath)
    }

    private func removeItemIfExists(at path: String) throws {
        guard self.fileManager.fileExists(atPath: path) else { return }
        try self.fileManager.removeItem(atPath: path)
    }

    private func canWriteRemovalTargets(for install: ExistingInstall) -> Bool {
        [install.binaryPath, install.serviceFilePath].allSatisfy { self.canWritePath($0) }
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

    private func stopCommands(for install: ExistingInstall, platform: InstallPlatform) -> [String] {
        switch platform {
        case .macOS:
            if install.runAsSystemService {
                return [
                    "launchctl bootout system \(shellQuote(install.serviceFilePath))",
                ]
            } else {
                let uid = getuid()
                return [
                    "launchctl bootout gui/\(uid) \(shellQuote(install.serviceFilePath))",
                ]
            }

        case .linux:
            if install.runAsSystemService {
                return [
                    "systemctl disable --now lumen.service",
                    "systemctl daemon-reload",
                ]
            } else {
                return [
                    "systemctl --user disable --now lumen.service",
                    "systemctl --user daemon-reload",
                ]
            }
        }
    }

    private func runShellCommand(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // best-effort stop before file removal
        }
    }

    private func askBool(prompt: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? "[Y/n]" : "[y/N]"

        while true {
            self.console.outputPrompt("\(prompt) \(suffix): ")
            let input = self.console.input(isSecure: false).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if input.isEmpty {
                return defaultValue
            }

            switch input {
            case "y", "yes":
                return true
            case "n", "no":
                return false
            default:
                self.console.printError("Please enter y or n.")
            }
        }
    }
}
