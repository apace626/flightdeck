import AppKit

final class MainViewController: NSViewController, WorkspaceDelegate {

    private final class Tab {
        var title: String
        let destination: String? // nil = anonymous terminal tab
        let workspace: Workspace

        init(title: String, destination: String?, workspace: Workspace) {
            self.title = title
            self.destination = destination
            self.workspace = workspace
        }
    }

    private let tabBar = TabBarView()
    private let container = NSView()
    private var tabs: [Tab] = []
    private var activeIndex = -1
    private var leader: LeaderController?
    private var zenMode = false
    private var config: Config!
    private var projects: [String: Project] = [:]   // keyed by name
    private var control: ControlServer?

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

        // Discover projects from flightdeck.toml files under the scan roots.
        for project in ProjectLoader.scan(config.projectScanRoots) {
            projects[project.name] = project
        }

        // Leader bindings: config destinations + keyed projects.
        var bindings = config.orderedDestinations.compactMap { dest in
            dest.key.map { DestinationBinding(key: $0, name: dest.name, title: dest.title) }
        }
        bindings += projects.values.compactMap { project in
            project.key.map { DestinationBinding(key: $0, name: project.name, title: project.name) }
        }
        leader = LeaderController(hostView: view, destinations: bindings) { [weak self] action in
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
    }

    // MARK: - Leader actions

    private func perform(_ action: LeaderAction) {
        switch action {
        case .newTerminalTab:
            addTerminalTab()
        case .openFinder:
            showFinder()
        case .openProjects:
            showProjectPicker()
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
        case .focus(let direction):
            activeWorkspace?.focusNeighbor(direction)
        case .closePane:
            activeWorkspace?.closeFocused()
        case .selectTab(let index):
            selectTab(index)
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
        tabs.append(Tab(title: "Term", destination: nil, workspace: workspace))
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
            let finder = FinderOverlay(frame: .zero, roots: config.finderRoots, style: .embedded)
            finder.delegate = self
            workspace = Workspace(initialPane: finder)
        case .terminal:
            workspace = Workspace(initialPane: TerminalPane(command: dest.command))
        case .web:
            guard let url = dest.url else {
                FileHandle.standardError.write(Data("flightdeck: destination \"\(name)\" has no valid url\n".utf8))
                return
            }
            workspace = Workspace(initialPane: WebPane(url: url))
        }
        workspace.delegate = self
        tabs.append(Tab(title: dest.title, destination: name, workspace: workspace))
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
        tabBar.update(titles: tabs.map(\.title), active: activeIndex)
    }

    private func toggleZen() {
        zenMode.toggle()
        tabBar.isHidden = zenMode
        if let window = view.window, window.styleMask.contains(.fullScreen) != zenMode {
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - Control socket

    /// Handle a tab-separated command from a pane shell (see ControlServer).
    private func handleControl(_ line: String) {
        let parts = line.components(separatedBy: "\t")
        switch parts.first {
        case "tab" where parts.count >= 3:
            openCommandTab(title: parts[1], command: parts[2])
        case "goto" where parts.count >= 2:
            if projects[parts[1]] != nil { openProject(parts[1]) }
            else { openDestination(parts[1]) }
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

    // MARK: - Projects

    private func openProject(_ name: String, select: Bool = true) {
        guard let project = projects[name] else { return }
        // Singleton by project name.
        if let index = tabs.firstIndex(where: { $0.destination == name }) {
            if select { selectTab(index) }
            return
        }
        let workspace = Workspace(spec: project.layout)
        workspace.delegate = self
        tabs.append(Tab(title: project.name, destination: name, workspace: workspace))
        if select { selectTab(tabs.count - 1) } else { refreshTabBar() }
    }

    private func showProjectPicker() {
        guard !view.subviews.contains(where: { $0 is ListPicker }) else { return }
        let items = projects.values
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { p in
                ListPicker.Item(
                    id: p.name,
                    title: p.name,
                    subtitle: (p.root as NSString).abbreviatingWithTildeInPath,
                    keyHint: p.key.map(String.init)
                )
            }
        let picker = ListPicker(frame: view.bounds, placeholder: "Open project…", items: items)
        picker.onSelect = { [weak self] name in self?.openProject(name) }
        picker.onClose = { [weak self] in self?.activeWorkspace?.focusInitial() }
        view.addSubview(picker)
        picker.focusField()
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
              tabs[index].destination == nil, !title.isEmpty else { return }
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
