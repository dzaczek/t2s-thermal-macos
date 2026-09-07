import Foundation

/// Builds one large picture out of many frames.
///
/// A 256x192 sensor is small, and the usual fix is to take advantage of the
/// fact that a hand never holds still. Each frame samples the scene from a
/// slightly different position, so a stack of them carries more detail than
/// any single one -- provided you know where each frame sat. That is the
/// whole job here: work out where each frame sits, then lay them all onto one
/// finer grid.
///
/// The same machinery covers two things that look different from outside:
///
///   * Hold the camera roughly still and the shifts are a fraction of a
///     pixel. The result is the same view at a higher resolution. `stack`
///     does that from a short burst.
///   * Sweep it across a wall and the shifts run to hundreds of pixels. The
///     canvas grows to hold wherever the frames landed and the result is a
///     mosaic far larger than the sensor can see at once. `PanoramaBuilder`
///     does that, taking frames as they arrive for as long as you keep going.
///
/// Movement in any direction is followed -- left, right, up, down or any
/// mixture, and the canvas grows on whichever sides it needs to. On a tripod,
/// with no movement at all, there is nothing to recover beyond less noise:
/// sub-pixel detail comes *from* the shake.
///
/// What is not worked out is rotation. This is not Hugin: there is no lens
/// model, no projection onto a sphere and no angle estimate, so twisting the
/// camera as you sweep leaves frames that cannot be lined up, and they are
/// dropped rather than smeared in. Slide it about as you like; keep it the
/// same way up.
enum SuperPhoto {

    struct Result {
        var values: [Double]
        var width: Int, height: Int
        /// How much finer the grid is than the sensor.
        var factor: Int
        var framesUsed: Int
        var framesRejected: Int
        /// Fraction of the canvas that real samples landed on. Below 1 the
        /// edges of a sweep are ragged and were filled in.
        var coverage: Double
        /// How far the frames wandered, in sensor pixels. Tells the difference
        /// between a stack and a sweep.
        var travel: Double
        /// Where the picture sits, in the coordinates of the first frame:
        /// output cell (x, y) is centred on
        /// (originX + x / factor, originY + y / factor).
        ///
        /// Worth carrying because the canvas is trimmed at the end, so the
        /// corner of the picture is not the corner of the first frame and
        /// nothing downstream can assume where it is.
        var originX: Double
        var originY: Double
    }

    /// How far a frame may have moved when nothing better is known.
    static let searchRadius = 6
    /// A frame matching worse than this fraction of the reference contrast is
    /// not a shifted view of the same scene -- something in it moved, or the
    /// camera turned. Stacking it would smear the result.
    static let acceptRatio = 0.75
    /// A burst is a burst: if the frames wandered further than this many
    /// sensor widths, the user was sweeping and wanted the other mode.
    private static let maxBurstGrowth = 3.0

    // MARK: - The grid everything lands on

    /// Accumulates samples on a grid finer than the sensor, growing to hold
    /// whatever arrives.
    ///
    /// Kept apart from the two ways of feeding it, so a burst and a sweep of
    /// a thousand frames share one implementation of the part that decides
    /// what a pixel ends up being.
    final class Canvas {
        let factor: Int
        private(set) var width = 0
        private(set) var height = 0
        /// The sensor-pixel coordinate that lands on cell zero.
        private(set) var originX = 0.0
        private(set) var originY = 0.0
        private var sum: [Double] = []
        private var weight: [Double] = []
        private let maxCells: Int

        /// Each sample is spread over a tent half a source pixel wide. Wider
        /// than that and neighbouring samples overlap so much that the result
        /// comes out blurrier than simply enlarging one frame, which defeats
        /// the whole exercise. Narrower leaves gaps, and those are filled in
        /// from their neighbours at the end.
        private var reach: Double { Double(factor) * 0.5 }

        init(factor: Int, maxCells: Int) {
            self.factor = factor
            self.maxCells = maxCells
        }

