import Foundation

/// Where a shell can be pointed at something that matters.
enum EnvKind: String, Codable, CaseIterable, Identifiable {
    case kube, aws, gcloud, terraform, docker, ssh, path
    var id: String { rawValue }

    /// Short label shown next to the value.
    var label: String {
        switch self {
        case .kube:      return "kube"
        case .aws:       return "aws"
        case .gcloud:    return "gcloud"
        case .terraform: return "tf"
        case .docker:    return "docker"
        case .ssh:       return "ssh"
        case .path:      return "dir"
        }
    }
}

struct EnvItem: Identifiable, Hashable {
    let kind: EnvKind
    let value: String
    var isProd = false
    var id: String { kind.rawValue + ":" + value }
    var text: String { kind.label + " " + value }
}

/// What a shell reported about its environment on the last prompt.
struct ShellContext: Equatable {
    var kubeconfig = ""
    var awsProfile = ""
    var gcloudConfig = ""
    var tfWorkspace = ""
    var dockerContext = ""
    var cwd = ""
}

// MARK: - Rules

enum ProdRules {
    /// A pattern with `*` is a glob over the whole name; anything else must equal
    /// one word of it. So `prod` catches `eks-prod-eu` and `arn:…:cluster/prod`,
    /// but not `product-api`.
    static func matches(_ name: String, patterns: [String]) -> Bool {
        let lower = name.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for raw in patterns {
            let p = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if p.contains("*") || p.contains("?") {
                if fnmatch(p, lower, 0) == 0 { return true }
            } else if words.contains(p) {
                return true
            }
        }
        return false
    }
}

// MARK: - Resolving

/// Turns a shell's variables into named environments, reading the files the
/// tools keep their state in. Files are cached by modification date, so the
/// periodic re-check costs a `stat` each.
@MainActor
enum EnvResolver {
    private static var cache: [String: (Date, String?)] = [:]

    static func items(for ctx: ShellContext, foreground: TrackedCommand?) -> [EnvItem] {
        var out: [EnvItem] = []
        if let kube = kubeContext(ctx.kubeconfig) { out.append(.init(kind: .kube, value: kube)) }
        if !ctx.awsProfile.isEmpty { out.append(.init(kind: .aws, value: ctx.awsProfile)) }
        if let g = gcloud(ctx.gcloudConfig) { out.append(.init(kind: .gcloud, value: g)) }
        if let tf = terraform(ctx.tfWorkspace, cwd: ctx.cwd) { out.append(.init(kind: .terraform, value: tf)) }
        if let d = docker(ctx.dockerContext) { out.append(.init(kind: .docker, value: d)) }
        if let cmd = foreground, let host = sshHost(cmd) { out.append(.init(kind: .ssh, value: host)) }
        if !ctx.cwd.isEmpty {
            let home = Paths.home
            let short = ctx.cwd.hasPrefix(home) ? "~" + ctx.cwd.dropFirst(home.count) : ctx.cwd
            out.append(.init(kind: .path, value: short))
        }
        return out
    }

    /// `current-context:` from the first kubeconfig that sets one — the same
    /// rule kubectl follows when `KUBECONFIG` lists several files.
    private static func kubeContext(_ kubeconfig: String) -> String? {
        let files = kubeconfig.isEmpty
            ? [Paths.home + "/.kube/config"]
            : kubeconfig.split(separator: ":").map { expand(String($0)) }
        for file in files {
            if let value = cached(file, parse: { text in
                text.split(separator: "\n").lazy
                    .first { $0.hasPrefix("current-context:") }
                    .map { unquote($0.dropFirst("current-context:".count)) }
            }), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// The configuration name, and the project it points at when there is one:
    /// the project id is usually where "prod" lives.
    private static func gcloud(_ env: String) -> String? {
        let base = Paths.home + "/.config/gcloud"
        let name = !env.isEmpty ? env
            : cached(base + "/active_config", parse: { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard let name, !name.isEmpty else { return nil }
        let project = cached(base + "/configurations/config_" + name, parse: { text in
            text.split(separator: "\n").lazy
                .first { $0.replacingOccurrences(of: " ", with: "").hasPrefix("project=") }
                .map { String($0.split(separator: "=", maxSplits: 1).last ?? "")
                    .trimmingCharacters(in: .whitespaces) }
        })
        if let project, !project.isEmpty { return name == "default" ? project : "\(name) (\(project))" }
        return name == "default" ? nil : name
    }

    /// `terraform workspace select` writes the name into `.terraform/environment`.
    private static func terraform(_ env: String, cwd: String) -> String? {
        if !env.isEmpty { return env }
        guard !cwd.isEmpty else { return nil }
        let value = cached(cwd + "/.terraform/environment", parse: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        guard let value, !value.isEmpty, value != "default" else { return nil }
        return value
    }

    private static func docker(_ env: String) -> String? {
        let value = !env.isEmpty ? env : cached(Paths.home + "/.docker/config.json", parse: { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["currentContext"] as? String
        })
        guard let value, !value.isEmpty, value != "default", value != "desktop-linux" else { return nil }
        return value
    }

    /// `ssh -i key -p 22 deploy@db-prod-1 uptime` → `db-prod-1`.
    static func sshHost(_ cmd: TrackedCommand) -> String? {
        let program = cmd.program
        guard program == "ssh" || program == "mosh" else { return nil }
        let withArgument: Set<Character> = ["b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
                                            "m", "O", "o", "p", "Q", "R", "S", "W", "w", "B"]
        var words = cmd.command.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, (first as NSString).lastPathComponent != program {
            words.removeFirst()   // sudo, env, FOO=bar
        }
        words = Array(words.dropFirst())
        var i = 0
        while i < words.count {
            let w = words[i]
            if w == "--" { i += 1; break }
            if w.hasPrefix("-") {
                // `-p 22` takes the next word; `-p22` carries its value
                if w.count == 2, let flag = w.last, withArgument.contains(flag) { i += 1 }
                i += 1
                continue
            }
            break
        }
        guard i < words.count else { return nil }
        let target = words[i]
        return String(target.split(separator: "@").last ?? Substring(target))
    }

    // MARK: file helpers

    private static func cached(_ path: String, parse: (String) -> String?) -> String? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        guard let mtime else { cache[path] = nil; return nil }
        if let hit = cache[path], hit.0 == mtime { return hit.1 }
        let value = (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(parse)
        cache[path] = (mtime, value)
        return value
    }

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? Paths.home + path.dropFirst() : path
    }

    private static func unquote(_ s: Substring) -> String {
        s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
