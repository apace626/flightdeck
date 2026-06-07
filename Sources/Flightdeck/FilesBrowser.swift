import Foundation

/// Installs Flightdeck's helper commands onto the user's PATH (~/.local/bin):
///   ff — on-demand fzf file browser
///   lg — pick a git repo (with change preview) → open it in lazygit
enum FilesBrowser {
    static func ensure() {
        install("ff", ffScript)
        install("lg", lgScript)
        install("fd-open", fdOpenScript)
    }

    // Boxed (--style=full) fzf themed to Catppuccin Mocha. Prepended to ff/lg.
    private static let fzfOpts =
        "export FZF_DEFAULT_OPTS=\"--style=full --layout=reverse --height=100% --pointer='▶' "
        + "--color=bg+:#313244,bg:#1e1e2e,hl:#f38ba8,fg:#cdd6f4,header:#f38ba8,"
        + "info:#cba6f7,pointer:#f5e0dc,marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,"
        + "hl+:#f38ba8,border:#cdd6f4,label:#f5e0dc\""

    private static func install(_ name: String, _ content: String) {
        let bin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        let path = bin.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? content.write(to: path, atomically: true, encoding: .utf8) // rewrite so updates propagate
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private static let ffScript = """
    #!/bin/sh
    # ff — fzf file browser with preview. Type `ff` (or `ff <dir>`).
    # Enter routes by type: text/code → $EDITOR (nvim); images/PDF/media/etc →
    # the macOS default app (open). Esc quits to the shell.
    # Installed by Flightdeck. Safe to edit; rewritten on next launch.

    \(fzfOpts)

    cd "${1:-$PWD}" || exit 1
    query=""
    while true; do
      # --print-query echoes the typed query as line 1 so we can restore it next
      # loop — otherwise the search resets every time you open a file.
      out=$(fd --type f --hidden --follow --strip-cwd-prefix \
                --exclude .git --exclude node_modules --exclude Library \
            | fzf --print-query --query "$query" --prompt 'files ❯ ' \
                  --preview 'f={}; case "$f" in \
                      *.md|*.markdown) glow -s dark -w "${FZF_PREVIEW_COLUMNS:-100}" "$f" 2>/dev/null ;; \
                      *) bat --color=always --theme="Catppuccin Mocha" --style=numbers --line-range :400 "$f" 2>/dev/null ;; \
                    esac' \
                  --preview-window 'right,60%' \
                  --header 'Enter: open · Esc: quit')
      rc=$?
      query=$(printf '%s' "$out" | sed -n '1p')
      file=$(printf '%s' "$out" | sed -n '2p')
      [ $rc -ne 0 ] && break       # Esc / abort → quit to shell
      [ -z "$file" ] && continue
      case "$(printf '%s' "$file" | tr 'A-Z' 'a-z')" in
        *.png|*.jpg|*.jpeg|*.gif|*.heic|*.webp|*.bmp|*.tiff|*.svg|*.ico| \
        *.pdf|*.mp4|*.mov|*.m4v|*.avi|*.mkv|*.mp3|*.wav|*.flac|*.aiff| \
        *.zip|*.dmg|*.app|*.pkg|*.key|*.numbers|*.pages| \
        *.docx|*.xlsx|*.pptx|*.doc|*.xls|*.ppt)
          open "$file" ;;          # macOS default app (Preview, QuickTime, …)
        *)
          fd-open "$file" ;;       # open text/code in a NEW Flightdeck tab (nvim)
      esac
    done
    """

    // fd-open <file> — ask Flightdeck (via the control socket) to open <file> in
    // a new nvim tab. Falls back to editing in place if the socket is unavailable.
    private static let fdOpenScript = """
    #!/bin/sh
    # fd-open <file> — open a file in a new Flightdeck tab (nvim). Installed by Flightdeck.
    SOCK="$HOME/.config/flightdeck/control.sock"
    file="$1"
    [ -z "$file" ] && exit 0
    case "$file" in /*) ;; *) file="$PWD/$file" ;; esac   # absolutize
    title=$(basename "$file")
    if [ -S "$SOCK" ] && command -v nc >/dev/null 2>&1; then
      printf "tab\\t%s\\tnvim '%s'\\n" "$title" "$file" | nc -U "$SOCK"
    else
      "${EDITOR:-nvim}" "$file"
    fi
    """

    private static let lgScript = """
    #!/bin/sh
    # lg — open a git repo in lazygit to browse changes/diffs.
    #   lg        pick a repo under ~/Projects (preview shows what changed)
    #   lg .      use the current repo
    # Installed by Flightdeck. Safe to edit; rewritten on next launch.

    \(fzfOpts)

    if [ -n "$1" ]; then
      cd "$1" 2>/dev/null || { echo "no such dir: $1"; exit 1; }
      exec lazygit
    fi

    # Repos = git dirs one or two levels under ~/Projects (skips vendored deps).
    # (fd ignores .git by default, so we glob instead.)
    while true; do
      repo=$(for d in "$HOME"/Projects/*/ "$HOME"/Projects/*/*/; do \
               [ -d "${d}.git" ] && printf '%s\\n' "${d%/}"; \
             done | sed "s|^$HOME/||" \
             | fzf --prompt 'repo ❯ ' \
                   --preview 'git -C "$HOME/{}" -c color.status=always status -s 2>/dev/null; \
                              echo; git -C "$HOME/{}" log --oneline -8 2>/dev/null' \
                   --preview-window 'right,55%' \
                   --header 'Enter: open in lazygit · Esc: quit') || break
      [ -z "$repo" ] && break
      ( cd "$HOME/$repo" && lazygit )
    done
    """
}
