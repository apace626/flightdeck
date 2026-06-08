import Foundation
import AppKit
import TOMLKit

/// A command runnable inside a project (leader+r menu). `target` decides where output goes.
struct ProjectCommand {
    enum Target { case splitDown, splitRight, tab, current }
    let key: Character?
    let name: String
    let run: String
    let target: Target
}

/// A project discovered from a `flightdeck.toml`. Its layout is a ready-to-build PaneSpec.
struct Project {
    let name: String
    let key: Character?
    let root: String
    let env: [String: String]
    let layout: PaneSpec
    let commands: [ProjectCommand]
}

// MARK: - TOML shape

private struct RawProjectFile: Codable {
    struct Meta: Codable {
        var name: String?
        var key: String?
        var root: String?
    }
    struct Command: Codable {
        var key: String?
        var run: String
        var `in`: String?
    }
    var project: Meta?
    var env: [String: String]?
    var layout: RawLayout?
    var commands: [String: Command]?
}

/// One project entry in a central `projects.toml` (keyed by project name).
private struct RawCentralProject: Codable {
    var name: String?
    var root: String?
    var key: String?
    var env: [String: String]?
    var layout: RawLayout?
    var commands: [String: RawProjectFile.Command]?
}

/// A layout node: either a leaf (`run`/`web`) or a split (`split` + `panes`).
private struct RawLayout: Codable {
    var split: String?          // "row" → side by side · "col"/"column" → stacked
    var ratios: [Double]?
    var panes: [RawLayout]?
    var run: String?
    var web: String?
    var cwd: String?
    var name: String?
}

// MARK: - Loader

enum ProjectLoader {
    /// Scan roots for `flightdeck.toml` (in each root and one level down).
    static func scan(_ roots: [String]) -> [Project] {
        let fm = FileManager.default
        var found: [Project] = []
        var seenPaths = Set<String>()

        for root in roots {
            let base = (root as NSString).expandingTildeInPath
            var candidates = ["\(base)/flightdeck.toml"]
            if let entries = try? fm.contentsOfDirectory(atPath: base) {
                for entry in entries {
                    candidates.append("\(base)/\(entry)/flightdeck.toml")
                }
            }
            for path in candidates where fm.fileExists(atPath: path) && !seenPaths.contains(path) {
                seenPaths.insert(path)
                if let project = load(path: path) {
                    found.append(project)
                }
            }
        }
        return found.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Load a central `projects.toml` — `[name]` tables each with an explicit
    /// `root` + layout/env/commands. Lets you define projects you don't own
    /// without dropping a file in their repo.
    static func loadCentral(_ path: String) -> [Project] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let raws = try TOMLDecoder().decode([String: RawCentralProject].self, from: try TOMLTable(string: text))
            var projects: [Project] = []
            for (key, raw) in raws {
                guard let rootRaw = raw.root else {
                    FileHandle.standardError.write(Data("flightdeck: project \"\(key)\" in projects.toml has no root\n".utf8))
                    continue
                }
                let root = expand(rootRaw, relativeTo: NSHomeDirectory())
                let env = raw.env ?? [:]
                let layout = raw.layout.map { build($0, root: root, env: env) }
                    ?? .terminal(command: nil, cwd: root, env: env)
                let commands: [ProjectCommand] = (raw.commands ?? [:]).map { ckey, cmd in
                    ProjectCommand(key: cmd.key?.first, name: ckey, run: cmd.run, target: target(cmd.in))
                }
                projects.append(Project(name: raw.name ?? key, key: raw.key?.first,
                                        root: root, env: env, layout: layout, commands: commands))
            }
            return projects.sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch {
            FileHandle.standardError.write(Data("flightdeck: bad projects.toml: \(error)\n".utf8))
            return []
        }
    }

    static func load(path: String) -> Project? {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let raw = try TOMLDecoder().decode(RawProjectFile.self, from: try TOMLTable(string: text))

            let root = raw.project?.root.map { expand($0, relativeTo: dir) } ?? dir
            let name = raw.project?.name ?? (dir as NSString).lastPathComponent
            let env = raw.env ?? [:]

            let layout = raw.layout.map { build($0, root: root, env: env) }
                ?? .terminal(command: nil, cwd: root, env: env) // no layout → a single shell

            let commands: [ProjectCommand] = (raw.commands ?? [:]).map { key, cmd in
                ProjectCommand(
                    key: cmd.key?.first,
                    name: key,
                    run: cmd.run,
                    target: target(cmd.in)
                )
            }.sorted { ($0.key.map(String.init) ?? $0.name) < ($1.key.map(String.init) ?? $1.name) }

            return Project(name: name, key: raw.project?.key?.first, root: root,
                           env: env, layout: layout, commands: commands)
        } catch {
            FileHandle.standardError.write(Data("flightdeck: bad project config \(path): \(error)\n".utf8))
            return nil
        }
    }

    // MARK: - Conversion

    private static func build(_ node: RawLayout, root: String, env: [String: String]) -> PaneSpec {
        if let panes = node.panes, !panes.isEmpty {
            // A split. "row" = panes side by side (vertical divider); "col" = stacked.
            let kind = (node.split ?? "row").lowercased()
            let sideBySide = kind.hasPrefix("row") || kind == "h" || kind.hasPrefix("horizontal")
            let children = panes.map { build($0, root: root, env: env) }
            let ratios = (node.ratios ?? evenRatios(panes.count)).map { CGFloat($0) }
            return .split(vertical: sideBySide, ratios: ratios, children: children)
        }
        if let web = node.web, let url = URL(string: web) {
            return .web(url)
        }
        // Leaf terminal: run command (if any) in a cwd, with the project env.
        // run panes keepAlive so a finished/errored command leaves the pane (and
        // its output) in place rather than collapsing the layout.
        let cwd = node.cwd.map { expand($0, relativeTo: root) } ?? root
        return .terminal(command: node.run, cwd: cwd, env: env, keepAlive: node.run != nil)
    }

    private static func evenRatios(_ n: Int) -> [Double] {
        guard n > 0 else { return [] }
        return Array(repeating: 1.0 / Double(n), count: n)
    }

    private static func target(_ s: String?) -> ProjectCommand.Target {
        switch (s ?? "split-down").lowercased() {
        case "split-right", "right": return .splitRight
        case "tab": return .tab
        case "current", "here": return .current
        default: return .splitDown
        }
    }

    private static func expand(_ path: String, relativeTo base: String) -> String {
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        if path.hasPrefix("/") { return path }
        return (base as NSString).appendingPathComponent(path)
    }
}
