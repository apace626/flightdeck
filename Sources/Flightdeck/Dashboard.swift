import Foundation

/// The dashboard tab. Top pane = system status + stocks (one combined script);
/// bottom 2/3 = the wttr.in weather forecast. Orchestrates shell — no logic here.
///
///   ┌──────────────────────────────────────────────┐
///   │  Flightdeck · date · time · SYSTEM/NET/DEV    │  top 1/3
///   │  STOCKS …                                     │
///   ├──────────────────────────────────────────────┤
///   │  weather — wttr.in 3-day forecast             │  bottom 2/3
///   └──────────────────────────────────────────────┘
enum Dashboard {
    static func spec() -> PaneSpec {
        let top = ensureScript(name: "dash-top.sh", content: topScript)
        _ = ensureScript(name: "banner.txt", content: bannerArt)
        // Single pane: banner + status + tools + stocks + current weather.
        return .terminal(command: "sh '\(top)'", hideCursor: true)
    }

    /// Write a default dashboard script to the config dir if absent, return its path.
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

    // FLIGHTDECK ASCII wordmark (figlet "small"), written to banner.txt.
    private static let bannerArt = """
     ___ _    ___ ___ _  _ _____ ___  ___ ___ _  __
    | __| |  |_ _/ __| || |_   _|   \\| __/ __| |/ /
    | _|| |__ | | (_ | __ | | | | |) | _| (__| ' <\u{0020}
    |_| |____|___\\___|_||_| |_| |___/|___\\___|_|\\_\\
    """

    // Combined dashboard: system status + stocks + current weather. Edit freely.
    // Delete ~/.config/flightdeck/dash-top.sh to regenerate.
    private static let topScript = """
    #!/bin/sh
    PROJECTS_DIR="$HOME/Projects/personal"
    PORTS="3000 8080 9090 5173"
    SYMBOLS="NVDA AAL YOLO ^GSPC ^IXIC ^DJI"

    e=$(printf '\\033')
    dim="$e[2m"; bold="$e[1m"; cyan="$e[1;36m"; white="$e[1;37m"; ylw="$e[1;33m"; grn="$e[1;32m"; red="$e[1;31m"; rst="$e[0m"
    DEPS="nvim git fzf fd bat pandoc lazygit"

    ip4=""; pubip=""; city=""; net_t=0
    sys=""; dev=""; tools=""; slow_t=0
    stocks=""; stock_t=0
    weather=""; weather_t=0
    repos=""; repos_t=0
    REPO_ROOTS="$HOME/Projects"

    # Instant loading screen (banner + spinner) so the first frame isn't a black
    # void while net/stocks/weather fetch on the first loop pass.
    clear
    printf '\\n%s' "$cyan"
    sed 's/^/  /' "$HOME/.config/flightdeck/banner.txt" 2>/dev/null
    printf '%s\\n\\n  %s%s%s  %s%s%s\\n' "$rst" "$bold" "$(date '+%A  %B %-d')" "$rst" "$white" "$(date '+%H:%M:%S')" "$rst"
    printf '\\n  %s◐  warming up the cockpit — fetching status, stocks, weather…%s\\n' "$cyan" "$rst"

    while true; do
      now=$(date +%s)

      if [ -z "$pubip" ] || [ $((now - net_t)) -ge 60 ]; then
        ip4=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '-')
        net=$(curl -s --max-time 4 ipinfo.io 2>/dev/null)
        pubip=$(printf '%s' "$net" | sed -n 's/.*"ip": "\\([^"]*\\)".*/\\1/p')
        city=$(printf '%s' "$net" | sed -n 's/.*"city": "\\([^"]*\\)".*/\\1/p')
        [ -z "$pubip" ] && pubip='-'
        net_t=$now
      fi

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
        tools=""
        for t in $DEPS; do
          if command -v "$t" >/dev/null 2>&1; then tools="$tools $grn$t$rst"
          else tools="$tools $red$t$rst"; fi
        done
        slow_t=$now
      fi

      if [ $((now - repos_t)) -ge 30 ]; then
        repos=$(
          for base in $REPO_ROOTS; do
            for d in "$base"/*/ "$base"/*/*/; do
              [ -d "$d.git" ] || continue
              st=$(git -C "$d" status --porcelain 2>/dev/null)
              [ -z "$st" ] && continue
              n=$(printf '%s\\n' "$st" | grep -c .)
              br=$(git -C "$d" branch --show-current 2>/dev/null)
              printf '  %s%-22s%s %s[%s]  %s changed%s\\n' "$red" "$(basename "${d%/}")" "$rst" "$dim" "${br:-?}" "$n" "$rst"
            done
          done
        )
        [ -z "$repos" ] && repos="  ${grn}all clean${rst}"
        repos_t=$now
      fi

      if [ -z "$stocks" ] || [ $((now - stock_t)) -ge 60 ]; then
        stocks=$(python3 - "$SYMBOLS" <<'PY'
    import sys, json, urllib.request
    syms = sys.argv[1].split()
    RED = "\\033[31m"; GRN = "\\033[32m"; DIM = "\\033[2m"; RST = "\\033[0m"
    out = []
    for s in syms:
        try:
            url = f"https://query1.finance.yahoo.com/v8/finance/chart/{s}?interval=1d&range=1d"
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            m = json.load(urllib.request.urlopen(req, timeout=8))["chart"]["result"][0]["meta"]
            p = m["regularMarketPrice"]; pc = m.get("chartPreviousClose") or m.get("previousClose")
            chg = (p - pc) / pc * 100
            col = GRN if chg >= 0 else RED; arr = "▲" if chg >= 0 else "▼"
            out.append(f"  {s:8} {p:>10,.2f}  {col}{arr}{chg:+.2f}%{RST}")
        except Exception:
            out.append(f"  {s:8} {DIM}n/a{RST}")
    print("\\n".join(out))
    PY
    )
        stock_t=$now
      fi

      if [ -z "$weather" ] || [ $((now - weather_t)) -ge 1800 ]; then
        w=$(curl -s --max-time 10 'wttr.in/77059?0' 2>/dev/null)
        weather=$(printf '%s' "$w" | sed '1,2d')   # drop wttr's own header line
        [ -z "$weather" ] && weather='  weather unavailable'
        weather_t=$now
      fi

      clear
      printf '\\n%s' "$cyan"
      sed 's/^/  /' "$HOME/.config/flightdeck/banner.txt" 2>/dev/null
      printf '%s\\n' "$rst"
      printf '  %s%s   %s%s%s\\n\\n' "$bold" "$(date '+%A  %B %-d')" "$white" "$(date '+%H:%M:%S')" "$rst"
      printf '  %sSYSTEM%s  %s%s%s\\n' "$ylw" "$rst" "$dim" "$sys" "$rst"
      printf '  %sNET   %s  %s%s  -  %s %s%s\\n' "$ylw" "$rst" "$dim" "$ip4" "$pubip" "$city" "$rst"
      printf '  %sDEV   %s  %s%s%s\\n' "$ylw" "$rst" "$dim" "$dev" "$rst"
      printf '  %sTOOLS %s %s\\n' "$ylw" "$rst" "$tools"
      printf '\\n  %sREPOS%s  %s(uncommitted)%s\\n' "$ylw" "$rst" "$dim" "$rst"
      printf '%s\\n' "$repos"
      printf '\\n  %sSTOCKS%s\\n' "$ylw" "$rst"
      printf '%s\\n' "$stocks"
      printf '\\n  %sWEATHER%s\\n' "$ylw" "$rst"
      printf '%s\\n' "$weather"
      sleep 1
    done
    """
}
