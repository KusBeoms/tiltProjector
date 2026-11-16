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
    private var activeSource: SourceID?
    private var activeSourceTitle = ""
    private var reconnecting = false
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
                DiagLog.write("capture stopped by system: \(error)")
                Task { @MainActor in await self?.reconnect(after: error) }
            }
            session.onClose = { [weak self] in
                DiagLog.write("output window closed -> stopping")
                Task { @MainActor in await self?.stop() }
            }
            isRunning = true
            activeSource = source
            activeSourceTitle = (catalog.displays + catalog.windows).first { $0.id == source }?.title ?? ""
            DiagLog.write("start source=\(source) output=\(selectedOutput)")
            status = "실행 중 — 이 창에서 조작 (출력 화면: 드래그=틸트, 스크롤=줌, Esc=중지, H=HUD)"
            try await capture.start(filter: filter)
        } catch {
            DiagLog.write("start failed: \(error)")
            status = "시작 실패: \(error.localizedDescription)"
            await stop(keepStatus: true)
        }
    }

    /// The capture dropped (e.g. the captured window was re-created). Keep the output window and its last
    /// frame on screen and keep trying to re-attach to the same source instead of tearing everything down.
    private func reconnect(after error: Error) async {
        guard session != nil, !reconnecting, let wanted = activeSource else { return }
        reconnecting = true
        defer { reconnecting = false }
        let title = activeSourceTitle
        for attempt in 1...120 {
            guard session != nil else { return }   // user stopped meanwhile
            status = "소스 연결이 끊겨 다시 연결하는 중… (\(attempt)) — \(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard session != nil else { return }
            guard let id = await catalog.resolve(id: wanted, title: title) else {
                DiagLog.write("reconnect #\(attempt): source not found (\(title))")
                continue
            }
            do {
                let filter = try await catalog.makeFilter(for: id)
                guard session != nil else { return }
                try await capture.start(filter: filter)
                activeSource = id
                status = "실행 중 — 이 창에서 조작 (출력 화면: 드래그=틸트, 스크롤=줌, Esc=중지, H=HUD)"
                DiagLog.write("reconnected after #\(attempt) source=\(id)")
                return
            } catch {
                DiagLog.write("reconnect #\(attempt) failed: \(error)")
            }
        }
        guard session != nil else { return }
        DiagLog.write("reconnect gave up")
        status = "캡처가 중단되었습니다: \(error.localizedDescription)"
        await stop(keepStatus: true)
    }

    func stop(keepStatus: Bool = false) async {
        let wasRunning = isRunning || session != nil
        DiagLog.write("stop wasRunning=\(wasRunning) status=\(status)")
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
