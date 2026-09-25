import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar of its own

        NotchController.shared.rebuild()
        AppState.shared.start()
        Migration.repointHooks()
        AppState.shared.refreshHookStatus()
        buildStatusItem()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchController.shared.rebuild() }
            }
    }

    /// A small menu-bar item is the only way back into the app once the strip is
    /// hidden, so it is not optional.
    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "terminal",
                                     accessibilityDescription: "Notchline")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Built on every open, so a language switch shows up without a relaunch.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: L10n.t("openSettings"), action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("quit"), action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// top-level code runs on the main thread; Swift 5 mode just does not know it
MainActor.assumeIsolated {
    Migration.moveSupportFolder()   // before anything creates the new folder
    #if DEBUG
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        Snapshots.run(into: dir)
        exit(0)
    }
    #endif
    let app = NSApplication.shared
    // before `run`, not in didFinishLaunching: by then an unbundled build has
    // already shown up in the Dock
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
