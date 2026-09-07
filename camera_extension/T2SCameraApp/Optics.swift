import Foundation

/// What the lens does to the picture, which matters as soon as you sweep the
/// camera rather than slide it.
///
/// Sweeping is a rotation, not a translation. Turn the camera by an angle and
/// a point near the edge of the frame moves further across the sensor than a
/// point in the middle -- by a factor of `1 + x^2/f^2`, so at the edge of this
/// camera's field it is nearly a fifth further. Treating a sweep as a slide
/// therefore cannot line the whole frame up at once: the aligner splits the
/// difference and the edges of every frame land slightly wrong, which shows up
/// as softness along the seams.
///
/// The fix is old and simple: warp each frame onto a cylinder first. In
/// cylindrical coordinates a yaw of the camera *is* a translation, so
/// everything downstream -- the shift estimate, the canvas, the accumulation
/// -- goes on working unchanged and now agrees with what the camera is
/// actually doing.
///
/// Only one number is needed for that: the focal length in pixels.
struct Optics: Equatable {

    /// Focal length in sensor pixels, which is the only optical constant a
    /// cylindrical panorama needs.
    ///
    /// The published figures for this camera do not agree with each other --
    /// a 3.2 mm lens on a 12 micron pitch works out at about 51 degrees
    /// across, while the specification sheets say 56 -- and the difference is
    /// large enough to matter over a wide sweep. So this is not taken on
    /// trust: it starts at the middle of that range and the app measures the
    /// real one from a sweep (see `Optics.estimateFocal`). Once measured it is
    /// saved.
    var focalPixels: Double = 260

    private static let storageKey = "opticsFocalPixels"

    /// The last measured value, or the starting guess if none has been taken.
    static func load() -> Optics {
        let stored = UserDefaults.standard.double(forKey: storageKey)
        var optics = Optics()
        if plausibleFocal.contains(stored) { optics.focalPixels = stored }
        return optics
    }

    func save() {
        UserDefaults.standard.set(focalPixels, forKey: Optics.storageKey)
    }

    /// True while the app is still working off the guess rather than a
    /// measurement, which is worth saying out loud.
    var isMeasured: Bool {
        UserDefaults.standard.object(forKey: Optics.storageKey) != nil
    }

    /// Horizontal field of view in degrees, for showing a human.
    func horizontalFieldOfView(width: Int) -> Double {
        2 * atan(Double(width) / 2 / focalPixels) * 180 / .pi
    }

    func verticalFieldOfView(height: Int) -> Double {
        2 * atan(Double(height) / 2 / focalPixels) * 180 / .pi
    }

    /// Anything outside this is not a camera lens, it is a mistake.
    static let plausibleFocal = 80.0...2000.0

    // MARK: - Warping onto the cylinder

    /// Projects a frame onto a cylinder about the vertical axis.
    ///
    /// Output pixel `u` is an angle, scaled so that one output pixel at the
    /// centre is one input pixel; that keeps the picture the same size in the
    /// middle and only compresses towards the edges, where the flat image was
    /// stretched.
    static func cylindrical(_ frame: [Double], width: Int, height: Int,
                            focalPixels f: Double) -> (values: [Double], width: Int, height: Int) {
        let halfW = Double(width) / 2, halfH = Double(height) / 2
        // The angular half-width, back in pixel units.
        let outHalfW = f * atan(halfW / f)
        // The tallest the frame gets is at its centre column, where the
        // cylinder is closest to the sensor plane.
        let outHalfH = halfH
        let outW = max(2, Int((outHalfW * 2).rounded()))
        let outH = max(2, Int((outHalfH * 2).rounded()))

        var out = [Double](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let v = Double(oy) + 0.5 - Double(outH) / 2
            for ox in 0..<outW {
                let u = Double(ox) + 0.5 - Double(outW) / 2
                // Undo the cylinder: the angle u/f names a ray, and the ray
                // meets the flat sensor at x = f tan(u/f).
                let angle = u / f
                let x = f * tan(angle)
                let y = v * sqrt(x * x + f * f) / f
                out[oy * outW + ox] = sample(frame, width: width, height: height,
                                             x: x + halfW - 0.5, y: y + halfH - 0.5)
            }
        }
        return (out, outW, outH)
    }

