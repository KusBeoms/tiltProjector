import AppKit
import SwiftUI
import MetalKit

final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OutputSession: NSObject, NSWindowDelegate {
    let model: TiltModel
    let renderer: TiltRenderer
    var onClose: (() -> Void)?

    private let window: OutputWindow
    private let hud: NSPanel
    private var closing = false
    private var targetScreenID: UInt32?
    private var watchdog: Timer?
    private var lastStateLog = Date.distantPast

    init?(model: TiltModel, output: OutputID) {
        guard let renderer = TiltRenderer(model: model) else { return nil }
        self.model = model
        self.renderer = renderer

        // Regular apps cannot put windows over another app's full-screen Space; accessory apps can.
        // Must happen before the window is created so it is assigned to the right Space.
        if case .display = output { NSApp.setActivationPolicy(.accessory) }

        let screen: NSScreen
        switch output {
        case .display(let id):
            targetScreenID = id
            screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id } ?? NSScreen.main ?? NSScreen.screens[0]
            window = OutputWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            // Must also appear above other apps' full-screen Spaces on that display.
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.hasShadow = false
            // A non-opaque window does not count as covering what is beneath it, so the captured app
            // (e.g. Music) is not marked occluded and keeps animating while our output sits on top.
            window.isOpaque = false
            window.alphaValue = 0.999
        case .floating:
            screen = NSScreen.main ?? NSScreen.screens[0]
            window = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                  styleMask: [.titled, .resizable, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "tiltProjector 출력"
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.backgroundColor = (window.isOpaque ? .black : .clear)

        let view = InteractiveMTKView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        renderer.attach(to: view)
        if !window.isOpaque { (view.layer as? CAMetalLayer)?.isOpaque = false }
        window.contentView = view

        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        window.delegate = self
        configureHUD(screen: screen)
        wire(view)

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let w = self?.window else { return }
            DiagLog.write("window state visible=\(w.isVisible) activeSpace=\(w.isOnActiveSpace) occluded=\(!w.occlusionState.contains(.visible)) screen=\(w.screen?.localizedName ?? "nil") level=\(w.level.rawValue) policy=\(NSApp.activationPolicy().rawValue)")
        }
        if targetScreenID != nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkWindow() }
            }
        }
        DiagLog.write("output window number=\(window.windowNumber) frame=\(window.frame)")
        // Output stays clean: only the tilted image. The HUD is hidden unless toggled with H.
    }

    private func configureHUD(screen: NSScreen) {
        hud.isFloatingPanel = true
        hud.hidesOnDeactivate = false
        hud.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        hud.isMovableByWindowBackground = true
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isReleasedWhenClosed = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: TiltControls(model: model).padding(12).frame(width: 300))
        let size = host.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        hud.contentView = effect

        let vf = screen.visibleFrame
        hud.setFrame(NSRect(x: vf.minX + 20, y: vf.minY + 20, width: size.width, height: size.height), display: false)
    }

    private func wire(_ view: InteractiveMTKView) {
        let model = self.model
        view.onDrag = { dx, dy in model.nudge(pitch: Double(dy) * 0.15, yaw: Double(dx) * 0.15) }
        view.onScroll = { dy in model.nudge(zoom: Double(dy) * 0.01) }
        view.onKey = { [weak self] event in
            guard let self else { return false }
            let step: Double = event.modifierFlags.contains(.shift) ? 5 : 1
            switch event.keyCode {
            case 53: self.requestClose(); return true
            case 126: model.nudge(pitch: step); return true   // up
            case 125: model.nudge(pitch: -step); return true  // down
            case 124: model.nudge(yaw: step); return true     // right
            case 123: model.nudge(yaw: -step); return true    // left
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h": self.toggleHUD(); return true
            case "q": model.nudge(roll: step); return true
            case "e": model.nudge(roll: -step); return true
            case "=", "+": model.nudge(zoom: 0.05); return true
            case "-", "_": model.nudge(zoom: -0.05); return true
            case "0": model.reset(); return true
            default: return false
            }
        }
    }

    /// Keeps the full-screen output window where it belongs: moved to another display/Space or hidden -> put it back.
    private func checkWindow() {
        guard !closing, let id = targetScreenID else { return }
        let screen = NSScreen.screens.first { AppController.screenID($0) == id }
        var fixed: [String] = []
        if let screen, window.frame != screen.frame { window.setFrame(screen.frame, display: true); fixed.append("frame") }
        if !window.isVisible || !window.isOnActiveSpace { window.orderFrontRegardless(); fixed.append("front") }
        let now = Date()
        if !fixed.isEmpty || now.timeIntervalSince(lastStateLog) > 30 {
            lastStateLog = now
            DiagLog.write("output window check fixed=\(fixed) visible=\(window.isVisible) activeSpace=\(window.isOnActiveSpace) occluded=\(!window.occlusionState.contains(.visible)) screen=\(window.screen?.localizedName ?? "nil") frame=\(window.frame) displayPresent=\(screen != nil)")
        }
    }

    private func toggleHUD() {
        if hud.isVisible { hud.orderOut(nil) } else { window.addChildWindow(hud, ordered: .above); hud.orderFront(nil) }
    }

    private func requestClose() {
        DiagLog.write("output: Esc pressed -> closing")
        close()
        onClose?()
    }

    /// Closes windows without invoking onClose.
    func close() {
        if closing { return }
        closing = true
        watchdog?.invalidate()
        NSApp.setActivationPolicy(.regular)
        window.delegate = nil
        window.removeChildWindow(hud)
        hud.orderOut(nil)
        window.orderOut(nil)
        window.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        DiagLog.write("output: windowWillClose closing=\(closing)")
        if closing { return }
        closing = true
        watchdog?.invalidate()
        NSApp.setActivationPolicy(.regular)
        hud.orderOut(nil)
        onClose?()
    }
}
