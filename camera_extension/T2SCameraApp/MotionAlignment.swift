import Foundation
import CoreGraphics

/// Fits common motion, rather than assuming that RGB brightness is thermal
/// brightness. The result is a candidate: the user previews and accepts it.
enum MotionAlignment {
    struct Observation { let rgb: CGPoint; let thermal: CGPoint }
    struct Result { let alignment: RGBAlignment; let error: Double; let inliers: Int }

    static func motionCentre(current: [Double], previous: [Double], threshold: Double) -> CGPoint? {
        let w = 64, h = 48
        guard current.count == w * h, previous.count == current.count else { return nil }
        let mask = zip(current, previous).map { abs($0 - $1) > threshold }
        var count = 0, sx = 0.0, sy = 0.0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) where mask[y * w + x] {
            var neighbours = 0
            for dy in -1...1 { for dx in -1...1 where mask[(y + dy) * w + x + dx] { neighbours += 1 } }
            if neighbours >= 4 { count += 1; sx += Double(x) + 0.5; sy += Double(y) + 0.5 }
        }}
        // Reject sensor noise and whole-scene changes (camera movement / lighting).
        guard count >= 12, count < w * h / 3 else { return nil }
        return CGPoint(x: sx / Double(count) * 4, y: sy / Double(count) * 4)
    }

    private struct Model {
        var a: Double, b: Double, x: Double, y: Double
        var mirror: Bool
        func source(_ p: CGPoint) -> CGPoint { CGPoint(x: (mirror ? 256 - p.x : p.x) - 128, y: p.y - 96) }
        func error(_ o: Observation) -> Double {
            let p = source(o.rgb)
            return hypot(a * p.x - b * p.y + x + 128 - o.thermal.x,
                         b * p.x + a * p.y + y + 96 - o.thermal.y)
        }
    }

    private static func solve(_ values: [Observation], mirrored: Bool) -> Model? {
        guard values.count >= 2 else { return nil }
        let n = Double(values.count)
        let src = values.map { CGPoint(x: (mirrored ? 256 - $0.rgb.x : $0.rgb.x) - 128, y: $0.rgb.y - 96) }
        let sx = src.reduce(0) { $0 + $1.x } / n, sy = src.reduce(0) { $0 + $1.y } / n
        let tx = values.reduce(0) { $0 + $1.thermal.x - 128 } / n
        let ty = values.reduce(0) { $0 + $1.thermal.y - 96 } / n
        var denominator = 0.0, aa = 0.0, bb = 0.0
        for (s, o) in zip(src, values) {
            let x = s.x - sx, y = s.y - sy, u = o.thermal.x - 128 - tx, v = o.thermal.y - 96 - ty
            denominator += x * x + y * y; aa += x * u + y * v; bb += x * v - y * u
        }
        guard denominator > 100 else { return nil }
        let a = aa / denominator, b = bb / denominator
        guard (0.2...5).contains(hypot(a, b)) else { return nil }
        return Model(a: a, b: b, x: tx - a * sx + b * sy, y: ty - b * sx - a * sy, mirror: mirrored)
    }

    static func fit(_ observations: [Observation], base: RGBAlignment) -> Result? {
        let values = observations.filter { [$0.rgb.x, $0.rgb.y, $0.thermal.x, $0.thermal.y].allSatisfy(\.isFinite) }
        guard values.count >= 20 else { return nil }
        let mx = values.reduce(0) { $0 + $1.rgb.x } / Double(values.count)
        let my = values.reduce(0) { $0 + $1.rgb.y } / Double(values.count)
        let xx = values.reduce(0) { $0 + pow($1.rgb.x - mx, 2) }
        let yy = values.reduce(0) { $0 + pow($1.rgb.y - my, 2) }
        let xy = values.reduce(0) { $0 + ($1.rgb.x - mx) * ($1.rgb.y - my) }
        guard xx / Double(values.count) > 100, yy / Double(values.count) > 70,
              xx * yy - xy * xy > xx * yy * 0.08 else { return nil } // Move in two directions.
        let training = values.enumerated().filter { $0.offset % 4 != 0 }.map(\.element)
        let validation = values.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        var best: Model?, bestCount = 0, bestError = Double.infinity
        for mirrored in [false, true] {
            for i in 0..<training.count { for j in (i + 1)..<training.count {
                guard hypot(training[i].rgb.x - training[j].rgb.x, training[i].rgb.y - training[j].rgb.y) > 24,
                      let model = solve([training[i], training[j]], mirrored: mirrored) else { continue }
                let inliers = training.filter { model.error($0) <= 8 }
                guard inliers.count >= max(12, training.count * 7 / 10),
                      let refined = solve(inliers, mirrored: mirrored) else { continue }
                let error = inliers.reduce(0) { $0 + pow(refined.error($1), 2) } / Double(inliers.count)
                if inliers.count > bestCount || (inliers.count == bestCount && error < bestError) {
                    best = refined; bestCount = inliers.count; bestError = error
                }
            }}
        }
        guard let best, bestError <= 25,
              validation.filter({ best.error($0) <= 10 }).count >= max(4, validation.count * 3 / 4) else { return nil }
        var settings = base
        settings.x = best.x; settings.y = best.y
        settings.zoom = hypot(best.a, best.b)
        settings.degrees = atan2(best.b, best.a) * 180 / .pi
        settings.mirrored = best.mirror; settings.mode = 2; settings.alpha = 0.5
        guard settings.isValid else { return nil }
        return Result(alignment: settings, error: sqrt(bestError), inliers: bestCount)
    }
}

final class MotionAlignmentSession {
    let started: TimeInterval
    var lastTime = -Double.infinity
    var previousIR: [Double]?
    var previousRGB: [Double]?
    var observations: [MotionAlignment.Observation] = []
    init(started: TimeInterval) { self.started = started }
}
