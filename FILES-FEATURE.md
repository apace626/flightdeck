# Flightdeck — File Navigation Feature (port notes)

> Framework-independent description of the file/finder/tab behavior built in the
> Swift/AppKit prototype, with Qt mappings. Hand this to the Qt port so it can
> reproduce behavior-for-behavior. Source of truth for *intent* is `SPEC.md`;
> this doc is the *as-built* detail for one feature area.

## What exists

Three ways files/dirs enter the workspace, layered so they complement rather than
overlap:

1. **Files destination** — a permanent singleton tab running `yazi` (full TUI file
   manager). For "I want to look around."
2. **Fuzzy finder overlay** (`leader+o`) — Telescope-style: type-to-match across a
   pre-built index, with a **native file preview pane**. For "I know roughly the
   name." Routes the chosen item by type (see §3).
3. **Ad-hoc directory tabs** — born from the finder: pick a folder → a new tab
   named after it, scoped there. Dynamic, session-only. For "open this place I
   just found as its own workspace."

## 1. Files destination (yazi)

- A config destination: `type=terminal, command="yazi", singleton=true, key="f"`.
- Just a terminal pane running yazi — Flightdeck adds nothing; yazi owns browsing,
  search (`s` name / `S` content / `f` filter), and preview.
- **Enter on a file in yazi** opens `$EDITOR` (nvim) *inside that pane*; quitting
  the editor returns to yazi. This is yazi's own opener behavior, not ours.

### Terminal env requirements (learned the hard way)

The pane must **sanitize inherited environment** before launching the shell, or
TUI tools misbehave. Specifically, strip the launching terminal's identity vars so
programs detect *our* emulator's real capabilities, not the host terminal's:

```
remove: TERM_PROGRAM, TERM_PROGRAM_VERSION, LC_TERMINAL, LC_TERMINAL_VERSION,
        ITERM_PROFILE, ITERM_SESSION_ID, KITTY_WINDOW_ID, KITTY_PID,
        WEZTERM_EXECUTABLE, WEZTERM_PANE, TMUX, TMUX_PANE, TERMINFO_DIRS
set:    TERM=xterm-256color, COLORTERM=truecolor, TERM_PROGRAM=Flightdeck
```

Symptom if you skip this: yazi saw `ITERM_*`, used iTerm2's inline-image protocol,
and the emulator rendered images it couldn't clear → **ghosted/stacked previews**.

### Inline image previews — known terminal-widget gap

yazi also *queries* the terminal for graphics capability and will use sixel/kitty
images if advertised. The Swift terminal widget (SwiftTerm) draws these but does
**not clear them**, so previews stack. **Workaround shipped**: a yazi config
override routing `image/*` to a text-metadata previewer (`file`) instead of pixels.

```toml
# ~/.config/yazi/yazi.toml
[plugin]
prepend_previewers = [ { mime = "image/*", run = "file" } ]
```

