// notch — show a script's progress in the NotchTape island.
//
// Talks to the app over the same Unix socket as the shell hook. It never fails a
// script because of NotchTape: with the app closed every command still exits 0
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
  notch agent claude              a Claude Code hook: reads the event on stdin
  notch agent codex <json>        a Codex `notify` program

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
            + "/Library/Application Support/NotchTape/notch.sock"
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

func agent(_ which: String, _ argument: String, socket: String) {
    let (pid, tty) = agentProcess()
    switch which {
    case "claude":
        // a Claude Code hook: the event arrives as JSON on stdin
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
        let session = event["session_id"] as? String ?? String(pid)
        let id = "claude-" + session
        let cwd = event["cwd"] as? String ?? ""
        let title = "Claude Code · " + (cwd as NSString).lastPathComponent
        switch event["hook_event_name"] as? String ?? "" {
        case "UserPromptSubmit":
            task("start", id: id, pid: pid, tty: tty, title: title,
                 detail: clip(event["prompt"] as? String ?? ""), socket: socket)
        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? ""
            let input = event["tool_input"] as? [String: Any] ?? [:]
            let what = input["command"] as? String ?? input["file_path"] as? String
                ?? input["pattern"] as? String ?? ""
            task("status", id: id, pid: pid, tty: tty, title: title,
                 detail: clip(what.isEmpty ? tool : tool + ": " + what), socket: socket)
        case "Notification":
            task("wait", id: id, pid: pid, tty: tty, title: title,
                 detail: clip(event["message"] as? String ?? ""), socket: socket)
        case "Stop":
            task("done", id: id, pid: pid, tty: tty, code: 0, title: title, socket: socket)
        case "SessionEnd":
            task("clear", id: id, pid: pid, tty: tty, title: title, socket: socket)
        default:
            break
        }
        // a hook's stdout can end up in the conversation; say nothing
        exit(0)

    case "codex":
        // Codex's `notify` program gets the event as its last argument
        guard let data = argument.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["type"] as? String == "agent-turn-complete" else { exit(0) }
        let cwd = event["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let title = "Codex · " + (cwd as NSString).lastPathComponent
        task("done", id: "codex-\(pid)", pid: pid, tty: tty, code: 0, title: title,
             detail: clip(event["last-assistant-message"] as? String ?? ""), socket: socket)
        exit(0)

    default:
        FileHandle.standardError.write(Data("notch: agent must be claude or codex\n".utf8))
        exit(64)
    }
}
