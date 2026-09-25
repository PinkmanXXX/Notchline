import AppKit
import XCTest

/// Runs the built debug app against a throwaway home and talks to it the way
/// shells and scripts do, plus the debug questions only debug builds answer.
final class AppHarness {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let appBinary = root.appendingPathComponent(".build/debug/NotchTape")
    static let cliBinary = root.appendingPathComponent(".build/debug/notch")

    /// Short on purpose: a Unix socket path must fit in 104 bytes.
    let home: String
    var support: String { home + "/Library/Application Support/NotchTape" }
    var socket: String { support + "/notch.sock" }
    var cli: String { support + "/bin/notch" }

    private var app: Process?

    /// `hooked`: the home's .zshrc already sources the hook, as for anyone
    /// who has set the app up; without it the island asks to be connected.
    init(prefs: [String: Any] = [:], hooked: Bool = true) throws {
        var template = Array("/tmp/nte.XXXXXX".utf8CString)
        guard let dir = mkdtemp(&template) else { throw XCTSkip("no temp dir") }
        home = String(cString: dir)
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)

        if hooked {
            let line = "[[ -r \"$HOME/Library/Application Support/NotchTape/shell/notchtape.zsh\" ]] && "
                + "source \"$HOME/Library/Application Support/NotchTape/shell/notchtape.zsh\"\n"
            try line.write(toFile: home + "/.zshrc", atomically: true, encoding: .utf8)
        }

        // quick thresholds and no sounds, so tests are fast and quiet: a command
        // shows after 1 s and is announced after 3 s
        var p: [String: Any] = ["lang": "en", "edge": "top", "show": "auto", "sound": false,
                                "showAfter": 1, "notifyAfter": 3, "systemNotifications": false]
        p.merge(prefs) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: p)
        try data.write(to: URL(fileURLWithPath: support + "/prefs.json"))
    }

    func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.appBinary.path),
              FileManager.default.isExecutableFile(atPath: Self.cliBinary.path) else {
            throw XCTSkip("build first: swift build (or make e2e)")
        }
        let process = Process()
        process.executableURL = Self.appBinary
        process.environment = ["NOTCHTAPE_TEST_HOME": home, "HOME": home,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        app = process
        try waitFor("the app's socket", timeout: 10) { _ in true }
    }

    func terminate() {
        guard let app else { return }
        app.terminate()
        let deadline = Date().addingTimeInterval(5)
        while app.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if app.isRunning { kill(app.processIdentifier, SIGKILL) }
        self.app = nil
    }

    func cleanUp() {
        terminate()
        try? FileManager.default.removeItem(atPath: home)
    }

    // MARK: talking to the app

    /// One connection, one message, like the hook and `notch`; for `debug`
    /// the app answers on the same connection.
    @discardableResult
    func send(_ fields: [String], expectReply: Bool = false) -> String? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socket.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: path)
            dst[path.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { return nil }
        let message = Array(fields.joined(separator: "\u{1F}").utf8)
        _ = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        guard expectReply else { return "" }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Ask a debug question; every answer is the app's state after it.
    @discardableResult
    func debug(_ args: String...) -> [String: Any] {
        guard let text = send(["1", "debug"] + args, expectReply: true),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    var state: [String: Any] { debug("dump") }

    /// Polls the state until `condition` holds; fails with the last state seen.
    @discardableResult
    func waitFor(_ what: String, timeout: TimeInterval = 5,
                 file: StaticString = #filePath, line: UInt = #line,
                 _ condition: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            last = state
            if !last.isEmpty && condition(last) { return last }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("timed out waiting for \(what); last state: \(last)", file: file, line: line)
        throw XCTSkip("stopping after timeout")
    }

    /// Asserts that `condition` stays false for `duration`.
    func never(_ what: String, for duration: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
               _ condition: ([String: Any]) -> Bool) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let s = state
            if condition(s) { XCTFail("\(what) happened: \(s)", file: file, line: line); return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: the notch command

    @discardableResult
    func notch(_ args: [String], stdin: String? = nil, env: [String: String] = [:]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        p.environment = ["HOME": home, "NOTCH_SOCKET": socket, "PATH": "/usr/bin:/bin"].merging(env) { _, n in n }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if let stdin {
            let pipe = Pipe()
            p.standardInput = pipe
            try p.run()
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
            try pipe.fileHandleForWriting.close()
        } else {
            try p.run()
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: shells

    /// An interactive zsh with the hook loaded, fed one line at a time.
    func shell(env: [String: String] = [:]) throws -> Shell {
        let zdot = home + "/zdot"
        try FileManager.default.createDirectory(atPath: zdot, withIntermediateDirectories: true)
        let rc = "source \"$HOME/Library/Application Support/NotchTape/shell/notchtape.zsh\"\n"
        try rc.write(toFile: zdot + "/.zshrc", atomically: true, encoding: .utf8)
        return try Shell(env: ["HOME": home, "ZDOTDIR": zdot, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                               "TERM": "dumb", "LANG": "en_US.UTF-8"].merging(env) { _, n in n })
    }

    // MARK: geometry

    /// The first screen's frame, where the island lives by default.
    var screen: CGRect { NSScreen.screens.first?.frame ?? .zero }

    func island(_ s: [String: Any]) -> CGRect {
        guard let i = (s["islands"] as? [[String: Double]])?.first else { return .zero }
        return CGRect(x: i["x"] ?? 0, y: i["y"] ?? 0, width: i["w"] ?? 0, height: i["h"] ?? 0)
    }
}

final class Shell {
    let process = Process()
    private let input = Pipe()

    init(env: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i"]
        process.environment = env
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    func type(_ line: String) {
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func exit() {
        type("exit")
        if !wait(5) { kill() }
    }

    /// What closing a terminal tab does: SIGHUP. An interactive zsh ignores
    /// SIGTERM, so `terminate()` would wait forever.
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGHUP)
        if !wait(3) {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = wait(3)
        }
    }

    private func wait(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return !process.isRunning
    }
}

// MARK: - reading the state

extension Dictionary where Key == String, Value == Any {
    func list(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }
    func bool(_ key: String) -> Bool { self[key] as? Bool ?? false }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func int(_ key: String) -> Int { self[key] as? Int ?? 0 }
    var toast: [String: Any]? { self["toast"] as? [String: Any] }
    func commands(_ key: String) -> [String] { list(key).compactMap { $0["command"] as? String } }
}
