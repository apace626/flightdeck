import AppKit

final class MainViewController: NSViewController, WorkspaceDelegate {

    private final class Tab {
        var title: String
        let destination: String? // nil = anonymous terminal tab
        let workspace: Workspace
        let kind: TabKind        // drives the colored dot in the tab bar
        var pinnedTitle = false  // manually renamed → don't auto-retitle from shell

        init(title: String, destination: String?, workspace: Workspace, kind: TabKind = .terminal) {
            self.title = title
            self.destination = destination
            self.workspace = workspace
            self.kind = kind
        }
    }

    private let tabBar = TabBarView()
    private let container = NSView()
    private var tabs: [Tab] = []
    private var activeIndex = -1
    private var leader: LeaderController?
    private var screenObservers: [NSObjectProtocol] = []
    private var zenMode = false
    private var config: Config!
    private var projects: [String: Project] = [:]   // keyed by name
    private var control: ControlServer?
    // Lazy: don't create the audio engine / speech recognizer (and trigger their
    // permission prompts) until the user first presses leader+m.
    private lazy var dictation = Dictation()
    private var visualizer: VisualizerOverlay?
    private var dictationKeyMonitor: Any?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(container)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let (config, warning) = ConfigLoader.load()
        self.config = config
        if let warning {
            FileHandle.standardError.write(Data("flightdeck: \(warning)\n".utf8))
        }
        FilesBrowser.ensure()  // install ff / lg / fd-open helpers on PATH
        GitDiff.start()        // local diff server for project diff panes
        Reminders.start()      // Reminders access + dashboard snapshot feed
        CalendarEvents.start(include: config.calendarInclude, exclude: config.calendarExclude)  // agenda snapshot feed

        // Control socket: lets pane shells open tabs / jump to destinations.
        control = ControlServer { [weak self] line in
            self?.handleControl(line)
        }

        // Resolve terminal font: config > JetBrainsMono Nerd Font > SF Mono.
        let fontSize = config.fontSize
        TerminalPane.preferredFont = config.fontName.flatMap { NSFont(name: $0, size: fontSize) }
            ?? NSFont(name: "JetBrainsMono Nerd Font", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        TerminalPane.theme = TerminalTheme.named(config.themeName)

        tabBar.onSelect = { [weak self] index in
            self?.selectTab(index)
        }
        tabBar.onNewTab = { [weak self] in
            self?.addTerminalTab()
        }
        tabBar.onClose = { [weak self] index in
            self?.closeTab(at: index)
        }

        // Discover projects: central projects.toml first, then in-repo
        // flightdeck.toml files (which win on a name collision).
        let centralPath = ConfigLoader.configDir.appendingPathComponent("projects.toml").path
        for project in ProjectLoader.loadCentral(centralPath) {
            projects[project.name] = project
        }
        for project in ProjectLoader.scan(config.projectScanRoots) {
            projects[project.name] = project
        }

        // Ctrl+Space opens the searchable launcher (all destinations/projects/actions).
        leader = LeaderController(hostView: view) { [weak self] action in
            self?.perform(action)
        }

        // Startup tabs, as declared in config.
        for name in config.startupTabs {
            if name == "terminal" {
                addTerminalTab(select: false)
            } else {
                openDestination(name, select: false)
            }
        }
        if tabs.isEmpty {
            addTerminalTab(select: false)
        }

        let initialIndex = config.startupActive.flatMap { active in
            tabs.firstIndex { $0.destination == active || (active == "terminal" && $0.destination == nil) }
        } ?? 0
        selectTab(initialIndex)

        maybeShowWelcome()
    }

