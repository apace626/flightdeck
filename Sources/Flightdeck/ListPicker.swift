import AppKit

/// A modern command-palette-style fuzzy picker (Catppuccin themed). Used for the
/// project picker (leader+p); reusable for a future command palette.
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

    // Catppuccin Mocha
    private static func col(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    private static let base    = col(30, 30, 46)
    private static let surface = col(49, 50, 68)
    private static let surface1 = col(69, 71, 90)
    private static let text    = col(205, 214, 244)
    private static let subtext = col(166, 173, 200)
    private static let mauve   = col(203, 166, 247)
    private static let overlay = col(108, 112, 134)
    private static let tileColors = [
        col(137, 180, 250), col(166, 227, 161), col(243, 139, 168),
        col(203, 166, 247), col(250, 179, 135), col(148, 226, 213),
    ]

    init(frame: NSRect, placeholder: String, items: [Item]) {
        self.allItems = items
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.45).cgColor

        // Panel
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Self.base.cgColor
        panel.layer?.cornerRadius = 16
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Self.surface1.cgColor
        panel.shadow = NSShadow()
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.45
        panel.layer?.shadowRadius = 30
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // Search row: magnifier + field
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glyph.contentTintColor = Self.overlay
        glyph.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 17, weight: .regular)
        field.textColor = Self.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        if let cell = field.cell as? NSTextFieldCell {
            cell.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: Self.overlay, .font: NSFont.systemFont(ofSize: 17)])
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Self.surface.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        panel.addSubview(glyph)
        panel.addSubview(field)
        panel.addSubview(divider)
        panel.addSubview(scroll)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            panel.widthAnchor.constraint(equalToConstant: 600),
            panel.heightAnchor.constraint(equalToConstant: 460),

            glyph.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            glyph.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),

            field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),

            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])

        refilter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusField() { window?.makeFirstResponder(field) }

    override func mouseDown(with event: NSEvent) { close() }

    private func close() { removeFromSuperview(); onClose?() }

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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PickerRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = matches[row]
        let cell = (tableView.makeView(withIdentifier: PickerCell.id, owner: nil) as? PickerCell) ?? PickerCell()
        cell.configure(item, tile: Self.tileColors[stableHash(item.title) % Self.tileColors.count],
                       text: Self.text, subtext: Self.subtext, badgeBg: Self.surface1, badgeFg: Self.subtext)
        return cell
    }

    private func stableHash(_ s: String) -> Int {
        var h = 0
        for u in s.unicodeScalars { h = h &* 31 &+ Int(u.value) }
        return abs(h)
    }
}

/// Rounded, inset selection highlight (Catppuccin surface).
private final class PickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 6, dy: 3)
        NSColor(srgbRed: 49 / 255, green: 50 / 255, blue: 68 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
    }
}

/// A picker row: colored initial tile + title/subtitle + optional key badge.
private final class PickerCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("PickerCell")

    private let tile = NSView()
    private let initial = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.id

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 9
        tile.translatesAutoresizingMaskIntoConstraints = false
        initial.font = .systemFont(ofSize: 16, weight: .bold)
        initial.textColor = NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 1)
        initial.alignment = .center
        initial.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(initial)

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)

        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(texts)
        addSubview(badge)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 38),
            tile.heightAnchor.constraint(equalToConstant: 38),
            initial.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: tile.centerYAnchor),

            texts.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 22),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            badgeLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            badgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ item: ListPicker.Item, tile tileColor: NSColor,
                   text: NSColor, subtext: NSColor, badgeBg: NSColor, badgeFg: NSColor) {
        tile.layer?.backgroundColor = tileColor.cgColor
        initial.stringValue = String(item.title.prefix(1)).uppercased()
        title.stringValue = item.title
        title.textColor = text
        subtitle.stringValue = item.subtitle
        subtitle.textColor = subtext
        if let key = item.keyHint {
            badge.isHidden = false
            badge.layer?.backgroundColor = badgeBg.cgColor
            badgeLabel.stringValue = key
            badgeLabel.textColor = badgeFg
        } else {
            badge.isHidden = true
        }
    }
}
