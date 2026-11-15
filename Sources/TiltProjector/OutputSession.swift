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

    init?(model: TiltModel, output: OutputID) {
        guard let renderer = TiltRenderer(model: model) else { return nil }
        self.model = model
        self.renderer = renderer

        let screen: NSScreen
        switch output {
        case .display(let id):
            screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id } ?? NSScreen.main ?? NSScreen.screens[0]
            window = OutputWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = false
        case .floating:
            screen = NSScreen.main ?? NSScreen.screens[0]
            window = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                                  styleMask: [.titled, .resizable, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "tiltProjector 출력"
            window.center()
        }
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black

        let view = InteractiveMTKView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        renderer.attach(to: view)
        window.contentView = view

        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        window.delegate = self
        configureHUD(screen: screen)
        wire(view)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
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

    private func toggleHUD() {
        if hud.isVisible { hud.orderOut(nil) } else { window.addChildWindow(hud, ordered: .above); hud.orderFront(nil) }
    }

    private func requestClose() {
        close()
        onClose?()
    }

    /// Closes windows without invoking onClose.
    func close() {
        if closing { return }
        closing = true
        window.delegate = nil
        window.removeChildWindow(hud)
        hud.orderOut(nil)
        window.orderOut(nil)
        window.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        if closing { return }
        closing = true
        hud.orderOut(nil)
        onClose?()
    }
}