    /// Bilinear, clamped at the edges. A cylinder asks for a little outside
    /// the corners of the flat frame; clamping is better than a black border,
    /// which the aligner would try to match on.
    private static func sample(_ frame: [Double], width: Int, height: Int,
                               x: Double, y: Double) -> Double {
        let cx = min(max(x, 0), Double(width - 1))
        let cy = min(max(y, 0), Double(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)
        let top = frame[y0 * width + x0] * (1 - fx) + frame[y0 * width + x1] * fx
        let bottom = frame[y1 * width + x0] * (1 - fx) + frame[y1 * width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: - Measuring it

    /// Works out the focal length from a pair of frames taken as the camera
    /// swept, without needing a specification sheet.
    ///
    /// The trick is that a rotation moves the edge of the frame further than
    /// the middle. Measure the shift in a window at the centre and again in a
    /// window out at the side: their ratio is `1 + x^2/f^2`, which gives `f`
    /// directly. It only works when the camera actually moved -- a shift of a
    /// pixel or two carries no usable signal -- so small movements return
    /// nothing rather than a wild guess.
    static func estimateFocal(_ a: [Double], _ b: [Double],
                              width: Int, height: Int) -> Double? {
        let windowWidth = width / 3
        let inset = 26                       // room for the window to shift either way
        guard width > windowWidth + 2 * inset else { return nil }

        // The middle of the frame moves by the least, and is the yardstick.
        let centreStart = (width - windowWidth) / 2
        guard let centreShift = shiftOfColumns(a, b, width: width, height: height,
                                               from: centreStart, count: windowWidth),
              abs(centreShift) > 3.0 else { return nil }

        // Both edges are tried. Each gives its own answer and they should
        // agree; using both halves the noise and covers the case where one
        // side of the picture happens to be featureless.
        var estimates: [Double] = []
        for start in [inset, width - inset - windowWidth] {
            guard let shift = shiftOfColumns(a, b, width: width, height: height,
                                             from: start, count: windowWidth) else { continue }
            let lever = Double(start + windowWidth / 2) - Double(width) / 2
            let ratio = shift / centreShift
            // The edge always moves further than the middle. A ratio at or
            // below one is noise, not geometry.
            guard ratio > 1.0005 else { continue }
            let f = abs(lever) / (ratio - 1).squareRoot()
            if plausibleFocal.contains(f) { estimates.append(f) }
        }
        guard !estimates.isEmpty else { return nil }
        return estimates.reduce(0, +) / Double(estimates.count)
    }

    /// Horizontal shift of one vertical band between two frames, to a
    /// fraction of a pixel.
    private static func shiftOfColumns(_ a: [Double], _ b: [Double],
                                       width: Int, height: Int,
                                       from x0: Int, count: Int) -> Double? {
        let margin = 4
        let radius = 24
        let yStart = margin, yEnd = height - 1 - margin
        guard count > 8, yEnd > yStart else { return nil }

        func error(_ dx: Int) -> Double? {
            // Only the columns that stay inside both frames once shifted. A
            // window near the edge would otherwise be unmeasurable in the very
            // direction the picture is moving.
            let xFrom = max(x0, -dx)
            let xTo = min(x0 + count - 1, width - 1 - dx)
            guard xTo - xFrom > count / 2 else { return nil }

            var meanA = 0.0, meanB = 0.0, n = 0.0
            for y in stride(from: yStart, through: yEnd, by: 2) {
                for x in stride(from: xFrom, through: xTo, by: 2) {
                    meanA += a[y * width + x]
                    meanB += b[y * width + x + dx]
                    n += 1
                }
            }
            guard n > 16 else { return nil }
            meanA /= n; meanB /= n
            var e = 0.0
            for y in stride(from: yStart, through: yEnd, by: 2) {
                for x in stride(from: xFrom, through: xTo, by: 2) {
                    e += abs((a[y * width + x] - meanA) - (b[y * width + x + dx] - meanB))
                }
            }
            return e / n
        }

        var best = (dx: 0, e: Double.greatestFiniteMagnitude)
        for dx in -radius...radius {
            guard let e = error(dx) else { continue }
            if e < best.e { best = (dx, e) }
        }
        guard best.e < .greatestFiniteMagnitude,
              let before = error(best.dx - 1), let after = error(best.dx + 1) else { return nil }

        let denominator = before - 2 * best.e + after
        var sub = 0.0
        if abs(denominator) > 1e-9 {
            sub = max(-0.5, min(0.5, 0.5 * (before - after) / denominator))
        }
        return -(Double(best.dx) + sub)
    }
}
