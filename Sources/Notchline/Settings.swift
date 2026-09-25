import Foundation

enum Edge: String, Codable, CaseIterable, Identifiable {
    case top, right, bottom, left
    var id: String { rawValue }
    var isVertical: Bool { self == .left || self == .right }
}

enum ShowMode: String, Codable, CaseIterable, Identifiable {
    /// The strip is always there; when idle it shows the last result.
    case always
    /// The strip appears while something runs; otherwise only a sliver is left.
    case auto
    /// Invisible until the cursor reaches the edge.
    case hidden
    var id: String { rawValue }
}

enum Surface: String, Codable, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
}

enum Lang: String, Codable, CaseIterable, Identifiable {
    case en, ru, zh
    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en_US")
        case .ru: return Locale(identifier: "ru_RU")
        case .zh: return Locale(identifier: "zh_CN")
        }
    }
    var title: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .zh: return "中文"
        }
    }
}

struct Prefs: Codable {
    var edge: Edge = .top
    var show: ShowMode = .auto
    var surface: Surface = .solid
    /// The whole island; 1 is a 14-inch MacBook Pro notch, 185 × 32 pt.
    var scale: Double = 1
    /// Its proportion: longer or shorter at the same height.
    var width: Double = 1
    /// Of the background only; text always stays fully opaque.
    var opacity: Double = 1
    var lang: Lang = .en
    var allDisplays: Bool = false

    /// Commands shorter than this never reach the strip, so `ls` does not flash it.
    var showAfter: Double = 3
    /// Commands at least this long announce that they finished.
    var notifyAfter: Double = 10
    var systemNotifications: Bool = false
    var sound: Bool = true
    /// First words of commands that run for as long as you use them.
    var ignored: [String] = ["vim", "nvim", "vi", "nano", "emacs", "less", "more", "man",
                             "top", "htop", "btop", "ssh", "mosh", "tmux", "screen",
                             "claude", "codex", "watch", "fg", "notch"]

    /// Prod guard: the strip turns red while a shell points at production.
    var guardEnabled: Bool = true
    var prodPatterns: [String] = ["prod", "production", "prd"]
    /// The folder path is off by default: `~/work/product` style names are common.
    var guardSources: [EnvKind] = [.kube, .aws, .gcloud, .terraform, .docker, .ssh]
    var guardAnnounce: Bool = true
    /// Recent commands survive a restart, in a file only this user can read.
    var keepHistory: Bool = true

    // what is announced with a toast (and a sound, and a system notification)
    var notifyDone: Bool = true
    var notifyFailed: Bool = true
    var notifyWaiting: Bool = true
    var notifyAgentDone: Bool = true
    var notifyTasks: Bool = true
    var notifyUpdates: Bool = true
    /// Once an hour, a look at the latest release on GitHub.
    var checkUpdates: Bool = true

    init() {}

    /// Every field is optional on disk, so adding a setting never resets the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs()
        edge = (try? c.decode(Edge.self, forKey: .edge)) ?? d.edge
        show = (try? c.decode(ShowMode.self, forKey: .show)) ?? d.show
        surface = (try? c.decode(Surface.self, forKey: .surface)) ?? d.surface
        scale = (try? c.decode(Double.self, forKey: .scale)) ?? d.scale
        width = (try? c.decode(Double.self, forKey: .width)) ?? d.width
        opacity = (try? c.decode(Double.self, forKey: .opacity)) ?? d.opacity
        lang = (try? c.decode(Lang.self, forKey: .lang)) ?? d.lang
        allDisplays = (try? c.decode(Bool.self, forKey: .allDisplays)) ?? d.allDisplays
        showAfter = (try? c.decode(Double.self, forKey: .showAfter)) ?? d.showAfter
        notifyAfter = (try? c.decode(Double.self, forKey: .notifyAfter)) ?? d.notifyAfter
        systemNotifications = (try? c.decode(Bool.self, forKey: .systemNotifications)) ?? d.systemNotifications
        sound = (try? c.decode(Bool.self, forKey: .sound)) ?? d.sound
        ignored = (try? c.decode([String].self, forKey: .ignored)) ?? d.ignored
        guardEnabled = (try? c.decode(Bool.self, forKey: .guardEnabled)) ?? d.guardEnabled
        prodPatterns = (try? c.decode([String].self, forKey: .prodPatterns)) ?? d.prodPatterns
        guardSources = (try? c.decode([EnvKind].self, forKey: .guardSources)) ?? d.guardSources
        guardAnnounce = (try? c.decode(Bool.self, forKey: .guardAnnounce)) ?? d.guardAnnounce
        keepHistory = (try? c.decode(Bool.self, forKey: .keepHistory)) ?? d.keepHistory
        notifyDone = (try? c.decode(Bool.self, forKey: .notifyDone)) ?? d.notifyDone
        notifyFailed = (try? c.decode(Bool.self, forKey: .notifyFailed)) ?? d.notifyFailed
        notifyWaiting = (try? c.decode(Bool.self, forKey: .notifyWaiting)) ?? d.notifyWaiting
        notifyAgentDone = (try? c.decode(Bool.self, forKey: .notifyAgentDone)) ?? d.notifyAgentDone
        notifyTasks = (try? c.decode(Bool.self, forKey: .notifyTasks)) ?? d.notifyTasks
        notifyUpdates = (try? c.decode(Bool.self, forKey: .notifyUpdates)) ?? d.notifyUpdates
        checkUpdates = (try? c.decode(Bool.self, forKey: .checkUpdates)) ?? d.checkUpdates
    }
}

/// Where "home" is. Debug builds honour `NOTCHLINE_TEST_HOME`, so end-to-end
/// tests run a full app against a throwaway home: its own support folder,
/// socket, `.zshrc`, `.claude` and kubeconfig, never the real ones.
enum Paths {
    nonisolated static let home: String = {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["NOTCHLINE_TEST_HOME"], !test.isEmpty { return test }
        #endif
        return NSHomeDirectory()
    }()

    nonisolated static var isTest: Bool { home != NSHomeDirectory() }
}

/// Everything lives in one JSON file in the app's support folder.
@MainActor
final class PrefsStore {
    static let shared = PrefsStore()

    nonisolated static let directory: URL = {
        let base = URL(fileURLWithPath: Paths.home)
            .appendingPathComponent("Library/Application Support/Notchline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private let url: URL
    private(set) var prefs: Prefs

    private init() {
        url = Self.directory.appendingPathComponent("prefs.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Prefs.self, from: data) {
            prefs = decoded
        } else {
            prefs = Prefs()
        }
    }

    func save(_ new: Prefs) {
        prefs = new
        guard let data = try? JSONEncoder().encode(new) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
