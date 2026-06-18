import Foundation

/// A tiny local server powering project "diff" panes: a single, clean list of
/// changed files; click a row (or select with ↑↓/j-k and hit Enter) to expand
/// its unified diff inline underneath — lazygit-style `-`/`+`, rendered here so
/// there's no horizontal scrolling and no diff2html. Auto-refreshes every 2s.
/// A project's right pane points at it:
///   web = "http://127.0.0.1:7717/?repo=/path/to/repo"
///
/// Started once at app launch via a login shell (so nvm's `node` is on PATH).
enum GitDiff {
    static let port = 7717
    private static var proc: Process?

    static var serverPath: String {
        NSHomeDirectory() + "/.config/flightdeck/gitdiff-server.js"
    }

    /// Write the server script and start it (idempotent; a second instance
    /// exits on EADDRINUSE, leaving the first to serve).
    static func start() {
        let dir = NSHomeDirectory() + "/.config/flightdeck"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? serverJS.write(toFile: serverPath, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -ilc → interactive login shell sources ~/.zshrc (nvm), so `node` resolves.
        // exec so killing the Process kills node directly, not just the shell.
        p.arguments = ["-ilc", "exec node '\(serverPath)' \(port)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        proc = p
    }

    static func stop() {
        proc?.terminate()
        proc = nil
    }

    // Node, built-in modules only. Endpoints:
    //   /                       → the SPA (file list + inline diffs)
    //   /files?repo=            → JSON [{path,status}] of changed files
    //   /filediff?repo=&path=   → JSON [{cls,text}] classified diff lines
    private static let serverJS = """
    const http = require('http');
    const { execFile } = require('child_process');
    const os = require('os');
    const PORT = parseInt(process.argv[2] || '7717', 10);

    function expand(p) { return p && p.startsWith('~') ? os.homedir() + p.slice(1) : p; }

    function git(repo, args) {
      return new Promise((resolve) => {
        execFile('git', ['-C', repo].concat(args), { maxBuffer: 1 << 22 }, (e, out) => resolve((out || '').trim()));
      });
    }

    // Files + repo info (branch, ahead/behind upstream, last commit) in one shot.
    async function status(repo) {
      const [porc, branch, ahead, behind, last] = await Promise.all([
        git(repo, ['-c', 'core.quotePath=false', 'status', '--porcelain', '--untracked-files=all']),
        git(repo, ['branch', '--show-current']),
        git(repo, ['rev-list', '--count', '@{u}..HEAD']),   // ahead (empty if no upstream)
        git(repo, ['rev-list', '--count', 'HEAD..@{u}']),   // behind
        git(repo, ['log', '-1', '--format=%cr']),           // last commit, relative
      ]);
      const files = porc.split('\\n').filter(Boolean).map((line) => {
        const x = line.charAt(0), y = line.charAt(1);
        let p = line.slice(3);
        const arrow = p.indexOf(' -> ');
        if (arrow >= 0) p = p.slice(arrow + 4);
        const st = (x === '?' || y === '?') ? '?'
                 : (x === 'A' || y === 'A') ? 'A'
                 : (x === 'D' || y === 'D') ? 'D'
                 : (x === 'R') ? 'R' : 'M';
        return { path: p, status: st };
      });
      const home = os.homedir();
      const dir = repo.startsWith(home) ? '~' + repo.slice(home.length) : repo;
      return {
        branch: branch || '(detached)',
        ahead: parseInt(ahead || '0', 10) || 0,
        behind: parseInt(behind || '0', 10) || 0,
        last: last,
        dir: dir,
        files: files,
      };
    }

    // Classify the unified diff into lines the client renders directly — keeps
    // the (newline-splitting) parsing server-side so the client JS stays simple.
    function fileDiff(repo, path, status, cb) {
      const args = status === '?'
        ? ['diff', '--no-index', '--', '/dev/null', path]
        : ['diff', 'HEAD', '--', path];
      execFile('git', args, { cwd: repo, maxBuffer: 1 << 24 }, (e, out) => {
        const result = [];
        (out || '').split('\\n').forEach((ln) => {
          if (ln.indexOf('@@') === 0) { result.push({ cls: 'hunk', text: ln }); return; }
          if (ln === '' || ln.indexOf('+++') === 0 || ln.indexOf('---') === 0
              || ln.indexOf('diff ') === 0 || ln.indexOf('index ') === 0
              || ln.indexOf('new file') === 0 || ln.indexOf('deleted file') === 0
              || ln.indexOf('similarity') === 0 || ln.indexOf('rename ') === 0
              || ln.indexOf('Binary ') === 0) return;
          const c0 = ln.charAt(0);
          result.push({ cls: c0 === '+' ? 'add' : c0 === '-' ? 'del' : 'ctx', text: ln });
        });
        cb(result);
      });
    }

    function page(repo) {
      return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="color-scheme" content="dark">
    <style>
      *{box-sizing:border-box}
      html,body{margin:0;background:#1e1e2e;color:#cdd6f4;font:13px/1.5 -apple-system,system-ui,sans-serif}
      #head{position:sticky;top:0;background:#1e1e2e;border-bottom:1px solid #313244;padding:11px 16px;z-index:5}
      #toprow{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
      .hcol{display:flex;flex-direction:column;min-width:0}
      .hright{align-items:flex-end}
      #count{color:#cba6f7;font-weight:600;font-size:12px;letter-spacing:.03em}
      #info{display:flex;gap:10px;align-items:baseline;justify-content:flex-end;font-size:11.5px;white-space:nowrap;overflow:hidden}
      #info .br{color:#89b4fa;font-weight:600}
      #info .bicon{font-family:"JetBrainsMono Nerd Font","Symbols Nerd Font",monospace;font-weight:400;margin-right:2px}
      #info .ab{color:#f9e2af}
      #info .last{color:#6c7086;overflow:hidden;text-overflow:ellipsis}
      #dir{color:#7f849c;font-size:11px;margin-top:3px;font-family:ui-monospace,"SF Mono",monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
      #hint{color:#585b70;font-size:11px;margin-top:3px}
      .file{display:flex;align-items:center;gap:8px;padding:7px 16px;cursor:pointer;white-space:nowrap;border-left:2px solid transparent}
      .file:hover{background:#26263a}
      .file.sel{border-left-color:#cba6f7}
      .file.open{background:#26263a;font-weight:600}
      .caret{color:#585b70;font-size:9px;width:10px;flex:none;transition:transform .12s}
      .file.open .caret{transform:rotate(90deg)}
      .badge{font:700 12px ui-monospace,monospace;width:12px;text-align:center;flex:none}
      .fname{overflow:hidden;text-overflow:ellipsis}
      .fname .dir{color:#6c7086;font-weight:400}
      .diffbox{background:#181825;border-top:1px solid #313244;border-bottom:1px solid #313244;padding:6px 0}
      .dl{font:12px/1.5 ui-monospace,"SF Mono",monospace;white-space:pre-wrap;word-break:break-word;padding:0 16px;border-left:3px solid transparent}
      .dl.add{background:rgba(166,227,161,.10);border-left-color:#a6e3a1}
      .dl.del{background:rgba(243,139,168,.10);border-left-color:#f38ba8}
      .dl.hunk{color:#89b4fa;padding-top:4px;padding-bottom:2px}
      .dl.ctx{color:#9399b2}
      .empty{color:#6c7086;padding:30px 16px}
    </style></head><body>
    <div id="head">
      <div id="toprow">
        <div class="hcol"><div id="count">…</div><div id="hint">↑↓ / j k to move · enter or click to expand</div></div>
        <div class="hcol hright"><div id="info"></div><div id="dir"></div></div>
      </div>
    </div>
    <div id="list"></div>
    <script>
      var REPO = ${JSON.stringify(repo)};
      var files = [], sel = -1, open = {}, cache = {};

      function color(s){ return s==="A"?"#a6e3a1":s==="D"?"#f38ba8":s==="?"?"#89b4fa":s==="R"?"#cba6f7":"#f9e2af"; }
      function esc(s){ return s.split("&").join("&amp;").split("<").join("&lt;").split(">").join("&gt;"); }

      function renderDiff(arr){
        if(!arr || !arr.length) return '<div class="empty">No changes.</div>';
        var h = "";
        for(var i=0;i<arr.length;i++){ h += '<div class="dl '+arr[i].cls+'">'+(esc(arr[i].text)||" ")+'</div>'; }
        return h;
      }

      function render(){
        var y = window.scrollY;
        var c = document.getElementById("list");
        document.getElementById("count").textContent = files.length + (files.length===1?" CHANGED FILE":" CHANGED FILES");
        c.innerHTML = "";
        if(!files.length){ c.innerHTML = '<div class="empty">No uncommitted changes.</div>'; return; }
        files.forEach(function(f,i){
          var row = document.createElement("div");
          row.className = "file" + (i===sel?" sel":"") + (open[f.path]?" open":"");
          var car = document.createElement("span"); car.className="caret"; car.textContent="▶";
          var b = document.createElement("span"); b.className="badge"; b.textContent=f.status; b.style.color=color(f.status);
          var n = document.createElement("span"); n.className="fname";
          var parts = f.path.split("/"); var base = parts.pop(); var dir = parts.length?parts.join("/")+"/":"";
          n.innerHTML = "<span class='dir'>"+dir+"</span>"+base;
          row.appendChild(car); row.appendChild(b); row.appendChild(n);
          row.onclick = function(){ sel=i; toggle(f.path); };
          c.appendChild(row);
          if(open[f.path]){
            var box = document.createElement("div"); box.className="diffbox";
            box.innerHTML = renderDiff(cache[f.path]);
            c.appendChild(box);
          }
        });
        window.scrollTo(0,y);
      }

      function toggle(path){
        if(open[path]) delete open[path];
        else { open[path]=true; loadDiff(path); }
        render();
      }

      function loadDiff(path){
        var f = files.find(function(x){return x.path===path;}); if(!f) return;
        fetch("/filediff?repo="+encodeURIComponent(REPO)+"&path="+encodeURIComponent(path)+"&status="+encodeURIComponent(f.status))
          .then(function(r){return r.json();})
          .then(function(arr){ cache[path]=arr; if(open[path]) render(); }).catch(function(){});
      }

      function scrollSel(){ var rows=document.querySelectorAll(".file"); if(rows[sel]) rows[sel].scrollIntoView({block:"nearest"}); }

      document.addEventListener("keydown", function(e){
        if(e.key==="ArrowDown"||e.key==="j"){ e.preventDefault(); sel=Math.min(sel+1, files.length-1); render(); scrollSel(); }
        else if(e.key==="ArrowUp"||e.key==="k"){ e.preventDefault(); sel=Math.max(sel-1, 0); render(); scrollSel(); }
        else if(e.key==="Enter"||e.key===" "){ e.preventDefault(); if(sel>=0 && files[sel]) toggle(files[sel].path); }
      });

      function renderInfo(s){
        var parts = [];
        parts.push('<span class="br"><span class="bicon">\\ue0a0</span>'+esc(s.branch||"")+'</span>');
        if(s.ahead||s.behind) parts.push('<span class="ab">↑'+s.ahead+' ↓'+s.behind+'</span>');
        if(s.last) parts.push('<span class="last">Last Commit: '+esc(s.last)+'</span>');
        document.getElementById("info").innerHTML = parts.join("");
        document.getElementById("dir").textContent = s.dir || "";
      }

      function poll(){
        fetch("/files?repo="+encodeURIComponent(REPO)).then(function(r){return r.json();}).then(function(s){
          files = s.files || [];
          renderInfo(s);
          if(sel>=files.length) sel=files.length-1;
          if(sel<0 && files.length) sel=0;
          Object.keys(open).forEach(function(p){
            if(files.find(function(x){return x.path===p;})) loadDiff(p); else delete open[p];
          });
          render();
        }).catch(function(){});
      }

      poll(); setInterval(poll, 2000);
    </script></body></html>`;
    }

    const server = http.createServer((req, res) => {
      const u = new URL(req.url, 'http://127.0.0.1');
      const repo = expand(u.searchParams.get('repo') || process.cwd());
      if (u.pathname === '/files') {
        status(repo).then((s) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(s)); });
      } else if (u.pathname === '/filediff') {
        fileDiff(repo, u.searchParams.get('path') || '', u.searchParams.get('status') || 'M',
                 (d) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(d)); });
      } else {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(page(repo));
      }
    });
    server.on('error', (e) => { process.exit(e.code === 'EADDRINUSE' ? 0 : 1); });
    server.listen(PORT, '127.0.0.1');
    """
}
