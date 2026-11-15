import AppKit
import CoreMedia
import ScreenCaptureKit

enum SourceID: Hashable {
    case display(UInt32)
    case window(UInt32)
}

struct SourceItem: Identifiable, Hashable {
    let id: SourceID
    let title: String
}

enum CaptureError: LocalizedError {
    case sourceNotFound
    case selfNotFound

    var errorDescription: String? {
        switch self {
        case .sourceNotFound: return "선택한 화면 또는 창을 찾을 수 없습니다."
        case .selfNotFound: return "앱 자신의 창을 캡처에서 제외하지 못했습니다. 컨트롤 창을 표시한 뒤 다시 시작하세요."
        }
    }
}

@MainActor
final class SourceCatalog: ObservableObject {
    @Published var displays: [SourceItem] = []
    @Published var windows: [SourceItem] = []
    @Published var errorMessage: String?

    func refresh() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let myPID = ProcessInfo.processInfo.processIdentifier

            var names: [UInt32: String] = [:]
            for screen in NSScreen.screens {
                if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    names[num.uint32Value] = screen.localizedName
                }
            }
            displays = content.displays.map { d in
                SourceItem(id: .display(d.displayID),
                           title: names[d.displayID] ?? "디스플레이 \(d.displayID)")
            }

            windows = content.windows.compactMap { w in
                guard w.isOnScreen,
                      w.windowLayer == 0,
                      let app = w.owningApplication,
                      app.processID != myPID,
                      w.frame.width > 100,
                      let title = w.title, !title.isEmpty
                else { return nil }
                return SourceItem(id: .window(w.windowID), title: "\(app.applicationName) — \(title)")
            }
            errorMessage = nil
        } catch {
            errorMessage = "화면 목록을 가져오지 못했습니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 권한을 허용해 주세요. (\(error.localizedDescription))"
        }
    }

    func makeFilter(for id: SourceID) async throws -> SCContentFilter {
        // Not on-screen-only: our own app must be found even if its window is minimized or on another Space.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        switch id {
        case .display(let did):
            guard let display = content.displays.first(where: { $0.displayID == did }) else {
                throw CaptureError.sourceNotFound
            }
            let myPID = ProcessInfo.processInfo.processIdentifier
            let mine = content.applications.filter { $0.processID == myPID }
            if mine.isEmpty { throw CaptureError.selfNotFound }
            return SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        case .window(let wid):
            guard let window = content.windows.first(where: { $0.windowID == wid }) else {
                throw CaptureError.sourceNotFound
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }
}

final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private let cbLock = NSLock()
    private var _onFrame: ((CVPixelBuffer) -> Void)?
    /// Read on the capture queue, written on the main thread.
    var onFrame: ((CVPixelBuffer) -> Void)? {
        get { cbLock.lock(); defer { cbLock.unlock() }; return _onFrame }
        set { cbLock.lock(); _onFrame = newValue; cbLock.unlock() }
    }
    var onStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private var generation = 0
    private let sampleQueue = DispatchQueue(label: "tiltProjector.capture.samples", qos: .userInteractive)

    @MainActor func start(filter: SCContentFilter) async throws {
        await stop()
        generation += 1
        let myGen = generation

        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let width = max(2, Int((info.contentRect.width * scale).rounded()))
        let height = max(2, Int((info.contentRect.height * scale).rounded()))

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 4
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream   // assign before awaiting so stop() can always reach it
        do {
            try await newStream.startCapture()
        } catch {
            if stream === newStream { stream = nil }
            throw error
        }
        if myGen != generation || stream !== newStream {   // stop() ran while starting
            try? await newStream.stopCapture()
        }
    }

    @MainActor func stop() async {
        generation += 1
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let raw = first[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let handler = onFrame
        handler?(pixelBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.stream === stream else { return }   // late error from a superseded stream
            self.stream = nil
            self.onStopped?(error)
        }
    }
}
