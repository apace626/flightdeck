import AppKit

enum LeaderAction {
    case newTerminalTab
    case openFinder
    case openProjects          // project picker (leader+p)
    case toggleMic             // mic visualizer (leader+m)
    case renameTab             // rename current tab (leader+n)
    case goto(String)          // destination or project name
    case splitRight
    case splitDown
    case focus(Direction)
    case closePane
    case selectTab(Int)
    case toggleZen
}

/// A destination's leader binding, derived from config.
struct DestinationBinding {
    let key: Character
    let name: String
    let title: String
}

/// Intercepts Ctrl+Space, then dispatches the next keypress as a command.
/// Shows a which-key HUD while the leader is active.
final class LeaderController {
    private weak var hostView: NSView?
    private let handler: (LeaderAction) -> Void
    private let destinations: [DestinationBinding]
    private var monitor: Any?
    private var active = false
    private var palette: LeaderPalette?

    private static let spaceKeyCode: UInt16 = 49

    init(hostView: NSView, destinations: [DestinationBinding], handler: @escaping (LeaderAction) -> Void) {
        self.hostView = hostView
        self.destinations = destinations
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.process(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func process(_ event: NSEvent) -> NSEvent? {
        if active {
            handleLeaderKey(event)
            return nil
        }
        if event.keyCode == Self.spaceKeyCode && event.modifierFlags.contains(.control) {
            activate()
            return nil
        }
        return event
    }

    private func handleLeaderKey(_ event: NSEvent) {
        // Escape cancels (also exits sticky help).
        if event.keyCode == 53 {
            deactivate()
            return
        }

        guard let chars = event.charactersIgnoringModifiers, let key = chars.first else {
            deactivate()
            return
        }

        let action = builtinAction(for: key)
            ?? destinations.first { $0.key == key }.map { LeaderAction.goto($0.name) }
        deactivate()
        if let action { handler(action) }
    }

    private func builtinAction(for key: Character) -> LeaderAction? {
        switch key {
        case "t": return .newTerminalTab
        case "o": return .openFinder
        case "p": return .openProjects
        case "m": return .toggleMic
        case "n": return .renameTab
        case "/": return .splitRight
        case "-": return .splitDown
        case "h": return .focus(.left)
        case "j": return .focus(.down)
        case "k": return .focus(.up)
        case "l": return .focus(.right)
        case "x": return .closePane
        case "z": return .toggleZen
        case "1"..."9": return .selectTab(Int(String(key))! - 1)
        default: return nil
        }
    }

    private func activate() {
        active = true
        showPalette()
    }

    private func deactivate() {
        active = false
        palette?.removeFromSuperview()
        palette = nil
    }

    // MARK: - Command palette

    private func showPalette() {
        guard let host = hostView, palette == nil else { return }

        // Destinations/projects (config-driven) form the "Go" group.
        var go = destinations.map { LeaderPalette.Item(key: String($0.key), label: $0.title) }
        go += [LeaderPalette.Item(key: "p", label: "Projects"),
               LeaderPalette.Item(key: "o", label: "Find file")]

        let panes = LeaderPalette.Group(title: "Panes", items: [
            .init(key: "/", label: "Split right"),
            .init(key: "-", label: "Split down"),
            .init(key: "h j k l", label: "Focus"),
            .init(key: "x", label: "Close pane"),
        ])
        let tabs = LeaderPalette.Group(title: "Tabs", items: [
            .init(key: "t", label: "New tab"),
            .init(key: "n", label: "Name tab"),
            .init(key: "1–9", label: "Switch tab"),
        ])
        let more = LeaderPalette.Group(title: "More", items: [
            .init(key: "m", label: "Dictate"),
            .init(key: "z", label: "Zen mode"),
        ])

        let columns: [[LeaderPalette.Group]] = [
            [LeaderPalette.Group(title: "Go", items: go)],
            [panes, more],
            [tabs],
        ]

        let p = LeaderPalette(frame: host.bounds, title: "Commands", columns: columns)
        host.addSubview(p)
        palette = p
    }
}