    /// Once the view is in a window, watch for screen / backing-scale changes
    /// (moving between the laptop display and an external monitor) and force the
    /// active tab to relayout — otherwise its panes and the tab bar stay stale
    /// until you switch tabs.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, screenObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            screenObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.relayoutActiveTab()
            })
        }
    }

    private func relayoutActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        // A beat after the screen settles, force a full relayout (same effect as
        // switching tabs, which is the known workaround).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.refreshTabBar()
            self.tabs[self.activeIndex].workspace.relayoutAndRepaint()
        }
    }

    deinit { screenObservers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - First-run welcome / dependency check

    private func maybeShowWelcome() {
        let key = "didWelcome"
        let firstRun = !UserDefaults.standard.bool(forKey: key)

        Dependencies.check { [weak self] statuses in
            guard let self else { return }
            let missingRequired = Dependencies.tools.contains { $0.required && statuses[$0.name] == false }
            guard firstRun || missingRequired else { return }

            let welcome = WelcomeOverlay(frame: self.view.bounds)
            welcome.apply(statuses: statuses)
            welcome.onContinue = { [weak self, weak welcome] in
                UserDefaults.standard.set(true, forKey: key)
                welcome?.removeFromSuperview()
                self?.activeWorkspace?.focusInitial()
            }
            self.view.addSubview(welcome)
            welcome.focusContinue()
        }
    }

    // MARK: - Leader actions

    private func perform(_ action: LeaderAction) {
        switch action {
        case .newTerminalTab:
            addTerminalTab()
        case .openLauncher:
            showLauncher()
        case .openFinder:
            showFinder()
        case .toggleMic:
            toggleMic()
        case .renameTab:
            renameActiveTab()
        case .goto(let name):
            // Projects take precedence over same-named destinations.
            if projects[name] != nil {
                openProject(name)
            } else {
                openDestination(name)
            }
        case .splitRight:
            activeWorkspace?.splitFocused(vertical: true)
        case .splitDown:
            activeWorkspace?.splitFocused(vertical: false)
        case .splitCodex:
            activeWorkspace?.splitFocused(vertical: false, command: "codex")
        case .focus(let direction):
            activeWorkspace?.focusNeighbor(direction)
        case .closePane:
            activeWorkspace?.closeFocused()
        case .selectTab(let index):
            selectTab(index)
        case .cycleTab(let delta):
            guard !tabs.isEmpty else { break }
            let n = tabs.count
            selectTab(((activeIndex + delta) % n + n) % n)   // wraps both ways
        case .toggleZen:
            toggleZen()
        }
    }

    private var activeWorkspace: Workspace? {
        guard tabs.indices.contains(activeIndex) else { return nil }
        return tabs[activeIndex].workspace
    }

    // MARK: - Tabs

    private func addTerminalTab(select: Bool = true) {
        let workspace = Workspace()
        workspace.delegate = self
        tabs.append(Tab(title: "New Tab", destination: nil, workspace: workspace))
        if select {
            selectTab(tabs.count - 1)
        } else {
            refreshTabBar()
        }
    }

    private func openDestination(_ name: String, select: Bool = true) {
        guard let dest = config.destinations[name] else {
            FileHandle.standardError.write(Data("flightdeck: unknown destination \"\(name)\"\n".utf8))
            return
        }

        // localhost: ask for a port, then open http://localhost:<port> in a tab
        // titled with the port. Each port is its own tab (no singleton jump).
        if dest.kind == .localhost {
            promptLocalhost()
            return
        }

        // Singleton destinations: jump if a tab already exists.
        if dest.singleton, let index = tabs.firstIndex(where: { $0.destination == name }) {
            if select { selectTab(index) }
            return
        }

        let workspace: Workspace
        switch dest.kind {
        case .dashboard:
            workspace = Workspace(spec: Dashboard.spec())
        case .files:
            // ff (fzf file browser with inline bat preview). Starts scoped to
            // ~/Projects (configurable via the destination's `command`), not the
            // whole home dir; Ctrl-O inside ff jumps to another directory.
            let root = dest.command.map { ($0 as NSString).expandingTildeInPath }
                ?? "\(NSHomeDirectory())/Projects"
            workspace = Workspace(initialPane: TerminalPane(command: "ff", workingDirectory: root, keepAlive: true))
        case .terminal:
            workspace = Workspace(initialPane: TerminalPane(command: dest.command))
        case .web:
            guard let url = dest.url else {
                FileHandle.standardError.write(Data("flightdeck: destination \"\(name)\" has no valid url\n".utf8))
                return
            }
            workspace = Workspace(initialPane: WebPane(url: url))
        case .localhost:
            return   // handled above via promptLocalhost()
        }
        workspace.delegate = self
        let tabKind: TabKind
        switch dest.kind {
        case .dashboard:        tabKind = .dashboard
        case .web:              tabKind = .web
        case .files, .terminal, .localhost: tabKind = .terminal
        }
        tabs.append(Tab(title: dest.title, destination: name, workspace: workspace, kind: tabKind))
        if select {
            selectTab(tabs.count - 1)
        } else {
            refreshTabBar()
        }
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index

        container.subviews.forEach { $0.removeFromSuperview() }
        let workspace = tabs[index].workspace
        workspace.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(workspace)
        NSLayoutConstraint.activate([
            workspace.topAnchor.constraint(equalTo: container.topAnchor),
            workspace.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            workspace.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        refreshTabBar()
        DispatchQueue.main.async {
            workspace.focusInitial()
        }
    }

    /// Kill all panes' process trees across every tab (called on app quit).
    func terminateAllProcesses() {
        GitDiff.stop()
        tabs.forEach { $0.workspace.terminateAll() }
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].workspace.terminateAll()
        tabs.remove(at: index)

        if tabs.isEmpty {
            addTerminalTab() // always keep at least one tab
            return
        }
        selectTab(min(index, tabs.count - 1))
    }

    private func refreshTabBar() {
        tabBar.update(tabs: tabs.map { ($0.title, $0.kind) }, active: activeIndex)
    }

    private func toggleZen() {
        zenMode.toggle()
        tabBar.isHidden = zenMode
        if let window = view.window, window.styleMask.contains(.fullScreen) != zenMode {
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - Rename tab

    private func renameActiveTab() {
        guard tabs.indices.contains(activeIndex),
              !view.subviews.contains(where: { $0 is TextPrompt }) else { return }
        let current = tabs[activeIndex].title
        let prompt = TextPrompt(frame: view.bounds, title: "Rename tab", initial: current)
        prompt.onSubmit = { [weak self] name in
            guard let self, self.tabs.indices.contains(self.activeIndex) else { return }
            self.tabs[self.activeIndex].title = name
            self.tabs[self.activeIndex].pinnedTitle = true
            self.refreshTabBar()
            self.activeWorkspace?.focusInitial()
        }
        prompt.onClose = { [weak self] in self?.activeWorkspace?.focusInitial() }
        view.addSubview(prompt)
        prompt.focusField()
    }

    // MARK: - Reminders quick capture

    private func addTaskPrompt() {
        guard !view.subviews.contains(where: { $0 is TextPrompt }) else { return }
        let prompt = TextPrompt(frame: view.bounds, title: "Add reminder", initial: "",
                                placeholder: "fix gate latch  #house  due:friday-9am",
                                hint: "↵  add     esc  cancel")
        prompt.onSubmit = { [weak self] text in
            Reminders.add(text) { message in self?.showToast(message) }
        }
        prompt.onClose = { [weak self] in self?.activeWorkspace?.focusInitial() }
        view.addSubview(prompt)
        prompt.focusField()
    }

    /// A transient confirmation pill at the bottom of the window.
    private func showToast(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor(srgbRed: 205/255, green: 214/255, blue: 244/255, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(srgbRed: 30/255, green: 30/255, blue: 46/255, alpha: 0.95).cgColor
        panel.layer?.cornerRadius = 10
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(srgbRed: 69/255, green: 71/255, blue: 90/255, alpha: 1).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)
        view.addSubview(panel)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak panel] in
            panel?.removeFromSuperview()
        }
    }

    // MARK: - Dictation (mic → text)

    private func toggleMic() {
        if dictation.running {
            finishDictation(insert: true)
            return
        }
        dictation.start { [weak self] ok in
            guard let self, ok else {
                FileHandle.standardError.write(Data("flightdeck: mic/speech permission denied\n".utf8))
                return
            }
            let viz = VisualizerOverlay(frame: self.view.bounds)
            self.view.addSubview(viz)
            self.visualizer = viz
            self.dictation.onLevel = { [weak viz] level in viz?.push(level: level) }
            self.dictation.onPartial = { [weak viz] text in viz?.setTranscript(text) }

            // While listening: ⏎ inserts, esc cancels. Drop any stale monitor first.
            if let m = self.dictationKeyMonitor { NSEvent.removeMonitor(m); self.dictationKeyMonitor = nil }
            self.dictationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 36, 76: self?.finishDictation(insert: true); return nil   // return / enter
                case 53:     self?.finishDictation(insert: false); return nil  // escape
                default:     return event
                }
            }
        }
    }

    private func finishDictation(insert: Bool) {
        let text = dictation.stop()
        if let monitor = dictationKeyMonitor { NSEvent.removeMonitor(monitor); dictationKeyMonitor = nil }
        visualizer?.removeFromSuperview(); visualizer = nil

        let term = activeWorkspace?.focusedPane() as? TerminalPane
        if insert, !text.isEmpty { term?.terminal.send(txt: text) }

        // After the overlay, SwiftTerm stops repainting — the program's output
        // lands in the buffer (cursor moves) but the screen stays stale until you
        // click in. needsDisplay alone doesn't wake it; a tiny size change does
        // (forces a full re-render + a SIGWINCH so the program repaints its TUI)
        // — exactly what clicking in triggers.
        DispatchQueue.main.async { [weak self] in
            guard let term else { self?.activeWorkspace?.focusInitial(); return }
            term.takeFocus()
            let tv = term.terminal
            let s = tv.frame.size
            tv.setFrameSize(NSSize(width: s.width, height: max(1, s.height - 24)))
            tv.setFrameSize(s)
            tv.needsDisplay = true
        }
    }

    // MARK: - Control socket

    /// Handle a tab-separated command from a pane shell (see ControlServer).
    private func handleControl(_ line: String) {
        let parts = line.components(separatedBy: "\t")
        switch parts.first {
        case "tab" where parts.count >= 3:
            openCommandTab(title: parts[1], command: parts[2])
        case "web" where parts.count >= 3:
            if let url = URL(string: parts[2]) { openWebTab(title: parts[1], url: url) }
        case "goto" where parts.count >= 2:
            if projects[parts[1]] != nil { openProject(parts[1]) }
            else { openDestination(parts[1]) }
        case "task" where parts.count >= 2:
            // task<TAB><text> → Reminders quick add (scripts, hooks, pollers).
            Reminders.add(parts[1...].joined(separator: " ")) { [weak self] message in
                self?.showToast(message)
            }
        default:
            break
        }
    }

    /// Open a new tab running an arbitrary command (used by the control socket).
    func openCommandTab(title: String, command: String) {
        let workspace = Workspace(initialPane: TerminalPane(command: command))
        workspace.delegate = self
        tabs.append(Tab(title: title, destination: nil, workspace: workspace))
        selectTab(tabs.count - 1)
    }

    /// Ask for a port and open http://localhost:<port> in a tab named ":<port>".
    private func promptLocalhost() {
        guard !view.subviews.contains(where: { $0 is TextPrompt }) else { return }
        let prompt = TextPrompt(frame: view.bounds, title: "Open localhost", initial: "",
                                placeholder: "3000",
                                hint: "↵  open     esc  cancel")
        prompt.onSubmit = { [weak self] text in
            guard let self else { return }
            // Accept "3000", ":3000", "localhost:3000", "http://localhost:3000/x".
            let digits = text.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            guard let port = Int(digits), (1...65535).contains(port),
                  let url = URL(string: "http://localhost:\(port)") else {
                self.showToast("not a valid port")
                return
            }
            self.openWebTab(title: ":\(port)", url: url)
        }
        prompt.onClose = { [weak self] in self?.activeWorkspace?.focusInitial() }
        view.addSubview(prompt)
        prompt.focusField()
    }

    /// Open a new web tab at a URL (used by the control socket — e.g. md preview).
    func openWebTab(title: String, url: URL) {
        let workspace = Workspace(initialPane: WebPane(url: url))
        workspace.delegate = self
        tabs.append(Tab(title: title, destination: nil, workspace: workspace, kind: .web))
        selectTab(tabs.count - 1)
    }

    // MARK: - Projects

    private func openProject(_ name: String, select: Bool = true) {
        guard let project = projects[name] else { return }
        // Singleton by project name.
        if let index = tabs.firstIndex(where: { $0.destination == name }) {
            if select { selectTab(index) }
            return
        }
        let statusBar = project.statusbar.map { (command: $0, cwd: project.root) }
        let workspace = Workspace(spec: project.layout, statusBar: statusBar)
        workspace.delegate = self
        tabs.append(Tab(title: project.name, destination: name, workspace: workspace, kind: .project))
        if select { selectTab(tabs.count - 1) } else { refreshTabBar() }
    }

    // MARK: - Launcher (Ctrl+Space) — search destinations, projects, actions

    private func showLauncher() {
        guard !view.subviews.contains(where: { $0 is ListPicker }) else { return }
        // Cache the active pane NOW, before the launcher overlay steals focus, so
        // a split/codex action picked from the launcher targets the right pane.
        _ = activeWorkspace?.focusedPane()
        var items: [ListPicker.Item] = []

        // Destinations (config order) — the "apps" you go to.
        for d in config.orderedDestinations {
            items.append(.init(id: "go:\(d.name)", title: d.title,
                               subtitle: destSubtitle(d), keyHint: d.key.map(String.init)))
        }
        // Projects.
        for p in projects.values.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            items.append(.init(id: "go:\(p.name)", title: p.name,
                               subtitle: (p.root as NSString).abbreviatingWithTildeInPath,
                               keyHint: p.key.map(String.init)))
        }
        // Actions.
        items += [
            .init(id: "act:newtab", title: "New Terminal Tab", subtitle: "blank shell",      keyHint: nil),
            .init(id: "act:finder", title: "Find File…",       subtitle: "fuzzy file finder", keyHint: nil),
            .init(id: "act:rename", title: "Rename Tab",       subtitle: "current tab",       keyHint: nil),
            .init(id: "act:splitr", title: "Split Right",      subtitle: "pane",              keyHint: nil),
            .init(id: "act:splitd", title: "Split Down",       subtitle: "pane",              keyHint: nil),
            .init(id: "act:codex",  title: "Codex",             subtitle: "split pane down · codex here", keyHint: nil),
            .init(id: "act:close",  title: "Close Pane",       subtitle: "",                  keyHint: nil),
            .init(id: "act:zen",    title: "Zen Mode",         subtitle: "fullscreen",        keyHint: nil),
            .init(id: "act:mic",    title: "Dictate",          subtitle: "voice → text",      keyHint: nil),
            .init(id: "act:task",   title: "Add Reminder",     subtitle: "Apple Reminders quick capture", keyHint: nil),
        ]

        let picker = ListPicker(frame: view.bounds,
                                placeholder: "Search destinations, projects, actions…", items: items)
        picker.onSelect = { [weak self] id in self?.launch(id) }
        picker.onClose = { [weak self] in self?.activeWorkspace?.focusInitial() }
        view.addSubview(picker)
        picker.focusField()
    }

    private func launch(_ id: String) {
        if id.hasPrefix("go:") { perform(.goto(String(id.dropFirst(3)))); return }
        switch id {
        case "act:newtab": perform(.newTerminalTab)
        case "act:finder": perform(.openFinder)
        case "act:rename": perform(.renameTab)
        case "act:splitr": perform(.splitRight)
        case "act:splitd": perform(.splitDown)
        case "act:codex":  perform(.splitCodex)
        case "act:close":  perform(.closePane)
        case "act:zen":    perform(.toggleZen)
        case "act:mic":    perform(.toggleMic)
        case "act:task":   addTaskPrompt()
        default: break
        }
    }

    private func destSubtitle(_ d: Destination) -> String {
        switch d.kind {
        case .web:       return d.url?.absoluteString ?? "web app"
        case .terminal:  return d.command ?? "terminal"
        case .dashboard: return "dashboard"
        case .files:     return "file finder"
        case .localhost: return "ask for a port → open in a tab"
        }
    }

    // MARK: - Fuzzy finder

    private func showFinder() {
        guard !view.subviews.contains(where: { $0 is FinderOverlay }) else { return }
        let finder = FinderOverlay(frame: view.bounds, roots: config.finderRoots)
        finder.delegate = self
        view.addSubview(finder)
        finder.focusField()
    }

    // MARK: - WorkspaceDelegate

    func workspaceDidBecomeEmpty(_ workspace: Workspace) {
        if let index = tabs.firstIndex(where: { $0.workspace === workspace }) {
            closeTab(at: index)
        }
    }

    func workspace(_ workspace: Workspace, paneTitleChanged title: String) {
        guard let index = tabs.firstIndex(where: { $0.workspace === workspace }),
              tabs[index].destination == nil, !tabs[index].pinnedTitle, !title.isEmpty else { return }
        tabs[index].title = title
        refreshTabBar()
    }
}

// MARK: - FinderOverlayDelegate

extension MainViewController: FinderOverlayDelegate {
    func finder(_ finder: FinderOverlay, openInEditor url: URL) {
        let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
        let pane = TerminalPane(command: "nvim '\(escaped)'")
        let workspace = Workspace(initialPane: pane)
        workspace.delegate = self
        tabs.append(Tab(title: url.lastPathComponent, destination: nil, workspace: workspace))
        selectTab(tabs.count - 1)
    }

    func finder(_ finder: FinderOverlay, openDirectory url: URL, asShell: Bool) {
        let pane = TerminalPane(workingDirectory: url.path)
        let workspace = Workspace(initialPane: pane)
        workspace.delegate = self
        tabs.append(Tab(title: url.lastPathComponent, destination: nil, workspace: workspace))
        selectTab(tabs.count - 1)
    }

    func finderDidClose(_ finder: FinderOverlay) {
        activeWorkspace?.focusInitial()
    }
}
