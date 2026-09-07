import Foundation

/// Keeps a measurement object on the thing it was placed on.
///
/// There is no motion sensor to lean on, only temperature, so this is plain
/// template matching: remember the patch of scene under the object, then each
/// frame look for the nearby offset that matches it best and move the object
/// there. Template and patch both have their own mean removed before
/// comparing, so a scene that warms up, a change of range or a NUC shifts
/// every value together without breaking the match -- what is followed is the
/// *shape* of the heat, not its absolute level.
///
/// It follows what it can see. A hand crossing in front of a wall, a face, a
/// switch on a panel: all fine. A featureless patch of that same wall is not
/// trackable by anything, and starting a track there is refused rather than
/// left to wander.
final class ObjectTracker {

    /// How far an object may move between frames, in sensor pixels. At 25fps
    /// a hand moves a couple of pixels; 12 leaves room for a fast pan without
    /// letting the match jump onto a different object.
    private static let searchRadius = 12
    /// Samples per axis. An area covering half the frame would otherwise cost
    /// millions of comparisons a frame for no more accuracy.
    private static let maxSamples = 16
    /// Smallest half-extent of the patch that gets remembered. A spot is 3x3,
    /// far too little to match on, so the *template* is bigger than the object
    /// it carries.
    private static let minHalfExtent = 7
    /// A patch flatter than this has no feature to lock onto.
    private static let minContrast = 0.4
    /// A match is believed while its residual stays this far below the
    /// template's own contrast. Relative, not a fixed number of degrees:
    /// a bold target tolerates a bigger residual than a subtle one.
    private static let acceptRatio = 0.6
    /// How fast the template follows the object's own temperature drift.
    private static let adaptRate = 0.12

    private struct Template {
        var halfW: Int, halfH: Int
        var stride: Int
        var samplesX: Int, samplesY: Int
        /// Mean removed, so only the shape is compared.
        var values: [Double]
        var contrast: Double
    }

    private var templates: [String: Template] = [:]
    private var lostNames: Set<String> = []
    /// Matching runs on the capture queue while the buttons and the menu are
    /// on the main one, so every entry point takes this.
    private let lock = NSLock()

    /// Objects whose target could not be found in the latest frame. They keep
    /// their last position; the overlay says the track is lost.
    var lost: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return lostNames
    }

    func isTracking(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return templates[name] != nil
    }

    func stop(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        templates[name] = nil
        lostNames.remove(name)
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        templates.removeAll()
        lostNames.removeAll()
    }

    /// Remembers the patch under an object. Returns false when there is
    /// nothing there to follow.
    func start(_ name: String, centreX: Int, centreY: Int, halfWidth: Int, halfHeight: Int,
               temps: [Double], width: Int, height: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let halfW = max(ObjectTracker.minHalfExtent, halfWidth)
        let halfH = max(ObjectTracker.minHalfExtent, halfHeight)
        // Round the step up, not down: dividing the longer axis down leaves
        // the sample count above the cap it is there to enforce.
        let span = max(2 * halfW, 2 * halfH)
        let stride = max(1, (span + ObjectTracker.maxSamples - 2) / (ObjectTracker.maxSamples - 1))
        let samplesX = (2 * halfW) / stride + 1
        let samplesY = (2 * halfH) / stride + 1

        var template = Template(halfW: halfW, halfH: halfH, stride: stride,
                                samplesX: samplesX, samplesY: samplesY,
                                values: [], contrast: 0)
        var patch = sample(template, atX: centreX, y: centreY,
                           temps: temps, width: width, height: height)
        let mean = patch.reduce(0, +) / Double(patch.count)
        for i in patch.indices { patch[i] -= mean }
        let contrast = patch.reduce(0) { $0 + abs($1) } / Double(patch.count)
        guard contrast >= ObjectTracker.minContrast else { return false }

        template.values = patch
        template.contrast = contrast
        templates[name] = template
        lostNames.remove(name)
        return true
    }

    /// Where the object went since the last frame, or nil if it was not found
    /// (or is not being tracked). The offset is in sensor pixels.
    func follow(_ name: String, centreX: Int, centreY: Int,
                temps: [Double], width: Int, height: Int) -> (dx: Int, dy: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard var template = templates[name] else { return nil }

        // Coarse pass over the window, then a fine pass around the winner:
        // a full single-pixel sweep of a 25x25 window costs three times as
        // much for the same answer.
        var best = (dx: 0, dy: 0, residual: Double.greatestFiniteMagnitude)
        let r = ObjectTracker.searchRadius
        for dy in stride(from: -r, through: r, by: 2) {
            for dx in stride(from: -r, through: r, by: 2) {
                let e = residual(template, atX: centreX + dx, y: centreY + dy,
                                 temps: temps, width: width, height: height)
                if e < best.residual { best = (dx, dy, e) }
            }
        }
        for dy in (best.dy - 1)...(best.dy + 1) {
            for dx in (best.dx - 1)...(best.dx + 1) {
                let e = residual(template, atX: centreX + dx, y: centreY + dy,
                                 temps: temps, width: width, height: height)
                if e < best.residual { best = (dx, dy, e) }
            }
        }

        guard best.residual < template.contrast * ObjectTracker.acceptRatio else {
            lostNames.insert(name)
            return nil
        }
        lostNames.remove(name)

        // Follow the object's own drift, so a hand that keeps warming stays
        // recognisable. Only ever from a match that was believed.
        var patch = sample(template, atX: centreX + best.dx, y: centreY + best.dy,
                           temps: temps, width: width, height: height)
        let mean = patch.reduce(0, +) / Double(patch.count)
        for i in patch.indices { patch[i] -= mean }
        let rate = ObjectTracker.adaptRate
        for i in template.values.indices {
            template.values[i] = template.values[i] * (1 - rate) + patch[i] * rate
        }
        template.contrast = template.values.reduce(0) { $0 + abs($1) }
            / Double(template.values.count)
        templates[name] = template

        return (best.dx, best.dy)
    }

    /// Samples the template grid centred on a point, clamped to the frame so
    /// an object at the edge still matches.
    private func sample(_ t: Template, atX cx: Int, y cy: Int,
                        temps: [Double], width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: t.samplesX * t.samplesY)
        var k = 0
        for j in 0..<t.samplesY {
            let py = min(max(cy - t.halfH + j * t.stride, 0), height - 1)
            for i in 0..<t.samplesX {
                let px = min(max(cx - t.halfW + i * t.stride, 0), width - 1)
                out[k] = temps[py * width + px]
                k += 1
            }
        }
        return out
    }

    /// Mean absolute difference between the template and the patch at a point,
    /// each with its own mean removed.
    private func residual(_ t: Template, atX cx: Int, y cy: Int,
                          temps: [Double], width: Int, height: Int) -> Double {
        var sum = 0.0
        var k = 0
        var patch = [Double](repeating: 0, count: t.values.count)
        for j in 0..<t.samplesY {
            let py = min(max(cy - t.halfH + j * t.stride, 0), height - 1)
            for i in 0..<t.samplesX {
                let px = min(max(cx - t.halfW + i * t.stride, 0), width - 1)
                let v = temps[py * width + px]
                patch[k] = v
                sum += v
                k += 1
            }
        }
        let mean = sum / Double(patch.count)
        var error = 0.0
        for i in patch.indices { error += abs(patch[i] - mean - t.values[i]) }
        return error / Double(patch.count)
    }
}
