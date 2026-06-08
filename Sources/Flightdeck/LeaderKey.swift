import AppKit

enum LeaderAction {
    case openLauncher          // Ctrl+Space → searchable launcher
    case newTerminalTab
    case openFinder
    case toggleMic
    case renameTab
    case goto(String)          // destination or project name
    case splitRight
    case splitDown
    case focus(Direction)
    case closePane
    case selectTab(Int)
    case toggleZen
}

/// Ctrl+Space opens the command launcher (a searchable list of all destinations,
/// projects, and actions — Spotlight-style). Every other keystroke passes through
/// to the focused pane untouched.
final class LeaderController {
    private let handler: (LeaderAction) -> Void
    private var monitor: Any?
    private static let spaceKeyCode: UInt16 = 49

    init(hostView: NSView, handler: @escaping (LeaderAction) -> Void) {
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == Self.spaceKeyCode && event.modifierFlags.contains(.control) {
                self.handler(.openLauncher)
                return nil
            }
            return event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
