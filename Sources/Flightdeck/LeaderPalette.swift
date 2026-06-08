import AppKit

/// A modern grid command-palette shown while the leader key is active. Groups of
/// commands in columns, each with a key badge — press a key to run it.
final class LeaderPalette: NSView {
    struct Item { let key: String; let label: String }
    struct Group { let title: String; let items: [Item] }

    private static func col(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    private static let base    = col(30, 30, 46)
    private static let surface = col(49, 50, 68)
    private static let surface1 = col(69, 71, 90)
    private static let text    = col(205, 214, 244)
    private static let subtext = col(166, 173, 200)
    private static let mauve   = col(203, 166, 247)

    /// `columns` is a list of columns; each column is a list of groups (stacked).
    init(frame: NSRect, title: String, columns: [[Group]]) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.45).cgColor

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

        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .bold)
        header.textColor = Self.mauve
        header.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(labelWithString: "press a key  ·  esc to close")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Self.subtext
        footer.translatesAutoresizingMaskIntoConstraints = false

        // Columns of groups.
        let columnViews = columns.map { groups -> NSStackView in
            let colStack = NSStackView(views: groups.map(Self.makeGroup))
            colStack.orientation = .vertical
            colStack.alignment = .leading
            colStack.spacing = 18
            return colStack
        }
        let grid = NSStackView(views: columnViews)
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.distribution = .fillEqually
        grid.spacing = 36
        grid.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(header)
        panel.addSubview(grid)
        panel.addSubview(footer)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),

            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),

            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            grid.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),

            footer.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            footer.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks pass through

    private static func makeGroup(_ group: Group) -> NSView {
        let title = NSTextField(labelWithString: group.title.uppercased())
        title.font = .systemFont(ofSize: 10, weight: .heavy)
        title.textColor = subtext
        let rows = group.items.map(makeRow)
        let stack = NSStackView(views: [title] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(9, after: title)
        return stack
    }

    private static func makeRow(_ item: Item) -> NSView {
        // Key badge
        let keyLabel = NSTextField(labelWithString: item.key)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keyLabel.textColor = text
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = surface1.cgColor
        badge.layer?.cornerRadius = 6
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(keyLabel)

        let label = NSTextField(labelWithString: item.label)
        label.font = .systemFont(ofSize: 13)
        label.textColor = text

        let row = NSStackView(views: [badge, label])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: 24),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            keyLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            keyLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            keyLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        return row
    }
}
