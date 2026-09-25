import SwiftUI

// MARK: - helpers

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

private let ok = Color(hex: "8BF0BE")
private let fail = Color(hex: "FF9FB2")
private let amber = Color(hex: "F2C063")
private let prodRed = Color(hex: "C4262E")
private let mono = Font.Design.monospaced

/// One spring for everything the island does, so every change feels the same.
let islandSpring = Animation.spring(duration: 0.5, bounce: 0.16)

/// Two groups held symmetrically apart by a fixed gap, so the camera housing
/// always lands in the gap however wide either side is.
struct NotchSplit: Layout {
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let l = subviews[0].sizeThatFits(.unspecified), r = subviews[1].sizeThatFits(.unspecified)
        return .init(width: max(l.width, r.width) * 2 + gap, height: max(l.height, r.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        // `.unspecified` rather than the measured size: proposing the exact ideal
        // width back can come out a hair short after rounding and truncate the text
        subviews[0].place(at: .init(x: bounds.midX - gap / 2, y: bounds.midY),
                          anchor: .trailing, proposal: .unspecified)
        subviews[1].place(at: .init(x: bounds.midX + gap / 2, y: bounds.midY),
                          anchor: .leading, proposal: .unspecified)
    }
}

/// Left-to-right, wrapping onto new lines: for the environment chips.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return .init(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                     height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: .init(x: x, y: bounds.minY + row.y), proposal: .init(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Running, passed or failed — the same mark on the strip, the panel and the toast.
struct StatusMark: View {
    let command: TrackedCommand?
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let command, command.ended != nil {
                Image(systemName: command.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(command.succeeded ? ok : fail)
            } else {
                Spinner(size: size)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }
}

/// An open ring turning at a calm pace; ProgressView's spinner is too busy at this size.
struct Spinner: View {
    var size: CGFloat = 12
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(Color.white.opacity(0.85), style: .init(lineWidth: max(1.5, size / 7), lineCap: .round))
            .frame(width: size - 1, height: size - 1)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// A task's mark: amber when it waits for you, a ring when it reports
/// progress, the spinner when it is only busy.
struct TaskMark: View {
    let task: ScriptTask
    var size: CGFloat = 12

    var body: some View {
        Group {
            if task.waiting {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: size - 1, weight: .semibold))
                    .foregroundStyle(amber)
            } else if let p = task.progress {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: max(1.5, size / 7))
                    Circle().trim(from: 0, to: p)
                        .stroke(Color.white, style: .init(lineWidth: max(1.5, size / 7), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: p)
                }
                .frame(width: size - 1, height: size - 1)
            } else {
                Spinner(size: size)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }
}

// MARK: - root

/// The whole window: transparent, with the island pressed against the edge.
struct RootView: View {
    @ObservedObject var state = AppState.shared
    let geometry: ScreenGeometry
    /// The island's frame in window coordinates, for hover and click-through.
    var report: (CGRect) -> Void = { _ in }

    enum Mode: Hashable { case toast, panel, strip, idle, sliver }

    private var edge: Edge { state.prefs.edge }
    private var m: Metrics {
        Metrics(edge: edge, scale: state.prefs.scale, widthScale: state.prefs.width, geometry: geometry)
    }

    private var mode: Mode {
        if state.toast != nil { return .toast }
        if state.expanded { return .panel }
        if state.stripHasContent { return .strip }
        return edge.isVertical ? .sliver : .idle
    }

    /// What the spring animates between. The timer ticking is not in here.
    private struct Key: Hashable {
        var mode: Mode
        var running: String?
        var recent: String?
        var count: Int
        var task: String?
        var waiting: Bool
        var prod: Bool
        var toast: UUID?
        var connected: Bool
        var scale: Double
        var width: Double
        var edge: Edge
    }

    private var key: Key {
        Key(mode: mode, running: state.visibleRunning.first?.id, recent: state.recent.first?.id,
            count: state.visibleRunning.count + state.tasks.count,
            task: state.orderedTasks.first?.id, waiting: state.orderedTasks.first?.waiting ?? false,
            prod: !state.prodAlert.isEmpty, toast: state.toast?.id,
            connected: state.isConnected, scale: state.prefs.scale, width: state.prefs.width, edge: edge)
    }

    /// The strip's natural size, measured off-screen so the island can animate
    /// to it instead of taking it on at once.
    @State private var barSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            BarView(m: m)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { barSize = $0 }
            island
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)   // white type on every surface
        .animation(islandSpring, value: key)
        .animation(islandSpring, value: barSize)
    }

