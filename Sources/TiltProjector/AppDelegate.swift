import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { controller.stopNow() }
    }
}
