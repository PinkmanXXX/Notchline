import XCTest
@testable import NotchTape

final class ProdRulesTests: XCTestCase {
    let defaults = ["prod", "production", "prd"]

    func testWholeWordsMatch() {
        XCTAssertTrue(ProdRules.matches("eks-prod-eu", patterns: defaults))
        XCTAssertTrue(ProdRules.matches("arn:aws:eks:eu-west-1:1234:cluster/prod", patterns: defaults))
        XCTAssertTrue(ProdRules.matches("acme_PRODUCTION", patterns: defaults))
        XCTAssertTrue(ProdRules.matches("db.prd.internal", patterns: defaults))
    }

    func testPartsOfWordsDoNot() {
        XCTAssertFalse(ProdRules.matches("product-api", patterns: defaults))
        XCTAssertFalse(ProdRules.matches("staging", patterns: defaults))
        XCTAssertFalse(ProdRules.matches("reproduce", patterns: defaults))
    }

    func testGlobs() {
        XCTAssertTrue(ProdRules.matches("shop-live", patterns: ["*-live"]))
        XCTAssertFalse(ProdRules.matches("shop-live-test", patterns: ["*-live"]))
        XCTAssertTrue(ProdRules.matches("PAYMENTS-LIVE", patterns: ["*-live"]))
    }

    func testEmptyPatternsMatchNothing() {
        XCTAssertFalse(ProdRules.matches("prod", patterns: []))
        XCTAssertFalse(ProdRules.matches("prod", patterns: ["  "]))
    }
}

@MainActor
final class EnvResolverTests: XCTestCase {
    private func command(_ text: String) -> TrackedCommand {
        TrackedCommand(id: "1-1", pid: 1, command: text, cwd: "/", tty: "", started: Date())
    }

    func testSSHHost() {
        XCTAssertEqual(EnvResolver.sshHost(command("ssh db-prod-1")), "db-prod-1")
        XCTAssertEqual(EnvResolver.sshHost(command("ssh -i ~/.ssh/key -p 2222 deploy@api.prod.acme.io uptime")),
                       "api.prod.acme.io")
        XCTAssertEqual(EnvResolver.sshHost(command("sudo ssh -p2222 -A root@10.0.0.5")), "10.0.0.5")
        XCTAssertEqual(EnvResolver.sshHost(command("mosh prod-bastion")), "prod-bastion")
        XCTAssertNil(EnvResolver.sshHost(command("ssh -v")))
        XCTAssertNil(EnvResolver.sshHost(command("git push")))
    }

    func testKubeContextFromKubeconfigList() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("a.yaml")
        let real = dir.appendingPathComponent("b.yaml")
        try "apiVersion: v1\nclusters: []\n".write(to: empty, atomically: true, encoding: .utf8)
        try "apiVersion: v1\ncurrent-context: \"eks-prod-eu\"\nkind: Config\n".write(to: real, atomically: true, encoding: .utf8)

        var ctx = ShellContext()
        ctx.kubeconfig = empty.path + ":" + real.path
        let kube = EnvResolver.items(for: ctx, foreground: nil).first { $0.kind == .kube }
        XCTAssertEqual(kube?.value, "eks-prod-eu")
    }

    func testTerraformWorkspaceFromFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".terraform"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "production\n".write(to: dir.appendingPathComponent(".terraform/environment"),
                                  atomically: true, encoding: .utf8)
        var ctx = ShellContext()
        ctx.cwd = dir.path
        let tf = EnvResolver.items(for: ctx, foreground: nil).first { $0.kind == .terraform }
        XCTAssertEqual(tf?.value, "production")
    }

    func testEnvironmentVariablesWin() {
        var ctx = ShellContext()
        ctx.awsProfile = "acme-prod-admin"
        ctx.tfWorkspace = "staging"
        ctx.dockerContext = "remote-prod"
        let items = EnvResolver.items(for: ctx, foreground: nil)
        XCTAssertEqual(items.first { $0.kind == .aws }?.value, "acme-prod-admin")
        XCTAssertEqual(items.first { $0.kind == .terraform }?.value, "staging")
        XCTAssertEqual(items.first { $0.kind == .docker }?.value, "remote-prod")
    }
}

final class ShellBridgeTests: XCTestCase {
    private let sep = "\u{1F}"

    func testStartKeepsSeparatorsInsideTheCommand() {
        let msg = ["1", "start", "42", "7", "/tmp", "/dev/ttys001", "echo a", "b"].joined(separator: sep)
        XCTAssertEqual(ShellBridge.parse(msg),
                       .start(pid: 42, seq: 7, cwd: "/tmp", tty: "/dev/ttys001", command: "echo a" + sep + "b"))
    }

    func testEndAndExit() {
        XCTAssertEqual(ShellBridge.parse(["1", "end", "42", "7", "130"].joined(separator: sep)),
                       .end(pid: 42, seq: 7, exitCode: 130))
        XCTAssertEqual(ShellBridge.parse(["1", "exit", "42"].joined(separator: sep)), .exit(pid: 42))
    }

    func testContext() {
        let msg = ["1", "ctx", "42", "/k1:/k2", "prod-admin", "", "", "", "/Users/me/infra"].joined(separator: sep)
        guard case let .context(pid, ctx)? = ShellBridge.parse(msg) else { return XCTFail("not a context") }
        XCTAssertEqual(pid, 42)
        XCTAssertEqual(ctx.kubeconfig, "/k1:/k2")
        XCTAssertEqual(ctx.awsProfile, "prod-admin")
        XCTAssertEqual(ctx.cwd, "/Users/me/infra")
    }

    func testTask() {
        let msg = ["1", "task", "pid-77", "77", "/dev/ttys002", "progress", "0.4", "", "Deploy", "3 of 7"]
            .joined(separator: sep)
        XCTAssertEqual(ShellBridge.parse(msg),
                       .task(.init(id: "pid-77", pid: 77, tty: "/dev/ttys002", state: "progress",
                                   progress: 0.4, exitCode: nil, title: "Deploy", detail: "3 of 7")))
        let fail = ["1", "task", "run-5", "5", "", "fail", "", "2", "make", "exit 2"].joined(separator: sep)
        guard case let .task(t)? = ShellBridge.parse(fail) else { return XCTFail("not a task") }
        XCTAssertEqual(t.exitCode, 2)
        XCTAssertNil(t.progress)
        XCTAssertNil(ShellBridge.parse(["1", "task", "x", "1", "", "explode", "", "", "", ""].joined(separator: sep)))
    }

    func testGarbageIsIgnored() {
        XCTAssertNil(ShellBridge.parse(""))
        XCTAssertNil(ShellBridge.parse("hello"))
        XCTAssertNil(ShellBridge.parse(["2", "start", "1"].joined(separator: sep)))
        XCTAssertNil(ShellBridge.parse(["1", "end", "x", "1", "0"].joined(separator: sep)))
    }
}

final class TrackedCommandTests: XCTestCase {
    private func program(_ text: String) -> String {
        TrackedCommand(id: "1", pid: 1, command: text, cwd: "/", tty: "", started: Date()).program
    }

    func testProgramSkipsWrappers() {
        XCTAssertEqual(program("sudo -E env FOO=1 /usr/bin/vim x"), "vim")
        XCTAssertEqual(program("time cargo build"), "cargo")
        XCTAssertEqual(program("RUST_LOG=debug ./target/app"), "app")
    }
}
