import AppKit
import CoreGraphics
import ScreenCaptureKit

enum OutputID: Hashable {
    case floating
    case display(UInt32)
}

@MainActor
final class AppController: ObservableObject {
    let model = TiltModel()
    let catalog = SourceCatalog()
    let capture = CaptureService()

    @Published var selectedSource: SourceID?
    @Published var selectedOutput: OutputID
    @Published var isRunning = false
    @Published var status = ""

    private var session: OutputSession?
    @Published private(set) var isStarting = false

    static func screenID(_ s: NSScreen) -> UInt32? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var screens: [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { s in Self.screenID(s).map { ($0, s.localizedName) } }
    }

    init() {
        let ids = NSScreen.screens.compactMap { Self.screenID($0) }
        if ids.count > 1 {
            selectedOutput = .display(ids[1])
        } else {
            selectedOutput = .floating
        }
    }

    func refresh() async {
        await catalog.refresh()
        if selectedSource == nil || !(catalog.displays + catalog.windows).contains(where: { $0.id == selectedSource }) {
            selectedSource = catalog.displays.first?.id
        }
        if let err = catalog.errorMessage { status = err }
    }

    func start() async {
        guard !isRunning, !isStarting, let source = selectedSource else {
            if selectedSource == nil { status = "캡처할 소스를 선택하세요." }
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            status = "화면 기록 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 허용한 뒤 앱을 다시 실행하세요."
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            let filter = try await catalog.makeFilter(for: source)
            guard let session = OutputSession(model: model, output: selectedOutput) else {
                status = "Metal 렌더러를 만들 수 없습니다."
                return
            }
            self.session = session
            let renderer = session.renderer
            capture.onFrame = { pb in renderer.submit(pb) }
            capture.onStopped = { [weak self] error in
                Task { @MainActor in
                    self?.status = "캡처가 중단되었습니다: \(error.localizedDescription)"
                    await self?.stop()
                }
            }
            session.onClose = { [weak self] in
                Task { @MainActor in await self?.stop() }
            }
            isRunning = true
            status = "실행 중 — 이 창에서 조작 (출력 화면: 드래그=틸트, 스크롤=줌, Esc=중지, H=HUD)"
            try await capture.start(filter: filter)
        } catch {
            status = "시작 실패: \(error.localizedDescription)"
            await stop(keepStatus: true)
        }
    }

    func stop(keepStatus: Bool = false) async {
        let wasRunning = isRunning || session != nil
        isRunning = false
        let s = session
        session = nil
        s?.onClose = nil
        s?.close()
        capture.onFrame = nil
        capture.onStopped = nil
        await capture.stop()
        if wasRunning && !keepStatus && !status.hasPrefix("캡처가") { status = "중지됨" }
    }

    /// Synchronous best-effort teardown for app termination.
    func stopNow() {
        isRunning = false
        session?.onClose = nil
        session?.close()
        session = nil
        capture.onFrame = nil
        capture.onStopped = nil
        Task { await capture.stop() }
    }
}
