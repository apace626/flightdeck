import AppKit
import EventKit

/// Calendar agenda for the dashboard (CarPlay-style: today + tomorrow), via
/// EventKit — same pattern as Reminders.swift: the app fetches and renders a
/// snapshot (~/.config/flightdeck/events.txt); a dumb pane script cats it.
/// `[calendar] include = [...]` in config.toml restricts which calendars show.
enum CalendarEvents {
    private static let store = EKEventStore()
    private static var timer: Timer?
    private static var granted = false
    private static var include: [String] = []   // empty = all calendars
    private static var exclude: [String] = []    // drop these (by name or account)

    static let snapshotPath = NSHomeDirectory() + "/.config/flightdeck/events.txt"
    static let calendarsPath = NSHomeDirectory() + "/.config/flightdeck/calendars.txt"

    // ANSI palette (matches dash-top.sh)
    private static let dim = "\u{1B}[2m"
    private static let ylw = "\u{1B}[1;33m"
    private static let grn = "\u{1B}[1;32m"
    private static let rst = "\u{1B}[0m"

    /// Request Calendar access (TCC prompt on first launch — usage strings come
    /// from bundle.sh) and refresh the agenda snapshot every 2 minutes.
    static func start(include calendarNames: [String], exclude excludeNames: [String] = []) {
        include = calendarNames
        exclude = excludeNames
        let finish: (Bool) -> Void = { ok in
            DispatchQueue.main.async {
                granted = ok
                guard ok else {
                    write("""

                      \(dim)Calendar access denied.\(rst)
                      \(dim)System Settings → Privacy & Security\(rst)
                      \(dim)→ Calendars → enable Flightdeck,\(rst)
                      \(dim)then relaunch.\(rst)

                    """)
                    return
                }
                refresh()
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in refresh() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in finish(ok) }
        } else {
            store.requestAccess(to: .event) { ok, _ in finish(ok) }
        }
    }

    static func refresh() {
        guard granted else { return }
        DispatchQueue.global(qos: .utility).async {
            dumpCalendars()   // keep ~/.config/flightdeck/calendars.txt current
            let cal = Calendar.current
            let startToday = cal.startOfDay(for: Date())
            guard let end = cal.date(byAdding: .day, value: 2, to: startToday) else { return }

            // include (whitelist) then exclude (blacklist). An entry matches a
            // calendar by its own name ("Work") or its account
            // ("you@gmail.com" → all of that account's calendars).
            var calendars = store.calendars(for: .event)
            if !include.isEmpty { calendars = calendars.filter { matches($0, include) } }
            if !exclude.isEmpty { calendars = calendars.filter { !matches($0, exclude) } }
            if calendars.isEmpty {
                write("\n  \(dim)no calendars after include/exclude filters —\(rst)\n  \(dim)see ~/.config/flightdeck/calendars.txt\(rst)\n")
                return
            }

            let predicate = store.predicateForEvents(withStart: startToday, end: end, calendars: calendars)
            let events = store.events(matching: predicate).sorted {
                ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast)
            }
            write(render(events, startToday: startToday))
        }
    }

    // MARK: - Rendering

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    private static func render(_ events: [EKEvent], startToday: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let startTomorrow = cal.date(byAdding: .day, value: 1, to: startToday)!

        func lines(for events: [EKEvent]) -> [String] {
            guard !events.isEmpty else { return ["  \(dim)nothing scheduled\(rst)"] }
            return events.map { e in
                var title = e.title ?? "(untitled)"
                if title.count > 26 { title = String(title.prefix(25)) + "…" }
                if e.isAllDay {
                    return "  \(dim)all-day\(rst)      \(title)"
                }
                let span = "\(hm.string(from: e.startDate))–\(hm.string(from: e.endDate))"
                let padded = span.padding(toLength: 12, withPad: " ", startingAt: 0)
                if e.startDate <= now && now <= e.endDate {
                    return "  \(grn)▶ \(padded)\(title)\(rst)"          // happening now
                }
                if e.endDate < now {
                    return "  \(dim)\(padded)\(title)\(rst)"            // already over
                }
                return "  \(padded) \(title)"
            }
        }

        let today = events.filter { $0.startDate < startTomorrow }
        let tomorrow = events.filter { $0.startDate >= startTomorrow }

        var out: [String] = []
        out.append("")
        out.append("  \(ylw)TODAY\(rst)  \(dim)\(dayLabel.string(from: startToday))\(rst)")
        out += lines(for: today)
        out.append("")
        out.append("  \(ylw)TOMORROW\(rst)  \(dim)\(dayLabel.string(from: startTomorrow))\(rst)")
        out += lines(for: tomorrow)
        return out.joined(separator: "\n") + "\n"
    }

    /// True if `cal` matches any name in `names`, by its own title or its
    /// account (source) title. Case-insensitive.
    private static func matches(_ cal: EKCalendar, _ names: [String]) -> Bool {
        let wanted = Set(names.map { $0.lowercased() })
        return wanted.contains(cal.title.lowercased())
            || wanted.contains((cal.source?.title ?? "").lowercased())
    }

    /// Write the full list of calendars EventKit sees to calendars.txt, grouped
    /// by account, with ✓ (shown) / · (filtered out). EventKit ignores
    /// Calendar.app's show/hide checkboxes, so this is the real source list —
    /// use it to fill in `[calendar] exclude`/`include`.
    private static func dumpCalendars() {
        let cals = store.calendars(for: .event).sorted {
            (($0.source?.title ?? "") + $0.title).lowercased()
                < (($1.source?.title ?? "") + $1.title).lowercased()
        }
        var lines = [
            "Calendars EventKit sees — Calendar.app's show/hide checkboxes do NOT",
            "affect this list. Mark unwanted ones in ~/.config/flightdeck/config.toml:",
            "",
            "  [calendar]",
            "  exclude = [\"US Holidays\", \"Birthdays\"]   # drop these",
            "  # include = [\"Personal\", \"Work\"]        # OR show only these",
            "",
            "  ✓ = currently shown    · = filtered out",
            "",
        ]
        var lastSource = ""
        for c in cals {
            let src = c.source?.title ?? "?"
            if src != lastSource { lines.append("[\(src)]"); lastSource = src }
            let included = include.isEmpty || matches(c, include)
            let excluded = !exclude.isEmpty && matches(c, exclude)
            let shown = included && !excluded
            lines.append("  \(shown ? "✓" : "·") \(c.title)")
        }
        let dir = (calendarsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(toFile: calendarsPath, atomically: true, encoding: .utf8)
    }

    private static func write(_ text: String) {
        let dir = (snapshotPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: snapshotPath, atomically: true, encoding: .utf8)
    }
}
