import CoreGraphics
import Foundation

/// Finding a hand, and the five points on it worth matching.
///
/// A hand held up in front of both cameras is the one thing they can both make
/// out clearly, and it comes with five landmarks already spread across the
/// frame. That is a better calibration than four points taken one at a time:
/// the fingertips are far apart, which is where the two cameras disagree most
/// and therefore where a mapping is pinned down best.
///
/// The two sides find the hand by different means, because they are looking at
/// different things. The thermal camera has the easy job -- skin runs well
/// above room temperature, so the hand is simply the warm region. The webcam
/// has to go by colour, which is less certain: it works in ordinary light
/// against a background that is not itself skin-coloured, and gives up rather
/// than guessing when it cannot. Bare wood, cardboard and warm lamplight are
/// the known ways to fool it, which is why nothing here is applied without
/// being shown first.
enum HandDetector {

    struct Region {
        var pixels: [Int]
        var centre: CGPoint
    }

    /// The largest run of connected pixels the test accepts.
    ///
    /// Largest, rather than the one containing the most extreme pixel: at any
    /// useful threshold the fingers are often islands separate from the palm,
    /// and following the most extreme pixel makes the answer hop between them
    /// with the noise.
    static func largestRegion(width: Int, height: Int,
                              minimum: Int, maximum: Int,
                              accepts: (Int) -> Bool) -> Region? {
        var seen = [Bool](repeating: false, count: width * height)
        var best: Region?
        var bestSize = 0

        for seed in 0..<(width * height) where !seen[seed] && accepts(seed) {
            var queue = [seed]
            seen[seed] = true
            var pixels: [Int] = []
            var sumX = 0, sumY = 0

            while let index = queue.popLast() {
                pixels.append(index)
                sumX += index % width
                sumY += index / width
                let x = index % width, y = index / width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard !seen[next], accepts(next) else { continue }
                    seen[next] = true
                    queue.append(next)
                }
            }
            if pixels.count > bestSize {
                bestSize = pixels.count
                best = Region(pixels: pixels,
                              centre: CGPoint(x: Double(sumX) / Double(pixels.count),
                                              y: Double(sumY) / Double(pixels.count)))
            }
        }
        guard let best, bestSize >= minimum, bestSize <= maximum else { return nil }
        return best
    }

    // MARK: - The warm hand

    static func thermalHand(_ temps: [Double], width: Int, height: Int) -> Region? {
        guard temps.count == width * height, !temps.isEmpty else { return nil }
        var hottest = -Double.greatestFiniteMagnitude
        var total = 0.0
        for t in temps {
            total += t
            if t > hottest { hottest = t }
        }
        let mean = total / Double(temps.count)
        guard hottest - mean > 2.5 else { return nil }

        // The threshold comes up from the scene rather than down from the
        // peak. The peak is itself the top of the noise, so measuring down
        // from it gives a threshold that moves frame to frame and sits so
        // close to the peak that only the warmest specks qualify.
        let threshold = max(mean + 0.45 * (hottest - mean), mean + 2.0)
        return largestRegion(width: width, height: height,
                             minimum: 12, maximum: width * height / 6) {
            temps[$0] >= threshold
        }
    }

    // MARK: - The visible hand

    /// Skin by colour, in the usual chrominance window.
    ///
    /// Brightness is deliberately not part of the test beyond excluding the
    /// nearly black and the blown out: it varies with the light and with how
    /// dark the skin is, while the blue and red differences do not nearly so
    /// much. This is the standard rule and it has standard failure modes --
    /// bare wood, cardboard and tungsten light all sit in the same window.
    static func visibleHand(_ frame: VisibleCapture.Frame) -> Region? {
        let count = frame.width * frame.height
        guard frame.rgb.count == count * 3 else { return nil }

        func isSkin(_ index: Int) -> Bool {
            let p = index * 3
            let r = Double(frame.rgb[p]), g = Double(frame.rgb[p + 1]), b = Double(frame.rgb[p + 2])
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            guard y > 40, y < 245 else { return false }
            let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            // Skin is redder than it is blue, whatever the lighting.
            return cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173 && r > b
        }
        return largestRegion(width: frame.width, height: frame.height,
                             minimum: max(60, count / 400), maximum: count / 2,
                             accepts: isSkin)
    }

    // MARK: - The five points on it

    /// The fingertips of a region: the points furthest from its middle, one
    /// per finger.
    ///
    /// Worked out from the outline's distance to the centre as it goes round.
    /// Each finger is a hump in that, and the tips are the tops of the humps.
    /// A hump only counts if it stands clear of the dip beside it, so the
    /// bumpy edge of a palm does not produce a dozen phantom fingers.
    ///
    /// Returned in order around the hand, which is what lets two sets from two
    /// cameras be matched up.
    static func fingertips(of region: Region, width: Int, height: Int,
                           count wanted: Int = 5) -> [CGPoint] {
        guard region.pixels.count > 30, wanted > 0 else { return [] }

        // The furthest pixel in each direction from the middle.
        let sectors = 180
        var radius = [Double](repeating: 0, count: sectors)
        var furthest = [Int](repeating: -1, count: sectors)
        for index in region.pixels {
            let dx = Double(index % width) - region.centre.x
            let dy = Double(index / width) - region.centre.y
            let r = (dx * dx + dy * dy).squareRoot()
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            let sector = min(sectors - 1, Int(angle / (2 * .pi) * Double(sectors)))
            if r > radius[sector] {
                radius[sector] = r
                furthest[sector] = index
            }
        }

        // Smooth around the circle: a single ragged pixel is not a finger.
        var smoothed = radius
        for i in 0..<sectors {
            let before = radius[(i + sectors - 1) % sectors]
            let after = radius[(i + 1) % sectors]
            smoothed[i] = (before + radius[i] + after) / 3
        }

        let longest = smoothed.max() ?? 0
        guard longest > 0 else { return [] }
        // A fingertip is one of the far points of the hand. Without this, the
        // notches *between* the fingers qualify: they are narrow, and a small
        // bump in one stands clear of its own tiny surroundings, so both the
        // other tests wave them through even though they sit almost on top of
        // the middle of the hand.
        let reachEnough = longest * 0.45

        var peaks: [(sector: Int, radius: Double)] = []
        for i in 0..<sectors {
            let before = smoothed[(i + sectors - 1) % sectors]
            let after = smoothed[(i + 1) % sectors]
            guard smoothed[i] >= before, smoothed[i] >= after, furthest[i] >= 0,
                  smoothed[i] >= reachEnough else { continue }
            // How far this hump stands clear of the dips beside it, and how
            // wide it is at half that height. A finger is a narrow hump with
            // a dip on each side; the heel of the palm is a broad one.
            //
            // "The dip beside it" means the *nearest* valley each way, not the
            // lowest point before the ground rises higher than this peak.
            // Measured the second way, the longest finger of a group takes its
            // reading from the deep notch down by the palm, which puts the
            // half-height level below the valleys separating it from its
            // neighbours -- so the width measurement walks straight through
            // them and calls three fingers one wide lump. That was two of the
            // five fingers lost.
            func nearestDip(step: Int) -> Double {
                var previous = smoothed[i]
                for distance in 1...(sectors / 3) {
                    let sample = smoothed[(i + sectors + step * distance) % sectors]
                    // Two sectors of grace, so a single ragged step does not
                    // pass for a valley.
                    if sample > previous, distance > 2 { return previous }
                    previous = min(previous, sample)
                }
                return previous
            }
            let base = max(nearestDip(step: -1), nearestDip(step: 1))
            let rise = smoothed[i] - base
            // Only enough to reject a wobble in the outline. It is tempting
            // to ask for more, but how deep the notch between two fingers
            // comes out depends on how far away the hand is and how the
            // outline was found, and asking for a fixed share of the reach
            // threw away two fingers in the webcam picture while keeping all
            // five in the thermal one. Telling a finger from the heel of the
            // palm is the narrowness test's job, and that one does not care
            // about scale.
            guard rise >= max(1.5, smoothed[i] * 0.03) else { continue }

            let level = base + rise * 0.5
            var width = 1
            for step in [-1, 1] {
                for distance in 1...(sectors / 4) {
                    let sample = smoothed[(i + sectors + step * distance) % sectors]
                    if sample < level { break }
                    width += 1
                }
            }
            guard width <= sectors / 8 else { continue }
            peaks.append((i, smoothed[i]))
        }

        // Keep the longest, but never two from the same finger.
        //
        // How far apart is the whole question here. Seen from the middle of a
        // hand, four fingers occupy something like forty degrees between them
        // -- barely a dozen degrees each -- so a generous separation quietly
        // deletes the fingers next to the longest one and leaves three tips
        // out of five. Ten degrees is enough to stop one finger being counted
        // twice, given the outline has already been smoothed.
        peaks.sort { $0.radius > $1.radius }
        var kept: [Int] = []
        let apart = max(3, sectors / 36)
        for peak in peaks {
            let tooClose = kept.contains { existing in
                let gap = abs(existing - peak.sector)
                return min(gap, sectors - gap) < apart
            }
            if !tooClose { kept.append(peak.sector) }
            if kept.count == wanted { break }
        }

        // Back round the hand in order, so two sets can be lined up.
        kept.sort()
        return kept.compactMap { sector -> CGPoint? in
            guard furthest[sector] >= 0 else { return nil }
            return tip(of: region, width: width, sector: sector,
                       reach: smoothed[sector], sectors: sectors)
        }
    }

    /// The middle of the outermost part of a finger, rather than the single
    /// pixel that happens to reach furthest.
    ///
    /// One pixel is a poor landmark: which pixel wins depends on the exact
    /// edge of the region, and the two cameras do not agree on that. Averaging
    /// the tip means both find the same part of the same finger, which is what
    /// a matched point has to be. It halved the error of the mapping fitted
    /// from these points.
    private static func tip(of region: Region, width: Int,
                            sector: Int, reach: Double, sectors: Int) -> CGPoint? {
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for index in region.pixels {
            let dx = Double(index % width) - region.centre.x
            let dy = Double(index / width) - region.centre.y
            let r = (dx * dx + dy * dy).squareRoot()
            guard r >= reach * 0.88 else { continue }
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            let s = min(sectors - 1, Int(angle / (2 * .pi) * Double(sectors)))
            let gap = abs(s - sector)
            guard min(gap, sectors - gap) <= 3 else { continue }
            sumX += Double(index % width)
            sumY += Double(index / width)
            count += 1
        }
        guard count > 0 else { return nil }
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    // MARK: - Pairing the two sets up

    /// Works out the mapping from two sets of fingertips.
    ///
    /// Both sets run round the hand in order, but neither knows which finger
    /// it started on, and the two cameras can see the hand the other way about.
    /// So every way of lining the two rings up is tried: the mapping is solved
    /// from four of the pairs and judged by how well it predicts the fifth,
    /// which is the one piece of evidence a four-point fit cannot fake.
    ///
    /// Nil when no arrangement predicts that fifth point, which is what a
    /// misdetected finger on either side looks like.
    static func pair(thermal: [CGPoint], visible: [CGPoint],
                     tolerance: Double = 30) -> (homography: Homography, error: Double)? {
        guard thermal.count == 5, visible.count == 5 else { return nil }

        var best: (homography: Homography, error: Double)?
        var bestPairs: [(from: CGPoint, to: CGPoint)] = []
        for reversed in [false, true] {
            let ring = reversed ? Array(visible.reversed()) : visible
            for offset in 0..<5 {
                let rotated = (0..<5).map { ring[($0 + offset) % 5] }
                for held in 0..<5 {
                    let pairs = (0..<5).filter { $0 != held }
                        .map { (from: thermal[$0], to: rotated[$0]) }
                    guard let candidate = Homography.solve(pairs) else { continue }
                    let predicted = candidate.map(thermal[held])
                    let error = Double(hypot(predicted.x - rotated[held].x,
                                             predicted.y - rotated[held].y))
                    if error < (best?.error ?? .greatestFiniteMagnitude) {
                        best = (candidate, error)
                        bestPairs = (0..<5).map { (from: thermal[$0], to: rotated[$0]) }
                    }
                }
            }
        }
        guard let best, best.error <= tolerance else { return nil }

        // The ordering is settled; now use all five points rather than the
        // four that found it. Every point is located to a few pixels, and a
        // four-point fit follows those errors instead of averaging them.
        if let refined = Homography.fit(bestPairs) {
            return (refined, best.error)
        }
        return best
    }
}
