import AppKit

enum LeaderAction {
    case newTerminalTab
    case openFinder
    case openProjects          // project picker (leader+p)
    case toggleMic             // mic visualizer (leader+m)
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
    private var sticky = false // '?' keeps the HUD open
    private var hud: NSView?

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

        if key == "?" {
            sticky = true
            return
        }

        let action = builtinAction(for: key)
            ?? destinations.first { $0.key == key }.map { LeaderAction.goto($0.name) }

        if sticky && action == nil {
            return // unknown key while help is pinned: stay open
        }
        deactivate()
        if let action { handler(action) }
    }

    private func builtinAction(for key: Character) -> LeaderAction? {
        switch key {
        case "t": return .newTerminalTab
        case "o": return .openFinder
        case "p": return .openProjects
        case "m": return .toggleMic
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
        showHUD()
    }

    private func deactivate() {
        active = false
        sticky = false
        hud?.removeFromSuperview()
        hud = nil
    }

    // MARK: - Which-key HUD

    private func showHUD() {
        guard let host = hostView, hud == nil else { return }

        var parts = ["t new tab", "o find file", "p projects", "m mic"]
        parts += destinations.map { "\($0.key) \($0.title.lowercased())" }
        parts += ["/ split →", "- split ↓", "h j k l focus", "x close", "1-9 tab", "z zen", "? pin", "esc cancel"]
        let bindings = parts.joined(separator: "    ")

        let label = NSTextField(labelWithString: bindings)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8

        label.translatesAutoresizingMaskIntoConstraints = false
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)

        host.addSubview(effect)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
            effect.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            effect.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -24),
        ])
        hud = effect
    }
}