Qt note: **QtWebEngine + xterm.js does NOT solve this** — xterm.js has no native
image protocol either. If real inline images in yazi matter, the terminal backend
must implement the kitty graphics protocol *including clears* (libghostty does;
that's the planned upgrade in both ports). Otherwise keep the text-metadata
override. **The good news:** the finder's preview (§2) sidesteps this entirely by
previewing at the GUI layer, not in a terminal.

## 2. Fuzzy finder overlay (the interesting part)

Trigger: `leader+o`. A centered modal panel over a dimmed backdrop.

### Layout
```
┌───────────────────────────────────────────────┐
│ [ text input: type to filter ]                 │
├──────────────────────┬──────────────────────────┤
│ results list (45%)   │  PREVIEW pane (rest)     │
│  path/to/match       │  (native file preview:   │
│  path/to/other/      │   image, pdf, video,     │
│  …  (≤100 shown)     │   text, anything)        │
├──────────────────────┴──────────────────────────┤
│ "N shown · M indexed"  (status)                  │
└───────────────────────────────────────────────┘
```

### Index
- Built **once per session**, cached statically; reopening the finder is instant.
- Built on a **background thread** (status shows `indexing…`, UI stays responsive).
- Walks configured root dirs recursively. **Both files and directories** are
  indexed (directories get the trailing-slash treatment and route differently).
- **Prune list** (don't descend): `node_modules .git .build .cache .npm .cargo
  .venv venv __pycache__ DerivedData Pods Library vendor dist`. Skips hidden files
  and package bundles. Hard cap 100k entries.
- Roots come from config: `[finder] roots = ["~/Projects","~/Downloads",
  "~/Documents","~/Desktop"]`.

### Fuzzy match algorithm (reproduce this for consistent feel)
- Query = input lowercased, spaces stripped. Match against the path **relative to
  home**.
- **Subsequence match**: every query char must appear in order. No match → excluded.
- **Scoring** (higher = better, shown top-first):
  - +1 per matched char
  - + (2 × current consecutive-run length) — rewards contiguous runs
  - +6 if the matched char is at a "word start" (preceded by `/ . _ -` or is index 0)
  - − (path length / 8) — mild preference for shorter paths
- Empty query → show first 100 indexed entries. Sort by score desc, take top 100.

### Keys
| Key | Action |
|-----|--------|
| type | live refilter |
| ↑ / ↓ | move selection (preview follows) |
| Enter | open selected (routes by type — §3) |
| ⌘/Ctrl + Enter | force alternate open (editor for files; plain shell for dirs) |
| double-click | same as Enter |
| Esc / click backdrop | close |

## 3. Open routing (what Enter does)

Decided by the selected entry:

- **Directory** → new tab named after the folder, running **yazi scoped to it**.
  (⌘Enter variant → plain login shell `cd`'d into it instead.)
- **Text/code file** → **new tab** running `nvim <file>`. "Text-ness" decided by:
  (a) an extension allowlist — `toml md txt json yml yaml swift js ts tsx jsx py
  sh zsh rb go rs c h cpp hpp lua kdl conf cfg ini xml html css scss sql env log
  csv`, OR (b) the OS-reported content type conforming to plain text.
- **Anything else** (image, pdf, binary, …) → hand to the OS default app.
  (⌘Enter forces it into the editor instead.)

Path strings passed to shell commands are single-quote-escaped.

## 4. Tab model (context for the above)

Three kinds of tabs coexist in one top tab strip:
- **Config destinations** — permanent, singleton, leader-key bound (Files, Scratch,
  ChatGPT). Invoking jumps to the existing one or creates it.
- **Anonymous terminals** (`leader+t`) — plain shells, self-title from shell title.
- **Ad-hoc directory tabs** — from the finder; named after the folder; as many as
  wanted; session-only (vanish on quit until restore-policy persistence lands).

Pane working directory: **every pane starts in an explicit cwd** (default: `$HOME`;
directory tabs: the chosen folder) then runs its command or execs a login shell.
Don't let panes inherit the app process's cwd — that surprised us (new shells
opened inside the app's repo dir).

## 5. Config surface added for this feature
```toml
[finder]
roots = ["~/Projects", "~/Downloads", "~/Documents", "~/Desktop"]
```

## 6. Qt mapping cheatsheet

| Swift/AppKit (as built) | Qt equivalent |
|---|---|
| Overlay `NSView` over dimmed backdrop | frameless `QWidget`/`QDialog` over a translucent overlay, or `QGraphicsBlurEffect` panel |
| `NSVisualEffectView` (HUD blur) | `QGraphicsDropShadow` + semi-opaque stylesheet (no native vibrancy) |
| `NSTableView` results | `QListView` + `QAbstractListModel`, or a simple `QListWidget` |
| `NSTextField` + delegate keystrokes | `QLineEdit` with an event filter for ↑/↓/Enter/Esc |
| **`QLPreviewView` (Quick Look)** | **no single equivalent** — biggest port gap. Options: `QImageReader` for images, a PDF view (`QPdfView`, Qt 5.15+/6), `QMediaPlayer` for video, a text widget for code. Or shell out to `qlmanage`/a thumbnailer. **This native preview is the finder's killer feature; budget real effort here.** |
| `FileManager.enumerator` + prune | `QDirIterator` (recursive) with manual prune set |
| Background index thread + `DispatchQueue.main` | `QThread`/`QtConcurrent::run` + signal back to GUI thread |
| Subsequence scorer (§2) | port the algorithm verbatim — it defines the feel |
| `NSWorkspace.open(url)` | `QDesktopServices::openUrl(QUrl::fromLocalFile(...))` |
| content-type check (`UTType.conforms(to:.text)`) | `QMimeDatabase().mimeTypeForFile().inherits("text/plain")` |
| Open file/dir in a new pane/tab running a command | identical at the orchestration layer — just spawn the pane with the command + cwd |

## 7. Things deliberately NOT done yet (so Qt doesn't over-build)
- No persistence of ad-hoc tabs across restart (waiting on restore-policy work).
- No cross-pane "open this file over in *that* editor pane" — needs the planned
  `flightdeck` CLI (Phase 3). Today files open in a *new* tab.
- Finder indexes on first open, no file-watching/refresh — restart picks up new
  files. Fine for now.
- No `.gitignore`-aware pruning (just the static skip list).
