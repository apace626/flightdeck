import AppKit
import SwiftTerm

/// A terminal color theme: background/foreground/cursor/selection + the 16 ANSI colors.
struct TerminalTheme {
    let bg, fg, cursor, selection: String          // hex
    let palette: [String]                          // 16 ANSI hex colors (0-15)

    static func named(_ name: String?) -> TerminalTheme? {
        guard let name else { return nil }
        return presets[name.lowercased()]
    }

    static let presetNames = presets.keys.sorted()

    static let presets: [String: TerminalTheme] = [
        "dracula": TerminalTheme(
            bg: "#282A36", fg: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
            palette: ["#21222C","#FF5555","#50FA7B","#F1FA8C","#BD93F9","#FF79C6","#8BE9FD","#F8F8F2",
                      "#6272A4","#FF6E6E","#69FF94","#FFFFA5","#D6ACFF","#FF92DF","#A4FFFF","#FFFFFF"]),
        "tokyo-night": TerminalTheme(
            bg: "#1A1B26", fg: "#C0CAF5", cursor: "#C0CAF5", selection: "#283457",
            palette: ["#15161E","#F7768E","#9ECE6A","#E0AF68","#7AA2F7","#BB9AF7","#7DCFFF","#A9B1D6",
                      "#414868","#F7768E","#9ECE6A","#E0AF68","#7AA2F7","#BB9AF7","#7DCFFF","#C0CAF5"]),
        "catppuccin-mocha": TerminalTheme(
            bg: "#1E1E2E", fg: "#CDD6F4", cursor: "#F5E0DC", selection: "#313244",
            palette: ["#45475A","#F38BA8","#A6E3A1","#F9E2AF","#89B4FA","#F5C2E7","#94E2D5","#BAC2DE",
                      "#585B70","#F38BA8","#A6E3A1","#F9E2AF","#89B4FA","#F5C2E7","#94E2D5","#A6ADC8"]),
        "gruvbox-dark": TerminalTheme(
            bg: "#282828", fg: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
            palette: ["#282828","#CC241D","#98971A","#D79921","#458588","#B16286","#689D6A","#A89984",
                      "#928374","#FB4934","#B8BB26","#FABD2F","#83A598","#D3869B","#8EC07C","#EBDBB2"]),
        "nord": TerminalTheme(
            bg: "#2E3440", fg: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
            palette: ["#3B4252","#BF616A","#A3BE8C","#EBCB8B","#81A1C1","#B48EAD","#88C0D0","#E5E9F0",
                      "#4C566A","#BF616A","#A3BE8C","#EBCB8B","#81A1C1","#B48EAD","#8FBCBB","#ECEFF4"]),
    ]

    // MARK: - Apply

    func apply(to terminal: LocalProcessTerminalView) {
        terminal.installColors(palette.map { Self.swiftTermColor($0) })
        terminal.nativeBackgroundColor = Self.nsColor(bg)
        terminal.nativeForegroundColor = Self.nsColor(fg)
        terminal.caretColor = Self.nsColor(cursor)
        terminal.selectedTextBackgroundColor = Self.nsColor(selection)
    }

    // MARK: - Hex parsing

    private static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = rgb(hex)
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    // SwiftTerm.Color uses 16-bit components (0-65535); scale 0-255 by 257.
    static func swiftTermColor(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = rgb(hex)
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }
}
