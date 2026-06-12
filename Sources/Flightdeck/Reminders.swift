import AppKit
import EventKit

/// Native Apple Reminders integration via EventKit — no external CLI.
/// Capture happens anywhere (Siri in the car, the phone, Reminders.app); iCloud
/// syncs to this Mac and Flightdeck just displays. Every 30s the app fetches
/// incomplete reminders and writes an ANSI-rendered snapshot that the
/// dashboard's right pane (a dumb `cat` loop) renders. "Add Reminder" in the
/// launcher creates reminders directly.
enum Reminders {
    private static let store = EKEventStore()
    private static var timer: Timer?
    private static var granted = false

    static let snapshotPath = NSHomeDirectory() + "/.config/flightdeck/reminders.txt"

    // ANSI palette (matches dash-top.sh)
    private static let dim = "\u{1B}[2m"
    private static let ylw = "\u{1B}[1;33m"
    private static let red = "\u{1B}[1;31m"
    private static let grn = "\u{1B}[1;32m"
    private static let rst = "\u{1B}[0m"

    // MARK: - Access + snapshot feed

    /// Request Reminders access (TCC prompt on first launch — needs the usage
    /// strings bundle.sh puts in Info.plist) and start the snapshot refresher.
    static func start() {
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                granted = ok
                guard ok else {
                    write("""

                      \(dim)Reminders access denied.\(rst)
                      \(dim)System Settings → Privacy & Security\(rst)
                      \(dim)→ Reminders → enable Flightdeck,\(rst)
                      \(dim)then relaunch.\(rst)

                    """)
                    return
                }
                refresh()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in refresh() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders { ok, _ in finish(ok) }
        } else {
            store.requestAccess(to: .reminder) { ok, _ in finish(ok) }
        }
    }

    /// Fetch incomplete reminders and rewrite the dashboard snapshot.
    static func refresh() {
        guard granted else { return }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { reminders in
            write(render(reminders ?? []))
        }
    }

    // MARK: - Quick capture

    /// Create a reminder from launcher text. Syntax: plain words = title,
    /// `#list` picks the Reminders list, `due:friday-9am` sets a due date
    /// (dashes become spaces, parsed as natural language). Completion runs on
    /// the main queue with a one-line message for the toast.
    static func add(_ text: String, completion: @escaping (String) -> Void) {
        let done: (String) -> Void = { msg in DispatchQueue.main.async { completion(msg) } }
        guard granted else {
            done("Reminders access not granted")
            return
        }

        var listName: String?
        var dueRaw: String?
        var words = text.split(separator: " ").map(String.init)
        words.removeAll { word in
            if word.hasPrefix("#"), word.count > 1 {
                listName = String(word.dropFirst()); return true
            }
            if word.lowercased().hasPrefix("due:"), word.count > 4 {
                dueRaw = String(word.dropFirst(4)); return true
            }
            return false
        }
        let title = words.joined(separator: " ")
        guard !title.isEmpty else { return }

        let calendar = listName.flatMap { name in
            store.calendars(for: .reminder).first { $0.title.lowercased() == name.lowercased() }
        } ?? store.defaultCalendarForNewReminders()
        guard let calendar else {
            done("no Reminders list available")
            return
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let dueRaw {
            let phrase = dueRaw.replacingOccurrences(of: "-", with: " ")
            if let date = detectDate(phrase) {
                // "9am" / "17:30" → reminder gets a time (and an alarm so it
                // actually notifies); a bare day stays date-only.
                let hasTime = phrase.range(of: #"\d(am|pm|:)"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil
                var units: Set<Calendar.Component> = [.year, .month, .day]
                if hasTime { units.insert(.hour); units.insert(.minute) }
                reminder.dueDateComponents = Calendar.current.dateComponents(units, from: date)
                if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
            }
        }

        do {
            try store.save(reminder, commit: true)
            refresh()
            done("added to \(calendar.title)")
        } catch {
            done("failed: \(error.localizedDescription)")
        }
    }

    private static func detectDate(_ s: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.date
    }

    // MARK: - Rendering

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Group by list (lists = projects), due-dated items first within each,
    /// overdue red / today yellow. Footer: open and overdue counts.
    private static func render(_ reminders: [EKReminder]) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var lines: [String] = []
        var open = 0
        var overdue = 0

        let byList = Dictionary(grouping: reminders) { $0.calendar?.title ?? "Reminders" }
        let order = store.calendars(for: .reminder).map(\.title)
        let names = order.filter { byList[$0] != nil }
            + byList.keys.filter { !order.contains($0) }.sorted()

        for name in names {
            guard var items = byList[name], !items.isEmpty else { continue }
            items.sort { a, b in
                let da = a.dueDateComponents.flatMap(cal.date(from:))
                let db = b.dueDateComponents.flatMap(cal.date(from:))
                switch (da, db) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return (a.title ?? "") < (b.title ?? "")
                }
            }
            lines.append("")
            lines.append("  \(ylw)\(name.uppercased())\(rst)")
            for r in items {
                open += 1
                var due = ""
                if let comps = r.dueDateComponents, let d = cal.date(from: comps) {
                    let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d)).day ?? 0
                    if days < 0 { overdue += 1; due = "\(red)\(-days)d late\(rst)" }
                    else if days == 0 { due = "\(ylw)today\(rst)" }
                    else if days == 1 { due = "tmrw" }
                    else { due = "\(dim)\(monthDay.string(from: d))\(rst)" }
                }
                var title = r.title ?? "(untitled)"
                if title.count > 28 { title = String(title.prefix(27)) + "…" }
                let padded = title.padding(toLength: 28, withPad: " ", startingAt: 0)
                lines.append("  ● \(padded) \(due)")
            }
        }

        if lines.count > 30 {
            lines = Array(lines.prefix(29))
            lines.append("  \(dim)…\(rst)")
        }
        lines.append("")
        lines.append(open == 0
            ? "  \(grn)all clear\(rst)"
            : "  \(dim)\(open) open · \(overdue) overdue\(rst)")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func write(_ text: String) {
        let dir = (snapshotPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: snapshotPath, atomically: true, encoding: .utf8)
    }
}
