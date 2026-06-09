import AppKit
import SwiftTerm
import WebKit

/// Base class for anything that can live in a workspace's split tree.
class PaneView: NSView {
    func takeFocus() {}
}

// MARK: - Terminal pane (SwiftTerm)

final class TerminalPane: PaneView, LocalProcessTerminalViewDelegate {
    /// Set once at startup from config. Nerd Fonts make TUI icons (yazi etc.) render.
    static var preferredFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    /// Optional color theme, set once at startup from config.
    static var theme: TerminalTheme?

    let terminal: LocalProcessTerminalView
    var onExit: ((TerminalPane) -> Void)?
    var onTitle: ((String) -> Void)?

    /// Kill this pane's entire process tree. The shell is a process-group leader
    /// (the pty calls setsid), so killing the group (-pid) takes down make/java/etc.
    /// — not just the shell. Prevents orphaned servers holding ports after quit.
    func terminateProcessTree() {
        // Only signal if the shell is still alive — shellPid is NOT reset on exit,
        // so killing a dead (possibly reused) pid's group could hit siblings.
        guard terminal.process.running else { return }
        let pid = terminal.process.shellPid
        guard pid > 0 else { return }
        killpg(pid, SIGTERM)
        // Escalate to SIGKILL shortly after, only if it's still running.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.terminal.process.running == true { killpg(pid, SIGKILL) }
        }
    }

    init(command: String? = nil, workingDirectory: String? = nil, extraEnv: [String: String] = [:], keepAlive: Bool = false, hideCursor: Bool = false) {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        terminal.processDelegate = self
        terminal.font = Self.preferredFont
        Self.theme?.apply(to: terminal)
        if hideCursor {
            // Output-only panes (dashboard, build/watch panes): make the caret
            // invisible so it doesn't blink/distract.
            terminal.caretColor = .clear
            terminal.caretTextColor = .clear
        }
        // The terminal's frame is set in layout() (below) — re-applied on EVERY
        // layout pass — so a pane that grows when a sibling closes actually resizes
        // its terminal (and repaints) instead of leaving a black gap. The inset is
        // the internal padding; the pane background matches the terminal's so the
        // inset reads as margin.
        wantsLayer = true
        layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        addSubview(terminal)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        // Strip markers of whatever terminal *launched* Flightdeck — programs in
        // panes must detect SwiftTerm's capabilities, not iTerm2's/kitty's.
        // (e.g. yazi saw ITERM_* here and used iTerm2's image protocol, which
        // SwiftTerm only partially supports → ghosted previews.)
        for key in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LC_TERMINAL",
                    "LC_TERMINAL_VERSION", "ITERM_PROFILE", "ITERM_SESSION_ID",
                    "KITTY_WINDOW_ID", "KITTY_PID", "WEZTERM_EXECUTABLE",
                    "WEZTERM_PANE", "TMUX", "TMUX_PANE", "TERMINFO_DIRS"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Flightdeck"
        for (key, value) in extraEnv { env[key] = value } // project / destination env
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Every pane starts in an explicit directory (default: home), then runs
        // its command — or execs into an interactive login shell.
        // Use an INTERACTIVE login shell (-i) so ~/.zshrc is sourced even for
        // command panes — otherwise nvm/rbenv/pyenv tools (e.g. ccusage) aren't
        // on PATH, since zsh only reads .zshrc for interactive shells.
        let dir = (workingDirectory ?? NSHomeDirectory()).replacingOccurrences(of: "'", with: "'\\''")
        let body: String
        if let command {
            // keepAlive: after the command exits (finishes or is Ctrl-C'd), drop to
            // an interactive shell so the pane persists with its output. `exit` then
            // closes the pane (the survivors reflow to fill — see Workspace.close).
            // `trap ':' INT` lets THIS wrapper survive Ctrl-C (the child still dies),
            // so Ctrl-C drops to the shell rather than aborting the whole list and
            // closing the pane.
            body = keepAlive ? "{ trap ':' INT; \(command); }; exec '\(shell)' -l" : command
        } else {
            body = "exec '\(shell)' -l"
        }
        terminal.startProcess(executable: shell, args: ["-i", "-l", "-c", "cd '\(dir)' && \(body)"], environment: envArray)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Internal padding around the terminal content (the prompt sits in from edges).
    private static let pad: CGFloat = 14

    override func layout() {
        super.layout()
        // Re-apply every layout pass so the terminal always fills the (padded) pane,
        // including after a sibling pane closes and this one grows to fill the slot.
        terminal.frame = bounds.insetBy(dx: Self.pad, dy: Self.pad)
    }

    override func takeFocus() {
        window?.makeFirstResponder(terminal)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?(self)
    }
}

// MARK: - Web pane (WKWebView, chrome-less)

final class WebPane: PaneView {
    let webView: WKWebView

    init(url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        // Present as Safari so web apps don't treat us as an embedded view.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        // Enable Safari's Web Inspector: right-click → Inspect Element (no F12 — this is WebKit, not Chrome).
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Force dark: web apps that honor prefers-color-scheme render dark
        // regardless of the macOS system appearance.
        webView.appearance = NSAppearance(named: .darkAqua)

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Navigate this pane to a new URL (used by the live file-preview pane).
    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Dim placeholder shown before anything is selected.
    func showPlaceholder(_ text: String) {
        let html = """
        <html><head><meta name="color-scheme" content="dark"></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
        background:#1e1e2e;color:#6c7086;font:14px -apple-system,system-ui,sans-serif;">\(text)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    override func takeFocus() {
        window?.makeFirstResponder(webView)
    }
}