        /// Makes room for a frame of this size sitting at this offset.
        /// Returns false when that would take the canvas past its cap, which
        /// is the only thing standing between a long sweep and all the memory
        /// in the machine.
        func reserve(frameWidth: Int, frameHeight: Int,
                     offsetX: Double, offsetY: Double) -> Bool {
            let f = Double(factor)
            if width == 0 {
                originX = offsetX
                originY = offsetY
                width = Int((Double(frameWidth) * f).rounded(.up)) + 2
                height = Int((Double(frameHeight) * f).rounded(.up)) + 2
                guard width * height <= maxCells else { width = 0; height = 0; return false }
                sum = [Double](repeating: 0, count: width * height)
                weight = [Double](repeating: 0, count: width * height)
                return true
            }

            let lowX = Int(floor((offsetX - originX) * f - reach)) - 1
            let lowY = Int(floor((offsetY - originY) * f - reach)) - 1
            let highX = Int(ceil((offsetX + Double(frameWidth) - originX) * f + reach)) + 1
            let highY = Int(ceil((offsetY + Double(frameHeight) - originY) * f + reach)) + 1
            guard lowX < 0 || lowY < 0 || highX >= width || highY >= height else { return true }

            // Grow in slabs rather than by the exact amount needed, so a slow
            // sweep does not reallocate on every single frame.
            let slab = 128
            func slabs(_ needed: Int) -> Int { needed <= 0 ? 0 : ((needed + slab - 1) / slab) * slab }
            let padLeft = slabs(-lowX)
            let padTop = slabs(-lowY)
            let padRight = slabs(highX - width + 1)
            let padBottom = slabs(highY - height + 1)

            let newWidth = width + padLeft + padRight
            let newHeight = height + padTop + padBottom
            guard newWidth * newHeight <= maxCells else { return false }

            var newSum = [Double](repeating: 0, count: newWidth * newHeight)
            var newWeight = [Double](repeating: 0, count: newWidth * newHeight)
            for y in 0..<height {
                let from = y * width
                let to = (y + padTop) * newWidth + padLeft
                for x in 0..<width {
                    newSum[to + x] = sum[from + x]
                    newWeight[to + x] = weight[from + x]
                }
            }
            sum = newSum
            weight = newWeight
            width = newWidth
            height = newHeight
            originX -= Double(padLeft) / f
            originY -= Double(padTop) / f
            return true
        }

        func add(_ frame: [Double], frameWidth: Int, frameHeight: Int,
                 offsetX: Double, offsetY: Double) {
            let f = Double(factor)
            let reach = self.reach
            let ox = (offsetX - originX) * f
            let oy = (offsetY - originY) * f
            for y in 0..<frameHeight {
                let cy = (Double(y) + 0.5) * f + oy
                let y0 = max(0, Int(floor(cy - reach))), y1 = min(height - 1, Int(ceil(cy + reach)))
                guard y0 <= y1 else { continue }
                for x in 0..<frameWidth {
                    let value = frame[y * frameWidth + x]
                    let cx = (Double(x) + 0.5) * f + ox
                    let x0 = max(0, Int(floor(cx - reach))), x1 = min(width - 1, Int(ceil(cx + reach)))
                    guard x0 <= x1 else { continue }
                    for py in y0...y1 {
                        let wy = 1 - abs(Double(py) + 0.5 - cy) / reach
                        guard wy > 0 else { continue }
                        let row = py * width
                        for px in x0...x1 {
                            let wx = 1 - abs(Double(px) + 0.5 - cx) / reach
                            guard wx > 0 else { continue }
                            let w = wx * wy
                            sum[row + px] += value * w
                            weight[row + px] += w
                        }
                    }
                }
            }
        }

        /// Turns the accumulation into a picture, cropping away any margin
        /// that nothing ever landed on.
        func finish() -> (values: [Double], width: Int, height: Int,
                          coverage: Double, originX: Double, originY: Double)? {
            guard width > 0, height > 0 else { return nil }

            // Slabs are added generously, so the canvas usually has empty
            // borders. Trim them: they are not part of the picture and would
            // show as a flat frame around it.
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                for x in 0..<width where weight[y * width + x] > 0.0001 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }

            let outW = maxX - minX + 1, outH = maxY - minY + 1
            var out = [Double](repeating: 0, count: outW * outH)
            var filled = [Bool](repeating: false, count: outW * outH)
            var covered = 0
            var total = 0.0
            for y in 0..<outH {
                for x in 0..<outW {
                    let w = weight[(y + minY) * width + (x + minX)]
                    guard w > 0.0001 else { continue }
                    let value = sum[(y + minY) * width + (x + minX)] / w
                    out[y * outW + x] = value
                    filled[y * outW + x] = true
                    covered += 1
                    total += value
                }
            }
            guard covered > 0 else { return nil }

