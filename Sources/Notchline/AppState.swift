import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var prefs: Prefs { didSet { PrefsStore.shared.save(prefs); L10n.lang = prefs.lang } }

    /// Every command that has started and not ended, including the short ones
    /// that have not earned a place on the strip yet.
    @Published private(set) var running: [TrackedCommand] = []
    /// The part of `running` old enough to show, newest first.
    @Published private(set) var visibleRunning: [TrackedCommand] = []
    /// Finished commands that were long enough to show, newest first.
    @Published private(set) var recent: [TrackedCommand] = [] { didSet { saveHistory() } }
    /// Tasks scripts report through `notch`, newest first.
    @Published private(set) var tasks: [ScriptTask] = []
    /// Shells that have talked to us since launch.
    @Published private(set) var shells: Set<Int32> = []
    @Published private(set) var hookInstalled = ShellIntegration.isInstalled

    /// Environments of the shell used last, with prod ones marked.
    @Published private(set) var env: [EnvItem] = []
    /// What makes the strip red: prod environments of the shell in use and of
    /// any shell that is busy running something.
    @Published private(set) var prodAlert: [EnvItem] = []
    /// Shells pointed at prod, whether in use or not.
    @Published private(set) var prodShells = 0

    @Published var expanded = false                       // panel open
    @Published var pinned = false
    @Published var toast: Toast? = nil
    @Published var settingsTab: SettingsTab = .general

    struct Toast: Equatable {
        enum Kind { case success, failure, prod, attention }
        var id = UUID()
        var title: String
        var subtitle: String
        var trailing: String
        var kind: Kind
        var pid: Int32
        var tty = ""
    }

    private var ticker: Timer?
    private var guardTimer: Timer?
    private var contexts: [Int32: ShellContext] = [:]
    /// The command each shell is running now, including ignored ones like `ssh`.
    private var foreground: [Int32: TrackedCommand] = [:]
    /// The shell that spoke last: the one you are typing in.
    private var activeShell: Int32?
    private let recentLimit = 30

    private init() {
        prefs = PrefsStore.shared.prefs
        L10n.lang = prefs.lang
        // straight into the storage: through the setter, `didSet` would write it back at once
        if prefs.keepHistory { _recent = Published(initialValue: Self.loadHistory()) }
    }

    func start() {
        ShellIntegration.writeScript()
        ShellBridge.shared.start { [weak self] message in
            guard let self else { return nil }
            #if DEBUG
            if case let .debug(args) = message { return self.debugReply(args) }
            #endif
            self.handle(message)
            return nil
        }
        if prefs.systemNotifications { requestNotificationPermission() }
    }

    /// A shell that has talked to us is connected, whichever rc file loaded the hook.
    var isConnected: Bool { hookInstalled || !shells.isEmpty }

    /// Whether the collapsed strip has anything to say.
    var stripHasContent: Bool {
        switch prefs.show {
        case .always: return true
        case .auto:   return !tasks.isEmpty || !visibleRunning.isEmpty || !isConnected || !prodAlert.isEmpty
        // the guard is a safety net, so it shows through even a hidden strip
        case .hidden: return !prodAlert.isEmpty
        }
    }

    // MARK: messages from the shells

    func handle(_ message: ShellBridge.Message) {
        apply(message)
        #if DEBUG
        // NOTCHLINE_TRACE=1 .build/debug/Notchline: every message and the state after it
        if ProcessInfo.processInfo.environment["NOTCHLINE_TRACE"] != nil {
            let t = tasks.map { "\($0.title)|\($0.detail)|\($0.progress.map { String($0) } ?? "-")|wait=\($0.waiting)" }
            FileHandle.standardError.write(Data("""
                in: \(message)
                  tasks: \(t)  toast: \(toast?.title ?? "-") / \(toast?.subtitle ?? "")  recent: \(recent.first?.command ?? "-")

                """.utf8))
        }
        #endif
    }

    private func apply(_ message: ShellBridge.Message) {
        switch message {
        case let .start(pid, seq, cwd, tty, command):
            shells.insert(pid)
            if !hookInstalled { hookInstalled = ShellIntegration.isInstalled }
            let cmd = TrackedCommand(id: "\(pid)-\(seq)", pid: pid, command: command,
                                     cwd: cwd, tty: tty, started: Date())
            foreground[pid] = cmd
            activeShell = pid
            evaluateGuard()
            guard !isIgnored(cmd) else { return }
            // a shell runs one foreground command at a time; anything left over
            // from it lost its `end` (Ctrl-Z, a crashed hook) and is stale
            running.removeAll { $0.pid == pid }
            running.append(cmd)
            startTicker()

        case let .end(pid, seq, exitCode):
            shells.insert(pid)
            foreground[pid] = nil
            activeShell = pid
            evaluateGuard()
            guard let i = running.firstIndex(where: { $0.id == "\(pid)-\(seq)" }) else { return }
            var cmd = running.remove(at: i)
            cmd.ended = Date()
            cmd.exitCode = exitCode
            finish(cmd)

        case let .exit(pid):
            shells.remove(pid)
            running.removeAll { $0.pid == pid }
            forget(pid)
            refreshVisible()

        case let .task(update):
            handleTask(update)

        case .debug:
            break   // answered in `start`, never applied

        case let .context(pid, ctx):
            shells.insert(pid)
            contexts[pid] = ctx
            activeShell = pid
            evaluateGuard()
            startGuardTimer()
        }
    }

    // MARK: tasks from `notch`

    private func handleTask(_ u: ShellBridge.TaskUpdate) {
        let now = Date()
        let i = tasks.firstIndex { $0.id == u.id }
        switch u.state {
        case "clear":
            if let i { tasks.remove(at: i) }

        case "done", "fail":
            let task = i.map { tasks.remove(at: $0) }
            let title = u.title.isEmpty ? (task?.title ?? "") : u.title
            let ok = u.state == "done"
            let started = task?.started ?? now
            let agent = u.id.hasPrefix("agent-")
            var record = TrackedCommand(id: "task-\(u.id)-\(Int(started.timeIntervalSince1970))",
                                        pid: u.pid, command: title.isEmpty ? L10n.t("task") : title,
                                        cwd: u.detail.isEmpty ? (task?.detail ?? "") : u.detail,
                                        tty: u.tty, started: started)
            record.ended = now
            record.exitCode = u.exitCode ?? (ok ? 0 : 1)
            if !agent {
                recent.insert(record, at: 0)
                if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
            }
            // a script asked for this, so it is announced whatever its length
            announce(record, detail: u.detail)

        default:   // start, progress, status
            var task = i.map { tasks[$0] } ?? ScriptTask(id: u.id, pid: u.pid, tty: u.tty,
                                                        title: L10n.t("task"), started: now, updated: now)
            if u.state == "start", i != nil {
                task = ScriptTask(id: u.id, pid: u.pid, tty: u.tty, title: task.title, started: now, updated: now)
            }
            if !u.title.isEmpty { task.title = u.title }
            if !u.detail.isEmpty || u.state == "status" { task.detail = u.detail }
            if let p = u.progress { task.progress = p }
            let wasWaiting = task.waiting
            task.waiting = u.state == "wait"
            task.pid = u.pid
            if !u.tty.isEmpty { task.tty = u.tty }
            task.updated = now
            if let i { tasks.remove(at: i) }
            tasks.insert(task, at: 0)
            startTicker()
            if task.waiting && !wasWaiting { askForAttention(task) }
        }
    }

    /// Waiting tasks come first: they are the ones that cannot go on without you.
    var orderedTasks: [ScriptTask] {
        tasks.filter(\.waiting) + tasks.filter { !$0.waiting }
    }

    private func askForAttention(_ task: ScriptTask) {
        let shown = Toast(title: task.title, subtitle: task.detail.isEmpty ? L10n.t("waitingForYou") : task.detail,
                          trailing: "", kind: .attention, pid: task.pid, tty: task.tty)
        toast = shown
        NotchController.shared.showToast()
        if prefs.sound { NSSound(named: "Tink")?.play() }
        if prefs.systemNotifications {
            let content = UNMutableNotificationContent()
            content.title = task.title
            content.body = shown.subtitle
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: task.id + "-wait", content: content, trigger: nil))
        }
        dismissLater(shown)
    }

    private func isIgnored(_ cmd: TrackedCommand) -> Bool {
        let program = cmd.program.lowercased()
        return prefs.ignored.contains { $0.lowercased() == program }
    }

    private func finish(_ cmd: TrackedCommand) {
        let duration = cmd.elapsed()
        if duration >= prefs.showAfter {
            recent.insert(cmd, at: 0)
            if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }
        }
        refreshVisible()
        if duration >= prefs.notifyAfter { announce(cmd) }
    }

    // MARK: ticking

    /// Runs only while something is running: promotes commands past the
    /// threshold, drops ones whose shell died, and lets the strip resize as the
    /// timer grows a digit.
    private func startTicker() {
        refreshVisible()
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AppState.shared.tick() }
        }
    }

    private func tick() {
        // a closed terminal tab takes its shell with it, and no `end` ever comes
        let dead = running.filter { !TerminalFocus.isAlive($0.pid) }
        if !dead.isEmpty {
            running.removeAll { cmd in dead.contains { $0.id == cmd.id } }
            dead.forEach { shells.remove($0.pid); forget($0.pid) }
        }
        // a script that died without `done` or `fail`; tasks from elsewhere, like
        // a remote host over a forwarded socket, have no local pid and time out
        let now = Date()
        tasks.removeAll { task in
            task.pid > 0 ? !TerminalFocus.isAlive(task.pid) : now.timeIntervalSince(task.updated) > 3600
        }
        refreshVisible()
        if running.isEmpty && tasks.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
        if !expanded && toast == nil { NotchController.shared.layout(animated: false) }
    }

    private func refreshVisible() {
        let now = Date()
        let visible = running
            .filter { $0.elapsed(at: now) >= prefs.showAfter }
            .sorted { $0.started > $1.started }
        guard visible.map(\.id) != visibleRunning.map(\.id) else { return }
        visibleRunning = visible
        if !expanded && toast == nil { NotchController.shared.layout(animated: true) }
    }

    // MARK: prod guard

    private func forget(_ pid: Int32) {
        contexts[pid] = nil
        foreground[pid] = nil
        if activeShell == pid { activeShell = nil }
        evaluateGuard()
    }

    /// Re-reads kubeconfig and friends every few seconds while shells are
    /// around: `kubectx` in one tab, or Lens, changes them without a prompt here.
    private func startGuardTimer() {
        guard guardTimer == nil else { return }
        guardTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let state = AppState.shared
                for pid in state.contexts.keys where !TerminalFocus.isAlive(pid) {
                    state.shells.remove(pid)
                    state.contexts[pid] = nil
                    state.foreground[pid] = nil
                }
                state.evaluateGuard()
                if state.contexts.isEmpty {
                    state.guardTimer?.invalidate()
                    state.guardTimer = nil
                }
            }
        }
    }

    func evaluateGuard() {
        let rules = prefs.prodPatterns
        let sources = Set(prefs.guardSources)
        var alert: [EnvItem] = []
        var activeItems: [EnvItem] = []
        var inProd = 0

        for pid in Set(contexts.keys).union(foreground.keys) {
            let items = EnvResolver.items(for: contexts[pid] ?? ShellContext(), foreground: foreground[pid])
                .map { item -> EnvItem in
                    var i = item
                    i.isProd = prefs.guardEnabled && sources.contains(i.kind)
                        && ProdRules.matches(i.value, patterns: rules)
                    return i
                }
                // the folder is context, not a warning, unless it is being watched
                .filter { $0.kind != .path || sources.contains(.path) }
            if pid == activeShell { activeItems = items }
            let prod = items.filter(\.isProd)
            if !prod.isEmpty { inProd += 1 }
            if pid == activeShell || foreground[pid] != nil {
                for p in prod where !alert.contains(p) { alert.append(p) }
            }
        }
        alert.sort { $0.id < $1.id }   // a stable order: dictionary order would make it flicker

        if activeItems != env { env = activeItems }
        if inProd != prodShells { prodShells = inProd }
        guard alert != prodAlert else { return }
        let entering = prodAlert.isEmpty && !alert.isEmpty
        prodAlert = alert
        if entering && prefs.guardAnnounce {
            announceProd(alert)
        } else if !expanded && toast == nil {
            NotchController.shared.layout(animated: true)
        }
    }

    private func announceProd(_ items: [EnvItem]) {
        let shown = Toast(title: L10n.t("prodEntered"), subtitle: items.map(\.text).joined(separator: " · "),
                          trailing: "", kind: .prod, pid: activeShell ?? 0)
        toast = shown
        NotchController.shared.showToast()
        if prefs.sound { NSSound(named: "Funk")?.play() }
        dismissLater(shown)
    }

    private func dismissLater(_ shown: Toast) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            // a newer toast may have replaced this one; it clears itself
            guard self.toast?.id == shown.id else { return }
            self.toast = nil
            NotchController.shared.layout(animated: true)
        }
    }

    // MARK: settings actions

    func installHook() throws {
        try ShellIntegration.install()
        hookInstalled = ShellIntegration.isInstalled
        NotchController.shared.layout(animated: true)
    }

    func refreshHookStatus() {
        hookInstalled = ShellIntegration.isInstalled
    }

    func removeHook() throws {
        try ShellIntegration.uninstall()
        hookInstalled = ShellIntegration.isInstalled
        NotchController.shared.layout(animated: true)
    }

    func clearRecent() {
        recent.removeAll()
        NotchController.shared.layout(animated: true)
    }

    // MARK: history

    private static var historyURL: URL { PrefsStore.directory.appendingPathComponent("history.json") }

    private static func loadHistory() -> [TrackedCommand] {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([TrackedCommand].self, from: data) else { return [] }
        return list.filter { $0.ended != nil }
    }

    /// Off while `--snapshot` fills the lists with sample commands.
    var historyWritesSuspended = false

    private func saveHistory() {
        guard !historyWritesSuspended else { return }
        let url = Self.historyURL
        guard prefs.keepHistory else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(recent) else { return }
        try? data.write(to: url, options: .atomic)
        // commands can carry tokens and hostnames: this user only
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Called when the setting flips, to write or delete the file right away.
    func historySettingChanged() { saveHistory() }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: announcing

    private func announce(_ cmd: TrackedCommand, detail: String = "") {
        let ok = cmd.succeeded
        let title = ok ? L10n.t("done") : L10n.t("failed", ["c": String(cmd.exitCode ?? -1)])
        let subtitle = detail.isEmpty ? cmd.short(48) : cmd.short(28) + " · " + detail
        let shown = Toast(title: title, subtitle: subtitle, trailing: Fmt.duration(cmd.elapsed()),
                          kind: ok ? .success : .failure, pid: cmd.pid, tty: cmd.tty)
        toast = shown
        NotchController.shared.showToast()

        if prefs.sound { NSSound(named: ok ? "Glass" : "Basso")?.play() }

        if prefs.systemNotifications {
            let content = UNMutableNotificationContent()
            content.title = title + " · " + shown.trailing
            content.body = cmd.command
            let request = UNNotificationRequest(identifier: cmd.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }

        dismissLater(shown)
    }

    /// Tapping a toast or a row takes you to the terminal it came from.
    func focusTerminal(pid: Int32, tty: String = "") {
        TerminalFocus.activate(shellPID: pid, tty: tty)
        if toast?.pid == pid {
            toast = nil
            NotchController.shared.layout(animated: true)
        }
    }

    #if DEBUG
    /// For `--snapshot`: a believable spread of commands without a real shell.
    func loadSample() {
        let now = Date()
        func cmd(_ n: Int, _ c: String, _ cwd: String, ago: TimeInterval, took: TimeInterval? = nil,
                 exit: Int32? = nil) -> TrackedCommand {
            var t = TrackedCommand(id: "1-\(n)", pid: 1, command: c, cwd: NSHomeDirectory() + cwd,
                                   tty: "/dev/ttys001", started: now.addingTimeInterval(-ago))
            if let took { t.ended = t.started.addingTimeInterval(took); t.exitCode = exit }
            return t
        }
        running = [cmd(9, "cargo build --release", "/Projects/engine", ago: 102),
                   cmd(8, "npm run test -- --watch=false", "/Projects/web", ago: 27)]
        visibleRunning = running
        recent = [cmd(7, "docker compose up -d --build", "/Projects/web", ago: 400, took: 188, exit: 0),
                  cmd(6, "terraform plan -out=tfplan", "/infra/prod", ago: 1300, took: 41, exit: 1),
                  cmd(5, "swift build -c release", "/Projects/notchline", ago: 3900, took: 74, exit: 0)]
        shells = [1, 2]
        hookInstalled = true
    }

    func showSampleToast(success: Bool) {
        toast = Toast(title: success ? L10n.t("done") : L10n.t("failed", ["c": "1"]),
                      subtitle: "terraform apply -auto-approve", trailing: "3:12",
                      kind: success ? .success : .failure, pid: 1)
    }

    func loadSampleProd() {
        env = [EnvItem(kind: .kube, value: "eks-prod-eu", isProd: true),
               EnvItem(kind: .aws, value: "acme-prod-admin", isProd: true),
               EnvItem(kind: .terraform, value: "default")]
        prodAlert = env.filter(\.isProd)
        prodShells = 2
    }

    func showSampleProdToast() {
        toast = Toast(title: L10n.t("prodEntered"), subtitle: "kube eks-prod-eu · aws acme-prod-admin",
                      trailing: "", kind: .prod, pid: 1)
    }

    func loadSampleTasks(waiting: Bool) {
        let now = Date()
        tasks = [ScriptTask(id: "pid-1", pid: 1, tty: "", title: "Деплой api", detail: "3 из 7 серверов",
                            progress: 0.42, started: now.addingTimeInterval(-95), updated: now)]
        if waiting {
            tasks.insert(ScriptTask(id: "agent-claude-1", pid: 1, tty: "", title: "Claude Code · web",
                                    detail: "Claude needs your permission to use Bash", waiting: true,
                                    started: now.addingTimeInterval(-40), updated: now), at: 0)
        }
    }

    func clearSampleTasks() { tasks = [] }

    func clearSampleCommands() {
        running = []
        visibleRunning = []
        recent = []
    }

    func clearSampleProd() {
        env = []
        prodAlert = []
        prodShells = 0
    }
    #endif
}

#if DEBUG
// MARK: - end-to-end hooks

extension AppState {
    /// The island's mode, worked out the same way RootView does.
    var islandMode: String {
        if toast != nil { return "toast" }
        if expanded { return "panel" }
        if stripHasContent { return "strip" }
        return prefs.edge.isVertical ? "sliver" : "idle"
    }

    /// Answers the end-to-end tests: `dump` returns the state as JSON, the
    /// others act and then answer with the state too.
    func debugReply(_ args: [String]) -> String {
        let controller = NotchController.shared
        func point() -> CGPoint? {
            guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else { return nil }
            return CGPoint(x: x, y: y)
        }
        switch args.first ?? "" {
        case "hover":
            controller.pointerOverride = point()
            controller.evaluateHover()
        case "click":
            controller.pointerOverride = point()
            controller.clickedOutside()
        case "pin":
            controller.togglePin()
        case "settings":
            SettingsWindow.show()
        case "closeSettings":
            SettingsWindow.close()
        case "guard":
            evaluateGuard()
        case "installAgent", "removeAgent":
            guard args.count >= 2, let agent = Agent(rawValue: args[1]) else { return #"{"error":"no such agent"}"# }
            do {
                if args[0] == "installAgent" { try AgentIntegration.install(agent) }
                else { try AgentIntegration.remove(agent) }
            } catch {
                return #"{"error":"\#(error.localizedDescription)"}"#
            }
        case "installHook", "removeHook", "installClaude", "removeClaude":
            do {
                switch args[0] {
                case "installHook": try installHook()
                case "removeHook": try removeHook()
                case "installClaude": try AgentIntegration.installClaude()
                default: try AgentIntegration.removeClaude()
                }
            } catch {
                return #"{"error":"\#(error.localizedDescription)"}"#
            }
        default:
            break
        }
        return debugDump()
    }

    func debugDump() -> String {
        func cmd(_ c: TrackedCommand) -> [String: Any] {
            ["id": c.id, "pid": c.pid, "command": c.command, "cwd": c.cwd, "tty": c.tty,
             "exit": c.exitCode.map { Int($0) } ?? NSNull()]
        }
        let islands = NotchController.shared.islandFrames.map {
            ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height]
        }
        let object: [String: Any] = [
            "mode": islandMode,
            "expanded": expanded,
            "pinned": pinned,
            "connected": isConnected,
            "hookInstalled": hookInstalled,
            "shells": shells.count,
            "settingsVisible": SettingsWindow.isVisible,
            "toast": toast.map { ["title": $0.title, "subtitle": $0.subtitle, "kind": "\($0.kind)"] } ?? NSNull(),
            "running": running.map(cmd),
            "visibleRunning": visibleRunning.map(cmd),
            "recent": recent.map(cmd),
            "tasks": orderedTasks.map { ["id": $0.id, "title": $0.title, "detail": $0.detail,
                                         "progress": $0.progress ?? NSNull(), "waiting": $0.waiting,
                                         "pid": $0.pid] },
            "prodAlert": prodAlert.map(\.text),
            "env": env.map { ["kind": $0.kind.rawValue, "value": $0.value, "prod": $0.isProd] },
            "islands": islands,
            "claudeInstalled": AgentIntegration.claudeInstalled,
            "agents": Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0.rawValue, AgentIntegration.isInstalled($0)) }),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif

enum SettingsTab: Hashable {
    case general, terminal, prodGuard, agents, about
}
