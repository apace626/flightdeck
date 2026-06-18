import Foundation

/// The external tools Flightdeck orchestrates. Checked on first run so a fresh
/// machine sees what's missing (and how to install it) instead of cryptic errors.
enum Dependencies {
    struct Tool {
        let name: String
        let purpose: String
        let formula: String   // homebrew formula (or "" if system-provided)
        let required: Bool
    }

    static let tools: [Tool] = [
        Tool(name: "nvim",    purpose: "editor (Files, Scratchpad)",        formula: "neovim",  required: true),
        Tool(name: "git",     purpose: "Git tab + dashboard status",         formula: "git",     required: true),
        Tool(name: "fzf",     purpose: "fuzzy file browser (ff)",            formula: "fzf",     required: false),
        Tool(name: "fd",      purpose: "fast file listing",                  formula: "fd",      required: false),
        Tool(name: "bat",     purpose: "syntax-highlighted previews",        formula: "bat",     required: false),
        Tool(name: "pandoc",  purpose: "markdown preview (ff Ctrl-G)",       formula: "pandoc",  required: false),
        Tool(name: "curl",    purpose: "dashboard weather / IP",             formula: "curl",    required: false),
        Tool(name: "python3", purpose: "dashboard stocks",                   formula: "python",  required: false),
    ]

    /// Check availability via a login shell (matches the PATH panes will have).
    static func check(_ completion: @escaping ([String: Bool]) -> Void) {
        let names = tools.map(\.name).joined(separator: " ")
        let script = "for t in \(names); do command -v \"$t\" >/dev/null 2>&1 && echo \"$t:1\" || echo \"$t:0\"; done"

        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String: Bool] = [:]
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-ilc", script]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let out = String(data: data, encoding: .utf8) ?? ""
                for line in out.split(separator: "\n") {
                    let parts = line.split(separator: ":")
                    if parts.count == 2 { result[String(parts[0])] = parts[1].contains("1") }
                }
            } catch {}
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The `brew install …` line for whatever's missing (empty if all present).
    static func installCommand(missing statuses: [String: Bool]) -> String {
        let formulas = tools
            .filter { statuses[$0.name] == false && !$0.formula.isEmpty }
            .map(\.formula)
        return formulas.isEmpty ? "" : "brew install " + formulas.joined(separator: " ")
    }
}