    private var alignment: Alignment {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Where the island grows from, for the content's scale.
    private var anchor: UnitPoint {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var corner: CGFloat {
        switch mode {
        case .panel: return Metrics.panelCorner
        case .toast: return Metrics.toastCorner
        case .strip, .idle, .sliver: return m.stripCorner
        }
    }

    /// With nothing to show the island is gone: a transparent hairline against
    /// the edge that pushing the cursor into still opens. It only comes out when
    /// something happens.
    private var invisible: Bool { mode == .idle || mode == .sliver }

    /// The island's size without its fillet margins. Set explicitly for every
    /// mode, because that is what the spring animates: content that brought its
    /// own size would make the island jump to it.
    private var size: CGSize {
        switch mode {
        case .toast:
            return CGSize(width: Metrics.toastWidth, height: ToastView.height + m.under)
        case .panel:
            let s = edge.isVertical ? Metrics.sidePanelSize : Metrics.panelSize
            return CGSize(width: s.width, height: s.height + m.under)
        case .strip:
            return barSize == .zero ? CGSize(width: m.notchWidth, height: m.thickness) : barSize
        case .idle:
            return CGSize(width: m.notchWidth, height: 4)
        case .sliver:
            return CGSize(width: 5, height: 78 * m.scale * m.widthScale)
        }
    }

    private var island: some View {
        let shape = NotchShape(edge: edge, fillet: m.fillet, corner: corner)
        let lifted = mode == .panel || mode == .toast
        let size = size
        return ZStack(alignment: alignment) { content }
            // the fillets curve out into this margin along the edge
            .frame(width: size.width + (edge.isVertical ? 0 : m.fillet * 2),
                   height: size.height + (edge.isVertical ? m.fillet * 2 : 0),
                   alignment: alignment)
            .background { surface(shape) }
            .clipShape(shape)
            .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: lifted ? 18 : 0, y: lifted ? 8 : 0)
            .contentShape(shape)
            .onTapGesture {
                if let toast = state.toast {
                    state.focusTerminal(pid: toast.pid, tty: toast.tty)
                } else if !state.expanded {
                    // a click on the closed island opens it and keeps it open;
                    // once open, only the pin button changes that
                    NotchController.shared.togglePin()
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
            .opacity(invisible ? 0.02 : 1)
    }

    /// Content arrives once the island has started to open, sharpening out of a
    /// blur; it leaves quickly, so the shrinking island never shows it squeezed.
    private var reveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Reveal(progress: 0, anchor: anchor),
                                 identity: Reveal(progress: 1, anchor: anchor))
                .animation(.easeOut(duration: 0.32).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.12)))
    }

    @ViewBuilder private func surface(_ shape: NotchShape) -> some View {
        if !state.prodAlert.isEmpty && mode != .panel {
            shape.fill(prodRed)
        } else if state.prefs.surface == .solid || m.realNotch {
            // next to a hardware notch anything but black reads as a separate object
            shape.fill(Color.black).opacity(state.prefs.opacity)
        } else if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular.tint(Color(hex: "16141C").opacity(0.45 * state.prefs.opacity)), in: shape)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color(hex: "16141C").opacity(0.42))
            }
            .opacity(state.prefs.opacity)
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .toast:
            ToastView()
                .frame(width: Metrics.toastWidth)
                .padding(.top, m.under)
                .transition(reveal)
        case .panel:
            let s = edge.isVertical ? Metrics.sidePanelSize : Metrics.panelSize
            PanelView(topInset: m.under)
                .frame(width: s.width, height: s.height + m.under)
                .transition(reveal)
        case .strip:
            BarView(m: m)
                .fixedSize()
                .transition(reveal)
        case .idle, .sliver:
            EmptyView()
        }
    }
}

/// Blur, fade and a slight scale from the edge the island grows out of.
private struct Reveal: ViewModifier {
    var progress: Double
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 8)
            .scaleEffect(0.94 + 0.06 * progress, anchor: anchor)
    }
}

// MARK: - collapsed strip

struct BarView: View {
    @ObservedObject var state = AppState.shared
    let m: Metrics

