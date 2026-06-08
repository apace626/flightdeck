import AppKit

/// Top tab strip. Active tab is a rounded highlight with an × close button;
/// roomy spacing; minimalist Catppuccin styling. A trailing + opens a new tab.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onClose: ((Int) -> Void)?

    private let stack = NSStackView()

    private static func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    private static let barBg   = c(24, 24, 37)    // crust
    private static let active  = c(49, 50, 68)    // surface0
    private static let text    = c(205, 214, 244)
    private static let dim     = c(127, 132, 156)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.barBg.cgColor

        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 42)
    }

    func update(titles: [String], active: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in titles.enumerated() {
            stack.addArrangedSubview(makeTab(index: index, title: title, isActive: index == active))
        }
        stack.addArrangedSubview(makePlus())
    }

    private func makeTab(index: Int, title: String, isActive: Bool) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.backgroundColor = (isActive ? Self.active : .clear).cgColor

        let label = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
        label.tag = index
        label.isBordered = false
        label.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        label.contentTintColor = isActive ? Self.text : Self.dim
        label.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(label)
        let trailing = label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14)

        if isActive {
            let close = NSButton(title: "×", target: self, action: #selector(closeClicked(_:)))
            close.tag = index
            close.isBordered = false
            close.font = .systemFont(ofSize: 15, weight: .medium)
            close.contentTintColor = Self.dim
            close.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(close)
            NSLayoutConstraint.activate([
                close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
                close.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
                close.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            ])
            trailing.isActive = false
        } else {
            trailing.isActive = true
        }

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5),
        ])
        return pill
    }

    private func makePlus() -> NSView {
        let plus = NSButton(title: "+", target: self, action: #selector(newTabClicked))
        plus.isBordered = false
        plus.font = .systemFont(ofSize: 16, weight: .medium)
        plus.contentTintColor = Self.dim
        return plus
    }

    @objc private func tabClicked(_ sender: NSButton) { onSelect?(sender.tag) }
    @objc private func closeClicked(_ sender: NSButton) { onClose?(sender.tag) }
    @objc private func newTabClicked() { onNewTab?() }
}
