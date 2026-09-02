import Foundation

/// Per-frame image maths: smoothing, auto-contrast and robust extremes.
/// Mirrors the Python prototype's behaviour so both render the same picture.
enum ThermalProcessor {

    /// Separable 5x5 Gaussian over the raw counts.
    ///
    /// This sensor's per-pixel readout noise is high enough that on a
    /// thermally flat scene the auto-contrast stretch turns it into
    /// structureless static. Averaging the NUC reference over many frames
    /// only helped ~30%, so it isn't a calibration artifact -- it's the noise
    /// floor, and a light blur (what every commercial thermal camera does)
    /// recovers real structure. Applied before both the display and the
    /// numbers so the two agree.
    static func smooth(_ raw: [UInt16], width: Int, height: Int) -> [Double] {
        let kernel: [Double] = [1, 4, 6, 4, 1]   // sums to 16
        let radius = 2
        var horizontal = [Double](repeating: 0, count: width * height)
        var output = [Double](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0, weight = 0.0
                for k in -radius...radius {
                    let xx = x + k
                    guard xx >= 0, xx < width else { continue }
                    let w = kernel[k + radius]
                    sum += Double(raw[y * width + xx]) * w
                    weight += w
                }
                horizontal[y * width + x] = sum / weight
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0, weight = 0.0
                for k in -radius...radius {
                    let yy = y + k
                    guard yy >= 0, yy < height else { continue }
                    let w = kernel[k + radius]
                    sum += horizontal[yy * width + x] * w
                    weight += w
                }
                output[y * width + x] = sum / weight
            }
        }
        return output
    }

    struct Extremes {
        var minValue: Double, maxValue: Double
        var minIndex: Int, maxIndex: Int
    }

    /// True minimum and maximum, and where they are.
    ///
    /// This used to clip to the 1st and 99th percentile so that one noisy pixel
    /// could not dominate. That quietly discarded any hot object smaller than
    /// 1% of the frame -- 491 pixels of 49152 -- which is most of what anyone
    /// points a thermal camera at. A 20x20 patch at 60C in a 20C room was
    /// reported as 20.0C, and because the clipped values then all compared
    /// equal, the marker was placed on pixel zero rather than on the object.
    ///
    /// Single-pixel noise is already dealt with before this: the frame goes
    /// through a 5x5 blur and dead pixels are repaired. So take the real
    /// extremes.
    static func extremes(_ values: [Double]) -> Extremes {
        guard !values.isEmpty else {
            return Extremes(minValue: 0, maxValue: 0, minIndex: 0, maxIndex: 0)
        }
        var lo = values[0], hi = values[0]
        var loIdx = 0, hiIdx = 0
        for (i, v) in values.enumerated() {
            if v < lo { lo = v; loIdx = i }
            if v > hi { hi = v; hiIdx = i }
        }
        return Extremes(minValue: lo, maxValue: hi, minIndex: loIdx, maxIndex: hiIdx)
    }

    /// Stretches values to 0...255 for display (per-frame auto-exposure).
    static func normalize(_ values: [Double]) -> [UInt8] {
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return [UInt8](repeating: 128, count: values.count)
        }
        return normalize(values, from: lo, to: hi)
    }

    /// Stretches a fixed range instead of the frame's own min/max.
    ///
    /// Auto-exposure re-stretches every frame, so on a thermally flat scene it
    /// amplifies the noise floor into static, and the picture also flickers
    /// whenever something hot enters or leaves the frame. Pinning the range
    /// ("level/span" on a real camera) is the standard fix and makes small
    /// differences readable.
    static func normalize(_ values: [Double], from lo: Double, to hi: Double) -> [UInt8] {
        guard hi > lo else { return [UInt8](repeating: 128, count: values.count) }
        let scale = 255.0 / (hi - lo)
        return values.map { UInt8(max(0, min(255, ($0 - lo) * scale))) }
    }
}
