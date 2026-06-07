import AppKit
import Quartz
import UniformTypeIdentifiers

protocol FinderOverlayDelegate: AnyObject {
    func finder(_ finder: FinderOverlay, openInEditor url: URL)
    func finder(_ finder: FinderOverlay, openDirectory url: URL, asShell: Bool)
    func finderDidClose(_ finder: FinderOverlay)
}

/// Telescope-style fuzzy file finder with a native Quick Look preview pane.
/// Enter routes by type: text → editor tab, everything else → system viewer.
///
/// Two presentations:
///   .overlay  — floating panel over a dimmed backdrop (leader+o); closes on open/Esc/click-out.
///   .embedded — fills its container as a persistent tab (the Files destination); never closes.
final class FinderOverlay: PaneView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Style { case overlay, embedded }

    weak var delegate: FinderOverlayDelegate?
    private let style: Style

    private let field = NSTextField()
    private let table = NSTableView()
    private var preview: QLPreviewView?
    private let countLabel = NSTextField(labelWithString: "")

    struct Entry {
        let url: URL
        let isDirectory: Bool
    }

    private var matches: [Entry] = []
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    // Session-wide index cache so reopening the finder is instant.
    private static var index: [Entry] = []
    private static var indexBuilt = false
    private static var indexing = false

    // Extensions that always open in the editor even when UTType doesn't know them.
    private static let editorExtensions: Set<String> = [
        "toml", "md", "txt", "json", "yml", "yaml", "swift", "js", "ts", "tsx", "jsx",
        "py", "sh", "zsh", "rb", "go", "rs", "c", "h", "cpp", "hpp", "lua", "kdl",
        "conf", "cfg", "ini", "xml", "html", "css", "scss", "sql", "env", "log", "csv",
    ]

    // MARK: - Setup

    init(frame: NSRect, roots: [String], style: Style = .overlay) {
        self.style = style
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = (style == .overlay)
            ? NSColor(calibratedWhite: 0, alpha: 0.55).cgColor   // dimmed backdrop
            : NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor // solid tab background

        buildPanel()
        buildIndexIfNeeded(roots: roots)
        refilter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func takeFocus() {
        focusField()
    }

    private func buildPanel() {
        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.state = .active
        panel.blendingMode = .withinWindow
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        field.placeholderString = (style == .overlay)
            ? "Find a file or folder…  (Enter open · ⌘Enter editor/shell · Esc close)"
            : "Find a file or folder…  (Enter open · ⌘Enter editor/shell)"
        field.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let ql = QLPreviewView(frame: .zero, style: .normal)
        ql?.shouldCloseWithWindow = false
        ql?.translatesAutoresizingMaskIntoConstraints = false
        preview = ql

        countLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(field)
        panel.addSubview(scroll)
        panel.addSubview(countLabel)
        if let ql { panel.addSubview(ql) }

        if style == .overlay {
            panel.layer?.cornerRadius = 10
            NSLayoutConstraint.activate([
                panel.centerXAnchor.constraint(equalTo: centerXAnchor),
                panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
                panel.widthAnchor.constraint(lessThanOrEqualToConstant: 980),
                panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.85).withPriority(.defaultHigh),
                panel.heightAnchor.constraint(equalToConstant: 520),
            ])
        } else {
            // Embedded: fill the tab edge-to-edge.
            panel.layer?.cornerRadius = 0
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: topAnchor),
                panel.leadingAnchor.constraint(equalTo: leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            scroll.widthAnchor.constraint(equalTo: panel.widthAnchor, multiplier: 0.45),
            scroll.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -6),

            countLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            countLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])

        if let ql {
            NSLayoutConstraint.activate([
                ql.topAnchor.constraint(equalTo: scroll.topAnchor),
                ql.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 12),
                ql.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
                ql.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
            ])
        }
    }

    func focusField() {
        window?.makeFirstResponder(field)
    }

    // Click on the dimmed backdrop closes the overlay (not the embedded tab).
    override func mouseDown(with event: NSEvent) {
        if style == .overlay { close() }
    }

    private func close() {
        guard style == .overlay else { return } // embedded finder is permanent
        removeFromSuperview()
        delegate?.finderDidClose(self)
    }

    // MARK: - Index

    private func buildIndexIfNeeded(roots: [String]) {
        guard !Self.indexBuilt, !Self.indexing else { return }
        Self.indexing = true
        countLabel.stringValue = "indexing…"

        DispatchQueue.global(qos: .userInitiated).async {
            let files = Self.scan(roots: roots)
            DispatchQueue.main.async { [weak self] in
                Self.index = files
                Self.indexBuilt = true
                Self.indexing = false
                self?.refilter()
            }
        }
    }

    private static func scan(roots: [String]) -> [Entry] {
        let fm = FileManager.default
        let skip: Set<String> = [
            "node_modules", ".git", ".build", ".cache", ".npm", ".cargo", ".venv",
            "venv", "__pycache__", "DerivedData", "Pods", "Library", "vendor", "dist",
        ]
        var out: [Entry] = []
        for root in roots {
            let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
            out.append(Entry(url: url, isDirectory: true)) // the root itself is jumpable
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if skip.contains(item.lastPathComponent) {
                        enumerator.skipDescendants()
                    } else {
                        out.append(Entry(url: item, isDirectory: true))
                    }
                } else if values?.isRegularFile == true {
                    out.append(Entry(url: item, isDirectory: false))
                }
                if out.count >= 100_000 { return out }
            }
        }
        return out
    }

    // MARK: - Fuzzy matching

    /// Subsequence match with bonuses for word starts and runs; nil = no match.
    private static func score(query: [Character], path: String) -> Int? {
        if query.isEmpty { return 0 }
        let chars = Array(path.lowercased())
        var qi = 0
        var total = 0
        var run = 0
        for (i, ch) in chars.enumerated() {
            guard qi < query.count else { break }
            if ch == query[qi] {
                run += 1
                let wordStart = i == 0 || chars[i - 1] == "/" || chars[i - 1] == "." || chars[i - 1] == "_" || chars[i - 1] == "-"
                total += 1 + run * 2 + (wordStart ? 6 : 0)
                qi += 1
            } else {
                run = 0
            }
        }
        guard qi == query.count else { return nil }
        return total - chars.count / 8 // mild preference for shorter paths
    }

    private func refilter() {
        let query = Array(field.stringValue.lowercased().filter { $0 != " " })
        let index = Self.index

        if query.isEmpty {
            matches = Array(index.prefix(100))
        } else {
            var scored: [(Entry, Int)] = []
            scored.reserveCapacity(256)
            for entry in index {
                let relative = String(entry.url.path.dropFirst(home.count + 1))
                if let s = Self.score(query: query, path: relative) {
                    scored.append((entry, s))
                }
            }
            scored.sort { $0.1 > $1.1 }
            matches = scored.prefix(100).map(\.0)
        }

        countLabel.stringValue = Self.indexing
            ? "indexing…"
            : "\(matches.count) shown · \(index.count) indexed"
        table.reloadData()
        if !matches.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updatePreview()
    }

    private func updatePreview() {
        let row = table.selectedRow
        preview?.previewItem = (matches.indices.contains(row) ? matches[row].url as NSURL : nil)
    }

    // MARK: - Open routing

    private func openSelection(forceEditor: Bool) {
        let row = table.selectedRow
        guard matches.indices.contains(row) else { return }
        let entry = matches[row]
        close() // no-op when embedded — the Files tab stays put after opening

        if entry.isDirectory {
            // Open the directory as a shell tab scoped there.
            delegate?.finder(self, openDirectory: entry.url, asShell: true)
        } else if forceEditor || Self.opensInEditor(entry.url) {
            delegate?.finder(self, openInEditor: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private static func opensInEditor(_ url: URL) -> Bool {
        if editorExtensions.contains(url.pathExtension.lowercased()) { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return type?.conforms(to: .text) ?? false
    }

    @objc private func rowDoubleClicked() {
        openSelection(forceEditor: false)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        refilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelection(forceEditor: NSEvent.modifierFlags.contains(.command))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if style == .overlay { close(); return true }
            field.stringValue = ""   // embedded: Esc just clears the query
            refilter()
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updatePreview()
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let label = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let l = NSTextField(labelWithString: "")
            l.identifier = id
            l.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            l.lineBreakMode = .byTruncatingHead
            return l
        }()
        let entry = matches[row]
        let relative = String(entry.url.path.dropFirst(home.count + 1))
        label.stringValue = entry.isDirectory ? relative + "/" : relative
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