    private var prod: Bool { !state.prodAlert.isEmpty }
    /// Scripts and agents speak up on purpose, so they go before plain commands.
    private var task: ScriptTask? { state.orderedTasks.first }
    private var busy: Bool { task != nil || !state.visibleRunning.isEmpty }
    private var others: Int { state.tasks.count + state.visibleRunning.count - 1 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if m.edge.isVertical {
                    vertical(now: context.date)
                } else {
                    horizontal(now: context.date)
                }
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: horizontal

    @ViewBuilder private func horizontal(now: Date) -> some View {
        if m.realNotch {
            // around a camera housing the halves take what they need
            NotchSplit(gap: m.notchWidth + 12 * m.scale) {
                HStack(spacing: 7 * m.scale) { lead(now: now) }
                HStack(spacing: 7 * m.scale) { trail(now: now) }
            }
            .padding(.horizontal, m.sideInset)
            .frame(minWidth: m.notchWidth)
            .frame(height: m.thickness)
            .fixedSize()
        } else {
            // a set length, so the island does not jump from command to command:
            // the text gives way, the timer and counts never do
            HStack(spacing: 0) {
                // above the spacer: otherwise HStack splits the room between them
                HStack(spacing: 7 * m.scale) { lead(now: now) }
                    .layoutPriority(0.5)
                Spacer(minLength: 10 * m.scale)
                HStack(spacing: 7 * m.scale) { trail(now: now) }
                    .fixedSize()
                    .layoutPriority(1)
            }
            .padding(.horizontal, m.sideInset)
            .frame(width: m.stripLength, height: m.thickness)
        }
    }

    private var font: CGFloat { m.font }
    private var commandLimit: Int { m.commandLimit }

    /// What is happening: a spinner and the command, or the last result.
    @ViewBuilder private func lead(now: Date) -> some View {
        if prod && !busy {
            warning
            Text("PROD").font(.system(size: font, weight: .heavy)).tracking(0.8)
                .fixedSize()
            // the environments give way to the length, the label never does
            Text(state.prodAlert.map(\.text).joined(separator: " · "))
                .font(.system(size: font - 1, weight: .medium, design: mono))
                .lineLimit(1).truncationMode(.tail)
        } else if let task {
            if prod && !task.waiting { warning } else { TaskMark(task: task, size: font) }
            Text(clip(task.title, commandLimit))
                .lineLimit(1).truncationMode(.middle)
                .font(.system(size: font, weight: .medium))
        } else if !state.isConnected {
            Image(systemName: "terminal").font(.system(size: font, weight: .semibold))
                .foregroundStyle(amber)
            Text(L10n.t("connect")).font(.system(size: font, weight: .medium))
        } else if let cmd = state.visibleRunning.first {
            if prod { warning } else { StatusMark(command: cmd, size: font) }
            Text(cmd.short(commandLimit))
                .lineLimit(1).truncationMode(.middle)
                .font(.system(size: font, weight: .medium, design: mono))
        } else if let last = state.recent.first {
            StatusMark(command: last, size: font)
            Text(last.short(commandLimit))
                .lineLimit(1).truncationMode(.middle)
                .font(.system(size: font, weight: .medium, design: mono))
                .foregroundStyle(.white.opacity(0.7))
        } else {
            Image(systemName: "terminal").font(.system(size: font, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(L10n.t("ready")).font(.system(size: font, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// How long, how many more, and where.
    @ViewBuilder private func trail(now: Date) -> some View {
        if prod && !busy {
            EmptyView()   // all of it is in `lead`, where it can be shortened
        } else if let task {
            if task.waiting {
                Text(L10n.t("waitingShort"))
                    .font(.system(size: font - 1, weight: .semibold))
                    .foregroundStyle(amber)
            } else if let p = task.progress {
                Text("\(Int((p * 100).rounded()))%")
                    .font(.system(size: font, weight: .semibold, design: mono))
            } else {
                Text(Fmt.duration(task.elapsed(at: now)))
                    .font(.system(size: font, weight: .semibold, design: mono))
            }
            if others > 0 { badge("+\(others)") }
            if prod, let first = state.prodAlert.first { badge(first.value) }
        } else if !state.isConnected {
            Image(systemName: "arrow.right.circle.fill").font(.system(size: font))
                .foregroundStyle(.white.opacity(0.5))
        } else if let cmd = state.visibleRunning.first {
            Text(Fmt.duration(cmd.elapsed(at: now)))
                .font(.system(size: font, weight: .semibold, design: mono))
            if others > 0 {
                badge("+\(others)")
                    .help(L10n.t("moreRunning", ["n": String(others)]))
            }
            if prod, let first = state.prodAlert.first { badge(first.value) }
        } else if let last = state.recent.first {
            Text(Fmt.duration(last.elapsed()))
                .font(.system(size: font, design: mono))
                .foregroundStyle(last.succeeded ? ok : fail)
        }
    }

    private func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private var warning: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: font, weight: .bold))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: font - 2, weight: .bold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 5 * m.scale).padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.2)))
    }

