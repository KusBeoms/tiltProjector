import Foundation
import simd

/// User-facing tilt parameters (degrees, zoom factor).
struct TiltParams: Equatable {
    var pitch: Double = 0   // + : top edge moves away
    var yaw: Double = 0     // + : right edge moves away
    var roll: Double = 0    // + : counter-clockwise
    var zoom: Double = 1
    var squeezeX: Double = 1   // < 1 : squash horizontally (content gets narrower)
    var squeezeY: Double = 1   // < 1 : squash vertically (content gets shorter)

    static let tiltLimit: Double = 60
    static let rollLimit: Double = 45
    static let squeezeRange: ClosedRange<Double> = 0.3...1.0
    static let zoomRange: ClosedRange<Double> = 0.4...1.0   // 1.0 = as large as fits; never crops

    var isIdentity: Bool { self == TiltParams() }

    func clamped() -> TiltParams {
        var p = self
        p.pitch = min(max(p.pitch, -Self.tiltLimit), Self.tiltLimit)
        p.yaw = min(max(p.yaw, -Self.tiltLimit), Self.tiltLimit)
        p.roll = min(max(p.roll, -Self.rollLimit), Self.rollLimit)
        p.zoom = min(max(p.zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        p.squeezeX = min(max(p.squeezeX, Self.squeezeRange.lowerBound), Self.squeezeRange.upperBound)
        p.squeezeY = min(max(p.squeezeY, Self.squeezeRange.lowerBound), Self.squeezeRange.upperBound)
        return p
    }
}

/// Geometry of the tilted source "panel" seen by a pinhole camera.
///
/// Camera at origin looking +z, image plane at z = `distance` (so an untilted panel at
/// z = `distance` maps 1:1 to NDC). Output NDC: y in [-1, 1], x in [-outAspect, outAspect].
/// The panel has half-height `scale` and half-width `scale * srcAspect`.
struct TiltGeometry {
    static let distance: Float = 3

    let c0: SIMD3<Float>   // columns of the panel rotation R
    let c1: SIMD3<Float>
    let c2: SIMD3<Float>
    private(set) var scale: Float
    let srcAspect: Float
    let outAspect: Float

    init(params: TiltParams, srcAspect: Float, outAspect: Float) {
        let p = Float(params.pitch * .pi / 180)
        let y = Float(params.yaw * .pi / 180)
        let r = Float(params.roll * .pi / 180)
        let rx = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(p), sin(p)), SIMD3(0, -sin(p), cos(p))))
        let ry = simd_float3x3(columns: (SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))))
        let rz = simd_float3x3(columns: (SIMD3(cos(r), sin(r), 0), SIMD3(-sin(r), cos(r), 0), SIMD3(0, 0, 1)))
        let m = ry * rx * rz
        c0 = m.columns.0
        c1 = m.columns.1
        c2 = m.columns.2
        // Squash = change the panel's aspect ratio; the source is stretched to the new shape.
        let a = max(srcAspect, 0.01) * Float(params.squeezeX / params.squeezeY)
        let o = max(outAspect, 0.01)
        scale = 1
        self.srcAspect = a
        self.outAspect = o
        // Largest scale (<= aspect-fit * zoom) at which every corner of the tilted panel
        // stays inside the output, so no part of the source is ever cropped.
        let limit = Float(params.zoom) * min(1, o / a)
        if fits(limit) {
            scale = limit
        } else {
            var lo: Float = 0, hi = limit
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if fits(mid) { lo = mid } else { hi = mid }
            }
            scale = lo
        }
    }

    private mutating func fits(_ s: Float) -> Bool {
        scale = s
        let eps: Float = 1e-5
        for (u, v) in [(Float(-1), Float(-1)), (1, -1), (-1, 1), (1, 1)] {
            let w = c0 * (u * s * srcAspect) + c1 * (v * s) + SIMD3(0, 0, Self.distance)
            if w.z < 0.05 { return false }
            let k = Self.distance / w.z
            if abs(w.x * k) > outAspect + eps || abs(w.y * k) > 1 + eps { return false }
        }
        return true
    }

    /// Panel point (u, v in [-1, 1], v up) -> output NDC.
    func forward(u: Float, v: Float) -> SIMD2<Float> {
        let lx = u * scale * srcAspect
        let ly = v * scale
        let world = c0 * lx + c1 * ly + SIMD3(0, 0, Self.distance)
        let k = Self.distance / world.z
        return SIMD2(world.x * k, world.y * k)
    }

    /// Output NDC -> source texture UV (origin top-left), nil when outside the panel.
    /// Mirrors the Metal fragment shader exactly.
    func sourceUV(ndc: SIMD2<Float>) -> SIMD2<Float>? {
        let d = Self.distance
        let ray = SIMD3(ndc.x, ndc.y, d)
        let denom = simd_dot(c2, ray)
        if abs(denom) < 1e-6 { return nil }
        let t = c2.z * d / denom
        if t <= 0 { return nil }
        let p = ray * t - SIMD3(0, 0, d)
        let lx = simd_dot(c0, p)
        let ly = simd_dot(c1, p)
        let uv = SIMD2(lx / (2 * scale * srcAspect) + 0.5, 0.5 - ly / (2 * scale))
        if uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1 { return nil }
        return uv
    }
}
