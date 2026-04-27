import Foundation
import Vapor

// MARK: - XML Helpers

func xmlUnescaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&amp;", with: "&")
}

// MARK: - ConfigParser

enum ConfigParser {
    static func loadExistingConfig(from path: String, platform: InstallPlatform) -> ExistingConfig {
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

    static func parseLaunchdConfig(_ contents: String) -> ExistingConfig {
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

            return xmlUnescaped(String(contents[valueRange])).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ExistingConfig(
            apiKey: value(for: "LUMEN_API_KEY"),
            port: value(for: "LUMEN_PORT").flatMap(Int.init),
            allowSudo: value(for: "LUMEN_ALLOW_SUDO").map { $0.lowercased() == "true" },
        )
    }

    static func parseSystemdConfig(_ contents: String) -> ExistingConfig {
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
}

// MARK: - FileManager

extension FileManager {
    func canWritePath(_ path: String) -> Bool {
        if self.fileExists(atPath: path) {
            return self.isWritableFile(atPath: path)
        }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if parent == path || parent.isEmpty {
            return false
        }

        if self.fileExists(atPath: parent) {
            return self.isWritableFile(atPath: parent)
        }

        return self.canWritePath(parent)
    }
}

// MARK: - Console

extension Console {
    func askBool(prompt: String, defaultValue: Bool) -> Bool {
        let suffix = defaultValue ? "[Y/n]" : "[y/N]"

        while true {
            self.outputPrompt("\(prompt) \(suffix): ")
            let input = self.input(isSecure: false).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if input.isEmpty {
                return defaultValue
            }

            switch input {
            case "y", "yes":
                return true
            case "n", "no":
                return false
            default:
                self.printError("Please enter y or n.")
            }
        }
    }
}
