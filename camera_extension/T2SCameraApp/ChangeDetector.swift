import Foundation

/// Flags areas that have become hotter or colder than they were.
///
/// The baseline is captured when detection is switched on, then allowed to
/// drift slowly. That makes "new" mean *recently changed*: a hot spot that has
/// been there since you started is not news, one that appeared a moment ago
/// is. A spot that stays hot fades out of the highlight after the baseline
/// catches up, which is the intended behaviour -- it is no longer new.
final class ChangeDetector {

    struct Region {
        var x0: Int, y0: Int, x1: Int, y1: Int
        /// Signed peak difference from baseline, in Celsius.
        var peakDelta: Double
        var isHot: Bool
    }

    /// Seconds for the baseline to substantially absorb a persistent change.
    private static let adaptSeconds = 45.0
    /// Minimum connected pixels, so sensor noise doesn't register as a spot.
    private static let minRegionPixels = 12
    /// Cap on reported regions, newest-largest first.
    private static let maxRegions = 6

    private var baseline: [Double] = []
    private var frameRate = 25.0

    var threshold = 2.0

    func reset() {
        baseline = []
    }

    var hasBaseline: Bool { !baseline.isEmpty }

    /// Returns the regions that currently differ from the baseline, and
    /// advances the baseline.
    func update(_ temps: [Double], width: Int, height: Int) -> [Region] {
        guard temps.count >= width * height else { return [] }
        if baseline.count != temps.count {
            baseline = temps
            return []
        }

        var mask = [Int8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let delta = temps[i] - baseline[i]
            if delta >= threshold { mask[i] = 1 }
            else if delta <= -threshold { mask[i] = -1 }
        }

        let regions = components(mask, temps: temps, width: width, height: height)

        // Drift the baseline afterwards, so this frame was judged against the
        // previous state rather than partly against itself.
        let alpha = 1.0 / (ChangeDetector.adaptSeconds * frameRate)
        for i in 0..<(width * height) {
            baseline[i] += (temps[i] - baseline[i]) * alpha
        }
        return regions
    }

    /// Flood-fills the flagged pixels into connected regions.
    private func components(_ mask: [Int8], temps: [Double],
                            width: Int, height: Int) -> [Region] {
        var seen = [Bool](repeating: false, count: mask.count)
        var out: [Region] = []
        var stack: [Int] = []

        for start in 0..<mask.count where mask[start] != 0 && !seen[start] {
            let sign = mask[start]
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true

            var x0 = width, y0 = height, x1 = 0, y1 = 0
            var count = 0
            var peak = 0.0
            var peakIsSet = false

            while let i = stack.popLast() {
                let x = i % width, y = i / width
                x0 = Swift.min(x0, x); x1 = Swift.max(x1, x)
                y0 = Swift.min(y0, y); y1 = Swift.max(y1, y)
                count += 1

                let d = temps[i] - baseline[i]
                if !peakIsSet || abs(d) > abs(peak) { peak = d; peakIsSet = true }

                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let n = ny * width + nx
                    guard !seen[n], mask[n] == sign else { continue }
                    seen[n] = true
                    stack.append(n)
                }
            }

            guard count >= ChangeDetector.minRegionPixels else { continue }
            out.append(Region(x0: x0, y0: y0, x1: x1, y1: y1,
                              peakDelta: peak, isHot: sign > 0))
        }

        return Array(out.sorted { abs($0.peakDelta) > abs($1.peakDelta) }
                        .prefix(ChangeDetector.maxRegions))
    }
}
