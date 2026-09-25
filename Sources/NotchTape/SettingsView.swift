import SwiftUI
import AppKit

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(_ tab: SettingsTab? = nil) {
        if let tab { AppState.shared.settingsTab = tab }
        // an open panel would sit on top of the window it just opened
        NotchController.shared.collapseUnlessPinned()
        let w = window ?? make()
        w.title = L10n.t("settings")   // the language may have changed since last time
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static var isVisible: Bool { window?.isVisible == true }
    static func close() { window?.close() }

    private static func make() -> NSWindow {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        window = w
        return w
    }
}

struct SettingsView: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        TabView(selection: $state.settingsTab) {
            GeneralTab()
                .tabItem { Label(L10n.t("general"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            TerminalTab()
                .tabItem { Label(L10n.t("terminal"), systemImage: "terminal") }
                .tag(SettingsTab.terminal)
            GuardTab()
                .tabItem { Label(L10n.t("prodGuard"), systemImage: "exclamationmark.shield") }
                .tag(SettingsTab.prodGuard)
            AgentsTab()
                .tabItem { Label(L10n.t("agents"), systemImage: "sparkles") }
                .tag(SettingsTab.agents)
            AboutTab()
                .tabItem { Label(L10n.t("about"), systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(16)
        .frame(width: 620, height: 560)
    }
}

/// A binding into `prefs` that re-lays the strip out on every change.
@MainActor
private func prefBinding<T>(_ key: WritableKeyPath<Prefs, T>) -> Binding<T> {
    let state = AppState.shared
    return Binding(get: { state.prefs[keyPath: key] },
                   set: { new in
                       var p = state.prefs; p[keyPath: key] = new; state.prefs = p
                       NotchController.shared.layout(animated: true)
                   })
}

// MARK: general

private struct GeneralTab: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Form {
            Picker(L10n.t("language"), selection: prefBinding(\.lang)) {
                ForEach(Lang.allCases) { l in Text(l.title).tag(l) }
            }
            .pickerStyle(.segmented)

            Section {
                Picker(L10n.t("show"), selection: prefBinding(\.show)) {
                    Text(L10n.t("showAuto")).tag(ShowMode.auto)
                    Text(L10n.t("showAlways")).tag(ShowMode.always)
                    Text(L10n.t("showHidden")).tag(ShowMode.hidden)
                }
                .pickerStyle(.segmented)
                Text(showHint).font(.caption).foregroundStyle(.secondary)

                Picker(L10n.t("screenEdge"), selection: prefBinding(\.edge)) {
                    Text(L10n.t("top")).tag(Edge.top)
                    Text(L10n.t("right")).tag(Edge.right)
                    Text(L10n.t("bottom")).tag(Edge.bottom)
                    Text(L10n.t("left")).tag(Edge.left)
                }
                .pickerStyle(.segmented)
                Toggle(L10n.t("allDisplays"), isOn: Binding(
                    get: { state.prefs.allDisplays },
                    set: { new in
                        var p = state.prefs; p.allDisplays = new; state.prefs = p
                        NotchController.shared.rebuild()
                    }))
            }

            Section(L10n.t("look")) {
                Picker(L10n.t("surface"), selection: prefBinding(\.surface)) {
                    Text(L10n.t("solid")).tag(Surface.solid)
                    Text(L10n.t("glass")).tag(Surface.glass)
                }
                .pickerStyle(.segmented)

                LabeledContent(L10n.t("size")) {
                    HStack {
                        Slider(value: prefBinding(\.scale), in: 0.8...1.5, step: 0.05)
                        Text("\(Int((state.prefs.scale * 100).rounded())) %")
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent(L10n.t("opacity")) {
                    HStack {
                        Slider(value: prefBinding(\.opacity), in: 0.2...1, step: 0.05)
                        Text("\(Int((state.prefs.opacity * 100).rounded())) %")
                            .monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Text(L10n.t("lookHint")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.t("resetLook")) {
                    var p = state.prefs; p.scale = 1; p.opacity = 1; p.surface = .solid; state.prefs = p
                }
                .disabled(state.prefs.scale == 1 && state.prefs.opacity == 1 && state.prefs.surface == .solid)
            }

        }
        .formStyle(.grouped)
    }

    private var showHint: String {
        switch state.prefs.show {
        case .auto:   return L10n.t("showHintAuto")
        case .always: return L10n.t("showHintAlways")
        case .hidden: return L10n.t("showHintHidden")
        }
    }
}

// MARK: terminal

private struct TerminalTab: View {
    @ObservedObject var state = AppState.shared
    @State private var problem = ""
    @State private var copied = false
    @State private var ignoredText = ""

    var body: some View {
        Form {
            Section(L10n.t("integration")) {
                HStack(spacing: 10) {
                    Image(systemName: state.hookInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(state.hookInstalled ? .green : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t(state.hookInstalled ? "integrationInstalled" : "integrationMissing"))
                        Text(state.shells.isEmpty ? L10n.t("waiting")
                                                  : L10n.t("liveShells", ["n": String(state.shells.count)]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.hookInstalled {
                        Button(L10n.t("remove")) { run { try state.removeHook() } }
                    } else {
                        Button(L10n.t("install")) { run { try state.installHook() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if state.hookInstalled && state.shells.isEmpty {
                    Label(L10n.t("reloadHint"), systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !problem.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                DisclosureGroup(L10n.t("manualInstall")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("manualHint")).font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .top) {
                            Text(ShellIntegration.sourceLine)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                            Button(copied ? L10n.t("copied") : L10n.t("copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ShellIntegration.sourceLine, forType: .string)
                                copied = true
                            }
                        }
                        Text(L10n.t("onlyZsh")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            Section(L10n.t("behaviour")) {
                Stepper(value: prefBinding(\.showAfter), in: 1...60, step: 1) {
                    LabeledContent(L10n.t("showAfter"),
                                   value: L10n.t("seconds", ["n": String(Int(state.prefs.showAfter))]))
                }
                Stepper(value: prefBinding(\.notifyAfter), in: 5...600, step: 5) {
                    LabeledContent(L10n.t("notifyAfter"),
                                   value: L10n.t("seconds", ["n": String(Int(state.prefs.notifyAfter))]))
                }
                Toggle(L10n.t("sound"), isOn: prefBinding(\.sound))
                Toggle(isOn: Binding(
                    get: { state.prefs.keepHistory },
                    set: { v in
                        var p = state.prefs; p.keepHistory = v; state.prefs = p
                        state.historySettingChanged()
                    })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("keepHistory"))
                        Text(L10n.t("keepHistoryHint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(L10n.t("systemNotifications"), isOn: Binding(
                    get: { state.prefs.systemNotifications },
                    set: { new in
                        var p = state.prefs; p.systemNotifications = new; state.prefs = p
                        if new { state.requestNotificationPermission() }
                    }))
            }

            Section(L10n.t("cli")) {
                HStack(spacing: 10) {
                    Image(systemName: ShellIntegration.cliInstalled ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(ShellIntegration.cliInstalled ? .green : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t(ShellIntegration.cliInstalled ? "cliReady" : "cliMissing"))
                        Text(ShellIntegration.cliURL.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Button(L10n.t("copyPath")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ShellIntegration.cliURL.path, forType: .string)
                    }
                }
                Text(Self.cliExample)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                Text(L10n.t("cliHint")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.t("ignore")) {
                TextField("", text: $ignoredText, prompt: Text("vim, ssh, tmux"))
                    .onSubmit(saveIgnored)
                    .onChange(of: ignoredText) { saveIgnored() }
                Text(L10n.t("ignoreHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { ignoredText = state.prefs.ignored.joined(separator: ", ") }
    }

    static let cliExample = """
    notch start "Deploy"
    notch progress 40 "Deploy"
    notch done "3 hosts updated"
    notch run make release
    """

    private func saveIgnored() {
        let words = ignoredText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard words != state.prefs.ignored else { return }
        var p = state.prefs; p.ignored = words; state.prefs = p
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); problem = "" }
        catch { problem = L10n.t("rcFailed", ["e": error.localizedDescription]) }
    }
}

// MARK: prod guard

private struct GuardTab: View {
    @ObservedObject var state = AppState.shared
    @State private var patternsText = ""

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("guardEnabled"), isOn: guardBinding(\.guardEnabled))
                Text(L10n.t("guardHint")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.t("patterns")) {
                TextField("", text: $patternsText, prompt: Text("prod, production, prd"))
                    .onChange(of: patternsText) { savePatterns() }
                Text(L10n.t("patternsHint")).font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.t("sources")) {
                ForEach(EnvKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { state.prefs.guardSources.contains(kind) },
                        set: { on in
                            var p = state.prefs
                            p.guardSources.removeAll { $0 == kind }
                            if on { p.guardSources.append(kind) }
                            state.prefs = p
                            state.evaluateGuard()
                        })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L10n.t("source." + kind.rawValue))
                            Text(L10n.t("sourceHint." + kind.rawValue))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(L10n.t("guardAnnounce"), isOn: guardBinding(\.guardAnnounce))
            }

            Section(L10n.t("now")) {
                if state.env.isEmpty {
                    Text(L10n.t("nowEmpty")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(state.env) { item in
                    HStack {
                        Text(item.kind.label).font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Text(item.value).font(.system(.body, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        if item.isProd {
                            Label("PROD", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { patternsText = state.prefs.prodPatterns.joined(separator: ", ") }
    }

    private func guardBinding(_ key: WritableKeyPath<Prefs, Bool>) -> Binding<Bool> {
        Binding(get: { state.prefs[keyPath: key] },
                set: { v in var p = state.prefs; p[keyPath: key] = v; state.prefs = p; state.evaluateGuard() })
    }

    private func savePatterns() {
        let words = patternsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard words != state.prefs.prodPatterns else { return }
        var p = state.prefs; p.prodPatterns = words; state.prefs = p
        state.evaluateGuard()
    }
}

// MARK: agents

private struct AgentsTab: View {
    @State private var installed: [Agent: Bool] = [:]
    @State private var problem: [Agent: String] = [:]
    @State private var copied: Agent?

    var body: some View {
        Form {
            Section {
                Text(L10n.t("agentsIntro")).font(.callout)
            }

            ForEach(Agent.allCases) { agent in
                Section(agent.name) { row(agent) }
            }

            Section(L10n.t("vscode")) {
                Text(L10n.t("vscodeHint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("otherAgents")) {
                Text(L10n.t("otherAgentsHint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.customExample)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    static let customExample = """
    notch start "My agent" --id my-agent     # it started working
    notch status "Editing App.swift" --id my-agent
    notch wait "Needs approval" --id my-agent   # amber, with a toast
    notch done --id my-agent                 # its turn is over
    """

    @ViewBuilder private func row(_ agent: Agent) -> some View {
        let on = installed[agent] ?? false
        HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(on ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(on ? "agentConnected" : "agentNotConnected"))
                Text(agent.configPath).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            switch agent.setup {
            case .line:
                Button(copied == agent ? L10n.t("copied") : L10n.t("copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentIntegration.line(for: agent), forType: .string)
                    copied = agent
                }
            case .mergedHooks, .ownFile:
                if on {
                    Button(L10n.t("remove")) { run(agent) { try AgentIntegration.remove(agent) } }
                } else {
                    Button(L10n.t("connectAgent")) { run(agent) { try AgentIntegration.install(agent) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        if agent.setup == .line {
            Text(AgentIntegration.line(for: agent))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
        }
        Text(L10n.t("agentHint." + agent.rawValue)).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let problem = problem[agent] {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func refresh() {
        for agent in Agent.allCases { installed[agent] = AgentIntegration.isInstalled(agent) }
    }

    private func run(_ agent: Agent, _ action: () throws -> Void) {
        do { try action(); problem[agent] = nil }
        catch { problem[agent] = error.localizedDescription }
        refresh()
    }
}

// MARK: about

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            Text("NotchTape").font(.title.bold())
            Text(L10n.t("tagline")).foregroundStyle(.secondary)
            Text(L10n.t("version", ["v": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.0"]))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
