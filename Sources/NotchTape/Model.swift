import Foundation

/// One command typed into a shell, from `preexec` to the next prompt.
struct TrackedCommand: Identifiable, Equatable, Codable {
    /// `<shell pid>-<sequence>`: unique for as long as the shell lives.
    let id: String
    let pid: Int32
    let command: String
    let cwd: String
    let tty: String
    let started: Date
    var ended: Date? = nil
    var exitCode: Int32? = nil

    var succeeded: Bool { exitCode == 0 }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        (ended ?? now).timeIntervalSince(started)
    }

    /// The program name, past `sudo`, `time`, `env` and `FOO=bar` prefixes.
    var program: String {
        let skip: Set<String> = ["sudo", "time", "env", "command", "exec", "nohup", "caffeinate"]
        for word in command.split(whereSeparator: \.isWhitespace) {
            let w = String(word)
            if skip.contains(w) || w.hasPrefix("-") || w.contains("=") { continue }
            return (w as NSString).lastPathComponent
        }
        return command
    }

    /// `~/Projects/app` instead of `/Users/name/Projects/app`.
    var shortCwd: String {
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// Short enough for the strip: long commands lose their middle.
    func short(_ limit: Int) -> String {
        let flat = command.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit, limit > 3 else { return flat }
        let head = (limit - 1) * 2 / 3
        let tail = limit - 1 - head
        return flat.prefix(head) + "…" + flat.suffix(tail)
    }
}

/// A task a script reports through `notch`.
struct ScriptTask: Identifiable, Equatable {
    let id: String
    /// The process that owns it; when it dies without a word, the task goes.
    var pid: Int32
    var tty: String
    var title: String
    var detail: String = ""
    /// 0…1, or nil while the script only says it is busy.
    var progress: Double?
    /// Asked for attention with `notch wait`: a question, a password, a permission.
    var waiting = false
    let started: Date
    var updated: Date

    /// Claude Code and Codex report every turn; those are not history.
    var isAgent: Bool { id.hasPrefix("claude-") || id.hasPrefix("codex-") }

    func elapsed(at now: Date = Date()) -> TimeInterval { now.timeIntervalSince(started) }
}

enum Fmt {
    /// 42s · 3:07 · 1:02:33
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func ago(_ date: Date, now: Date = Date(), locale: Locale) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}
