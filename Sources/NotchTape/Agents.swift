import Foundation

/// Wires coding agents to `notch`, so their sessions show in the island:
/// working, waiting for you, done.
@MainActor
enum AgentIntegration {
    // MARK: Claude Code

    static var claudeSettingsURL: URL {
        URL(fileURLWithPath: Paths.home).appendingPathComponent(".claude/settings.json")
    }

    /// The hook command, with the full path: hooks run without our PATH.
    static var claudeCommand: String { "\"\(ShellIntegration.cliURL.path)\" agent claude" }

    /// Events and what they become: a prompt starts work, a tool call updates
    /// it, a notification asks for you, a stop finishes the turn.
    static let claudeEvents = ["UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]

    private static func isOurs(_ entry: Any) -> Bool {
        guard let hooks = (entry as? [String: Any])?["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains("notch\" agent claude") == true }
    }

    static var claudeInstalled: Bool {
        guard let root = readClaudeSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return claudeEvents.allSatisfy { ((hooks[$0] as? [Any]) ?? []).contains(where: isOurs) }
    }

    private static func readClaudeSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeSettingsURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Adds one hook per event, next to whatever is already there. The first
    /// time it touches the file it leaves a copy beside it.
    static func installClaude() throws {
        guard var root = readClaudeSettings() else { throw AgentError.unreadable(claudeSettingsURL.path) }
        backup(claudeSettingsURL)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            var entries = (hooks[event] as? [Any] ?? []).filter { !isOurs($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": claudeCommand, "timeout": 5]]]
            if event == "PreToolUse" { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        try write(root, to: claudeSettingsURL)
    }

    static func removeClaude() throws {
        guard var root = readClaudeSettings(), var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            let kept = (value as? [Any] ?? []).filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try write(root, to: claudeSettingsURL)
    }

    // MARK: Codex

    /// Codex takes one `notify` program in ~/.codex/config.toml. TOML is not
    /// ours to rewrite, so this is a line to paste.
    static var codexLine: String { "notify = [\"\(ShellIntegration.cliURL.path)\", \"agent\", \"codex\"]" }

    static var codexInstalled: Bool {
        let url = URL(fileURLWithPath: Paths.home).appendingPathComponent(".codex/config.toml")
        return (try? String(contentsOf: url, encoding: .utf8))?.contains("\"agent\", \"codex\"") == true
    }

    // MARK: files

    enum AgentError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return L10n.t("agentUnreadable", ["p": path])
            }
        }
    }

    private static func backup(_ url: URL) {
        let copy = url.appendingPathExtension("notchtape-backup")
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.copyItem(at: url, to: copy)
    }

    /// Writes through a symlink to its target, as dotfile repos expect.
    private static func write(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: target, options: .atomic)
    }
}
