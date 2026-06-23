import Foundation
import TOMLKit

// MARK: - Model

struct Destination {
    enum Kind: String {
        case terminal, web, dashboard, files, localhost
    }

    let name: String        // config key, e.g. "chatgpt"
    var title: String       // tab label, e.g. "ChatGPT"
    var kind: Kind
    var command: String?    // terminal destinations
    var url: URL?           // web destinations
    var key: Character?     // leader shortcut
    var singleton: Bool
}

struct Config {
    var startupTabs: [String]      // destination names; "terminal" = plain shell tab
    var startupActive: String?
    var destinations: [String: Destination]
    var orderedDestinations: [Destination]
    var fontName: String?          // terminal font; nil = auto (Nerd Font if present)
    var fontSize: Double
    var themeName: String?         // terminal color theme (see TerminalTheme.presets)
    var finderRoots: [String]      // directories the fuzzy finder indexes
    var projectScanRoots: [String] // directories scanned for flightdeck.toml
    var calendarInclude: [String]  // dashboard agenda calendars; empty = all
    var calendarExclude: [String]  // calendars to drop (e.g. holidays)
}

// MARK: - TOML file shape

private struct ConfigFile: Codable {
    struct General: Codable {
        var font: String?
        var fontSize: Double?
        var theme: String?

        enum CodingKeys: String, CodingKey {
            case font
            case fontSize = "font_size"
            case theme
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            font = (try? c.decodeIfPresent(String.self, forKey: .font)) ?? nil
            theme = (try? c.decodeIfPresent(String.self, forKey: .theme)) ?? nil
            // Accept font_size as either a float (13.5) or an integer (13).
            if let d = try? c.decode(Double.self, forKey: .fontSize) {
                fontSize = d
            } else if let i = try? c.decode(Int.self, forKey: .fontSize) {
                fontSize = Double(i)
            } else {
                fontSize = nil
            }
        }
    }

    struct Startup: Codable {
        var tabs: [String]?
        var active: String?
    }

    struct Dest: Codable {
        var type: String?
        var title: String?
        var command: String?
        var url: String?
        var key: String?
        var singleton: Bool?
    }

    struct Finder: Codable {
        var roots: [String]?
    }

    struct Projects: Codable {
        var scan: [String]?
    }

    struct CalendarSection: Codable {
        var include: [String]?
        var exclude: [String]?
    }

    var general: General?
    var startup: Startup?
    var finder: Finder?
    var projects: Projects?
    var calendar: CalendarSection?
    var destinations: [String: Dest]?
}

// MARK: - Loader

enum ConfigLoader {
    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flightdeck", isDirectory: true)
    }

    static var configFile: URL {
        configDir.appendingPathComponent("config.toml")
    }

    /// Loads the user config, writing the default config file first if none exists.
    /// Invalid config degrades to defaults with a warning — never a crash.
    static func load() -> (config: Config, warning: String?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configFile.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            try? defaultConfigTOML.write(to: configFile, atomically: true, encoding: .utf8)
        }

        do {
            let text = try String(contentsOf: configFile, encoding: .utf8)
            return (try parse(text), nil)
        } catch {
            let fallback = (try? parse(defaultConfigTOML))
                ?? Config(startupTabs: ["terminal"], startupActive: nil,
                          destinations: [:], orderedDestinations: [],
                          fontName: nil, fontSize: 13, themeName: nil,
                          finderRoots: ["~/Projects"],
                          projectScanRoots: ["~/Projects"],
                          calendarInclude: [], calendarExclude: [])
            return (fallback, "config error in \(configFile.path): \(error)")
        }
    }

    static func parse(_ text: String) throws -> Config {
        let table = try TOMLTable(string: text)
        let file = try TOMLDecoder().decode(ConfigFile.self, from: table)

        var destinations: [String: Destination] = [:]
        for (name, dest) in file.destinations ?? [:] {
            destinations[name] = Destination(
                name: name,
                title: dest.title ?? name.capitalized,
                kind: Destination.Kind(rawValue: dest.type ?? "terminal") ?? .terminal,
                command: dest.command,
                url: dest.url.flatMap(URL.init(string:)),
                key: dest.key?.first,
                singleton: dest.singleton ?? true
            )
        }

        return Config(
            startupTabs: file.startup?.tabs ?? ["terminal"],
            startupActive: file.startup?.active,
            destinations: destinations,
            orderedDestinations: destinations.values.sorted { $0.title < $1.title },
            fontName: file.general?.font,
            fontSize: file.general?.fontSize ?? 13,
            themeName: file.general?.theme,
            finderRoots: file.finder?.roots ?? ["~/Projects", "~/Downloads", "~/Documents", "~/Desktop"],
            projectScanRoots: file.projects?.scan ?? ["~/Projects", "~/Projects/personal"],
            calendarInclude: file.calendar?.include ?? [],
            calendarExclude: file.calendar?.exclude ?? []
        )
    }
}

// MARK: - Default config (written on first launch)

let defaultConfigTOML = """
# Flightdeck configuration
# Destinations are named places you jump to with the leader key (Ctrl+Space).

[general]
# Terminal font. A Nerd Font makes ranger/starship icons render.
# Omit to auto-detect (tries JetBrainsMono Nerd Font, falls back to SF Mono).
font = "JetBrainsMono Nerd Font"
font_size = 13

[startup]
# Tabs opened at launch, in order. "terminal" = a plain shell tab.
tabs = ["dashboard", "git", "files"]
active = "dashboard"

[destinations.dashboard]
# A multi-pane status tab: system/network/dev status, stocks, weather.
type = "dashboard"
title = "Dashboard"
key = "d"

[calendar]
# Dashboard agenda pane: show only these calendars. An entry matches a
# calendar name ("Work") or a whole account ("you@gmail.com").
# Omit (or leave empty) to show all of them.
# include = ["Personal", "you@gmail.com"]

[finder]
# Directories indexed by the fuzzy file finder (leader+o).
roots = ["~/Projects", "~/Downloads", "~/Documents", "~/Desktop"]

[destinations.files]
# A plain terminal. Type `ff` for the fzf file browser (installed to ~/.local/bin).
type = "terminal"
title = "Files"
key = "f"

[destinations.braindump]
# fzf-browse ~/sync/braindump on open; Esc drops to a shell there.
type = "terminal"
title = "Braindump"
command = "cd ~/sync/braindump && ff; exec ${SHELL:-/bin/zsh} -l"
key = "b"

[destinations.scratchpad]
# A throwaway empty Neovim buffer for quick notes.
type = "terminal"
title = "Scratchpad"
command = "nvim"
key = "s"

[destinations.journal]
# Daily journal: one rolling file with a "## <date>" header per day. Opens at
# the bottom (today's space); scroll up for previous days.
type = "terminal"
title = "Journal"
command = "f=~/sync/braindump/journal.md; h=$(date '+## %A, %B %-d, %Y'); grep -qF \"$h\" \"$f\" 2>/dev/null || printf '\\n%s\\n\\n' \"$h\" >> \"$f\"; nvim + \"$f\""
key = "j"

[destinations.localhost]
# Prompts for a port, then opens http://localhost:<port> in a tab named ":<port>".
type = "localhost"
title = "localhost"
key = "l"

[destinations.chatgpt]
type = "web"
title = "ChatGPT"
url = "https://chatgpt.com"
key = "c"

[destinations.trello]
type = "web"
title = "Trello"
url = "https://trello.com"
key = "r"

[destinations.digitalocean]
type = "web"
title = "Digital Ocean"
url = "https://cloud.digitalocean.com"
key = "o"
"""
