# Flightdeck

A keyboard-driven developer workspace: i3-in-a-window, with tabs at the top.
Swift/AppKit, macOS-only.

- **[SPEC.md](SPEC.md)** — the framework-independent spec: vision, config design, roadmap (source of truth)
- `../flightdeck-plan.md` — original planning narrative and decision history

## Run

```sh
swift run
```

## Configuration

Flightdeck is config-driven: `~/.config/flightdeck/config.toml` (created with
defaults on first launch) declares your startup tabs and destinations. See
[SPEC.md §4](SPEC.md) for the full schema. Default destinations: Files (yazi),
Scratch (nvim on `~/scratch.md`), ChatGPT. Edit the file and relaunch to change
anything — destination commands, leader keys, startup set.

## Keys

Leader: **Ctrl+Space**, then:

| Key | Action |
|-----|--------|
| `t` | New terminal tab (built-in) |
| `f` `s` `c` … | Jump to destination (from config; singletons jump-or-create) |
| `/` | Split focused pane right |
| `-` | Split focused pane down |
| `h` `j` `k` `l` | Directional pane focus |
| `x` | Close focused pane (closes tab when last pane exits) |
| `1`–`9` | Jump to tab N |
| `z` | Zen mode (fullscreen, hide tab bar) |
| `?` | Pin the which-key HUD open |
| `Esc` | Cancel |

Built-in keys win on collision with destination keys. Typing `exit` in a shell
closes its pane automatically.

## Stack

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal panes (planned v2 backend: libghostty)
- WKWebView — chrome-less web destinations (ChatGPT)
- NSSplitView — i3-style pane tiling
- NSEvent local monitor — leader key

## Phase 0 known limitations

- No persistence yet (tabs/layouts don't survive restart) — Phase 2
- No command palette / fuzzy destinations yet — Phase 1
- Web logins may not persist until the app is a proper `.app` bundle with a
  bundle identifier (WKWebsiteDataStore needs one to pick a storage location)
- `Ctrl+Space` collides with macOS "Select previous input source" if you have
  multiple input sources enabled (System Settings → Keyboard → Shortcuts)
