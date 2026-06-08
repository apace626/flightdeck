import AppKit

/// A small centered text-input overlay. Enter submits, Esc cancels.
final class TextPrompt: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(frame: NSRect, title: String, initial: String) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.5).cgColor

        let panel = NSVisualEffectView()
        panel.material = .hudWindow
        panel.state = .active
        panel.blendingMode = .withinWindow
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        field.stringValue = initial
        field.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(label)
        panel.addSubview(field)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            panel.widthAnchor.constraint(equalToConstant: 420),

            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),

            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            field.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusField() {
        window?.makeFirstResponder(field)
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