    // MARK: vertical

    /// A side edge has no room for the command: the mark, the timer, the count.
    private func vertical(now: Date) -> some View {
        VStack(spacing: 6 * m.scale) {
            if prod {
                warning
                Text("PROD").font(.system(size: 9 * m.scale, weight: .heavy))
            }
            if let task {
                TaskMark(task: task, size: font + 2)
                Text(task.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? Fmt.duration(task.elapsed(at: now)))
                    .font(.system(size: 10 * m.scale, weight: .semibold, design: mono))
                if others > 0 { badge("+\(others)") }
            } else if !state.isConnected {
                Image(systemName: "terminal").font(.system(size: font + 2, weight: .semibold))
                    .foregroundStyle(amber)
            } else if let cmd = state.visibleRunning.first {
                StatusMark(command: cmd, size: font + 2)
                Text(Fmt.duration(cmd.elapsed(at: now)))
                    .font(.system(size: 10 * m.scale, weight: .semibold, design: mono))
                if state.visibleRunning.count > 1 { badge("+\(state.visibleRunning.count - 1)") }
            } else if !prod, let last = state.recent.first {
                StatusMark(command: last, size: font + 2)
                Text(Fmt.duration(last.elapsed()))
                    .font(.system(size: 10 * m.scale, design: mono))
                    .foregroundStyle(.white.opacity(0.7))
            } else if !prod {
                Image(systemName: "terminal").font(.system(size: font + 1))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.vertical, m.sideInset)
        .frame(width: m.thickness + 16 * m.scale)
        .fixedSize()
    }
}

// MARK: - panel

struct PanelView: View {
    @ObservedObject var state = AppState.shared
    var topInset: CGFloat = 0
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 12)

            if !state.env.isEmpty { environment.padding(.bottom, 12) }

            if !state.isConnected {
                callout.padding(.bottom, 10)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                // scrolls only when the rows do not fit
                ViewThatFits(in: .vertical) {
                    list(now: context.date)
                    ScrollView { list(now: context.date) }.scrollIndicators(.never)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 18 + topInset)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            Text(L10n.t("terminal").uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(1.4)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            HStack(spacing: 6) {
                iconButton(state.pinned ? "pin.fill" : "pin", active: state.pinned,
                           help: L10n.t(state.pinned ? "unpin" : "pin")) {
                    NotchController.shared.togglePin()
                }
                iconButton("gearshape", help: L10n.t("settings")) { SettingsWindow.show() }
            }
        }
    }

