import AppKit
import SwiftUI

/// What a panel needs to know about the screen it hangs on.
struct ScreenGeometry: Equatable {
    /// Width of the camera housing, 0 on a screen without one.
    var notchWidth: CGFloat = 0
    /// Height of the camera housing, or of the menu bar on a screen without one.
    var topInset: CGFloat = 0

    var hasNotch: Bool { notchWidth > 0 }

    init() {}

    init(_ screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, screen.frame.width - left.width - right.width)
            topInset = screen.safeAreaInsets.top
        } else {
            // with an auto-hidden menu bar the difference is 0
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            topInset = menuBar > 0 ? menuBar : 24
        }
    }
}

/// Every size the island is drawn at, derived from one scale and the screen.
/// At scale 1 the idle island is a 14-inch MacBook Pro notch, 185 × 32 pt; on a
/// screen with a real notch it takes that notch's exact size instead.
struct Metrics {
    let edge: Edge
    let scale: CGFloat
    let geometry: ScreenGeometry

    /// Only the top edge meets a camera housing.
    var realNotch: Bool { edge == .top && geometry.hasNotch }

    var notchWidth: CGFloat { realNotch ? geometry.notchWidth : 185 * scale }
    var thickness: CGFloat { realNotch ? max(geometry.topInset, 32 * scale) : 32 * scale }
    /// Space the expanded content leaves free for the housing.
    var under: CGFloat { realNotch ? geometry.topInset : 0 }

    var font: CGFloat { 12 * scale }
    var fillet: CGFloat { 6 * scale }
    var stripCorner: CGFloat { 10 * scale }
    /// Text never comes closer to the island's side than its curve plus a margin.
    var sideInset: CGFloat { stripCorner + 6 * scale }

    static let toastCorner: CGFloat = 20
    static let panelCorner: CGFloat = 24
    static let toastWidth: CGFloat = 400
    static let panelSize = CGSize(width: 560, height: 440)
    static let sidePanelSize = CGSize(width: 420, height: 460)
}

/// A fixed, transparent, click-through window per screen, holding the island.
///
/// The window never moves or resizes. The island inside is plain SwiftUI, so
/// growing from notch to panel is one spring animation of its size, corners and
/// content, instead of a window frame animation that the content cannot follow.
/// Clicks pass through everywhere except over the island itself.
@MainActor
final class NotchController: NSObject {
    static let shared = NotchController()

    private struct Slot {
        let panel: NSPanel
        let screen: NSScreen
        let geometry: ScreenGeometry
        /// The island's frame in window coordinates (top-left origin), as SwiftUI
        /// last laid it out.
        var local: CGRect = .zero
        /// The same frame in screen coordinates, for hover and click-through.
        var island: CGRect = .zero

        @MainActor mutating func place() {
            let f = panel.frame
            island = CGRect(x: f.minX + local.minX, y: f.maxY - local.maxY,
                            width: local.width, height: local.height)
        }
    }

    private var slots: [Slot] = []
    private var monitors: [Any] = []
    private var pendingCollapse: DispatchWorkItem?

    // MARK: lifecycle

    func rebuild() {
        slots.forEach { $0.panel.orderOut(nil); $0.panel.close() }
        slots = screens().map { screen in
            let geometry = ScreenGeometry(screen)
            return Slot(panel: makePanel(on: screen, geometry: geometry), screen: screen, geometry: geometry)
        }
        layout()
        if monitors.isEmpty { startMonitoring() }
    }

    private func screens() -> [NSScreen] {
        let prefs = AppState.shared.prefs
        if prefs.allDisplays { return NSScreen.screens }
        // `NSScreen.main` follows the key window, which for an accessory app is
        // arbitrary; the first screen is the one that carries the menu bar.
        return [NSScreen.screens.first].compactMap { $0 }
    }

    private func makePanel(on screen: NSScreen, geometry: ScreenGeometry) -> NSPanel {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false             // the island draws its own
        panel.isFloatingPanel = true        // before `level`: setting it resets the level to .floating
        panel.level = .statusBar            // above the menu bar, which sits at .mainMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true

        let root = RootView(geometry: geometry) { [weak self, weak panel] rect in
            guard let self, let panel else { return }
            self.islandMoved(rect, in: panel)
        }
        panel.contentView = NSHostingView(rootView: root)
        panel.orderFrontRegardless()
        return panel
    }

    /// SwiftUI reports the island in window coordinates, top-left origin.
    private func islandMoved(_ rect: CGRect, in panel: NSPanel) {
        guard let i = slots.firstIndex(where: { $0.panel === panel }) else { return }
        slots[i].local = rect
        slots[i].place()
    }

