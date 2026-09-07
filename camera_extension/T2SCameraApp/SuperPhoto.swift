import Foundation

/// Builds one large picture out of many frames.
///
/// A 256x192 sensor is small, and the usual fix is to take advantage of the
/// fact that a hand never holds still. Each frame samples the scene from a
/// slightly different position, so a stack of them carries more detail than
/// any single one -- provided you know where each frame sat. That is the
/// whole job here: work out the shift between frames, then lay them all onto
/// one finer grid.
///
/// The same machinery covers two things that look different from outside:
///
///   * Hold the camera in your hand and the shifts are a fraction of a pixel.
///     The result is the same view at a higher resolution.
///   * Pan it deliberately and the shifts run to whole pixels. The canvas
///     grows to hold wherever the frames landed, and the result is a mosaic
///     wider than the sensor can see at once.
///
/// On a tripod, with no movement at all, there is nothing to recover beyond
/// less noise. Sub-pixel detail comes *from* the shake.
///
/// Only translation is estimated. Twist the camera as you pan and the frames
/// will not line up; the residual check throws out the worst of it, but the
/// honest limit is "move it sideways, do not rotate it".
enum SuperPhoto {

    struct Result {
        var values: [Double]
        var width: Int, height: Int
        /// How much finer the grid is than the sensor.
        var factor: Int
        var framesUsed: Int
        var framesRejected: Int
        /// Fraction of the canvas that real samples landed on. Below 1 the
        /// edges of a mosaic are ragged and were filled in.
        var coverage: Double
        /// How far the frames wandered, in sensor pixels. Tells the difference
        /// between a stack and a pan.
        var travel: Double
    }

    /// How far a frame may have moved from the one before it.
    private static let searchRadius = 6
    /// A frame matching worse than this fraction of the reference contrast is
    /// not a shifted view of the same scene -- something in it moved, or the
    /// camera turned. Stacking it would smear the result.
    private static let acceptRatio = 0.75
    /// Refuse to build a canvas more than this many times the sensor area,
    /// so waving the camera around cannot ask for a gigabyte.
    private static let maxCanvasGrowth = 3.0

