import AppKit

/// A modern centered text-input overlay — same Catppuccin panel/layout as the
/// launcher (ListPicker). Enter submits, Esc cancels, click-away closes.
final class TextPrompt: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    // Catppuccin Mocha (matches ListPicker)
    private static func col(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    private static let base     = col(30, 30, 46)
    private static let surface  = col(49, 50, 68)
    private static let surface1 = col(69, 71, 90)
    private static let text     = col(205, 214, 244)
    private static let mauve    = col(203, 166, 247)
    private static let overlay  = col(108, 112, 134)

    init(frame: NSRect, title: String, initial: String,
         placeholder: String = "new name…",
         hint: String = "↵  rename     esc  cancel") {
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

        // Caption (the prompt title)
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 12, weight: .semibold)
        caption.textColor = Self.mauve
        caption.translatesAutoresizingMaskIntoConstraints = false

        // Search-style row: pencil glyph + field
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        glyph.contentTintColor = Self.overlay
        glyph.translatesAutoresizingMaskIntoConstraints = false

        field.stringValue = initial
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

        let hint = NSTextField(labelWithString: hint)
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = Self.overlay
        hint.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(caption)
        panel.addSubview(glyph)
        panel.addSubview(field)
        panel.addSubview(divider)
        panel.addSubview(hint)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -60),
            panel.widthAnchor.constraint(equalToConstant: 560),

            caption.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            caption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),

            glyph.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            glyph.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),

            field.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),

            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            hint.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            hint.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusField() {
        window?.makeFirstResponder(field)
        // Catppuccin selection (default blue-on-light is unreadable with light text).
        if let editor = field.currentEditor() as? NSTextView {
            editor.selectedTextAttributes = [
                .backgroundColor: Self.surface1,
                .foregroundColor: Self.text,
            ]
            editor.insertionPointColor = Self.mauve
        }
        field.currentEditor()?.selectAll(nil)
    }

    override func mouseDown(with event: NSEvent) { close() }

    private func close() {
        removeFromSuperview()
        onClose?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            close()
            if !text.isEmpty { onSubmit?(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}
