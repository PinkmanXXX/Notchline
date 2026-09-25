// notch — show a script's progress in the Notchline island.
//
// Talks to the app over the same Unix socket as the shell hook. It never fails a
// script because of Notchline: with the app closed every command still exits 0
// (`run` exits with the wrapped command's status).

import Foundation

let usage = """
usage: notch <command> [arguments] [options]

  notch start "Deploy"            a task with a spinner
  notch progress 40 ["Deploy"]    a task at 40 %
  notch status "3 of 7 hosts"     change the line under the title
  notch wait ["Needs a password"] ask for attention: amber, with a toast
  notch done ["All green"]        finish with a green toast
  notch fail ["Rollback"]         finish with a red toast
  notch clear                     remove the task without a toast
  notch run <command> [args…]     run a command and report how it ended
  notch agent <name>              an agent hook: claude, gemini, copilot, cursor,
                                  codex (event as argument) or aider

options
  --id <name>      the task to update. Defaults to the calling process,
                   so every call from one script updates the same task
  --title <text>   set the title with any command
  --socket <path>  talk to this socket; also NOTCH_SOCKET

"""

let separator = "\u{1F}"

struct Options {
    var id: String?
    var title = ""
    // $HOME first, like the zsh hook, so both always reach the same app
    var socket = ProcessInfo.processInfo.environment["NOTCH_SOCKET"]
        ?? (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
            + "/Library/Application Support/Notchline/notch.sock"
    var positional: [String] = []
}

func parse(_ args: ArraySlice<String>) -> Options {
    var o = Options()
    var rest = args
    while let a = rest.popFirst() {
        switch a {
        case "--id":     o.id = rest.popFirst()
        case "--title":  o.title = rest.popFirst() ?? ""
        case "--socket": o.socket = rest.popFirst() ?? o.socket
        case "--":       o.positional += rest; rest = []
        default:         o.positional.append(a)
        }
    }
    return o
}

/// One connection, one message; errors are swallowed on purpose.
func send(_ message: String, to path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        dst.copyBytes(from: bytes)
        dst[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return }
    let data = Array(message.utf8)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
}

func tty() -> String {
    for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where isatty(fd) != 0 {
        if let name = ttyname(fd) { return String(cString: name) }
    }
    return ""
}

// MARK: process tree

func processInfo(_ pid: Int32) -> kinfo_proc? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}

func name(of info: kinfo_proc) -> String {
    var comm = info.kp_proc.p_comm
    return withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// The agent behind a hook: the first ancestor that is not a shell the hook
/// was run through. Its pid keeps the task alive, its terminal is where a
/// click should go.
func agentProcess() -> (pid: Int32, tty: String) {
    let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "notch"]
    var pid = getppid()
    for _ in 0..<6 {
        guard let info = processInfo(pid) else { break }
        if !wrappers.contains(name(of: info)) {
            let dev = info.kp_eproc.e_tdev
            var tty = ""
            if dev != -1, let name = devname(dev, S_IFCHR) { tty = "/dev/" + String(cString: name) }
            return (pid, tty)
        }
        pid = info.kp_eproc.e_ppid
    }
    return (getppid(), "")
}

/// 1␟task␟<id>␟<pid>␟<tty>␟<state>␟<progress>␟<exit code>␟<title>␟<detail>
func task(_ state: String, id: String, pid: Int32, tty: String = tty(), progress: Double? = nil,
          code: Int32? = nil, title: String, detail: String = "", socket: String) {
    let fields = ["1", "task", id, String(pid), tty, state,
                  progress.map { String($0) } ?? "", code.map { String($0) } ?? "",
                  title.replacingOccurrences(of: separator, with: " "), detail]
    send(fields.joined(separator: separator), to: socket)
}

// MARK: -

let args = CommandLine.arguments
guard args.count >= 2, !["-h", "--help", "help"].contains(args[1]) else {
    print(usage, terminator: "")
    exit(args.count >= 2 ? 0 : 64)
}

let command = args[1]
var o = parse(args.dropFirst(2))
// the script calling us: it owns the task, and when it dies the task goes too
let owner = getppid()
let id = o.id ?? "pid-\(owner)"
let text = o.positional.joined(separator: " ")

switch command {
case "start":
    task("start", id: id, pid: owner, title: o.title.isEmpty ? text : o.title,
         detail: o.title.isEmpty ? "" : text, socket: o.socket)

case "progress":
    guard let first = o.positional.first,
          let value = Double(first.replacingOccurrences(of: "%", with: "")) else {
        FileHandle.standardError.write(Data("notch: progress needs a number from 0 to 100\n".utf8))
        exit(64)
    }
    let title = o.title.isEmpty ? o.positional.dropFirst().joined(separator: " ") : o.title
    task("progress", id: id, pid: owner, progress: min(max(value, 0), 100) / 100,
         title: title, socket: o.socket)

case "status":
    task("status", id: id, pid: owner, title: o.title, detail: text, socket: o.socket)

case "wait":
    task("wait", id: id, pid: owner, title: o.title, detail: text, socket: o.socket)

case "done":
    task("done", id: id, pid: owner, code: 0, title: o.title, detail: text, socket: o.socket)

case "fail":
    task("fail", id: id, pid: owner, code: 1, title: o.title, detail: text, socket: o.socket)

case "clear":
    task("clear", id: id, pid: owner, title: "", socket: o.socket)

case "run":
    guard !o.positional.isEmpty else {
        FileHandle.standardError.write(Data("notch: run needs a command\n".utf8))
        exit(64)
    }
    // the task belongs to this process, which lives exactly as long as the command
    let runID = o.id ?? "run-\(getpid())"
    let title = o.title.isEmpty ? o.positional.joined(separator: " ") : o.title
    task("start", id: runID, pid: getpid(), title: title,
         detail: FileManager.default.currentDirectoryPath, socket: o.socket)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = o.positional
    do { try process.run() } catch {
        FileHandle.standardError.write(Data("notch: \(error.localizedDescription)\n".utf8))
        task("fail", id: runID, pid: getpid(), code: 127, title: title, detail: "not found", socket: o.socket)
        exit(127)
    }
    // Ctrl-C reaches the child through the process group; we only wait for it
    signal(SIGINT, SIG_IGN)
    process.waitUntilExit()
    let code: Int32 = process.terminationReason == .uncaughtSignal
        ? 128 + process.terminationStatus : process.terminationStatus
    task(code == 0 ? "done" : "fail", id: runID, pid: getpid(), code: code, title: title,
         detail: code == 0 ? "" : "exit \(code)", socket: o.socket)
    exit(code)

case "agent":
    agent(o.positional.first ?? "", o.positional.dropFirst().joined(separator: " "), socket: o.socket)

default:
    FileHandle.standardError.write(Data("notch: unknown command '\(command)'\n\n\(usage)".utf8))
    exit(64)
}

