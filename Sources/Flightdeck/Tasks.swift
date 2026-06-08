import Foundation

/// The Tasks tab: taskwarrior-tui (interactive) on the left, a live at-a-glance
/// summary on the right. Orchestrates the `task` CLI — no logic of our own.
///
///   ┌───────────────────────────┬──────────────────┐
///   │  taskwarrior-tui          │  TASKS            │
///   │  (manage interactively)   │  counts · overdue │
///   │                           │  due today · proj │
///   └───────────────────────────┴──────────────────┘
enum Tasks {
    static func spec() -> PaneSpec {
        let summary = ensureScript()
        // keepAlive so quitting the TUI drops to a task-ready shell instead of
        // closing the tab.
        let tui = "command -v taskwarrior-tui >/dev/null 2>&1 && taskwarrior-tui "
            + "|| echo 'taskwarrior-tui not found — run: brew install taskwarrior-tui'"
        return .split(vertical: true, ratios: [0.62, 0.38], children: [
            .terminal(command: tui, keepAlive: true),
            .terminal(command: "sh '\(summary)'", hideCursor: true),
        ])
    }

    private static func ensureScript() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flightdeck", isDirectory: true)
        let path = dir.appendingPathComponent("tasks-summary.sh")
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? script.write(to: path, atomically: true, encoding: .utf8)
        }
        return path.path
    }

    private static let script = """
    #!/bin/sh
    # Flightdeck Tasks summary — taskwarrior at a glance. Edit freely; refreshes 30s.
    e=$(printf '\\033')
    cyan="$e[1;36m"; ylw="$e[1;33m"; red="$e[1;31m"; grn="$e[1;32m"; dim="$e[2m"; rst="$e[0m"

    while true; do
      pending=$(task rc.verbose=nothing +PENDING count 2>/dev/null)
      overdue=$(task rc.verbose=nothing +OVERDUE count 2>/dev/null)
      today=$(task rc.verbose=nothing +TODAY count 2>/dev/null)

      clear
      printf '\\n  %sTASKS%s\\n\\n' "$cyan" "$rst"
      printf '  %sPending%s    %s%s%s\\n' "$dim" "$rst" "$grn" "${pending:-0}" "$rst"
      printf '  %sDue today%s  %s%s%s\\n' "$dim" "$rst" "$ylw" "${today:-0}" "$rst"
      printf '  %sOverdue%s    %s%s%s\\n' "$dim" "$rst" "$red" "${overdue:-0}" "$rst"

      printf '\\n  %s⚠ Overdue%s\\n' "$red" "$rst"
      task rc.verbose=nothing rc._forcecolor=on +OVERDUE limit:5 minimal 2>/dev/null

      printf '\\n  %s◷ Due today%s\\n' "$ylw" "$rst"
      task rc.verbose=nothing rc._forcecolor=on +TODAY limit:5 minimal 2>/dev/null

      printf '\\n  %s▸ Projects%s\\n' "$cyan" "$rst"
      task rc.verbose=nothing summary 2>/dev/null | head -12

      sleep 30
    done
    """
}
