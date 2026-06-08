import Foundation

/// The dashboard tab's pane layout. Orchestrates existing tools — no logic of
/// our own. The status pane runs an editable shell script in the config dir.
///
///   ┌──────────────────────────────────────────────┐
///   │  Flightdeck · date · time                     │
///   │  SYSTEM  battery · disk · load                │
///   │  NET     local ip · public ip · city          │
///   │  DEV     dirty repos · listening ports        │
///   ├──────────────────────────────────────────────┤
///   │  weather — wttr.in 3-day forecast (full art)  │
///   └──────────────────────────────────────────────┘
enum Dashboard {
    static func spec() -> PaneSpec {
        let status = ensureScript(name: "status.sh", content: statusScript)
        let stocks = ensureScript(name: "stocks.sh", content: stocksScript)
        return .split(vertical: false, ratios: [0.30, 0.22, 0.48], children: [
            .terminal(command: "sh '\(status)'", hideCursor: true),
            .terminal(command: "sh '\(stocks)'", hideCursor: true),
            .terminal(command: weather, hideCursor: true),
        ])
    }

    /// Write a default dashboard script to the config dir if absent, return its path.
    /// Users can edit them freely (or delete to regenerate). Config-driven by design.
    private static func ensureScript(name: String, content: String) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/flightdeck", isDirectory: true)
        let path = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? content.write(to: path, atomically: true, encoding: .utf8)
        }
        return path.path
    }

    // Full wttr.in output for ZIP 77059 — ASCII art + current + 3-day forecast.
    private static let weather = """
    while true; do \
      clear; \
      curl -s --max-time 10 'wttr.in/77059' 2>/dev/null || echo 'weather unavailable (offline?)'; \
      sleep 1800; \
    done
    """

    // The default dashboard status script (written to ~/.config/flightdeck/status.sh).
    private static let statusScript = """
    #!/bin/sh
    # Flightdeck dashboard status — edit freely; the dashboard runs this on launch.
    # Delete this file to regenerate the default.

    PROJECTS_DIR="$HOME/Projects/personal"
    PORTS="3000 8080 9090 5173"

    e=$(printf '\\033')
    dim="$e[2m"; bold="$e[1m"; cyan="$e[1;36m"; white="$e[1;37m"; ylw="$e[1;33m"; rst="$e[0m"

    ip4=""; pubip=""; city=""; net_t=0
    sys=""; dev=""; slow_t=0

    while true; do
      now=$(date +%s)

      # Network — every 60s
      if [ -z "$pubip" ] || [ $((now - net_t)) -ge 60 ]; then
        ip4=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '-')
        net=$(curl -s --max-time 4 ipinfo.io 2>/dev/null)
        pubip=$(printf '%s' "$net" | sed -n 's/.*"ip": "\\([^"]*\\)".*/\\1/p')
        city=$(printf '%s' "$net" | sed -n 's/.*"city": "\\([^"]*\\)".*/\\1/p')
        [ -z "$pubip" ] && pubip='-'
        net_t=$now
      fi

      # System + Dev — every 5s
      if [ -z "$sys" ] || [ $((now - slow_t)) -ge 5 ]; then
        batt=$(pmset -g batt | grep -Eo '[0-9]+%' | head -1)
        bstate=$(pmset -g batt | grep -Eo 'charging|discharging|charged' | head -1)
        [ -z "$batt" ] && batt="AC"
        disk=$(df -h / | awk 'NR==2{print $4}')
        load=$(sysctl -n vm.loadavg | awk '{print $2}')
        sys="$batt $bstate  -  $disk free  -  load $load"

        dirty=0
        for d in "$PROJECTS_DIR"/*/; do
          [ -d "$d.git" ] || continue
          [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ] && dirty=$((dirty + 1))
        done
        open=""
        for p in $PORTS; do
          lsof -ti:"$p" >/dev/null 2>&1 && open="$open :$p"
        done
        [ -z "$open" ] && open=" none"
        dev="$dirty repo(s) changed  -  ports$open"
        slow_t=$now
      fi

      clear
      printf '\\n  %sFlightdeck%s\\n' "$cyan" "$rst"
      printf '  %s%s%s\\n' "$bold" "$(date '+%A  %B %-d')" "$rst"
      printf '  %s%s%s\\n\\n' "$white" "$(date '+%H:%M:%S')" "$rst"
      printf '  %sSYSTEM%s  %s%s%s\\n' "$ylw" "$rst" "$dim" "$sys" "$rst"
      printf '  %sNET   %s  %s%s  -  %s %s%s\\n' "$ylw" "$rst" "$dim" "$ip4" "$pubip" "$city" "$rst"
      printf '  %sDEV   %s  %s%s%s\\n' "$ylw" "$rst" "$dim" "$dev" "$rst"
      sleep 1
    done
    """

    // Default stocks script (~/.config/flightdeck/stocks.sh). Edit SYMBOLS.
    // Quotes via Yahoo's no-key chart endpoint (stooq now blocks headless curl).
    private static let stocksScript = """
    #!/bin/sh
    # Flightdeck stocks — edit SYMBOLS below. Delete this file to regenerate.
    # Stocks: AAPL · indices: ^GSPC ^IXIC · crypto: BTC-USD ETH-USD
    SYMBOLS="NVDA AAL YOLO ^GSPC ^IXIC ^DJI"

    exec python3 - "$SYMBOLS" <<'PY'
    import sys, time, json, urllib.request
    syms = sys.argv[1].split()
    RED="\\033[31m"; GRN="\\033[32m"; DIM="\\033[2m"; YLW="\\033[1;33m"; RST="\\033[0m"
    def quote(s):
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{s}?interval=1d&range=1d"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        m = json.load(urllib.request.urlopen(req, timeout=8))["chart"]["result"][0]["meta"]
        p = m["regularMarketPrice"]; pc = m.get("chartPreviousClose") or m.get("previousClose")
        chg = (p - pc) / pc * 100
        col = GRN if chg >= 0 else RED; arr = "▲" if chg >= 0 else "▼"
        return f"  {s:9} {p:>11,.2f}  {col}{arr}{chg:+.2f}%{RST}"
    while True:
        lines = []
        for s in syms:
            try: lines.append(quote(s))
            except Exception: lines.append(f"  {s:9} {DIM}n/a{RST}")
        print("\\033[2J\\033[H", end="")          # clear + home
        print(f"\\n  {YLW}STOCKS{RST}\\n")
        print("\\n".join(lines), flush=True)
        time.sleep(60)
    PY
    """
}
