# Flightdeck — Specification

> Framework- and language-independent. This document defines **what Flightdeck is**;
> how it's built (Swift/AppKit today) lives in implementation docs and can change
> without touching this spec.

## 1. Vision

A keyboard-driven developer workspace that behaves like a tiling window manager
contained in a single application. It **orchestrates** best-in-class tools
(shell, Neovim, yazi, Claude Code, web apps) — it never reimplements them.

Work is organized around **Projects, Activities, and Destinations** — not files,
windows, panes, or sessions. The user thinks *"go to ChambaDesk"*, *"go to
ChatGPT"* — never *"find pane 3 in session 4"*.

The grammar: **Project → Destination → Activity.** Panes, buffers, sessions, and
windows are implementation details the user never manages.

Inspirations: i3 (tiling, workspaces), Spacemacs (leader key, discoverability),
Arc Spaces (named destinations, palette-as-new-tab), Zellij (layouts as config).

## 2. Core concepts

| Concept | Definition |
|---|---|
| **Tab** | A top-level destination, shown in a tab strip at the top. Tabs are dynamic — they reflect what the user needs today. |
| **Destination** | A *named* tab the user jumps to: a project, a utility (Files, Scratch), or a web app (ChatGPT). Destinations are typically **singletons**: invoking one jumps to it if it exists, creates it if not. |
| **Project** | A destination defined by its own config file, with a declared pane layout and project-scoped commands. |
| **Pane** | A tile inside a tab. Either a **terminal** (running any command) or a **web view** (chrome-less). Panes tile i3-style: split, resize, directional focus, zoom. |
| **Leader key** | One prefix chord opens the command layer. Every action is reachable and *discoverable* from it (which-key HUD). Plain keystrokes always pass through to panes untouched. |
| **Command** | A named, runnable action — global or project-scoped — invokable by leader shortcut or palette. |

## 3. Interaction model

- **Leader key** (default `Ctrl+Space`) → which-key HUD showing every binding.
  Single follow-up keys execute: jump to destination, split, focus, close, zen,
  tab N, project commands. `?` pins the HUD (help system = the bindings themselves).
- **New tab defaults to a terminal, instantly, no questions.** Everything else is
  named: the palette (leader + `Space`) takes a destination name, project name,
  or URL — typing decides what opens (the Arc model). The `+` tab button opens
  the palette.
- **Web destinations have no browser chrome.** A web app fills its tab/pane
  entirely and is treated as a first-class application.
- All mouse interactions (click tab, drag divider) exist but are conveniences;
  every action has a keyboard path.

## 4. Configuration (the contract)

Flightdeck is **config-first**: on launch, it already knows what you want because
you told it in files. The GUI never owns state that config files can't express.

### 4.1 Global config — `~/.config/flightdeck/config.toml`

```toml
[general]
leader = "ctrl+space"
shell  = "$SHELL"            # default for new terminal panes
theme  = "dark"

[startup]
# What greets you at launch:
tabs    = ["files", "scratch", "chambadesk", "chatgpt"]
active  = "chambadesk"
restore = "merge"            # "declared" = exactly the tabs above
                             # "last"     = whatever was open at quit
                             # "merge"    = declared set + tabs added last session

[destinations.files]
type      = "terminal"
command   = "yazi"
key       = "f"              # leader+f jumps here
singleton = true

[destinations.scratch]
type      = "terminal"
command   = "nvim ~/scratch"
key       = "s"
singleton = true

[destinations.chatgpt]
type      = "web"
url       = "https://chatgpt.com"
key       = "c"
singleton = true
profile   = "personal"       # isolated cookie/login store name

[projects]
# Directories scanned for project config files:
scan  = ["~/Projects/personal"]
# Explicit additions outside scan roots:
extra = ["~/work/clientx/flightdeck.toml"]
```

### 4.2 Project config — `flightdeck.toml` in the project root

Projects are **their own config files, living in the repo** — versionable,
shareable, discovered by the scan paths above. (A project without a repo can
live in `~/.config/flightdeck/projects/<name>.toml` with an explicit `root`.)

