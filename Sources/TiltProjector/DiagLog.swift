import AppKit
import Foundation

/// Always-on diagnostics, persisted across launches in ~/Library/Logs/tiltProjector/tiltProjector.log.
/// Lifecycle events (launch, quit, stop reasons, display/Space/sleep changes, crashes) are always recorded;
/// high-rate frame/draw lines are throttled. The file rotates at 5 MB (one previous copy is kept).
enum DiagLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tiltProjector", isDirectory: true)
    static let path = directory.appendingPathComponent("tiltProjector.log").path
    private static let maxBytes = 5_000_000

    private static let lock = NSLock()
    private static var last: [String: Date] = [:]
    private static var frames = 0
    private static var fd: Int32 = -1
    private static let pid = ProcessInfo.processInfo.processIdentifier
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func openFile() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
            let old = path + ".1"
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.moveItem(atPath: path, toPath: old)
        }
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    static func write(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        if fd < 0 { openFile() }
        guard fd >= 0 else { return }
        let line = "\(formatter.string(from: Date())) [\(pid)] \(s)\n"
        _ = line.withCString { Foundation.write(fd, $0, strlen($0)) }
    }

    private static func throttled(_ key: String, every: TimeInterval = 5, _ s: @autoclosure () -> String) {
        lock.lock()
        let now = Date()
        let ok = now.timeIntervalSince(last[key] ?? .distantPast) > every
        if ok { last[key] = now }
        lock.unlock()
        if ok { write(s()) }
    }

    static func frame(_ w: Int, _ h: Int, _ hasHandler: Bool) {
        lock.lock(); frames += 1; let n = frames; lock.unlock()
        throttled("frame", "frame \(w)x\(h) handler=\(hasHandler) totalFrames=\(n)")
    }

    static func draw(hasTexture: Bool, params: TiltParams, size: CGSize) {
        throttled("draw", "draw texture=\(hasTexture) size=\(Int(size.width))x\(Int(size.height)) pitch=\(params.pitch) yaw=\(params.yaw) roll=\(params.roll) zoom=\(params.zoom)")
    }

    /// Call once at launch: records the launch and hooks crashes, signals and system events.
    static func install() {
        let info = Bundle.main.infoDictionary
        write("=== launch v\(info?["CFBundleShortVersionString"] ?? "?") macOS \(ProcessInfo.processInfo.operatingSystemVersionString) screens=\(NSScreen.screens.map { $0.localizedName })")

        NSSetUncaughtExceptionHandler { e in
            DiagLog.write("UNCAUGHT EXCEPTION \(e.name.rawValue): \(e.reason ?? "") \n\(e.callStackSymbols.joined(separator: "\n"))")
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGTERM, SIGHUP, SIGINT] {
            signal(sig) { s in
                DiagLog.write("SIGNAL \(s) received; backtrace:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                signal(s, SIG_DFL)
                raise(s)
            }
        }

        let nc = NotificationCenter.default
        let wc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            write("screens changed: \(NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))" })")
        }
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            write("=== willTerminate")
        }
        for (name, text) in [
            (NSWorkspace.activeSpaceDidChangeNotification, "active Space changed"),
            (NSWorkspace.willSleepNotification, "system will sleep"),
            (NSWorkspace.didWakeNotification, "system did wake"),
            (NSWorkspace.screensDidSleepNotification, "screens did sleep"),
            (NSWorkspace.screensDidWakeNotification, "screens did wake"),
        ] {
            wc.addObserver(forName: name, object: nil, queue: .main) { _ in write(text) }
        }
    }
}
