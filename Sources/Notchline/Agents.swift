import Foundation

/// A coding agent that can tell `notch` what it is doing.
enum Agent: String, CaseIterable, Identifiable {
    case claude, gemini, copilot, cursor, codex, aider
    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude:  return "Claude Code"
        case .gemini:  return "Gemini CLI"
        case .copilot: return "GitHub Copilot (VS Code)"
        case .cursor:  return "Cursor"
        case .codex:   return "Codex"
        case .aider:   return "Aider"
        }
    }

    /// How it is wired up.
    enum Setup {
        /// Hooks merged into a JSON settings file shared with the user's own.
        case mergedHooks
        /// A hooks file of our own in a folder the agent reads.
        case ownFile
        /// A line to paste into a config format that is not ours to rewrite.
        case line
    }

    var setup: Setup {
        switch self {
        case .claude, .gemini, .cursor: return .mergedHooks
        case .copilot:                  return .ownFile
        case .codex, .aider:            return .line
        }
    }

    var configPath: String {
        switch self {
        case .claude:  return "~/.claude/settings.json"
        case .gemini:  return "~/.gemini/settings.json"
        case .copilot: return "~/.copilot/hooks/notchline.json"
        case .cursor:  return "~/.cursor/hooks.json"
        case .codex:   return "~/.codex/config.toml"
        case .aider:   return "~/.aider.conf.yml"
        }
    }

    var configURL: URL {
        URL(fileURLWithPath: Paths.home).appendingPathComponent(String(configPath.dropFirst(2)))
    }

    /// The events we listen to. Cursor gets non-blocking ones only: its
    /// blocking hooks treat an empty answer as "deny".
    var events: [String] {
        switch self {
        case .claude:  return ["UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
        case .gemini:  return ["BeforeAgent", "BeforeTool", "Notification", "AfterAgent", "SessionEnd"]
        case .copilot: return ["UserPromptSubmit", "PreToolUse", "Stop"]
        case .cursor:  return ["postToolUse", "stop", "sessionEnd"]
        case .codex, .aider: return []
        }
    }

    /// The command the agent runs: full path, because hooks run without our PATH.
    var command: String { "\"\(ShellIntegration.cliURL.path)\" agent \(rawValue)" }
}

/// Wires coding agents to `notch`, so their sessions show in the island:
/// working, waiting for you, done.
@MainActor
enum AgentIntegration {
    // MARK: status

    static func isInstalled(_ agent: Agent) -> Bool {
        switch agent.setup {
        case .ownFile:
            return FileManager.default.fileExists(atPath: agent.configURL.path)
        case .line:
            let text = (try? String(contentsOf: agent.configURL, encoding: .utf8)) ?? ""
            return text.contains("agent \(agent.rawValue)") || text.contains("\"agent\", \"\(agent.rawValue)\"")
        case .mergedHooks:
            guard let root = read(agent.configURL), let hooks = root["hooks"] as? [String: Any] else { return false }
            return agent.events.allSatisfy { ((hooks[$0] as? [Any]) ?? []).contains { isOurs($0, agent) } }
        }
    }

    // MARK: install and remove

    static func install(_ agent: Agent) throws {
        switch agent.setup {
        case .line:
            return   // shown in Settings to paste
        case .ownFile:
            var hooks: [String: Any] = [:]
            for event in agent.events { hooks[event] = [entry(for: agent, event: event)] }
            try write(["hooks": hooks], to: agent.configURL)
        case .mergedHooks:
            guard var root = read(agent.configURL) else { throw AgentError.unreadable(agent.configPath) }
            backup(agent.configURL)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in agent.events {
                var entries = (hooks[event] as? [Any] ?? []).filter { !isOurs($0, agent) }
                entries.append(entry(for: agent, event: event))
                hooks[event] = entries
            }
            root["hooks"] = hooks
            if agent == .cursor, root["version"] == nil { root["version"] = 1 }
            try write(root, to: agent.configURL)
        }
    }

    static func remove(_ agent: Agent) throws {
        switch agent.setup {
        case .line:
            return
        case .ownFile:
            try? FileManager.default.removeItem(at: agent.configURL)
        case .mergedHooks:
            guard var root = read(agent.configURL), var hooks = root["hooks"] as? [String: Any] else { return }
            for (event, value) in hooks {
                let kept = (value as? [Any] ?? []).filter { !isOurs($0, agent) }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            try write(root, to: agent.configURL)
        }
    }

    /// One hook entry in the shape each agent expects.
    private static func entry(for agent: Agent, event: String) -> [String: Any] {
        switch agent {
        case .cursor:
            // flat, timeout in seconds
            return ["command": agent.command, "timeout": 5]
        case .copilot:
            return ["type": "command", "command": agent.command, "timeout": 5]
        case .gemini:
            // Claude-like nesting, timeout in milliseconds
            var e: [String: Any] = ["hooks": [["type": "command", "command": agent.command,
                                               "name": "notchline", "timeout": 5000]]]
            if event == "BeforeTool" { e["matcher"] = "*" }
            return e
        default:
            var e: [String: Any] = ["hooks": [["type": "command", "command": agent.command, "timeout": 5]]]
            if event == "PreToolUse" { e["matcher"] = "*" }
            return e
        }
    }

    private static func isOurs(_ entry: Any, _ agent: Agent) -> Bool {
        let marker = "notch\" agent \(agent.rawValue)"
        guard let dict = entry as? [String: Any] else { return false }
        if (dict["command"] as? String)?.contains(marker) == true { return true }
        let nested = dict["hooks"] as? [[String: Any]] ?? []
        return nested.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    // MARK: lines to paste

    /// For config formats we do not rewrite: TOML and YAML.
    static func line(for agent: Agent) -> String {
        let cli = ShellIntegration.cliURL.path
        switch agent {
        case .codex: return "notify = [\"\(cli)\", \"agent\", \"codex\"]"
        case .aider: return "notifications: true\nnotifications-command: \"\\\"\(cli)\\\" agent aider\""
        default:     return ""
        }
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

    /// nil when the file exists but is not a JSON object; an empty object when
    /// it does not exist yet.
    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func backup(_ url: URL) {
        let copy = url.appendingPathExtension("notchline-backup")
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

    // MARK: kept for the tests and older call sites

    static var claudeInstalled: Bool { isInstalled(.claude) }
    static func installClaude() throws { try install(.claude) }
    static func removeClaude() throws { try remove(.claude) }
}
