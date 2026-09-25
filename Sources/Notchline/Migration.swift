import Foundation

/// The app used to be called NotchTape. On the first launch under the new name
/// its folder moves over, and everything that pointed into it is repointed:
/// the line in ~/.zshrc and the agents' hooks.
enum Migration {
    private static let oldName = "Notch" + "Tape"   // split, so a rename cannot rewrite it
    private static var oldDirectory: URL {
        URL(fileURLWithPath: Paths.home).appendingPathComponent("Library/Application Support/\(oldName)")
    }
    private static var oldHookPath: String { "\(oldName)/shell/\(oldName.lowercased()).zsh" }
    private static var oldCLIPath: String { "\(oldName)/bin/notch" }

    /// Before anything touches the support folder: `PrefsStore.directory`
    /// creates the new one, after which there would be nothing to move into.
    nonisolated static func moveSupportFolder() {
        let fm = FileManager.default
        let new = URL(fileURLWithPath: Paths.home).appendingPathComponent("Library/Application Support/Notchline")
        guard fm.fileExists(atPath: oldDirectory.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: oldDirectory, to: new)
        // the old hook script and socket go; launch writes and opens new ones
        try? fm.removeItem(at: new.appendingPathComponent("shell/\(oldName.lowercased()).zsh"))
        try? fm.removeItem(at: new.appendingPathComponent("notch.sock"))
    }

    /// A config file's text with JSON's optional `\/` escapes undone, so a path
    /// is found however the file was last written.
    private static func text(_ url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").replacingOccurrences(of: "\\/", with: "/")
    }

    /// After launch has written the new hook script and copied `notch`.
    @MainActor static func repointHooks() {
        let fm = FileManager.default

        // ~/.zshrc: take out the old line, put in the new one
        if let rc = try? String(contentsOf: ShellIntegration.rcURL, encoding: .utf8), rc.contains(oldHookPath) {
            try? ShellIntegration.uninstall()
            try? ShellIntegration.install()
        }

        // agents whose hooks run the old `notch`: installing again replaces ours in place
        for agent in Agent.allCases where agent.setup != .line {
            if text(agent.configURL).contains(oldCLIPath) { try? AgentIntegration.install(agent) }
        }
        let oldCopilotFile = URL(fileURLWithPath: Paths.home)
            .appendingPathComponent(".copilot/hooks/\(oldName.lowercased()).json")
        if fm.fileExists(atPath: oldCopilotFile.path) {
            try? fm.removeItem(at: oldCopilotFile)
            try? AgentIntegration.install(.copilot)
        }

        // Codex and Aider keep a pasted line we do not rewrite: leave a link where it points
        let pasted = Agent.allCases.filter { $0.setup == .line }.contains { text($0.configURL).contains(oldCLIPath) }
        if pasted {
            let link = oldDirectory.appendingPathComponent("bin/notch")
            try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(at: link, withDestinationURL: ShellIntegration.cliURL)
        }
    }

    /// Lines of ours in ~/.zshrc, under either name.
    static func isOurRCLine(_ line: String) -> Bool {
        line.contains("Notchline/shell/notchline.zsh") || line.contains(oldHookPath)
            || line == "# Notchline: long-running commands in the notch"
            || line == "# \(oldName): long-running commands in the notch"
    }
}
