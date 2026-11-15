import SwiftUI
import AppKit

struct TiltPad: View {
    @ObservedObject var model: TiltModel
    var height: CGFloat = 150

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(.black.opacity(0.35)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 10), with: .color(.white.opacity(0.3)), lineWidth: 1)
            var cross = Path()
            cross.move(to: CGPoint(x: rect.midX, y: 0)); cross.addLine(to: CGPoint(x: rect.midX, y: size.height))
            cross.move(to: CGPoint(x: 0, y: rect.midY)); cross.addLine(to: CGPoint(x: size.width, y: rect.midY))
            ctx.stroke(cross, with: .color(.white.opacity(0.2)), lineWidth: 1)

            // Tilted quad preview.
            let p = model.params
            let g = TiltGeometry(params: p, srcAspect: 16.0 / 9.0, outAspect: Float(size.width / size.height))
            let corners: [(Float, Float)] = [(-1, 1), (1, 1), (1, -1), (-1, -1)]
            var quad = Path()
            for (i, c) in corners.enumerated() {
                let n = g.forward(u: c.0, v: c.1)
                let pt = CGPoint(x: rect.midX + CGFloat(n.x) / CGFloat(g.outAspect) * rect.midX,
                                 y: rect.midY - CGFloat(n.y) * rect.midY)
                if i == 0 { quad.move(to: pt) } else { quad.addLine(to: pt) }
            }
            quad.closeSubpath()
            ctx.fill(quad, with: .color(.accentColor.opacity(0.2)))
            ctx.stroke(quad, with: .color(.accentColor), lineWidth: 1.5)

            // Dot.
            let L = TiltParams.tiltLimit
            let dot = CGPoint(x: rect.midX + CGFloat(p.yaw / L) * rect.midX,
                              y: rect.midY - CGFloat(p.pitch / L) * rect.midY)
            ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)), with: .color(.white))
        }
        .frame(height: height)
        .overlay(
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let L = TiltParams.tiltLimit
                        let nx = Double((v.location.x / geo.size.width) * 2 - 1)
                        let ny = Double(1 - (v.location.y / geo.size.height) * 2)
                        var p = model.params
                        p.yaw = nx * L
                        p.pitch = ny * L
                        model.params = p.clamped()
                    })
            }
        )
    }
}

struct TiltControls: View {
    @ObservedObject var model: TiltModel

    private func slider(_ title: String, _ keyPath: WritableKeyPath<TiltParams, Double>,
                        _ range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 84, alignment: .leading)
            let binding = Binding<Double>(
                get: { model.params[keyPath: keyPath] },
                set: { model.params[keyPath: keyPath] = min(max($0, range.lowerBound), range.upperBound) })
            Slider(value: binding, in: range)
            // Editable readout: type a number and press Return (values are clamped to the slider range).
            TextField("", value: binding, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .monospacedDigit().frame(width: 58)
            Text(unit).frame(width: 14, alignment: .leading).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TiltPad(model: model)
            slider("피치", \.pitch, -TiltParams.tiltLimit...TiltParams.tiltLimit, unit: "°")
            slider("요", \.yaw, -TiltParams.tiltLimit...TiltParams.tiltLimit, unit: "°")
            slider("롤", \.roll, -TiltParams.rollLimit...TiltParams.rollLimit, unit: "°")
            slider("줌", \.zoom, TiltParams.zoomRange, unit: "×")
            slider("가로 찌그러짐", \.squeezeX, TiltParams.squeezeRange, unit: "")
            slider("세로 찌그러짐", \.squeezeY, TiltParams.squeezeRange, unit: "")
            Button("초기화") { model.reset() }
        }
    }
}

struct ControlView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var catalog: SourceCatalog

    init(controller: AppController) {
        self.controller = controller
        self.catalog = controller.catalog
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("소스").font(.headline)
                    Spacer()
                    Button("새로고침") { Task { await controller.refresh() } }
                }
                Picker("소스", selection: $controller.selectedSource) {
                    Text("선택 안 함").tag(SourceID?.none)
                    Section("디스플레이") {
                        ForEach(catalog.displays) { Text($0.title).tag(SourceID?.some($0.id)) }
                    }
                    Section("창") {
                        ForEach(catalog.windows) { Text($0.title).tag(SourceID?.some($0.id)) }
                    }
                }
                .labelsHidden()
                .disabled(controller.isRunning)

                Text("출력").font(.headline)
                Picker("출력", selection: $controller.selectedOutput) {
                    Text("플로팅 창").tag(OutputID.floating)
                    ForEach(controller.screens, id: \.id) { s in
                        Text("전체 화면: \(s.name)").tag(OutputID.display(s.id))
                    }
                }
                .labelsHidden()
                .disabled(controller.isRunning)

                Button(controller.isRunning ? "중지" : "시작") {
                    Task {
                        if controller.isRunning { await controller.stop() } else { await controller.start() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((!controller.isRunning && controller.selectedSource == nil) || controller.isStarting)

                if !controller.status.isEmpty {
                    Text(controller.status).font(.callout).foregroundColor(.secondary)
                }
                if let err = catalog.errorMessage {
                    Text(err).font(.callout).foregroundColor(.red)
                    Button("화면 기록 설정 열기") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Divider()
                Text("기울기").font(.headline)
                TiltControls(model: controller.model)

                Divider()
                Text("출력 화면 조작: 드래그 = 기울이기, 스크롤 = 줌, 방향키 = 피치/요 (Shift = 5°), Q/E = 롤, +/- = 줌, 0 = 초기화, H = HUD 전환, Esc = 중지")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(16)
        }
        .frame(minWidth: 380, minHeight: 560)
        .task { await controller.refresh() }
    }
}
