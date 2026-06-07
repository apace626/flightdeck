import Foundation

/// A Unix-domain socket that lets pane processes drive Flightdeck. A shell sends
/// a tab-separated command line; the handler runs on the main queue.
///
/// Protocol (one line per connection):
///   tab<TAB><title><TAB><shell command>     → open a new tab running the command
///   goto<TAB><destination-or-project name>   → jump to / open a destination
final class ControlServer {
    static let socketPath = NSHomeDirectory() + "/.config/flightdeck/control.sock"

    private var fd: Int32 = -1
    private let handler: (String) -> Void

    init(handler: @escaping (String) -> Void) {
        self.handler = handler
        start()
    }

    deinit { stop() }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(ControlServer.socketPath)
    }

    private func start() {
        let path = ControlServer.socketPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                strncpy(dst, src, maxLen - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd); fd = -1; return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while fd >= 0 {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &buf, buf.count)
            if n > 0, let line = String(bytes: buf[0..<n], encoding: .utf8) {
                let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cmd.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.handler(cmd) }
                }
            }
            close(client)
        }
    }
}