    /// Stacks decoded temperature fields. All must be the same size.
    static func stack(_ frames: [[Double]], width: Int, height: Int,
                      factor: Int = 2) -> Result? {
        guard frames.count >= 2, factor >= 1,
              frames.allSatisfy({ $0.count == width * height }) else { return nil }

        // Where each frame sits relative to the first, in sensor pixels.
        var offsets: [(dx: Double, dy: Double)] = [(0, 0)]
        var accepted = [0]
        var rejected = 0
        var anchor = 0                     // last frame we trusted
        var anchorOffset = (dx: 0.0, dy: 0.0)

        for i in 1..<frames.count {
            guard let shift = estimateShift(frames[anchor], frames[i],
                                            width: width, height: height) else {
                rejected += 1
                continue
            }
            let total = (dx: anchorOffset.dx + shift.dx, dy: anchorOffset.dy + shift.dy)
            offsets.append(total)
            accepted.append(i)
            anchor = i
            anchorOffset = total
        }
        guard accepted.count >= 2 else { return nil }

        // Chaining frame to frame is the only way to follow a pan, but every
        // link adds its own small error and they accumulate: over a dozen
        // frames a 32-pixel pan measured 36. So each frame is measured again
        // directly against the first, searching only around where the chain
        // said it should be. That leaves one estimate's worth of error instead
        // of a dozen. Where the two frames no longer overlap enough to match,
        // the chained value stands.
        for n in 1..<accepted.count {
            let guess = (dx: Int((-offsets[n].dx).rounded()), dy: Int((-offsets[n].dy).rounded()))
            if let direct = estimateShift(frames[0], frames[accepted[n]],
                                          width: width, height: height,
                                          around: guess, radius: 2) {
                offsets[n] = direct
            }
        }

        // The canvas covers wherever the frames landed.
        let minX = offsets.map(\.dx).min()!, maxX = offsets.map(\.dx).max()!
        let minY = offsets.map(\.dy).min()!, maxY = offsets.map(\.dy).max()!
        let spanX = Double(width) + (maxX - minX)
        let spanY = Double(height) + (maxY - minY)
        guard spanX <= Double(width) * maxCanvasGrowth,
              spanY <= Double(height) * maxCanvasGrowth else { return nil }

        let outW = Int((spanX * Double(factor)).rounded(.up))
        let outH = Int((spanY * Double(factor)).rounded(.up))
        var sum = [Double](repeating: 0, count: outW * outH)
        var weight = [Double](repeating: 0, count: outW * outH)

        // Each sample is spread over a tent half a source pixel wide. Wider
        // than that and neighbouring samples overlap so much that the result
        // comes out blurrier than simply enlarging one frame, which defeats
        // the whole exercise. Narrow leaves gaps in the finer grid, and those
        // are filled in afterwards from their neighbours.
        let f = Double(factor)
        let reach = f * 0.5
        for (n, index) in accepted.enumerated() {
            let frame = frames[index]
            let ox = (offsets[n].dx - minX) * f
            let oy = (offsets[n].dy - minY) * f
            for y in 0..<height {
                let cy = (Double(y) + 0.5) * f + oy
                let y0 = max(0, Int(floor(cy - reach))), y1 = min(outH - 1, Int(ceil(cy + reach)))
                guard y0 <= y1 else { continue }
                for x in 0..<width {
                    let value = frame[y * width + x]
                    let cx = (Double(x) + 0.5) * f + ox
                    let x0 = max(0, Int(floor(cx - reach))), x1 = min(outW - 1, Int(ceil(cx + reach)))
                    guard x0 <= x1 else { continue }
                    for py in y0...y1 {
                        let wy = 1 - abs(Double(py) + 0.5 - cy) / reach
                        guard wy > 0 else { continue }
                        for px in x0...x1 {
                            let wx = 1 - abs(Double(px) + 0.5 - cx) / reach
                            guard wx > 0 else { continue }
                            let w = wx * wy
                            sum[py * outW + px] += value * w
                            weight[py * outW + px] += w
                        }
                    }
                }
            }
        }

        var out = [Double](repeating: 0, count: outW * outH)
        var covered = 0
        var total = 0.0
        for i in 0..<out.count where weight[i] > 0.0001 {
            out[i] = sum[i] / weight[i]
            covered += 1
            total += out[i]
        }
        guard covered > 0 else { return nil }

        // Gaps come from two places: cells that no sample quite reached, and
        // the corners of a mosaic that no frame covered at all. Both are
        // filled from whatever is around them, which is right for a one-cell
        // gap and honest enough at a ragged edge. Anything still empty after
        // that is nowhere near real data and gets the average.
        var filled = [Bool](repeating: false, count: out.count)
        for i in 0..<out.count { filled[i] = weight[i] > 0.0001 }
        for _ in 0..<3 {
            var added: [(Int, Double)] = []
            for py in 0..<outH {
                for px in 0..<outW where !filled[py * outW + px] {
                    var sum = 0.0, n = 0.0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            let qx = px + dx, qy = py + dy
                            guard qx >= 0, qx < outW, qy >= 0, qy < outH,
                                  filled[qy * outW + qx] else { continue }
                            sum += out[qy * outW + qx]; n += 1
                        }
                    }
                    if n > 0 { added.append((py * outW + px, sum / n)) }
                }
            }
            if added.isEmpty { break }
            for (index, value) in added { out[index] = value; filled[index] = true }
        }
        let fill = total / Double(covered)
        for i in 0..<out.count where !filled[i] { out[i] = fill }

        let travel = max(maxX - minX, maxY - minY)
        return Result(values: out, width: outW, height: outH, factor: factor,
                      framesUsed: accepted.count, framesRejected: rejected,
                      coverage: Double(covered) / Double(out.count), travel: travel)
    }

    /// How far `moved` sits from `reference`, to a fraction of a pixel.
    ///
    /// A plain search gives whole pixels; the sub-pixel part comes from
    /// fitting a parabola through the error either side of the best whole
    /// pixel, which is the standard trick and costs three more comparisons.
    private static func estimateShift(_ reference: [Double], _ moved: [Double],
                                      width: Int, height: Int,
                                      around guess: (dx: Int, dy: Int) = (0, 0),
                                      radius: Int? = nil) -> (dx: Double, dy: Double)? {
        let reach = radius ?? searchRadius
        let margin = 4
        let far = max(abs(guess.dx), abs(guess.dy)) + reach + 1
        // Frames that barely overlap cannot be lined up on what little they
        // share.
        guard width - 2 * margin - far > width / 3,
              height - 2 * margin - far > height / 3 else { return nil }

        /// The window of the reference that lands inside `moved` once shifted.
        func windowRows(_ dy: Int) -> (Int, Int) {
            (max(margin, margin - dy), min(height - 1 - margin, height - 1 - margin - dy))
        }
        func windowCols(_ dx: Int) -> (Int, Int) {
            (max(margin, margin - dx), min(width - 1 - margin, width - 1 - margin - dx))
        }
        // One step, chosen for the widest window so every offset samples the
        // same grid and their errors stay comparable.
        let step = max(1, min(width / 48, height / 48))

        /// Mean absolute difference over the overlap, each side with its own
        /// mean removed. Also returns the reference's own contrast there, so
        /// a match can be judged against what there was to match.
        func compare(_ dx: Int, _ dy: Int) -> (error: Double, contrast: Double)? {
            let (rowStart, rowEnd) = windowRows(dy)
            let (colStart, colEnd) = windowCols(dx)
            guard rowStart < rowEnd, colStart < colEnd else { return nil }
            var meanA = 0.0, meanB = 0.0, n = 0.0
            for y in stride(from: rowStart, through: rowEnd, by: step) {
                for x in stride(from: colStart, through: colEnd, by: step) {
                    meanA += reference[y * width + x]
                    meanB += moved[(y + dy) * width + (x + dx)]
                    n += 1
                }
            }
            guard n > 16 else { return nil }
            meanA /= n; meanB /= n
            var e = 0.0, contrast = 0.0
            for y in stride(from: rowStart, through: rowEnd, by: step) {
                for x in stride(from: colStart, through: colEnd, by: step) {
                    let a = reference[y * width + x] - meanA
                    let b = moved[(y + dy) * width + (x + dx)] - meanB
                    e += abs(a - b)
                    contrast += abs(a)
                }
            }
            return (e / n, contrast / n)
        }

        // A featureless scene cannot be aligned, and stacking it blind would
        // invent detail that is not there.
        guard let reference0 = compare(guess.dx, guess.dy), reference0.contrast > 0.15 else {
            return nil
        }
        let contrast = reference0.contrast

        func error(_ dx: Int, _ dy: Int) -> Double {
            compare(dx, dy)?.error ?? Double.greatestFiniteMagnitude
        }

        var best = (dx: guess.dx, dy: guess.dy, e: Double.greatestFiniteMagnitude)
        for dy in (guess.dy - reach)...(guess.dy + reach) {
            for dx in (guess.dx - reach)...(guess.dx + reach) {
                let e = error(dx, dy)
                if e < best.e { best = (dx, dy, e) }
            }
        }
        guard best.e < contrast * acceptRatio else { return nil }

        // Sub-pixel: the minimum of the parabola through the neighbouring
        // errors. Clamped, because a flat or noisy surface can otherwise
        // throw the vertex a long way outside the pixel it belongs to.
        func refine(_ centre: Double, _ before: Double, _ after: Double) -> Double {
            let denominator = before - 2 * centre + after
            guard abs(denominator) > 1e-9 else { return 0 }
            return max(-0.5, min(0.5, 0.5 * (before - after) / denominator))
        }
        let subX = refine(best.e, error(best.dx - 1, best.dy), error(best.dx + 1, best.dy))
        let subY = refine(best.e, error(best.dx, best.dy - 1), error(best.dx, best.dy + 1))

        // The search moved the *other* frame to line it up, so the frame's own
        // position is the opposite of the offset that matched.
        return (dx: -(Double(best.dx) + subX), dy: -(Double(best.dy) + subY))
    }
}
