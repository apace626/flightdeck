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
    case splitCodex            // split + run codex in the focused pane's dir
    case focus(Direction)
    case closePane
    case selectTab(Int)
    case cycleTab(Int)         // +1 next, -1 previous (wraps)
    case toggleZen
}

/// Ctrl+Space opens the command launcher (a searchable list of all destinations,
/// projects, and actions — Spotlight-style). Every other keystroke passes through
/// to the focused pane untouched.
final class LeaderController {
    private let handler: (LeaderAction) -> Void
    private var monitor: Any?
    private static let spaceKeyCode: UInt16 = 49

    // Double-tap either Option key (no other key/modifier) → toggle dictation.
    private var lastOptionTap: TimeInterval = 0
    private var optionTapCandidate = false
    private static let doubleTapWindow: TimeInterval = 0.4

    init(hostView: NSView, handler: @escaping (LeaderAction) -> Void) {
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == Self.spaceKeyCode && event.modifierFlags.contains(.control) {
                    self.handler(.openLauncher)
                    return nil
                }
                self.optionTapCandidate = false   // a key pressed during an Option hold = chord, not a tap
                // Option + ←/→ cycles tabs (wraps). Overrides the terminal's
                // Option+arrow word-jump — by request.
                if event.modifierFlags.contains(.option),
                   event.modifierFlags.isDisjoint(with: [.command, .control]) {
                    if event.keyCode == 123 { self.handler(.cycleTab(-1)); return nil }   // ←
                    if event.keyCode == 124 { self.handler(.cycleTab(1));  return nil }   // →
                }
                return event
            case .flagsChanged:
                self.handleFlags(event)
                return event
            default:
                return event
            }
        }
    }

    /// A "tap" is Option pressed then released with no other key or modifier in
    /// between; two taps within the window fire dictation. keyCode 58/61 = L/R Option.
    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == 58 || event.keyCode == 61 else { return }
        if event.modifierFlags.contains(.option) {              // pressed
            let others: NSEvent.ModifierFlags = [.command, .control, .shift, .function]
            optionTapCandidate = event.modifierFlags.isDisjoint(with: others)
        } else {                                                 // released
            if optionTapCandidate {
                if event.timestamp - lastOptionTap < Self.doubleTapWindow {
                    lastOptionTap = 0
                    handler(.toggleMic)
                } else {
                    lastOptionTap = event.timestamp
                }
            }
            optionTapCandidate = false
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
