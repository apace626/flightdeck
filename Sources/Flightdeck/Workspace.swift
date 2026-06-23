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

    /// Re-tile the surviving children evenly after a pane closes (the original
    /// ratios no longer apply once a child is gone). Forces a real resize so the
    /// survivors' terminals repaint into the freed space.
    func retile() {
        desiredRatios = nil
        ratiosApplied = true
        adjustSubviews()
        layoutSubtreeIfNeeded()
    }

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
    case terminal(command: String?, cwd: String? = nil, env: [String: String] = [:], keepAlive: Bool = false, hideCursor: Bool = false)
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
    private let content = NSView()              // hosts the pane tree
    private let statusBar: StatusBarView?
    private var statusTimer: Timer?

    private init(rootView: NSView, terminals: [TerminalPane],
                 statusBar sb: (command: String, cwd: String)?) {
        root = rootView
        statusBar = sb != nil ? StatusBarView() : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 760))

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        if let bar = statusBar, let sb {
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: 26),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.bottomAnchor.constraint(equalTo: bar.topAnchor),
            ])
            startStatus(command: sb.command, cwd: sb.cwd)
        } else {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        installRoot(rootView)
        terminals.forEach { hook($0) }
    }

    deinit { statusTimer?.invalidate() }

    convenience init(initialPane: PaneView) {
        let terms = (initialPane as? TerminalPane).map { [$0] } ?? []
        self.init(rootView: initialPane, terminals: terms, statusBar: nil)
    }

    /// Build a multi-pane workspace from a declarative spec, with an optional
    /// bottom status bar (a shell command run periodically in `cwd`).
    convenience init(spec: PaneSpec, statusBar: (command: String, cwd: String)? = nil) {
        var terms: [TerminalPane] = []
        let view = Workspace.build(spec, into: &terms)
        self.init(rootView: view, terminals: terms, statusBar: statusBar)
    }

    /// Convenience: workspace with a fresh shell.
    convenience init() {
        self.init(initialPane: TerminalPane())
    }

    /// Build a split workspace from already-constructed panes (so the caller can
    /// keep references to them — e.g. a live preview pane it updates later).
    convenience init(splitVertical: Bool, ratios: [CGFloat], panes: [PaneView]) {
        let split = PaneSplitView()
        split.isVertical = splitVertical
        split.dividerStyle = .thin
        split.desiredRatios = ratios
        panes.forEach { split.addArrangedSubview($0) }
        self.init(rootView: split, terminals: panes.compactMap { $0 as? TerminalPane }, statusBar: nil)
    }

    // MARK: - Status bar

    private func startStatus(command: String, cwd: String) {
        let dir = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let run: () -> Void = { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", "cd '\(dir)' && \(command)"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                var text = ""
                do {
                    try proc.run()
                    let d = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    text = String(data: d, encoding: .utf8) ?? ""
                } catch {}
                let line = text.split(separator: "\n").first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                DispatchQueue.main.async { self?.statusBar?.setText(line) }
            }
        }
        run()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in run() }
    }

    private static func build(_ spec: PaneSpec, into terms: inout [TerminalPane]) -> NSView {
        switch spec {
        case .terminal(let command, let cwd, let env, let keepAlive, let hideCursor):
            let pane = TerminalPane(command: command, workingDirectory: cwd, extraEnv: env, keepAlive: keepAlive, hideCursor: hideCursor)
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
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
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

    private weak var lastFocusedPane: PaneView?

    func focusedPane() -> PaneView? {
        var responder = window?.firstResponder as? NSView
        while let view = responder {
            if let pane = view as? PaneView, pane.isDescendant(of: self) {
                lastFocusedPane = pane          // remember the real focused pane
                return pane
            }
            responder = view.superview
        }
        // First responder isn't one of our panes — e.g. the launcher overlay
        // grabbed it. Fall back to the pane that was last actually focused, so a
        // split/codex action opened from the launcher acts on the pane you were
        // in (not always the first one).
        if let last = lastFocusedPane, last.isDescendant(of: self) { return last }
        return allPanes().first
    }

    func focusInitial() {
        allPanes().first?.takeFocus()
    }

    /// Re-layout and force every terminal to reflow + repaint. Used when the
    /// window's screen or backing scale changes (laptop ↔ external monitor),
    /// which otherwise leaves the active tab's panes stale until you switch tabs.
    func relayoutAndRepaint() {
        layoutSubtreeIfNeeded()
        for case let term as TerminalPane in allPanes() {
            let tv = term.terminal
            let s = tv.frame.size
            tv.setFrameSize(NSSize(width: s.width, height: max(1, s.height - 1)))
            tv.setFrameSize(s)   // nudge → SwiftTerm reflows + SIGWINCH + repaints
            tv.needsDisplay = true
        }
    }

    // MARK: - Split / close

    /// Split the focused pane. `vertical: true` = side-by-side (vertical divider).
    func splitFocused(vertical: Bool, command: String? = nil) {
        guard let pane = focusedPane() else { return }
        // New pane inherits the focused pane's directory (so a codex/review split
        // opens "here"). keepAlive when running a command so quitting it drops to
        // a shell rather than closing the pane.
        let cwd = (pane as? TerminalPane)?.currentDirectory
        let newPane = TerminalPane(command: command, workingDirectory: cwd, keepAlive: command != nil)
        hook(newPane)

        // Capture the PARENT split's divider positions: swapping `pane` for a new
        // sub-split makes NSSplitView redistribute the parent (shoving e.g. the
        // claude | diff divider over), so we restore them after.
        let parentSplit = pane.superview as? NSSplitView
        let savedDividers: [CGFloat] = parentSplit.map { ps in
            guard ps.arrangedSubviews.count >= 2 else { return [] }
            return (0..<(ps.arrangedSubviews.count - 1)).map { i in
                ps.isVertical ? ps.arrangedSubviews[i].frame.maxX : ps.arrangedSubviews[i].frame.maxY
            }
        } ?? []

        let split = PaneSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        // Apply 50/50 on the split's FIRST real layout (same mechanism the static
        // layouts use). The old `setPosition(bounds/2)` ran before the split was
        // sized, so bounds was 0 → one pane collapsed to nothing.
        split.desiredRatios = [0.5, 0.5]

        replaceInParent(pane, with: split)
        split.addArrangedSubview(pane)
        split.addArrangedSubview(newPane)

        // Once layout settles: restore the parent's dividers (so the existing
        // panes don't move), repaint the reparented pane, focus the new one.
        DispatchQueue.main.async { [weak self] in
            self?.layoutSubtreeIfNeeded()
            if let ps = parentSplit {
                for (i, pos) in savedDividers.enumerated() { ps.setPosition(pos, ofDividerAt: i) }
            }
            (pane as? TerminalPane)?.terminal.needsDisplay = true
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
        if split.arrangedSubviews.count == 1 {
            // Collapse the now-redundant split: promote the lone survivor into the
            // grandparent so it gets a real full-size slot (a single child left in a
            // split does NOT reliably re-tile). layout() then repaints it.
            let survivor = split.arrangedSubviews[0]
            split.removeArrangedSubview(survivor)
            survivor.removeFromSuperview()
            replaceInParent(split, with: survivor)
        } else {
            (split as? PaneSplitView)?.retile()
        }
        refocusAfterMutation()
    }

    /// Re-layout + force a redraw on the surviving panes after a layout change.
    private func refocusAfterMutation() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            for case let term as TerminalPane in self.allPanes() {
                term.terminal.needsDisplay = true
            }
            self.allPanes().last?.takeFocus()
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

/// A thin bottom status bar showing a single line of text (e.g., git status).
final class StatusBarView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 49 / 255, green: 50 / 255, blue: 68 / 255, alpha: 1).cgColor

        // Use the configured terminal (Nerd) font so glyphs like  render.
        label.font = NSFont(name: TerminalPane.preferredFont.fontName, size: 11)
            ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(srgbRed: 166 / 255, green: 173 / 255, blue: 200 / 255, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(srgbRed: 24 / 255, green: 24 / 255, blue: 37 / 255, alpha: 1).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setText(_ s: String) { label.stringValue = s }
}
