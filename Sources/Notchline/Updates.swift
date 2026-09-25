import AppKit
import Foundation

/// Looks for a newer release on GitHub. The only request the app makes to the
/// internet, once an hour and on demand, and it can be turned off. Unsigned
/// GitHub API calls allow 60 an hour, so one is well within it.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = URL(string: "https://github.com/PinkmanXXX/Notchline")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/PinkmanXXX/Notchline/releases/latest")!

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL, download: URL?)
        case failed
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?
    private var timer: Timer?
    /// A version is announced once; it stays in About and the menu after that.
    private var announced: String?

    var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// A quiet check a minute after launch, then once an hour.
    func start() {
        guard !Paths.isTest else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            Task { await self?.check(manual: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        guard manual || AppState.shared.prefs.checkUpdates else { return }
        status = .checking
        var request = URLRequest(url: Self.latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notchline/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // 404: no release published yet, which is not a failure
            if (response as? HTTPURLResponse)?.statusCode == 404 { status = .upToDate; lastChecked = Date(); return }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                status = .failed
                return
            }
            let dmg = (json["assets"] as? [[String: Any]])?
                .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            lastChecked = Date()
            if Self.isNewer(version, than: current) {
                status = .available(version: version, page: page, download: dmg.flatMap(URL.init(string:)))
                if announced != version {
                    announced = version
                    AppState.shared.announceUpdate(version)
                }
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed
        }
    }

    /// Opens the DMG if the release has one, the release page otherwise.
    func download() {
        guard case let .available(_, page, dmg) = status else { return }
        NSWorkspace.shared.open(dmg ?? page)
    }

    /// 1.10 is newer than 1.9: numbers, not strings.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