    // MARK: window placement

    /// Places each window against its edge, big enough for the largest island.
    /// Cheap and idempotent: callers use it after any change that might matter.
    func layout(animated: Bool = true) {
        let edge = AppState.shared.prefs.edge
        for i in slots.indices {
            let slot = slots[i]
            let frame = windowFrame(edge: edge, screen: slot.screen, geometry: slot.geometry)
            guard slot.panel.frame != frame else { continue }
            slot.panel.setFrame(frame, display: true)
            // the island may sit at the same spot inside a window that moved, and
            // then SwiftUI has nothing new to report
            slots[i].place()
        }
    }

    private func windowFrame(edge: Edge, screen: NSScreen, geometry: ScreenGeometry) -> CGRect {
        let s = screen.frame
        let shadowRoom: CGFloat = 60
        if edge.isVertical {
            let w = min(s.width, Metrics.sidePanelSize.width + shadowRoom)
            let h = min(s.height, Metrics.sidePanelSize.height + 40 + shadowRoom * 2)
            return CGRect(x: edge == .left ? s.minX : s.maxX - w, y: s.midY - h / 2, width: w, height: h)
        }
        let under = edge == .top && geometry.hasNotch ? geometry.topInset : 0
        let w = min(s.width, 760)
        let h = min(s.height, Metrics.panelSize.height + under + shadowRoom)
        return CGRect(x: s.midX - w / 2, y: edge == .top ? s.maxY - h : s.minY, width: w, height: h)
    }

    func showToast() {}   // the island animates itself; kept as the call site for clarity

    // MARK: hover and clicks

    /// Hover is decided from where the cursor is relative to the island, and the
    /// window lets clicks through everywhere else.
    private func startMonitoring() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { _ in
            MainActor.assumeIsolated { NotchController.shared.evaluateHover() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { event in
            MainActor.assumeIsolated { NotchController.shared.evaluateHover() }
            return event
        }) { monitors.append(m) }

        // clicks in other apps, on the desktop or the menu bar
        if let m = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            MainActor.assumeIsolated { NotchController.shared.clickedOutside() }
        }) { monitors.append(m) }
        // clicks in our own windows other than the island, such as Settings
        if let m = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { event in
            MainActor.assumeIsolated {
                let controller = NotchController.shared
                if !controller.slots.contains(where: { $0.panel === event.window }) {
                    controller.clickedOutside()
                }
            }
            return event
        }) { monitors.append(m) }
    }

    private func cursorOverIsland(margin: CGFloat) -> Bool {
        let p = NSEvent.mouseLocation
        return slots.contains { $0.island.insetBy(dx: -margin, dy: -margin).contains(p) }
    }

    fileprivate func evaluateHover() {
        let p = NSEvent.mouseLocation
        for slot in slots {
            let over = slot.island.insetBy(dx: -1, dy: -1).contains(p)
            if slot.panel.ignoresMouseEvents == over { slot.panel.ignoresMouseEvents = !over }
        }

        let state = AppState.shared
        guard state.toast == nil else { return }

        if state.expanded {
            // a little slack around the open panel, and a short grace period, so
            // grazing the border does not slam it shut
            if cursorOverIsland(margin: 8) || state.pinned {
                pendingCollapse?.cancel()
                pendingCollapse = nil
            } else if pendingCollapse == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingCollapse = nil
                        if !self.cursorOverIsland(margin: 8) && !state.pinned { self.collapse() }
                    }
                }
                pendingCollapse = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        } else if cursorOverIsland(margin: 1) {
            state.expanded = true
        }
    }

    /// The pin button, and a click on the closed island. Releasing never closes
    /// the panel under the cursor: it closes once the cursor leaves, like plain hover.
    func togglePin() {
        let state = AppState.shared
        state.pinned.toggle()
        if !state.expanded { state.expanded = true }
    }

    /// A pinned panel stays open until it is unpinned; a click elsewhere only
    /// closes one that is open because of hover.
    fileprivate func clickedOutside() {
        let state = AppState.shared
        guard state.expanded, !state.pinned, !cursorOverIsland(margin: 0) else { return }
        collapse()
    }

    /// Steps aside for another window, such as Settings, unless it was pinned.
    func collapseUnlessPinned() {
        guard AppState.shared.expanded, !AppState.shared.pinned else { return }
        collapse()
    }

    private func collapse() {
        let state = AppState.shared
        pendingCollapse?.cancel()
        pendingCollapse = nil
        state.pinned = false
        state.expanded = false
    }
}
