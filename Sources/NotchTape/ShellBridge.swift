import AppKit
import Darwin

// MARK: - Socket

/// A Unix stream socket the shell hooks write to. One connection carries one
/// message and is closed by the sender, so there is no framing to get wrong.
///
/// Wire format, fields separated by U+001F (unit separator), version first:
///
///     1␟start␟<pid>␟<seq>␟<cwd>␟<tty>␟<command>
///     1␟end␟<pid>␟<seq>␟<exit code>
///     1␟exit␟<pid>
///     1␟ctx␟<pid>␟<KUBECONFIG>␟<AWS profile>␟<gcloud config>␟<TF_WORKSPACE>␟<DOCKER_CONTEXT>␟<cwd>
///     1␟task␟<id>␟<pid>␟<tty>␟<state>␟<progress 0…1>␟<exit code>␟<title>␟<detail>
///
/// `task` comes from the `notch` command; `state` is start, progress, status,
/// done, fail or clear, and empty fields leave the previous value alone.
final class ShellBridge: @unchecked Sendable {
    static let shared = ShellBridge()

    static let socketPath = PrefsStore.directory.appendingPathComponent("notch.sock").path

    enum Message: Equatable {
        case start(pid: Int32, seq: Int, cwd: String, tty: String, command: String)
        case end(pid: Int32, seq: Int, exitCode: Int32)
        case exit(pid: Int32)
        case context(pid: Int32, ShellContext)
        case task(TaskUpdate)
    }

    struct TaskUpdate: Equatable {
        var id: String
        var pid: Int32
        var tty: String
        var state: String
        var progress: Double?
        var exitCode: Int32?
        var title: String
        var detail: String
    }

    // touched only on `queue` after `start`
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "notchtape.shell-bridge")

    func start(_ deliver: @escaping @MainActor (Message) -> Void) {
        queue.async { self.open(deliver) }
    }

    private func open(_ deliver: @escaping @MainActor (Message) -> Void) {
        let path = Self.socketPath
        unlink(path)   // a stale socket from a previous run refuses to bind

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 32) == 0 else { close(fd); return }
        chmod(path, 0o600)   // only this user's shells may talk to us
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listener = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll(deliver) }
        src.resume()
        source = src
    }

    private func acceptAll(_ deliver: @escaping @MainActor (Message) -> Void) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }   // EWOULDBLOCK: drained
            if let text = readAll(client), let message = Self.parse(text) {
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver(message) } }
            }
            close(client)
        }
    }

    /// Senders write a few hundred bytes and hang up; a short timeout keeps a
    /// misbehaving client from stalling the queue.
    private func readAll(_ fd: Int32) -> String? {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ text: String) -> Message? {
        let f = text.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        // a task is keyed by its own id, not a shell pid
        if f.count >= 10, f[0] == "1", f[1] == "task", let pid = Int32(f[3]) {
            let states: Set<String> = ["start", "progress", "status", "wait", "done", "fail", "clear"]
            guard !f[2].isEmpty, states.contains(f[5]) else { return nil }
            return .task(TaskUpdate(id: f[2], pid: pid, tty: f[4], state: f[5],
                                    progress: Double(f[6]).map { min(max($0, 0), 1) },
                                    exitCode: Int32(f[7]), title: f[8],
                                    detail: f[9...].joined(separator: "\u{1F}")))
        }
        guard f.count >= 3, f[0] == "1", let pid = Int32(f[2]) else { return nil }
        switch f[1] {
        case "start" where f.count >= 7:
            guard let seq = Int(f[3]) else { return nil }
            // the command itself may contain anything, including the separator
            let command = f[6...].joined(separator: "\u{1F}")
            return .start(pid: pid, seq: seq, cwd: f[4], tty: f[5], command: command)
        case "end" where f.count >= 5:
            guard let seq = Int(f[3]), let code = Int32(f[4]) else { return nil }
            return .end(pid: pid, seq: seq, exitCode: code)
        case "exit":
            return .exit(pid: pid)
        case "ctx" where f.count >= 9:
            return .context(pid: pid, ShellContext(kubeconfig: f[3], awsProfile: f[4], gcloudConfig: f[5],
                                                   tfWorkspace: f[6], dockerContext: f[7],
                                                   cwd: f[8...].joined(separator: "\u{1F}")))
        default:
            return nil
        }
    }
}

// MARK: - Installing the hook

/// Writes the zsh hook next to the socket and wires it into `~/.zshrc`.
@MainActor
enum ShellIntegration {
    static let scriptURL = PrefsStore.directory
        .appendingPathComponent("shell", isDirectory: true)
        .appendingPathComponent("notchtape.zsh")

