import AppKit

/// A lightweight fuzzy list overlay — pick one of N items. Reused for the project
/// picker (leader+p) and, later, the command palette. No preview pane.
final class ListPicker: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let id: String
        let title: String
        let subtitle: String
        let keyHint: String?
    }

    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let table = NSTableView()
    private let allItems: [Item]
    private var matches: [Item] = []

    init(frame: NSRect, placeholder: String, items: [Item]) {
        self.allItems = items
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor

        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.state = .active
        panel.blendingMode = .withinWindow
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        field.placeholderString = placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
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

        panel.addSubview(field)
        panel.addSubview(scroll)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            panel.widthAnchor.constraint(equalToConstant: 560),
            panel.heightAnchor.constraint(equalToConstant: 420),

            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])

        refilter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusField() { window?.makeFirstResponder(field) }

    override func mouseDown(with event: NSEvent) { close() }

    private func close() {
        removeFromSuperview()
        onClose?()
    }

    // MARK: - Filtering

    private func refilter() {
        let q = field.stringValue.lowercased().filter { $0 != " " }
        if q.isEmpty {
            matches = allItems
        } else {
            matches = allItems
                .compactMap { item -> (Item, Int)? in
                    let hay = (item.title + " " + item.subtitle).lowercased()
                    guard let s = Self.score(Array(q), hay) else { return nil }
                    return (item, s)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        table.reloadData()
        if !matches.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private static func score(_ query: [Character], _ hay: String) -> Int? {
        if query.isEmpty { return 0 }
        let chars = Array(hay)
        var qi = 0, total = 0, run = 0
        for (i, ch) in chars.enumerated() {
            guard qi < query.count else { break }
            if ch == query[qi] {
                run += 1
                let boundary = i == 0 || chars[i - 1] == " " || chars[i - 1] == "/" || chars[i - 1] == "-"
                total += 1 + run * 2 + (boundary ? 5 : 0)
                qi += 1
            } else { run = 0 }
        }
        return qi == query.count ? total : nil
    }

    private func choose() {
        let row = table.selectedRow
        guard matches.indices.contains(row) else { return }
        let id = matches[row].id
        close()
        onSelect?(id)
    }

    @objc private func rowDoubleClicked() { choose() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = matches[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSStackView) ?? {
            let title = NSTextField(labelWithString: "")
            title.identifier = NSUserInterfaceItemIdentifier("title")
            title.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            title.textColor = .white
            let sub = NSTextField(labelWithString: "")
            sub.identifier = NSUserInterfaceItemIdentifier("sub")
            sub.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            sub.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [title, sub])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.identifier = id
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
            return stack
        }()
        if let title = cell.views.first(where: { $0.identifier?.rawValue == "title" }) as? NSTextField {
            title.stringValue = item.keyHint.map { "[\($0)]  \(item.title)" } ?? item.title
        }
        if let sub = cell.views.first(where: { $0.identifier?.rawValue == "sub" }) as? NSTextField {
            sub.stringValue = item.subtitle
        }
        return cell
    }
}
