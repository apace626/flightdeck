import AppKit

/// Minimal top tab strip. Phase 0: text buttons, active tab highlighted.
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?

    private let stack = NSStackView()
    private var titles: [String] = []
    private var activeIndex = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
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
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    func update(titles: [String], active: Int) {
        self.titles = titles
        self.activeIndex = active

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in titles.enumerated() {
            let button = NSButton(title: " \(title) ", target: self, action: #selector(tabClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            let isActive = index == active
            button.layer?.backgroundColor = isActive
                ? NSColor(calibratedWhite: 0.28, alpha: 1.0).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = isActive ? .white : .lightGray
            button.font = NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
            stack.addArrangedSubview(button)
        }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }
}
