import AppKit

/// First-run boot screen: app identity + a live dependency checklist (with the
/// brew command for whatever's missing), then "Continue" into the dashboard.
final class WelcomeOverlay: NSView {
    var onContinue: (() -> Void)?

    private static let banner = """
     ___ _    ___ ___ _  _ _____ ___  ___ ___ _  __
    | __| |  |_ _/ __| || |_   _|   \\| __/ __| |/ /
    | _|| |__ | | (_ | __ | | | | |) | _| (__| ' <\u{0020}
    |_| |____|___\\___|_||_| |_| |___/|___\\___|_|\\_\\
    """

    private let rows = NSStackView()
    private let subtitle = NSTextField(labelWithString: "Checking dependencies…")
    private let installField = NSTextField(labelWithString: "")
    private let continueButton = NSButton(title: "Continue to Dashboard  ↵", target: nil, action: nil)

    private static let mauve = NSColor(srgbRed: 0.80, green: 0.65, blue: 0.97, alpha: 1)
    private static let green = NSColor(srgbRed: 0.65, green: 0.89, blue: 0.63, alpha: 1)
    private static let red   = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.66, alpha: 1)
    private static let dim   = NSColor.secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.18, alpha: 0.98).cgColor

        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 10
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // Header: ASCII wordmark + tagline.
        let banner = NSTextField(labelWithString: Self.banner)
        banner.font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .bold)
        banner.textColor = Self.mauve
        banner.maximumNumberOfLines = 0

        let tagline = NSTextField(labelWithString: "A keyboard-driven developer workspace")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = Self.dim

        let header = NSStackView(views: [banner, tagline])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        subtitle.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.textColor = Self.mauve

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5

        installField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        installField.textColor = Self.green
        installField.isSelectable = true
        installField.isHidden = true

        let footer = NSTextField(labelWithString: "Tip: press  Ctrl+Space ?  anytime to see all commands.")
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = Self.dim

        continueButton.target = self
        continueButton.action = #selector(continueClicked)
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"

        panel.addArrangedSubview(header)
        panel.setCustomSpacing(20, after: header)
        panel.addArrangedSubview(subtitle)
        panel.addArrangedSubview(rows)
        panel.addArrangedSubview(installField)
        panel.setCustomSpacing(18, after: installField)
        panel.addArrangedSubview(footer)
        panel.setCustomSpacing(14, after: footer)
        panel.addArrangedSubview(continueButton)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusContinue() { window?.makeFirstResponder(continueButton) }

    /// Populate the checklist once the dependency check returns.
    func apply(statuses: [String: Bool]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var missingRequired = false

        for tool in Dependencies.tools {
            let ok = statuses[tool.name] ?? false
            if !ok && tool.required { missingRequired = true }

            let mark = NSTextField(labelWithString: ok ? "✓" : "✗")
            mark.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
            mark.textColor = ok ? Self.green : Self.red
            mark.widthAnchor.constraint(equalToConstant: 18).isActive = true

            let name = NSTextField(labelWithString: tool.name)
            name.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            name.textColor = ok ? .white : Self.red
            name.widthAnchor.constraint(equalToConstant: 90).isActive = true

            let purpose = NSTextField(labelWithString: tool.purpose + (tool.required ? "  (required)" : ""))
            purpose.font = .systemFont(ofSize: 12)
            purpose.textColor = Self.dim

            let row = NSStackView(views: [mark, name, purpose])
            row.orientation = .horizontal
            row.spacing = 8
            rows.addArrangedSubview(row)
        }

        let install = Dependencies.installCommand(missing: statuses)
        if install.isEmpty {
            subtitle.stringValue = "All set — everything's installed."
            subtitle.textColor = Self.green
            installField.isHidden = true
        } else {
            subtitle.stringValue = missingRequired
                ? "Some required tools are missing:"
                : "Optional tools are missing (features will degrade):"
            subtitle.textColor = missingRequired ? Self.red : Self.mauve
            installField.stringValue = "  " + install
            installField.isHidden = false
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { continueClicked() }   // esc also continues
        else { super.keyDown(with: event) }
    }

    @objc private func continueClicked() {
        onContinue?()
    }
}
