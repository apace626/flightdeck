import AppKit

protocol WorkspaceDelegate: AnyObject {
    /// The last pane in this workspace closed.
    func workspaceDidBecomeEmpty(_ workspace: Workspace)
    func workspace(_ workspace: Workspace, paneTitleChanged title: String)
}

enum Direction {
    case left, right, up, down
}

/// NSSplitView with a divider that's actually visible between dark panes.
/// Optionally applies a one-time set of proportional divider positions on first layout.
final class PaneSplitView: NSSplitView {
    override var dividerColor: NSColor {
        NSColor(calibratedWhite: 0.35, alpha: 1.0)
    }

    override var dividerThickness: CGFloat { 2 }

    /// Fractions per child (sum ≈ 1). Applied once when the view first has a real size.
    var desiredRatios: [CGFloat]?
    private var ratiosApplied = false

    override func layout() {
        super.layout()
        guard let ratios = desiredRatios, !ratiosApplied,
              bounds.width > 1, bounds.height > 1,
              arrangedSubviews.count >= 2 else { return }
        ratiosApplied = true
        let total = isVertical ? bounds.width : bounds.height
        var acc: CGFloat = 0
        for i in 0..<(arrangedSubviews.count - 1) {
            acc += (ratios[safe: i] ?? (1.0 / CGFloat(arrangedSubviews.count))) * total
            setPosition(acc, ofDividerAt: i)
        }
    }
}

/// Declarative description of a pane tree — the spec's layout format (§4.2).
indirect enum PaneSpec {
    case terminal(command: String?, cwd: String? = nil, env: [String: String] = [:], keepAlive: Bool = false)
    case web(URL)
    /// `vertical == true` → side-by-side columns; `false` → stacked rows.
    case split(vertical: Bool, ratios: [CGFloat], children: [PaneSpec])
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// One tab's content: an i3-style tree of panes built from nested NSSplitViews.
final class Workspace: NSView {
    weak var delegate: WorkspaceDelegate?
    private var root: NSView

    private init(rootView: NSView, terminals: [TerminalPane]) {
        root = rootView
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 760))
        installRoot(rootView)
        terminals.forEach { hook($0) }
    }

    convenience init(initialPane: PaneView) {
        let terms = (initialPane as? TerminalPane).map { [$0] } ?? []
        self.init(rootView: initialPane, terminals: terms)
    }

    /// Build a multi-pane workspace from a declarative spec.
    convenience init(spec: PaneSpec) {
        var terms: [TerminalPane] = []
        let view = Workspace.build(spec, into: &terms)
        self.init(rootView: view, terminals: terms)
    }

    /// Convenience: workspace with a fresh shell.
    convenience init() {
        self.init(initialPane: TerminalPane())
    }

    private static func build(_ spec: PaneSpec, into terms: inout [TerminalPane]) -> NSView {
        switch spec {
        case .terminal(let command, let cwd, let env, let keepAlive):
            let pane = TerminalPane(command: command, workingDirectory: cwd, extraEnv: env, keepAlive: keepAlive)
            terms.append(pane)
            return pane
        case .web(let url):
            return WebPane(url: url)
        case .split(let vertical, let ratios, let children):
            let split = PaneSplitView()
            split.isVertical = vertical
            split.dividerStyle = .thin
            split.desiredRatios = ratios
            for child in children {
                split.addArrangedSubview(build(child, into: &terms))
            }
            return split
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func installRoot(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        root = view
    }

    private func hook(_ pane: PaneView) {
        guard let term = pane as? TerminalPane else { return }
        term.onExit = { [weak self] p in
            DispatchQueue.main.async { self?.close(p) }
        }
        term.onTitle = { [weak self] title in
            guard let self else { return }
            self.delegate?.workspace(self, paneTitleChanged: title)
        }
    }

    // MARK: - Queries

    func allPanes() -> [PaneView] {
        var result: [PaneView] = []
        func walk(_ view: NSView) {
            if let pane = view as? PaneView {
                result.append(pane)
            } else if let split = view as? NSSplitView {
                split.arrangedSubviews.forEach(walk)
            }
        }
        walk(root)
        return result
    }

    func focusedPane() -> PaneView? {
        var responder = window?.firstResponder as? NSView
        while let view = responder {
            if let pane = view as? PaneView, pane.isDescendant(of: self) {
                return pane
            }
            responder = view.superview
        }
        return allPanes().first
    }

    func focusInitial() {
        allPanes().first?.takeFocus()
    }

    // MARK: - Split / close

    /// Split the focused pane. `vertical: true` = side-by-side (vertical divider).
    func splitFocused(vertical: Bool) {
        guard let pane = focusedPane() else { return }
        let newPane = TerminalPane()
        hook(newPane)

        let split = PaneSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin

        replaceInParent(pane, with: split)
        split.addArrangedSubview(pane)
        split.addArrangedSubview(newPane)

        // Even 50/50 once the split view has its real size.
        DispatchQueue.main.async {
            let total = vertical ? split.bounds.width : split.bounds.height
            split.setPosition(total / 2, ofDividerAt: 0)
            newPane.takeFocus()
        }
    }

    func closeFocused() {
        guard let pane = focusedPane() else { return }
        close(pane)
    }

    /// Kill every terminal pane's process tree (on tab/app close).
    func terminateAll() {
        for case let term as TerminalPane in allPanes() {
            term.terminateProcessTree()
        }
    }

    private func close(_ pane: PaneView) {
        (pane as? TerminalPane)?.terminateProcessTree()
        guard let split = pane.superview as? NSSplitView else {
            // Root pane — workspace is now empty.
            delegate?.workspaceDidBecomeEmpty(self)
            return
        }
        split.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        // Intentionally do NOT collapse a single-child split: reparenting the
        // survivor leaves its SwiftTerm view blank. A lone child fills the split.
        refocusAfterMutation()
    }

    /// Restore focus + force a redraw on the surviving pane after a layout change.
    private func refocusAfterMutation() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pane = self.allPanes().last else { return }
            (pane as? TerminalPane)?.terminal.needsDisplay = true
            pane.takeFocus()
        }
    }

    private func replaceInParent(_ old: NSView, with new: NSView) {
        if let split = old.superview as? NSSplitView {
            guard let index = split.arrangedSubviews.firstIndex(of: old) else { return }
            split.removeArrangedSubview(old)
            old.removeFromSuperview()
            split.insertArrangedSubview(new, at: index)
        } else {
            // `old` is the root.
            old.removeFromSuperview()
            installRoot(new)
        }
    }

    // MARK: - Directional focus (i3-style h/j/k/l)

    func focusNeighbor(_ direction: Direction) {
        let panes = allPanes()
        guard panes.count > 1, let current = focusedPane() else { return }

        let currentFrame = current.convert(current.bounds, to: self)
        let center = NSPoint(x: currentFrame.midX, y: currentFrame.midY)

        var best: (pane: PaneView, distance: CGFloat)?
        for pane in panes where pane !== current {
            let frame = pane.convert(pane.bounds, to: self)
            let dx = frame.midX - center.x
            let dy = frame.midY - center.y

            // Non-flipped view: +y is up.
            let matches: Bool
            switch direction {
            case .left:  matches = dx < -1
            case .right: matches = dx > 1
            case .up:    matches = dy > 1
            case .down:  matches = dy < -1
            }
            guard matches else { continue }

            let distance = abs(dx) + abs(dy)
            if best == nil || distance < best!.distance {
                best = (pane, distance)
            }
        }
        best?.pane.takeFocus()
    }
}