// MARK: - agents

/// One line of what the agent is doing, short enough for the island.
func clip(_ text: String, _ limit: Int = 60) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
}

/// What an agent's event means for the island.
enum Step {
    case start(String), status(String), wait(String), done(String), clear, nothing
}

func agent(_ which: String, _ argument: String, socket: String) {
    // local, not a global: top-level code in main.swift runs in order, and this
    // function is called from above where a global would be initialised
    let agentNames = ["claude": "Claude Code", "gemini": "Gemini CLI", "copilot": "Copilot",
                      "cursor": "Cursor", "codex": "Codex", "aider": "Aider"]
    guard let name = agentNames[which] else {
        FileHandle.standardError.write(Data("notch: agent must be one of \(agentNames.keys.sorted().joined(separator: ", "))\n".utf8))
        exit(64)
    }
    let (pid, tty) = agentProcess()

    // hooks bring the event as JSON on stdin, Codex as its last argument, Aider not at all
    var event: [String: Any] = [:]
    switch which {
    case "codex":
        event = (try? JSONSerialization.jsonObject(with: Data(argument.utf8))) as? [String: Any] ?? [:]
    case "aider":
        break
    default:
        let input = FileHandle.standardInput.readDataToEndOfFile()
        event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
    }

    /// The first non-empty string among the keys: agents spell the same thing differently.
    func field(_ keys: String..., in object: [String: Any]? = nil) -> String {
        for k in keys { if let v = (object ?? event)[k] as? String, !v.isEmpty { return v } }
        return ""
    }

    let session = field("session_id", "sessionId", "conversation_id", "conversationId")
    let id = "agent-\(which)-" + (session.isEmpty ? String(pid) : session)
    var cwd = field("cwd")
    if cwd.isEmpty { cwd = (event["workspace_roots"] as? [String])?.first ?? "" }
    if cwd.isEmpty { cwd = FileManager.default.currentDirectoryPath }
    let title = name + " · " + (cwd as NSString).lastPathComponent

    // `Bash: npm test`, `Edit: Sources/App.swift`
    func tool() -> String {
        let name = field("tool_name", "toolName")
        let input = (event["tool_input"] ?? event["toolInput"]) as? [String: Any]
        let what = field("command", "file_path", "filePath", "path", "pattern", "query", in: input ?? [:])
        return clip(what.isEmpty ? name : name + ": " + what)
    }

    let hook = field("hook_event_name", "hookEventName")
    let step: Step
    switch (which, hook) {
    case ("claude", "UserPromptSubmit"), ("gemini", "BeforeAgent"), ("copilot", "UserPromptSubmit"):
        step = .start(clip(field("prompt")))
    case ("claude", "PreToolUse"), ("gemini", "BeforeTool"), ("copilot", "PreToolUse"), ("cursor", "postToolUse"):
        step = .status(tool())
    case ("claude", "Notification"), ("gemini", "Notification"):
        step = .wait(clip(field("message", "notification_type")))
    case ("claude", "Stop"), ("gemini", "AfterAgent"), ("copilot", "Stop"), ("cursor", "stop"):
        step = .done("")
    case ("claude", "SessionEnd"), ("gemini", "SessionEnd"), ("cursor", "sessionEnd"):
        step = .clear
    case ("codex", _):
        step = field("type") == "agent-turn-complete" ? .done(clip(field("last-assistant-message"))) : .nothing
    case ("aider", _):
        // Aider calls its notifications command when a reply is done and it waits for you
        step = .done("")
    default:
        step = .nothing
    }

    switch step {
    case .start(let d):  task("start", id: id, pid: pid, tty: tty, title: title, detail: d, socket: socket)
    case .status(let d): task("status", id: id, pid: pid, tty: tty, title: title, detail: d, socket: socket)
    case .wait(let d):   task("wait", id: id, pid: pid, tty: tty, title: title, detail: d, socket: socket)
    case .done(let d):   task("done", id: id, pid: pid, tty: tty, code: 0, title: title, detail: d, socket: socket)
    case .clear:         task("clear", id: id, pid: pid, tty: tty, title: title, socket: socket)
    case .nothing:       break
    }

    // Claude adds a hook's stdout to the conversation, so it gets nothing; Gemini,
    // Copilot and Cursor parse it as JSON, where an empty object means "no opinion"
    if ["gemini", "copilot", "cursor"].contains(which) { print("{}") }
    exit(0)
}
