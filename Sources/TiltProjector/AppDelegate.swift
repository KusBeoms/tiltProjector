import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagLog.install()
        controller = MainActor.assumeIsolated { AppController() }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "tiltProjector"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ControlView(controller: controller))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Diagnostic: TILT_AUTOTEST=1 starts a display capture in a floating window and applies a tilt.
        if ProcessInfo.processInfo.environment["TILT_AUTOTEST"] != nil {
            let c = controller!
            Task { @MainActor in
                await c.refresh()
                if let name = ProcessInfo.processInfo.environment["TILT_AUTOTEST_WINDOW"],
                   let item = c.catalog.windows.first(where: { $0.title.contains(name) }) {
                    c.selectedSource = item.id
                    DiagLog.write("autotest source window: \(item.title)")
                }
                if ProcessInfo.processInfo.environment["TILT_AUTOTEST"] == "display",
                   let id = (ProcessInfo.processInfo.environment["TILT_AUTOTEST_SCREEN"] == "first" ? c.screens.first : c.screens.last)?.id {
                    c.selectedOutput = .display(id)
                } else {
                    c.selectedOutput = .floating
                }
                await c.start()
                DiagLog.write("autotest running=\(c.isRunning) status=\(c.status)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                c.model.params = TiltParams(pitch: 25, yaw: 30).clamped()
                DiagLog.write("autotest tilt applied")
                if ProcessInfo.processInfo.environment["TILT_AUTOTEST_DROP"] != nil {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    DiagLog.write("autotest: simulating capture drop")
                    c.capture.onStopped?(NSError(domain: "autotest", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated drop"]))
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DiagLog.write("last window closed -> app will quit (windows: \(NSApp.windows.map { "\($0.title.isEmpty ? "-" : $0.title) visible=\($0.isVisible)" }))")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagLog.write("applicationWillTerminate")
        MainActor.assumeIsolated { controller.stopNow() }
    }
}
