import XCTest

/// End to end: the real app binary, real zsh sessions with the real hook, the
/// real `notch` command, all in a throwaway home. Needs a GUI session (the app
/// puts its window on screen) and a prior `swift build`: run `make e2e`.
final class NotchlineE2ETests: XCTestCase {
    var app: AppHarness!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = try AppHarness()
        try app.launch()
    }

    override func tearDown() {
        app?.cleanUp()
    }

    // MARK: the island

    func testIdleIslandIsANotchSizedHairlineAtTheTopCentre() throws {
        let s = try app.waitFor("idle") { $0.string("mode") == "idle" && !$0.bool("expanded") }
        let island = app.island(s)
        let screen = app.screen
        // 185 pt notch plus 6 pt fillets each side, 4 pt tall while hidden
        XCTAssertEqual(island.width, 197, accuracy: 0.5)
        XCTAssertEqual(island.height, 4, accuracy: 0.5)
        XCTAssertEqual(island.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(island.maxY, screen.maxY, accuracy: 0.5)
    }

    // MARK: commands from zsh

    func testLongCommandShowsWhileRunningAndLandsInRecent() throws {
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("sleep 2")
        let running = try app.waitFor("the command on the island") {
            $0.commands("visibleRunning") == ["sleep 2"] && $0.string("mode") == "strip"
        }
        XCTAssertEqual(app.island(running).maxY, app.screen.maxY, accuracy: 0.5)
        let done = try app.waitFor("the command in recent") { $0.commands("recent").first == "sleep 2" }
        XCTAssertEqual(done.list("recent").first?["exit"] as? Int, 0)
        XCTAssertNil(done.toast, "under the notify threshold: no toast")
        try app.waitFor("the island to hide again") { $0.string("mode") == "idle" }
    }

    func testShortCommandNeverShows() throws {
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("true")
        sh.type("sleep 0.2")
        try app.waitFor("the shell to connect") { $0.int("shells") == 1 }
        app.never("a short command on the island", for: 1.5) {
            !$0.commands("visibleRunning").isEmpty || !$0.commands("recent").isEmpty
        }
    }

    func testFailureAfterNotifyThresholdShowsRedToast() throws {
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("sleep 3.2 && false")
        let s = try app.waitFor("a failure toast", timeout: 7) { $0.toast?["kind"] as? String == "failure" }
        XCTAssertEqual(s.toast?["title"] as? String, "Failed · exit 1")
        XCTAssertEqual(s.list("recent").first?["exit"] as? Int, 1)
    }

    /// A subshell runs `zshexit` with its parent's $$; that must not end the command.
    func testSubshellExitDoesNotEndTheCommandEarly() throws {
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("(sleep 3.2; exit 3)")
        let s = try app.waitFor("exit 3 in recent", timeout: 7) { $0.list("recent").first?["exit"] as? Int == 3 }
        XCTAssertEqual(s.commands("recent").first, "(sleep 3.2; exit 3)")
        XCTAssertEqual(s.toast?["kind"] as? String, "failure")
        XCTAssertEqual(s.int("shells"), 1, "the shell itself is still there")
    }

    func testIgnoredProgramsAreNotTracked() throws {
        app.cleanUp()
        app = try AppHarness(prefs: ["ignored": ["nap"]])
        try app.launch()
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("nap() { sleep 2 }")
        sh.type("nap")
        try app.waitFor("the shell to connect") { $0.int("shells") == 1 }
        app.never("an ignored program on the island", for: 3) { !$0.commands("recent").isEmpty }
    }

    func testClosingTheShellForgetsIt() throws {
        let sh = try app.shell()
        sh.type("sleep 0.1")
        try app.waitFor("the shell to connect") { $0.int("shells") == 1 }
        sh.exit()
        try app.waitFor("the shell to be forgotten") { $0.int("shells") == 0 }
    }

    func testKilledShellMidCommandIsDropped() throws {
        let sh = try app.shell()
        sh.type("sleep 30")
        try app.waitFor("the command to show") { $0.commands("visibleRunning") == ["sleep 30"] }
        sh.kill()
        try app.waitFor("the orphan to be dropped", timeout: 5) { $0.commands("running").isEmpty }
    }

    // MARK: notch

    func testNotchTaskLifecycle() throws {
        try app.notch(["start", "Deploy", "--id", "d"])
        try app.waitFor("the task") { ($0.list("tasks").first?["title"] as? String) == "Deploy" }

        try app.notch(["progress", "40", "--id", "d"])
        try app.waitFor("40 %") { ($0.list("tasks").first?["progress"] as? Double) == 0.4 }

        try app.notch(["status", "3 of 7 hosts", "--id", "d"])
        try app.waitFor("the detail") { ($0.list("tasks").first?["detail"] as? String) == "3 of 7 hosts" }

        try app.notch(["wait", "Needs the 2FA code", "--id", "d"])
        let waiting = try app.waitFor("attention") { ($0.list("tasks").first?["waiting"] as? Bool) == true }
        XCTAssertEqual(waiting.toast?["kind"] as? String, "attention")

        try app.notch(["done", "All green", "--id", "d"])
        let done = try app.waitFor("done") { $0.list("tasks").isEmpty && $0.commands("recent").first == "Deploy" }
        XCTAssertEqual(done.toast?["kind"] as? String, "success")
        XCTAssertEqual(done.toast?["subtitle"] as? String, "Deploy · All green")
    }

    func testNotchRunPassesTheExitCodeThrough() throws {
        let code = try app.notch(["run", "sh", "-c", "sleep 0.3; exit 3"])
        XCTAssertEqual(code, 3)
        let s = try app.waitFor("the run in recent") { $0.list("recent").first?["exit"] as? Int == 3 }
        XCTAssertEqual(s.toast?["kind"] as? String, "failure")
    }

    func testNotchWithTheAppClosedStillSucceeds() throws {
        app.terminate()
        XCTAssertEqual(try app.notch(["start", "Nobody listens"]), 0)
        XCTAssertEqual(try app.notch(["run", "true"]), 0)
        XCTAssertEqual(try app.notch(["progress", "nope"]), 64, "bad arguments are still errors")
    }

    func testTaskDiesWithItsScript() throws {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "\"\(app.cli)\" start 'Long job'; sleep 30"]
        script.environment = ["NOTCH_SOCKET": app.socket, "PATH": "/usr/bin:/bin"]
        try script.run()
        try app.waitFor("the task") { ($0.list("tasks").first?["title"] as? String) == "Long job" }
        script.terminate()
        script.waitUntilExit()
        try app.waitFor("the task to go", timeout: 5) { $0.list("tasks").isEmpty }
    }

    // MARK: agents

    func testClaudeCodeHooksThroughTheInstalledCommand() throws {
        // an existing setup the install must keep
        let claudeDir = app.home + "/.claude"
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let mine: [String: Any] = ["model": "opus",
                                   "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        try JSONSerialization.data(withJSONObject: mine).write(to: URL(fileURLWithPath: claudeDir + "/settings.json"))

        XCTAssertTrue(app.debug("installClaude").bool("claudeInstalled"))
        let settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: claudeDir + "/settings.json"))) as? [String: Any] ?? [:]
        let hooks = settings["hooks"] as? [String: [[String: Any]]] ?? [:]
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(hooks["Stop"]?.count, 2, "the existing Stop hook stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeDir + "/settings.json.notchline-backup"))

        // run the installed command exactly as Claude Code would: through a shell, event on stdin
        let command = ((hooks["UserPromptSubmit"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        func fire(_ event: [String: Any]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.environment = ["NOTCH_SOCKET": app.socket, "PATH": "/usr/bin:/bin"]
            let pipe = Pipe()
            p.standardInput = pipe
            try p.run()
            pipe.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event))
            try pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let base: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/web"]
        try fire(base.merging(["hook_event_name": "UserPromptSubmit", "prompt": "fix the flaky test"]) { _, n in n })
        try app.waitFor("the session") { ($0.list("tasks").first?["title"] as? String) == "Claude Code · web" }

        try fire(base.merging(["hook_event_name": "PreToolUse", "tool_name": "Bash",
                               "tool_input": ["command": "npm test"]]) { _, n in n })
        try app.waitFor("the tool call") { ($0.list("tasks").first?["detail"] as? String) == "Bash: npm test" }

        try fire(base.merging(["hook_event_name": "Notification",
                               "message": "Claude needs your permission to use Bash"]) { _, n in n })
        try app.waitFor("waiting") { ($0.list("tasks").first?["waiting"] as? Bool) == true }

        try fire(base.merging(["hook_event_name": "Stop"]) { _, n in n })
        let done = try app.waitFor("the turn to end") { $0.list("tasks").isEmpty }
        XCTAssertTrue(done.commands("recent").isEmpty, "agent turns stay out of the history")

        // removing takes out ours only
        XCTAssertFalse(app.debug("removeClaude").bool("claudeInstalled"))
        let after = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: claudeDir + "/settings.json"))) as? [String: Any] ?? [:]
        let left = after["hooks"] as? [String: [[String: Any]]] ?? [:]
        XCTAssertEqual(Array(left.keys), ["Stop"])
        XCTAssertEqual(left["Stop"]?.count, 1)
    }

    // MARK: more agents

    private func readJSON(_ path: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] ?? [:]
    }

    /// Runs an installed hook command the way an agent does: through a shell,
    /// with the event on stdin. Returns what it printed.
    @discardableResult
    private func fire(_ command: String, _ event: [String: Any]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.environment = ["NOTCH_SOCKET": app.socket, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: event))
        try input.fileHandleForWriting.close()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testGeminiCLIHooks() throws {
        let path = app.home + "/.gemini/settings.json"
        try FileManager.default.createDirectory(atPath: app.home + "/.gemini", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["theme": "Dracula"]).write(to: URL(fileURLWithPath: path))

        XCTAssertEqual((app.debug("installAgent", "gemini")["agents"] as? [String: Bool])?["gemini"], true)
        let settings = try readJSON(path)
        XCTAssertEqual(settings["theme"] as? String, "Dracula")
        let hooks = settings["hooks"] as? [String: [[String: Any]]] ?? [:]
        XCTAssertEqual(Set(hooks.keys), ["BeforeAgent", "BeforeTool", "Notification", "AfterAgent", "SessionEnd"])
        let inner = (hooks["BeforeTool"]?.first?["hooks"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(inner["timeout"] as? Int, 5000, "Gemini counts milliseconds")
        let command = inner["command"] as? String ?? ""

        let base: [String: Any] = ["session_id": "g1", "cwd": "/Users/me/infra"]
        XCTAssertEqual(try fire(command, base.merging(["hook_event_name": "BeforeAgent", "prompt": "plan it"]) { _, n in n }), "{}",
                       "Gemini parses stdout as JSON")
        try app.waitFor("the session") { ($0.list("tasks").first?["title"] as? String) == "Gemini CLI · infra" }
        try fire(command, base.merging(["hook_event_name": "BeforeTool", "tool_name": "run_shell_command",
                                        "tool_input": ["command": "terraform plan"]]) { _, n in n })
        try app.waitFor("the tool") { ($0.list("tasks").first?["detail"] as? String) == "run_shell_command: terraform plan" }
        try fire(command, base.merging(["hook_event_name": "Notification", "notification_type": "ToolPermission",
                                        "message": "Allow terraform apply?"]) { _, n in n })
        try app.waitFor("waiting") { ($0.list("tasks").first?["waiting"] as? Bool) == true }
        try fire(command, base.merging(["hook_event_name": "AfterAgent"]) { _, n in n })
        try app.waitFor("done") { $0.list("tasks").isEmpty && $0.toast?["kind"] as? String == "success" }

        app.debug("removeAgent", "gemini")
        let after = try readJSON(path)
        XCTAssertNil(after["hooks"])
        XCTAssertEqual(after["theme"] as? String, "Dracula")
    }

    func testCopilotInVSCodeGetsItsOwnHooksFile() throws {
        let path = app.home + "/.copilot/hooks/notchline.json"
        XCTAssertEqual((app.debug("installAgent", "copilot")["agents"] as? [String: Bool])?["copilot"], true)
        let hooks = try readJSON(path)["hooks"] as? [String: [[String: Any]]] ?? [:]
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "PreToolUse", "Stop"])
        let command = hooks["Stop"]?.first?["command"] as? String ?? ""

        // VS Code may spell the fields in camelCase
        let base: [String: Any] = ["sessionId": "v1", "cwd": "/Users/me/site"]
        try fire(command, base.merging(["hookEventName": "UserPromptSubmit", "prompt": "add dark mode"]) { _, n in n })
        try app.waitFor("the session") { ($0.list("tasks").first?["title"] as? String) == "Copilot · site" }
        try fire(command, base.merging(["hookEventName": "PreToolUse", "toolName": "editFiles",
                                        "toolInput": ["filePath": "src/theme.css"]]) { _, n in n })
        try app.waitFor("the tool") { ($0.list("tasks").first?["detail"] as? String) == "editFiles: src/theme.css" }
        XCTAssertEqual(try fire(command, base.merging(["hookEventName": "Stop"]) { _, n in n }), "{}")
        try app.waitFor("done") { $0.list("tasks").isEmpty }

        app.debug("removeAgent", "copilot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// Cursor's blocking hooks deny on an empty answer; only non-blocking ones may be ours.
    func testCursorUsesNonBlockingHooksOnly() throws {
        let path = app.home + "/.cursor/hooks.json"
        try FileManager.default.createDirectory(atPath: app.home + "/.cursor", withIntermediateDirectories: true)
        let mine: [String: Any] = ["version": 1, "hooks": ["beforeShellExecution": [["command": "./audit.sh"]]]]
        try JSONSerialization.data(withJSONObject: mine).write(to: URL(fileURLWithPath: path))

        app.debug("installAgent", "cursor")
        let config = try readJSON(path)
        XCTAssertEqual(config["version"] as? Int, 1)
        let hooks = config["hooks"] as? [String: [[String: Any]]] ?? [:]
        XCTAssertEqual(Set(hooks.keys), ["beforeShellExecution", "postToolUse", "stop", "sessionEnd"])
        XCTAssertEqual(hooks["beforeShellExecution"]?.count, 1, "the user's own blocking hook, untouched and alone")
        let command = hooks["stop"]?.first?["command"] as? String ?? ""

        let base: [String: Any] = ["conversation_id": "c1", "workspace_roots": ["/Users/me/mobile"]]
        try fire(command, base.merging(["hook_event_name": "postToolUse", "tool_name": "Shell",
                                        "tool_input": ["command": "pod install"]]) { _, n in n })
        try app.waitFor("the session") {
            ($0.list("tasks").first?["title"] as? String) == "Cursor · mobile"
                && ($0.list("tasks").first?["detail"] as? String) == "Shell: pod install"
        }
        XCTAssertEqual(try fire(command, base.merging(["hook_event_name": "stop", "status": "completed"]) { _, n in n }), "{}")
        try app.waitFor("done") { $0.list("tasks").isEmpty }

        app.debug("removeAgent", "cursor")
        let after = try readJSON(path)["hooks"] as? [String: Any] ?? [:]
        XCTAssertEqual(Array(after.keys), ["beforeShellExecution"])
    }

    func testClaudeHookStaysSilent() throws {
        app.debug("installAgent", "claude")
        let hooks = try readJSON(app.home + "/.claude/settings.json")["hooks"] as? [String: [[String: Any]]] ?? [:]
        let command = ((hooks["UserPromptSubmit"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        let printed = try fire(command, ["hook_event_name": "UserPromptSubmit", "session_id": "q", "cwd": "/x", "prompt": "hi"])
        XCTAssertEqual(printed, "", "Claude adds UserPromptSubmit output to the conversation")
    }

    func testAiderNotificationsCommand() throws {
        try app.notch(["agent", "aider"])
        let s = try app.waitFor("the toast") { $0.toast?["kind"] as? String == "success" }
        XCTAssertTrue((s.toast?["subtitle"] as? String ?? "").hasPrefix("Aider · "))
        XCTAssertTrue(s.commands("recent").isEmpty, "agent turns stay out of the history")
    }

    func testCodexTurnComplete() throws {
        let event = #"{"type":"agent-turn-complete","last-assistant-message":"Tests pass","cwd":"/Users/me/api"}"#
        try app.notch(["agent", "codex", event])
        let s = try app.waitFor("the toast") { $0.toast?["kind"] as? String == "success" }
        XCTAssertEqual(s.toast?["subtitle"] as? String, "Codex · api · Tests pass")
    }

    // MARK: prod guard

    func testProdGuardFollowsKubeconfigAndAwsProfile() throws {
        let prod = app.home + "/prod.yaml", dev = app.home + "/dev.yaml"
        try "current-context: eks-prod-eu\n".write(toFile: prod, atomically: true, encoding: .utf8)
        try "current-context: kind-local\n".write(toFile: dev, atomically: true, encoding: .utf8)
        let sh = try app.shell()
        defer { sh.kill() }

        sh.type("export KUBECONFIG=\(dev)")
        try app.waitFor("dev") { ($0.list("env").first { $0["kind"] as? String == "kube" }?["value"] as? String) == "kind-local" }
        XCTAssertTrue(app.state.strings("prodAlert").isEmpty)

        sh.type("export KUBECONFIG=\(prod)")
        let inProd = try app.waitFor("prod") { $0.strings("prodAlert") == ["kube eks-prod-eu"] }
        XCTAssertEqual(inProd.string("mode"), "toast", "entering prod is announced")
        try app.waitFor("the red strip", timeout: 7) { $0.string("mode") == "strip" }

        sh.type("export AWS_PROFILE=acme-prod-admin")
        try app.waitFor("both") { Set($0.strings("prodAlert")) == ["kube eks-prod-eu", "aws acme-prod-admin"] }

        sh.type("unset AWS_PROFILE; export KUBECONFIG=\(dev)")
        try app.waitFor("out of prod") { $0.strings("prodAlert").isEmpty }
        try app.waitFor("the island to hide") { $0.string("mode") == "idle" }
    }

    func testProdGuardMatchesWholeWordsOnly() throws {
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("export AWS_PROFILE=product-api")
        try app.waitFor("the profile") { ($0.list("env").first { $0["kind"] as? String == "aws" }?["value"] as? String) == "product-api" }
        XCTAssertTrue(app.state.strings("prodAlert").isEmpty)
    }

    func testSSHToAProdHostWhileItRuns() throws {
        // `ssh` is ignored as a command but still read for its host; a fake one keeps it offline
        let bin = app.home + "/fakebin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 3\n".write(toFile: bin + "/ssh", atomically: true, encoding: .utf8)
        chmod(bin + "/ssh", 0o755)
        let sh = try app.shell(env: ["PATH": bin + ":/usr/bin:/bin"])
        defer { sh.kill() }
        sh.type("ssh -p 2222 deploy@db-prod-1")
        try app.waitFor("the ssh host") { $0.strings("prodAlert") == ["ssh db-prod-1"] }
        try app.waitFor("the session to end", timeout: 6) { $0.strings("prodAlert").isEmpty }
    }

    // MARK: hover, pin and clicks

    private func centre(_ s: [String: Any]) -> CGPoint {
        let r = app.island(s)
        return CGPoint(x: r.midX, y: r.maxY - 1)
    }

    private func hover(_ p: CGPoint) -> [String: Any] { app.debug("hover", "\(p.x)", "\(p.y)") }
    private func click(_ p: CGPoint) -> [String: Any] { app.debug("click", "\(p.x)", "\(p.y)") }
    private var away: CGPoint { CGPoint(x: app.screen.minX + 40, y: app.screen.midY) }

    func testHoverOpensAndLeavingCloses() throws {
        let idle = try app.waitFor("idle") { $0.string("mode") == "idle" }
        XCTAssertTrue(hover(centre(idle)).bool("expanded"))
        let open = try app.waitFor("the panel") { $0.string("mode") == "panel" }
        XCTAssertEqual(app.island(open).width, 560 + 12, accuracy: 0.5, "the panel grows out of the notch")
        XCTAssertEqual(app.island(open).midX, app.screen.midX, accuracy: 1)

        _ = hover(away)
        XCTAssertTrue(app.state.bool("expanded"), "a grace period before closing")
        try app.waitFor("closing") { !$0.bool("expanded") }
    }

    func testPinnedPanelSurvivesLeavingAndOutsideClicks() throws {
        let idle = try app.waitFor("idle") { $0.string("mode") == "idle" }
        _ = hover(centre(idle))
        XCTAssertTrue(app.debug("pin").bool("pinned"))

        _ = hover(away)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(click(away).bool("expanded"), "pinned: an outside click leaves it open")
        XCTAssertTrue(app.state.bool("pinned"))

        XCTAssertFalse(app.debug("pin").bool("pinned"))
        _ = hover(away)
        try app.waitFor("closing once unpinned") { !$0.bool("expanded") }
    }

    func testOutsideClickClosesAnUnpinnedPanel() throws {
        let idle = try app.waitFor("idle") { $0.string("mode") == "idle" }
        _ = hover(centre(idle))
        XCTAssertFalse(click(away).bool("expanded"))
    }

    func testSettingsPushesAnUnpinnedPanelAside() throws {
        let idle = try app.waitFor("idle") { $0.string("mode") == "idle" }
        _ = hover(centre(idle))
        let s = app.debug("settings")
        XCTAssertFalse(s.bool("expanded"))
        XCTAssertTrue(s.bool("settingsVisible"))
        app.debug("closeSettings")

        _ = hover(centre(idle))
        app.debug("pin")
        XCTAssertTrue(app.debug("settings").bool("expanded"), "a pinned panel stays")
        app.debug("closeSettings")
    }

    // MARK: history and installation

    func testHistorySurvivesARestartAndIsPrivate() throws {
        try app.notch(["run", "sh", "-c", "sleep 0.2"])
        try app.waitFor("recent") { !$0.commands("recent").isEmpty }
        let file = app.support + "/history.json"
        let mode = (try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)

        app.terminate()
        try app.launch()
        XCTAssertEqual(app.state.commands("recent"), ["sh -c sleep 0.2"])
    }

    func testInstallingTheHookAppendsAndRemovesCleanly() throws {
        let rc = app.home + "/.zshrc"
        let original = "export EDITOR=vim\nalias ll='ls -l'\n"
        try original.write(toFile: rc, atomically: true, encoding: .utf8)

        XCTAssertTrue(app.debug("installHook").bool("hookInstalled"))
        let installed = try String(contentsOfFile: rc, encoding: .utf8)
        XCTAssertTrue(installed.hasPrefix(original))
        XCTAssertTrue(installed.contains("Notchline/shell/notchline.zsh"))

        XCTAssertTrue(app.debug("installHook").bool("hookInstalled"))
        let twice = try String(contentsOfFile: rc, encoding: .utf8)
        XCTAssertEqual(installed, twice, "installing again adds nothing")

        XCTAssertFalse(app.debug("removeHook").bool("hookInstalled"))
        let removed = try String(contentsOfFile: rc, encoding: .utf8)
        XCTAssertEqual(removed.trimmingCharacters(in: .whitespacesAndNewlines),
                       original.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testUnconnectedIslandAsksToBeConnected() throws {
        app.cleanUp()
        app = try AppHarness(hooked: false)
        try app.launch()
        let s = try app.waitFor("the prompt to connect") { $0.string("mode") == "strip" }
        XCTAssertFalse(s.bool("connected"))
        XCTAssertTrue(app.debug("installHook").bool("connected"))
        try app.waitFor("the island to hide once connected") { $0.string("mode") == "idle" }
    }

    /// The app used to be NotchTape: its folder, its line in .zshrc and the
    /// agents' hooks all move over on the first launch under the new name.
    func testMigratesFromTheOldName() throws {
        app.cleanUp()
        app = try AppHarness(hooked: false)
        let old = "Notch" + "Tape"
        let oldDir = app.home + "/Library/Application Support/\(old)"
        try FileManager.default.removeItem(atPath: app.support)
        try FileManager.default.createDirectory(atPath: oldDir + "/bin", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["lang": "ru", "showAfter": 1, "notifyAfter": 3, "sound": false])
            .write(to: URL(fileURLWithPath: oldDir + "/prefs.json"))
        let oldLine = "[[ -r \"$HOME/Library/Application Support/\(old)/shell/\(old.lowercased()).zsh\" ]] && "
            + "source \"$HOME/Library/Application Support/\(old)/shell/\(old.lowercased()).zsh\""
        try "export EDITOR=vim\n\n# \(old): long-running commands in the notch\n\(oldLine)\n"
            .write(toFile: app.home + "/.zshrc", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: app.home + "/.claude", withIntermediateDirectories: true)
        let oldHook = ["type": "command", "command": "\"\(oldDir)/bin/notch\" agent claude", "timeout": 5] as [String: Any]
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [oldHook]]]]])
            .write(to: URL(fileURLWithPath: app.home + "/.claude/settings.json"))

        try app.launch()
        let s = try app.waitFor("the migrated state") { $0.bool("hookInstalled") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir + "/prefs.json"), "the old folder moved")
        let prefs = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: app.support + "/prefs.json"))) as? [String: Any]
        XCTAssertEqual(prefs?["lang"] as? String, "ru", "settings came along")
        XCTAssertEqual(s.string("mode"), "idle", "connected, so nothing to ask")

        let rc = try String(contentsOfFile: app.home + "/.zshrc", encoding: .utf8)
        XCTAssertTrue(rc.hasPrefix("export EDITOR=vim"))
        XCTAssertFalse(rc.contains(old), "no trace of the old name: \(rc)")
        XCTAssertTrue(rc.contains("Notchline/shell/notchline.zsh"))

        let claude = try String(contentsOfFile: app.home + "/.claude/settings.json", encoding: .utf8)
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(claude.contains("\(old)/bin/notch"), "hooks repointed: \(claude)")
        XCTAssertTrue(claude.contains("Notchline/bin/notch"))
        XCTAssertEqual((s["agents"] as? [String: Bool])?["claude"], true)

        // and the repointed hook works
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("sleep 1.5")
        try app.waitFor("a command through the new hook") { $0.commands("recent").first == "sleep 1.5" }
    }

    func testTheHookPutsNotchOnPath() throws {
        let sh = try app.shell()
        defer { sh.kill() }
        sh.type("notch start 'From zsh' --id z")
        try app.waitFor("the task") { ($0.list("tasks").first?["title"] as? String) == "From zsh" }
    }
}
