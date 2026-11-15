import Foundation
import simd

/// `TiltProjector --selftest` : verifies the tilt geometry without needing a GUI or permissions.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print(ok ? "PASS  \(name)" : "FAIL  \(name)")
            if !ok { failures += 1 }
        }
        func near(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) < eps }

        let aspect: Float = 16.0 / 9.0

        // 1. Identity maps the source 1:1 onto the output.
        let id = TiltGeometry(params: TiltParams(), srcAspect: aspect, outAspect: aspect)
        let c = id.sourceUV(ndc: .zero)
        check(c != nil && near(c!.x, 0.5) && near(c!.y, 0.5), "identity centre -> (0.5, 0.5)")
        let tr = id.forward(u: 1, v: 1)
        check(near(tr.x, aspect) && near(tr.y, 1), "identity top-right corner -> (aspect, 1)")
        let uvTR = id.sourceUV(ndc: SIMD2(aspect * 0.999, 0.999))
        check(uvTR != nil && near(uvTR!.x, 1, 2e-3) && near(uvTR!.y, 0, 2e-3), "identity top-right UV -> (1, 0)")

        // 2. forward/inverse round trip under random tilts.
        var rng = SystemRandomNumberGenerator()
        var worst: Float = 0
        for _ in 0..<500 {
            let p = TiltParams(
                pitch: Double.random(in: -50...50, using: &rng),
                yaw: Double.random(in: -50...50, using: &rng),
                roll: Double.random(in: -40...40, using: &rng),
                zoom: Double.random(in: 0.5...1.0, using: &rng))
            let g = TiltGeometry(params: p, srcAspect: aspect, outAspect: 16.0 / 10.0)
            let u = Float.random(in: -0.9...0.9, using: &rng)
            let v = Float.random(in: -0.9...0.9, using: &rng)
            let ndc = g.forward(u: u, v: v)
            guard let uv = g.sourceUV(ndc: ndc) else { worst = .infinity; break }
            worst = max(worst, abs(uv.x - (u * 0.5 + 0.5)), abs(uv.y - (0.5 - v * 0.5)))
        }
        check(worst < 1e-3, "round trip forward->sourceUV (max err \(worst))")

        // 3. Yaw > 0 pushes the right edge away (it gets shorter).
        let yaw = TiltGeometry(params: TiltParams(yaw: 30), srcAspect: aspect, outAspect: aspect)
        check(abs(yaw.forward(u: 1, v: 1).y) < abs(yaw.forward(u: -1, v: 1).y), "yaw+ : right edge farther than left")

        // 4. Pitch > 0 pushes the top edge away (it gets narrower).
        let pitch = TiltGeometry(params: TiltParams(pitch: 30), srcAspect: aspect, outAspect: aspect)
        check(abs(pitch.forward(u: 1, v: 1).x) < abs(pitch.forward(u: 1, v: -1).x), "pitch+ : top edge farther than bottom")

        // 5. Roll > 0 is counter-clockwise.
        let roll = TiltGeometry(params: TiltParams(roll: 90), srcAspect: 1, outAspect: 1)
        let r = roll.forward(u: 1, v: 0)
        check(near(r.x, 0) && r.y > 0, "roll+ : right edge rotates upward (CCW)")

        // 6. Points outside the tilted panel are rejected.
        let small = TiltGeometry(params: TiltParams(zoom: 0.5), srcAspect: aspect, outAspect: aspect)
        check(small.sourceUV(ndc: SIMD2(aspect * 0.9, 0.9)) == nil, "zoom 0.5 : output corner is outside the panel")

        // 7. Tilted panels never leave the output: all four corners stay inside.
        var worstOut: Float = 0
        for _ in 0..<500 {
            let p = TiltParams(
                pitch: Double.random(in: -60...60, using: &rng),
                yaw: Double.random(in: -60...60, using: &rng),
                roll: Double.random(in: -45...45, using: &rng),
                zoom: 1)
            let g = TiltGeometry(params: p, srcAspect: aspect, outAspect: 16.0 / 10.0)
            for (u, v) in [(Float(-1), Float(-1)), (1, -1), (-1, 1), (1, 1)] {
                let n = g.forward(u: u, v: v)
                worstOut = max(worstOut, abs(n.x) - g.outAspect, abs(n.y) - 1)
            }
        }
        check(worstOut < 1e-3, "max tilt keeps every corner inside output (overshoot \(worstOut))")
        let tilted = TiltGeometry(params: TiltParams(pitch: 40, yaw: 30), srcAspect: aspect, outAspect: aspect)
        check(tilted.scale < id.scale, "tilt shrinks the panel to fit")

        // 8. Squash narrows the content but keeps it fully visible and invertible.
        let sq = TiltGeometry(params: TiltParams(pitch: 20, squeezeX: 0.5), srcAspect: aspect, outAspect: aspect)
        let sqFlat = TiltGeometry(params: TiltParams(squeezeX: 0.5), srcAspect: aspect, outAspect: aspect)
        check(sqFlat.forward(u: 1, v: 0).x < id.forward(u: 1, v: 0).x - 0.1, "squeezeX 0.5 : content is narrower")
        var sqWorst: Float = 0
        for (u, v) in [(Float(-1), Float(-1)), (1, -1), (-1, 1), (1, 1)] {
            let n = sq.forward(u: u, v: v)
            sqWorst = max(sqWorst, abs(n.x) - sq.outAspect, abs(n.y) - 1)
        }
        check(sqWorst < 1e-3, "squash + tilt stays inside output")
        if let uv = sq.sourceUV(ndc: sq.forward(u: 0.3, v: -0.4)) {
            check(near(uv.x, 0.65) && near(uv.y, 0.7), "squash + tilt round trip")
        } else { check(false, "squash + tilt round trip") }

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