    private func iconButton(_ symbol: String, active: Bool = false, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(active ? 0.28 : 0.1)))
                .overlay(Circle().stroke(Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: environment

    private var environment: some View {
        VStack(alignment: .leading, spacing: 6) {
            Flow(spacing: 6) {
                ForEach(state.env) { chip($0) }
            }
            if state.prodShells > (state.env.contains(where: \.isProd) ? 1 : 0) {
                Label(L10n.t("otherProdShells", ["n": String(state.prodShells)]),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fail)
            }
        }
    }

    private func chip(_ item: EnvItem) -> some View {
        HStack(spacing: 5) {
            if item.isProd {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5, weight: .bold))
            }
            Text(item.kind.label).foregroundStyle(.white.opacity(item.isProd ? 0.85 : 0.5))
            Text(item.value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium, design: mono))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(item.isProd ? prodRed : Color.white.opacity(0.08)))
        .frame(maxWidth: 300, alignment: .leading)
        .help(item.isProd ? L10n.t("prodMatched") : "")
    }

    private var callout: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 13, weight: .semibold)).foregroundStyle(amber)
            Text(L10n.t("connectHint")).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.t("connectButton")) { SettingsWindow.show(.terminal) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: rows

    private func list(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.tasks.isEmpty {
                sectionTitle(L10n.t("tasks"), count: state.tasks.count)
                ForEach(state.orderedTasks) { taskRow($0, now: now) }
                    .padding(.bottom, state.visibleRunning.isEmpty ? 0 : 6)
            }
            if !state.visibleRunning.isEmpty {
                sectionTitle(L10n.t("running"), count: state.visibleRunning.count)
                ForEach(state.visibleRunning) { row($0, now: now) }
            }
            if !state.recent.isEmpty {
                HStack {
                    sectionTitle(L10n.t("recent"), count: nil)
                    Spacer()
                    Button(L10n.t("clear")) { state.clearRecent() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.trailing, 8)
                }
                .padding(.top, state.visibleRunning.isEmpty ? 0 : 8)
                ForEach(state.recent.prefix(12)) { row($0, now: now) }
            }
            if state.tasks.isEmpty && state.visibleRunning.isEmpty && state.recent.isEmpty && state.isConnected {
                Text(L10n.t("emptyHint", ["s": String(Int(state.prefs.showAfter))]))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20).padding(.horizontal, 8)
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if let count {
                Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func taskRow(_ task: ScriptTask, now: Date) -> some View {
        Button { state.focusTerminal(pid: task.pid, tty: task.tty) } label: {
            HStack(spacing: 10) {
                TaskMark(task: task, size: 13)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if !task.detail.isEmpty {
                        Text(task.detail)
                            .font(.system(size: 10.5, design: mono))
                            .foregroundStyle(task.waiting ? amber : .white.opacity(0.5))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if let p = task.progress, !task.waiting {
                        Capsule().fill(Color.white.opacity(0.12))
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in
                                    Capsule().fill(Color.white).frame(width: g.size.width * p)
                                }
                            }
                            .animation(.easeOut(duration: 0.3), value: p)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                Group {
                    if task.waiting {
                        Text(L10n.t("waitingShort")).foregroundStyle(amber)
                    } else if let p = task.progress {
                        Text("\(Int((p * 100).rounded()))%")
                    } else {
                        Text(Fmt.duration(task.elapsed(at: now)))
                    }
                }
                .font(.system(size: 12.5, weight: .semibold, design: mono))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(task.waiting ? amber.opacity(0.12) : Color.white.opacity(hovered == task.id ? 0.09 : 0)))
            .animation(.easeOut(duration: 0.15), value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? task.id : (hovered == task.id ? nil : hovered) }
    }

    private func row(_ cmd: TrackedCommand, now: Date) -> some View {
        Button { state.focusTerminal(pid: cmd.pid, tty: cmd.tty) } label: {
            HStack(spacing: 10) {
                StatusMark(command: cmd, size: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cmd.command.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12.5, weight: .medium, design: mono))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(cmd.shortCwd).lineLimit(1).truncationMode(.head)
                        if let code = cmd.exitCode, code != 0 {
                            Text("exit \(code)").foregroundStyle(fail)
                        }
                    }
                    .font(.system(size: 10.5, design: mono))
                    .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.duration(cmd.elapsed(at: now)))
                        .font(.system(size: 12.5, weight: .semibold, design: mono))
                    if let ended = cmd.ended {
                        Text(Fmt.ago(ended, now: now, locale: state.prefs.lang.locale))
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovered == cmd.id ? 0.09 : 0)))
            .animation(.easeOut(duration: 0.15), value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? cmd.id : (hovered == cmd.id ? nil : hovered) }
        .help(cmd.command)
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.bottom, 9)
            HStack(spacing: 6) {
                Circle().fill(state.shells.isEmpty ? Color.white.opacity(0.35) : ok)
                    .frame(width: 5, height: 5)
                Text(state.shells.isEmpty ? L10n.t("waiting")
                                          : L10n.t("liveShells", ["n": String(state.shells.count)]))
                Spacer()
                Text("zsh")
            }
            .font(.system(size: 10.5, design: mono))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - toast

struct ToastView: View {
    @ObservedObject var state = AppState.shared
    static let height: CGFloat = 56

    var body: some View {
        let t = state.toast
        let kind = t?.kind ?? .success
        let tint: Color = switch kind {
        case .success: ok
        case .failure: fail
        case .attention: amber
        case .prod: .white
        }
        let symbol = switch kind {
        case .success: "checkmark"
        case .failure: "xmark"
        case .attention: "hand.raised.fill"
        case .prod: "exclamationmark.triangle.fill"
        }
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(kind == .prod ? 0.25 : 0.2)))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(t?.title ?? "").font(.system(size: 12.5, weight: .semibold))
                Text(t?.subtitle ?? "").font(.system(size: 11, design: mono))
                    .foregroundStyle(.white.opacity(kind == .prod ? 0.85 : 0.65))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let trailing = t?.trailing, !trailing.isEmpty {
                Text(trailing).font(.system(size: 13, weight: .bold, design: mono))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .foregroundStyle(.white)
    }
}