```toml
[project]
name = "ChambaDesk"
key  = "d"                   # leader+p d, or surfaced in the project picker
# root defaults to the directory containing this file

[env]                        # exported to every pane in this project
NODE_ENV = "development"

# ---- Layout: what the tab looks like when opened ----
[layout]
split = "row"                # children side-by-side
ratio = [0.6, 0.4]

  [[layout.children]]
  split = "column"           # stacked
    [[layout.children.children]]
    name = "claude"
    run  = "claude --continue"
    [[layout.children.children]]
    name = "editor"
    run  = "nvim"

  [[layout.children]]
  split = "column"
    [[layout.children.children]]
    name = "api"
    run  = "npm run dev"
    cwd  = "backend"         # relative to project root
    [[layout.children.children]]
    name = "web"
    type = "web"
    url  = "http://localhost:3000"

# ---- Project commands: leader+r opens this menu inside the project ----
[commands.test]
key  = "t"
run  = "npm test"
in   = "split-down"          # where output goes (see §4.3)

[commands.migrate]
key  = "m"
run  = "npm run db:migrate"
in   = "pane:api"            # reuse the named pane

[commands.deploy]
key     = "d"
run     = "./scripts/deploy.sh"
in      = "split-down"
confirm = true               # ask before running

[commands.logs]
key = "l"
run = "tail -f /tmp/api.log"
in  = "floating"             # overlay pane, esc to dismiss
```

### 4.3 Command targets (`in =`)

| Value | Behavior |
|---|---|
| `split-down` / `split-right` | New pane next to the focused one; closes when process exits |
| `pane:<name>` | Send to the named layout pane (interrupt + run, or spawn if missing) |
| `floating` | Temporary overlay pane, dismissed with Esc |
| `background` | No pane; notify on completion/failure |
| `tab` | Its own new tab |

### 4.4 Rules

- **Config is the source of truth; state is a cache.** Runtime additions (an ad-hoc
  split, an extra tab) persist to a separate state file — never written back into
  the user's config files.
- Config reloads on file change (at minimum: on demand via a reload command).
- Missing/invalid config degrades gracefully: defaults + a visible warning, never
  a crash, never silent rewriting of the user's file.
- Every key shown in a which-key HUD comes from config or defaults — there are no
  unbindable built-ins.

## 5. Persistence model

- **Layout, not processes.** Quitting Flightdeck quits everything in it (like an
  IDE). Reopening restores the tab set (per `startup.restore`), each tab's pane
  tree, and relaunches each pane's command.
- Tools own their own state across relaunch: nvim auto-session, `claude --continue`,
  stateless dev servers. Default pane commands should use resumable forms.
- **Per-pane opt-in process survival**: any pane's `run` may be wrapped in a
  multiplexer (`tmux new -A -s job '…'`) — user's choice, zero special support.
- Web destinations keep persistent, per-profile login state.

## 6. Design decisions (settled)

1. **Orchestrate, don't reinvent** — no terminal emulator, editor, file manager,
   or AI chat of our own. Ever.
2. **Own the pane tiling** (not zellij/tmux inside tabs) — so web views and
   terminals are siblings in one layout and there is exactly one keybinding layer.
3. **Layout persistence, not process persistence** (§5) — deletes the daemon/pty-
   server problem entirely.
4. **Prefix leader, not bare Space** — panes must receive every plain keystroke;
   nvim keeps its own Space leader.
5. **Terminal is the zero-thought default; everything else is named** (§3).
6. **Destinations are singletons you go to**, not windows you instantiate.
7. **Config-first** (§4): startup is declared; projects are files in their repos;
   commands/shortcuts are project-scoped config.
8. **Discoverability over memorization**: the help system is the leader HUD itself.

## 7. What any implementation must provide

Three component slots plus two mechanisms — this is the entire framework checklist:

| Slot | Requirement |
|---|---|
| **Terminal pane** | Real emulation (TUI-correct: nvim/htop/yazi), fast enough to feel native, selection/copy/paste, OS text-input protocol (dictation/IME) |
| **Web pane** | Real engine, chrome-less, persistent isolated profiles |
| **Tiling** | Nested splits of arbitrary widgets, drag-resize, programmatic ratios |
| **Key interception** | Capture the leader chord before panes see it; pass everything else through untouched |
| **Process control** | Spawn/signal/reap pane processes; env + cwd per pane |

Current implementation: **Swift/AppKit** (SwiftTerm, WKWebView, NSSplitView,
NSEvent monitor) — chosen for native macOS quality; macOS-only accepted.
Candidate terminal upgrade: libghostty when its C API stabilizes.

## 8. Roadmap

- **Phase 0 — Spike** ✅ terminal feel, splits, leader, web destination
- **Phase 1 — Shell**: palette, Files/Scratch destinations, pane polish (zoom,
  close-collapse), which-key refinement
- **Phase 2 — Config & projects**: §4 in full — global config, project file
  discovery, layout instantiation, project commands, startup/restore
- **Phase 3 — Polish**: web profiles, URL-in-palette, `flightdeck` CLI
  (`flightdeck open --tab scratch <file>`), zen mode, theming, config reload
- **Phase 4 — Later**: tab presets ("today I need…"), pane health indicators,
  hold-to-talk dictation into panes, libghostty terminal backend
