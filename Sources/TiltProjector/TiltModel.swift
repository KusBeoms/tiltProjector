import Foundation
import Combine

/// Shared tilt state. Not actor-isolated on purpose: the Metal draw callback reads `params`.
final class TiltModel: ObservableObject {
    @Published var params = TiltParams()

    func reset() { params = TiltParams() }

    func nudge(pitch: Double = 0, yaw: Double = 0, roll: Double = 0, zoom: Double = 0) {
        var p = params
        p.pitch += pitch; p.yaw += yaw; p.roll += roll; p.zoom += zoom
        params = p.clamped()
    }
}