    static var rcURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zshrc")
    }

    private static let marker = "# NotchTape: long-running commands in the notch"

    /// The line added to `~/.zshrc`. It survives the app being deleted.
    static var sourceLine: String {
        let path = "$HOME/Library/Application Support/NotchTape/shell/notchtape.zsh"
        return "[[ -r \"\(path)\" ]] && source \"\(path)\""
    }

    /// Where `notch` lives for shells and hooks: a stable path outside the app
    /// bundle, so moving or updating the app does not break a script.
    static let cliURL = PrefsStore.directory
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("notch")

    /// Rewritten on every launch, so a new app version updates the hook too.
    static func writeScript() {
        try? FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? zshScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        installCLI()
    }

    /// Copies `notch` from next to the app's own executable (inside the bundle,
    /// or in .build during development).
    static func installCLI() {
        guard let source = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("notch"),
              FileManager.default.isExecutableFile(atPath: source.path) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: cliURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // copy to a temporary name and swap, so a script running `notch` right now never sees half a file
        let temp = cliURL.deletingLastPathComponent().appendingPathComponent(".notch.new")
        try? fm.removeItem(at: temp)
        guard (try? fm.copyItem(at: source, to: temp)) != nil else { return }
        _ = try? fm.replaceItemAt(cliURL, withItemAt: temp)
        if !fm.fileExists(atPath: cliURL.path) { try? fm.moveItem(at: temp, to: cliURL) }
    }

    static var cliInstalled: Bool { FileManager.default.isExecutableFile(atPath: cliURL.path) }

    static var isInstalled: Bool {
        guard let rc = try? String(contentsOf: rcURL, encoding: .utf8) else { return false }
        return rc.contains("NotchTape/shell/notchtape.zsh")
    }

    /// Appends rather than rewrites: `~/.zshrc` is often a symlink into a dotfiles repo.
    static func install() throws {
        writeScript()
        guard !isInstalled else { return }
        let block = "\n\(marker)\n\(sourceLine)\n"
        let url = rcURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try block.write(to: url, atomically: false, encoding: .utf8)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(block.utf8))
    }

    static func uninstall() throws {
        let url = rcURL.resolvingSymlinksInPath()
        guard let rc = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = rc.components(separatedBy: "\n").filter {
            $0 != marker && !$0.contains("NotchTape/shell/notchtape.zsh")
        }
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Plain zsh: `zsh/net/socket` connects in-process, so a hook costs no fork.
    static let zshScript = #"""
    # NotchTape shell integration for zsh — generated by the app, rewritten on launch.
    # Reports each command to NotchTape so long ones show up in the notch.

    [[ -o interactive ]] || return 0
    (( ${+__notchtape_loaded} )) && return 0
    typeset -g __notchtape_loaded=1
    zmodload zsh/net/socket 2>/dev/null || return 0

    typeset -g __nt_sock="${NOTCHTAPE_SOCKET:-$HOME/Library/Application Support/NotchTape/notch.sock}"

    # `notch` for scripts started from this shell
    typeset -g __nt_bin="$HOME/Library/Application Support/NotchTape/bin"
    [[ -d $__nt_bin && ${path[(Ie)$__nt_bin]} -eq 0 ]] && path+=("$__nt_bin")
    typeset -gi __nt_seq=0
    typeset -g __nt_active=""
    typeset -g __nt_sep=$'\x1f'

    __nt_send() {
      [[ -S $__nt_sock ]] || return 0
      zsocket "$__nt_sock" 2>/dev/null || return 0
      local fd=$REPLY
      print -rn -u $fd -- "$1" 2>/dev/null
      exec {fd}>&-
    }

    __nt_preexec() {
      (( __nt_seq++ ))
      __nt_active=1
      __nt_send "1${__nt_sep}start${__nt_sep}$$${__nt_sep}${__nt_seq}${__nt_sep}${PWD}${__nt_sep}${TTY}${__nt_sep}$1"
    }

    __nt_precmd() {
      local code=$?
      if [[ -n $__nt_active ]]; then
        __nt_active=""
        __nt_send "1${__nt_sep}end${__nt_sep}$$${__nt_sep}${__nt_seq}${__nt_sep}${code}"
      fi
      __nt_context
    }

    # Environment variables only; the app reads kubeconfig and friends itself, so
    # a prompt never parses a large file. Sent on every prompt, so a restarted app
    # catches up at once.
    __nt_context() {
      local s=$__nt_sep
      __nt_send "1${s}ctx${s}$$${s}${KUBECONFIG}${s}${AWS_VAULT:-${AWS_PROFILE:-$AWS_DEFAULT_PROFILE}}${s}${CLOUDSDK_ACTIVE_CONFIG_NAME}${s}${TF_WORKSPACE}${s}${DOCKER_CONTEXT}${s}${PWD}"
    }

    __nt_zshexit() {
      # subshells run this too, with the parent's $$; only the shell itself leaving counts
      (( ZSH_SUBSHELL )) && return 0
      __nt_send "1${__nt_sep}exit${__nt_sep}$$"
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook preexec __nt_preexec
    add-zsh-hook zshexit __nt_zshexit
    # first in line, so no other hook has touched $? yet
    precmd_functions=(__nt_precmd ${precmd_functions:#__nt_precmd})
    __nt_context
    """#
}

// MARK: - Back to the terminal

enum TerminalFocus {
    /// Walks up from the shell to the first process that is a regular app —
    /// Terminal, iTerm, Ghostty, a VS Code window — and brings it forward. In
    /// Terminal and iTerm2 it goes on to the exact tab, found by its tty; macOS
    /// asks once for permission to control them.
    @MainActor static func activate(shellPID: Int32, tty: String = "") {
        var pid = shellPID
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                if !tty.isEmpty, selectTab(tty: tty, in: app.bundleIdentifier ?? "") { return }
                app.activate()
                return
            }
            guard let parent = parent(of: pid), parent > 1 else { return }
            pid = parent
        }
    }

    /// The tty comes from the shell itself (`$TTY`, `ttyname`), so it is always a
    /// plain `/dev/ttys…` path; anything else is refused rather than quoted.
    @MainActor private static func selectTab(tty: String, in bundleID: String) -> Bool {
        guard tty.hasPrefix("/dev/"), tty.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" }) else {
            return false
        }
        let source: String
        switch bundleID {
        case "com.apple.Terminal":
            source = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            source = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return false
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    private static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// `kill(pid, 0)` checks existence without sending anything.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
