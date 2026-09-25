#if DEBUG
import AppKit
import SwiftUI

/// `Notchline --snapshot <dir>` renders the island in its states to PNGs with
/// sample commands, for checking layout without screen-recording rights.
/// Debug builds only.
@MainActor
enum Snapshots {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = AppState.shared
        let original = state.prefs
        state.historyWritesSuspended = true   // sample commands must not replace the real history
        defer { state.prefs = original }      // prefs persist on every change
        var prefs = Prefs()
        prefs.lang = .ru                   // the images go into the Russian README
        state.prefs = prefs

        var notch = ScreenGeometry()
        notch.notchWidth = 200
        notch.topInset = 34
        var plain = ScreenGeometry()
        plain.topInset = 30
        let strip = CGSize(width: 520, height: 60)

        state.loadSample()
        state.clearSampleCommands()
        render(RootView(geometry: plain), strip, "idle", dir)

        state.loadSample()
        render(RootView(geometry: plain), strip, "running", dir)
        render(RootView(geometry: notch), CGSize(width: 760, height: 60), "running-notch", dir)

        state.loadSampleProd()
        render(RootView(geometry: plain), strip, "prod-running", dir)
        state.clearSampleCommands()
        render(RootView(geometry: plain), strip, "prod", dir)
        state.loadSample()

        state.expanded = true
        render(RootView(geometry: plain), CGSize(width: 640, height: 500), "panel-prod", dir)
        state.clearSampleProd()
        render(RootView(geometry: plain), CGSize(width: 640, height: 500), "panel", dir)
        state.expanded = false

        state.showSampleToast(success: false)
        render(RootView(geometry: plain), CGSize(width: 460, height: 90), "toast-fail", dir)
        state.loadSampleProd()
        state.showSampleProdToast()
        render(RootView(geometry: plain), CGSize(width: 460, height: 90), "toast-prod", dir)
        state.toast = nil
        state.clearSampleProd()

        state.loadSampleTasks(waiting: false)
        render(RootView(geometry: plain), strip, "task", dir)
        state.loadSampleTasks(waiting: true)
        render(RootView(geometry: plain), strip, "agent-waiting", dir)
        state.clearSampleCommands()   // the renderer cannot draw a scroll view: keep it short
        state.expanded = true
        render(RootView(geometry: plain), CGSize(width: 640, height: 500), "panel-tasks", dir)
        state.expanded = false
        state.clearSampleTasks()
        state.loadSample()

        prefs.scale = 1.4
        prefs.opacity = 0.55
        state.prefs = prefs
        render(RootView(geometry: plain), CGSize(width: 640, height: 70), "running-large-translucent", dir)
        prefs.scale = 0.8
        prefs.opacity = 1
        state.prefs = prefs
        render(RootView(geometry: plain), strip, "running-small", dir)

        prefs.scale = 1
        prefs.width = 0.6
        state.prefs = prefs
        render(RootView(geometry: plain), strip, "running-narrow", dir)
        prefs.width = 1
        prefs.edge = .right
        state.prefs = prefs
        render(RootView(geometry: plain), CGSize(width: 90, height: 200), "vertical", dir)
    }

    /// On a mid-grey backdrop, so the island's own edges and any transparency show.
    private static func render(_ view: some View, _ size: CGSize, _ name: String, _ dir: URL) {
        let framed = view
            .frame(width: size.width, height: size.height)
            // NOTCHLINE_SNAPSHOT_CLEAR=1: no backdrop, for composing promo images
            .background(ProcessInfo.processInfo.environment["NOTCHLINE_SNAPSHOT_CLEAR"] != nil
                        ? Color.clear : Color(white: 0.42))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = Double(ProcessInfo.processInfo.environment["NOTCHLINE_SNAPSHOT_SCALE"] ?? "") ?? 2
        // the first pass measures the strip; the second draws the island at that size
        _ = renderer.nsImage
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { print("failed: \(name)"); return }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        print("wrote \(name).png")
    }
}
#endif