            // Gaps come from two places: cells that no sample quite reached,
            // and the ragged edge of a sweep. Both are filled from whatever is
            // around them, which is right for a one-cell gap and honest enough
            // at an edge. Anything still empty is nowhere near real data and
            // gets the average.
            for _ in 0..<3 {
                var added: [(Int, Double)] = []
                for py in 0..<outH {
                    for px in 0..<outW where !filled[py * outW + px] {
                        var neighbours = 0.0, n = 0.0
                        for dy in -1...1 {
                            for dx in -1...1 where !(dx == 0 && dy == 0) {
                                let qx = px + dx, qy = py + dy
                                guard qx >= 0, qx < outW, qy >= 0, qy < outH,
                                      filled[qy * outW + qx] else { continue }
                                neighbours += out[qy * outW + qx]; n += 1
                            }
                        }
                        if n > 0 { added.append((py * outW + px, neighbours / n)) }
                    }
                }
                if added.isEmpty { break }
                for (index, value) in added { out[index] = value; filled[index] = true }
            }
            let fill = total / Double(covered)
            for i in 0..<out.count where !filled[i] { out[i] = fill }

            // A sample at sensor coordinate s landed at canvas coordinate
            // (s - origin + 0.5) * factor, so after trimming by minX the
            // first output cell sits here.
            let f = Double(factor)
            return (out, outW, outH, Double(covered) / Double(outW * outH),
                    (Double(minX) + 0.5) / f - 0.5 + originX,
                    (Double(minY) + 0.5) / f - 0.5 + originY)
        }
    }

    // MARK: - A short burst, held roughly still

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

        // Chaining frame to frame is the only way to follow movement, but
        // every link adds its own small error and they accumulate: over a
        // dozen frames a 32-pixel drift measured 36. So each frame is measured
        // again directly against the first, searching only around where the
        // chain said it should be. That leaves one estimate's worth of error
        // instead of a dozen.
        for n in 1..<accepted.count {
            let guess = (dx: Int((-offsets[n].dx).rounded()), dy: Int((-offsets[n].dy).rounded()))
            if let direct = estimateShift(frames[0], frames[accepted[n]],
                                          width: width, height: height,
                                          around: guess, radius: 2) {
                offsets[n] = direct
            }
        }

        let minX = offsets.map(\.dx).min()!, maxX = offsets.map(\.dx).max()!
        let minY = offsets.map(\.dy).min()!, maxY = offsets.map(\.dy).max()!
        // A burst that wandered this far was a sweep, and a sweep wants the
        // other mode: it can keep going, and it does not have to hold every
        // frame in memory at once.
        guard Double(width) + (maxX - minX) <= Double(width) * maxBurstGrowth,
              Double(height) + (maxY - minY) <= Double(height) * maxBurstGrowth else { return nil }

        let canvas = Canvas(factor: factor, maxCells: 8_000_000)
        for (n, index) in accepted.enumerated() {
            guard canvas.reserve(frameWidth: width, frameHeight: height,
                                 offsetX: offsets[n].dx, offsetY: offsets[n].dy) else { return nil }
            canvas.add(frames[index], frameWidth: width, frameHeight: height,
                       offsetX: offsets[n].dx, offsetY: offsets[n].dy)
        }
        guard let done = canvas.finish() else { return nil }

        return Result(values: done.values, width: done.width, height: done.height,
                      factor: factor, framesUsed: accepted.count, framesRejected: rejected,
                      coverage: done.coverage, travel: max(maxX - minX, maxY - minY),
                      originX: done.originX, originY: done.originY)
    }

    // MARK: - Where a frame sits

    /// How far `moved` sits from `reference`, to a fraction of a pixel.
    ///
    /// A plain search gives whole pixels; the sub-pixel part comes from
    /// fitting a parabola through the error either side of the best whole
    /// pixel, which is the standard trick and costs three more comparisons.
    static func estimateShift(_ reference: [Double], _ moved: [Double],
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

/// Lays frames onto one growing canvas as they arrive, for as long as you
/// keep sweeping.
///
/// A burst holds every frame in memory and works out all the shifts at the
/// end, which is fine for a second of them and hopeless for a minute. This
/// adds each frame to the canvas and lets it go, so what is held is the
/// picture and nothing else -- a sweep can run as long as the canvas cap
/// allows regardless of how many frames go into it.
///
/// Drift is the thing to get right over a long sweep. Measuring each frame
/// against the one before it accumulates one small error per frame, and
/// hundreds of frames later the far end is visibly out of place. So frames
/// are measured against a *keyframe* which is only replaced once the view has
/// moved a good part of a sensor width: one error per keyframe instead of one
/// per frame. Where the next frame will be is predicted from how fast the
/// last ones moved, which keeps the search small however quickly you sweep,
/// and works the same in any direction.
final class PanoramaBuilder {

    private let width: Int, height: Int
    private let canvas: SuperPhoto.Canvas
    private let factor: Int

    private var keyframe: [Double]?
    private var keyframeOffset = (dx: 0.0, dy: 0.0)
    private var lastOffset = (dx: 0.0, dy: 0.0)
    private var velocity = (dx: 0.0, dy: 0.0)

    private(set) var framesUsed = 0
    private(set) var framesRejected = 0
    private var spanX = (min: 0.0, max: 0.0)
    private var spanY = (min: 0.0, max: 0.0)
    /// Set once the canvas cap is reached: the sweep has to stop there.
    private(set) var isFull = false

    /// How far the view may move from the keyframe before a new one is taken.
    /// A third of the sensor still leaves plenty of overlap to match on.
    private static let keyframeDistance = 0.33

    init(width: Int, height: Int, factor: Int = 2, maxCells: Int = 24_000_000) {
        self.width = width
        self.height = height
        self.factor = factor
        self.canvas = SuperPhoto.Canvas(factor: factor, maxCells: maxCells)
    }

    var canvasSize: (width: Int, height: Int) { (canvas.width, canvas.height) }
    var travel: Double { max(spanX.max - spanX.min, spanY.max - spanY.min) }

    /// Adds a frame. False means it could not be placed: either it did not
    /// match what came before, or the canvas is full.
    @discardableResult
    func add(_ frame: [Double]) -> Bool {
        guard frame.count == width * height, !isFull else { return false }

        guard let keyframe else {
            guard canvas.reserve(frameWidth: width, frameHeight: height,
                                 offsetX: 0, offsetY: 0) else { isFull = true; return false }
            canvas.add(frame, frameWidth: width, frameHeight: height, offsetX: 0, offsetY: 0)
            self.keyframe = frame
            framesUsed = 1
            return true
        }

        // Where the frame should be, going on how the last ones moved.
        let predicted = (dx: lastOffset.dx + velocity.dx - keyframeOffset.dx,
                         dy: lastOffset.dy + velocity.dy - keyframeOffset.dy)
        let guess = (dx: Int((-predicted.dx).rounded()), dy: Int((-predicted.dy).rounded()))

        // A tight search around the prediction first; a wider one only if that
        // fails, which is what a sudden change of speed looks like.
        var shift = SuperPhoto.estimateShift(keyframe, frame, width: width, height: height,
                                             around: guess, radius: 3)
        if shift == nil {
            shift = SuperPhoto.estimateShift(keyframe, frame, width: width, height: height,
                                             around: guess, radius: SuperPhoto.searchRadius)
        }
        guard let shift else {
            framesRejected += 1
            return false
        }

        let offset = (dx: keyframeOffset.dx + shift.dx, dy: keyframeOffset.dy + shift.dy)
        guard canvas.reserve(frameWidth: width, frameHeight: height,
                             offsetX: offset.dx, offsetY: offset.dy) else {
            isFull = true
            return false
        }
        canvas.add(frame, frameWidth: width, frameHeight: height,
                   offsetX: offset.dx, offsetY: offset.dy)

        velocity = (dx: offset.dx - lastOffset.dx, dy: offset.dy - lastOffset.dy)
        lastOffset = offset
        framesUsed += 1
        spanX = (min(spanX.min, offset.dx), max(spanX.max, offset.dx))
        spanY = (min(spanY.min, offset.dy), max(spanY.max, offset.dy))

        if max(abs(offset.dx - keyframeOffset.dx), abs(offset.dy - keyframeOffset.dy))
            > Double(width) * PanoramaBuilder.keyframeDistance {
            self.keyframe = frame
            keyframeOffset = offset
        }
        return true
    }

    func finish() -> SuperPhoto.Result? {
        guard framesUsed >= 2, let done = canvas.finish() else { return nil }
        return SuperPhoto.Result(values: done.values, width: done.width, height: done.height,
                                 factor: factor, framesUsed: framesUsed,
                                 framesRejected: framesRejected,
                                 coverage: done.coverage, travel: travel,
                                 originX: done.originX, originY: done.originY)
    }
}
