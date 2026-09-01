import Foundation

/// Measurement objects -- the spots and areas the user drops on the image.
///
/// Named after the convention every thermal package uses (FLIR, HikMicro,
/// Testo): "Sp1" for spots, "Ar1" for areas, so the readouts are familiar.
struct Measurement: Equatable {
    enum Kind: Equatable { case spot, area, line }

    /// A spot is not one pixel. This sensor's per-pixel noise is high enough
    /// that a single-pixel readout jitters by a degree or more, so a spot
    /// reports the 3x3 neighbourhood -- which is also what the user asked for
    /// ("srednia z danego mikropunktu") and what commercial spot meters do.
    static let spotRadius = 1

    var id: Int
    var kind: Kind
    /// Sensor coordinates (256x192), top-left origin.
    var x: Int
    var y: Int
    /// Area only; a spot derives its extent from `spotRadius`.
    var w: Int
    var h: Int
    /// Line only: the far end. Kept separate from w/h so a line can run in any
    /// direction, which a width/height pair cannot express.
    var x2: Int = 0
    var y2: Int = 0
    /// Per-object emissivity. nil means "use the camera-wide value" -- the
    /// point of overriding it is a scene with two materials in one frame
    /// (bare metal reads far too cold next to painted steel otherwise).
    var emissivity: Double?

    var name: String {
        switch kind {
        case .spot: return "Sp\(id)"
        case .area: return "Ar\(id)"
        case .line: return "Li\(id)"
        }
    }

    /// Pixel indices the line passes through, sampled one per step along its
    /// longer axis so no pixel is visited twice.
    func linePixels(width: Int, height: Int) -> [Int] {
        let dx = x2 - x, dy = y2 - y
        let steps = Swift.max(abs(dx), abs(dy))
        guard steps > 0 else {
            let px = Swift.min(Swift.max(x, 0), width - 1)
            let py = Swift.min(Swift.max(y, 0), height - 1)
            return [py * width + px]
        }
        var out: [Int] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let px = Int((Double(x) + t * Double(dx)).rounded())
            let py = Int((Double(y) + t * Double(dy)).rounded())
            guard px >= 0, px < width, py >= 0, py < height else { continue }
            out.append(py * width + px)
        }
        return out
    }

    /// Pixel bounds, clamped to the sensor.
    func bounds(width: Int, height: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let r = Measurement.spotRadius
        let rawX0 = kind == .spot ? x - r : x
        let rawY0 = kind == .spot ? y - r : y
        let rawX1 = kind == .spot ? x + r : x + w - 1
        let rawY1 = kind == .spot ? y + r : y + h - 1
        return (max(0, rawX0), max(0, rawY0),
                min(width - 1, rawX1), min(height - 1, rawY1))
    }
}

struct MeasurementResult {
    var minValue: Double
    var maxValue: Double
    var average: Double
    /// Frame-wide pixel indices, so the renderer can mark where in the area
    /// the hot and cold points actually are.
    var minIndex: Int
    var maxIndex: Int
    /// Line only: the N most prominent peaks (or troughs) along it, hottest or
    /// coldest first. Frame-wide pixel indices, with their temperature.
    var extrema: [(index: Int, value: Double)] = []

    static let zero = MeasurementResult(minValue: 0, maxValue: 0, average: 0,
                                        minIndex: 0, maxIndex: 0)
}

enum MeasurementEngine {

    /// What the N markers on a line should point at.
    enum ExtremeMode { case hottest, coldest }

    static func evaluate(_ m: Measurement, temps: [Double], width: Int, height: Int,
                         lineExtremeCount: Int = 3,
                         lineExtremeMode: ExtremeMode = .hottest) -> MeasurementResult {
        if m.kind == .line {
            return evaluateLine(m, temps: temps, width: width, height: height,
                                count: lineExtremeCount, mode: lineExtremeMode)
        }
        let b = m.bounds(width: width, height: height)
        guard b.x1 >= b.x0, b.y1 >= b.y0 else { return .zero }

        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        var loIdx = 0, hiIdx = 0

        for py in b.y0...b.y1 {
            for px in b.x0...b.x1 {
                let i = py * width + px
                guard i < temps.count else { continue }
                let t = temps[i]
                if t < lo { lo = t; loIdx = i }
                if t > hi { hi = t; hiIdx = i }
                sum += t
                count += 1
            }
        }
        guard count > 0 else { return .zero }
        return MeasurementResult(minValue: lo, maxValue: hi,
                                 average: sum / Double(count),
                                 minIndex: loIdx, maxIndex: hiIdx)
    }

    private static func evaluateLine(_ m: Measurement, temps: [Double],
                                     width: Int, height: Int,
                                     count: Int, mode: ExtremeMode) -> MeasurementResult {
        let pixels = m.linePixels(width: width, height: height)
        guard !pixels.isEmpty else { return .zero }

        let values = pixels.map { $0 < temps.count ? temps[$0] : 0 }
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        var loIdx = pixels[0], hiIdx = pixels[0]
        var sum = 0.0
        for (i, v) in values.enumerated() {
            if v < lo { lo = v; loIdx = pixels[i] }
            if v > hi { hi = v; hiIdx = pixels[i] }
            sum += v
        }

        return MeasurementResult(minValue: lo, maxValue: hi,
                                 average: sum / Double(values.count),
                                 minIndex: loIdx, maxIndex: hiIdx,
                                 extrema: peaks(values, pixels: pixels,
                                                count: count, mode: mode))
    }

    /// Picks the N most prominent local peaks (or troughs) along the profile.
    ///
    /// Taking the N highest samples outright is useless: they all land on the
    /// same hot spot, a pixel apart. Local extrema give N *distinct* features,
    /// which is what "the three hottest points on this line" means.
    private static func peaks(_ values: [Double], pixels: [Int],
                              count: Int, mode: ExtremeMode) -> [(index: Int, value: Double)] {
        guard count > 0, values.count > 1 else { return [] }
        let beats: (Double, Double) -> Bool = mode == .hottest ? (>) : (<)
        let ties: (Double, Double) -> Bool = mode == .hottest ? (>=) : (<=)

        // Position along the profile, not the frame-wide pixel index: for any
        // line that is not horizontal, consecutive samples differ by roughly a
        // row width, so a separation test on the index never fires and the
        // markers pile up on one feature.
        var found: [(step: Int, index: Int, value: Double)] = []
        for i in values.indices {
            let left = i > 0 ? values[i - 1] : values[i]
            let right = i < values.count - 1 ? values[i + 1] : values[i]
            // Strictly better than at least one neighbour, so a flat stretch
            // does not report every one of its pixels as a peak -- which it
            // did, turning "mark the 9 hottest points" on a uniform wall into
            // nine markers sitting on identical readings.
            let isPeak = (beats(values[i], left) && ties(values[i], right))
                || (ties(values[i], left) && beats(values[i], right))
            if isPeak { found.append((i, pixels[i], values[i])) }
        }
        // A monotonic profile has no interior extremum; its end is the answer.
        if found.isEmpty {
            let i = mode == .hottest
                ? (values.firstIndex(of: values.max()!) ?? 0)
                : (values.firstIndex(of: values.min()!) ?? 0)
            found = [(i, pixels[i], values[i])]
        }
        found.sort { mode == .hottest ? $0.value > $1.value : $0.value < $1.value }

        // Collapse a plateau: neighbouring samples of one feature all qualify.
        // Keep markers visually apart: one feature spans several samples, and
        // two markers a pixel apart are unreadable at any zoom.
        let minSeparation = Swift.max(3, values.count / 40)
        var kept: [(step: Int, index: Int, value: Double)] = []
        for candidate in found {
            let tooClose = kept.contains { abs($0.step - candidate.step) < minSeparation }
            if !tooClose { kept.append(candidate) }
            if kept.count == count { break }
        }
        return kept.map { (index: $0.index, value: $0.value) }
    }
}

/// Holds the user's measurement objects and hands out sequential ids.
final class MeasurementStore {
    private(set) var items: [Measurement] = []
    private var nextSpotID = 1
    private var nextAreaID = 1
    private var nextLineID = 1

    @discardableResult
    func addSpot(x: Int, y: Int) -> Measurement {
        let m = Measurement(id: nextSpotID, kind: .spot, x: x, y: y, w: 1, h: 1,
                            emissivity: nil)
        nextSpotID += 1
        items.append(m)
        return m
    }

    @discardableResult
    func addLine(x: Int, y: Int, x2: Int, y2: Int) -> Measurement {
        let m = Measurement(id: nextLineID, kind: .line, x: x, y: y, w: 1, h: 1,
                            x2: x2, y2: y2, emissivity: nil)
        nextLineID += 1
        items.append(m)
        return m
    }

    @discardableResult
    func addArea(x: Int, y: Int, w: Int, h: Int) -> Measurement {
        let m = Measurement(id: nextAreaID, kind: .area, x: x, y: y,
                            w: max(2, w), h: max(2, h), emissivity: nil)
        nextAreaID += 1
        items.append(m)
        return m
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
    }

    func removeAll() {
        items.removeAll()
        nextSpotID = 1
        nextAreaID = 1
        nextLineID = 1
    }

    func setEmissivity(_ value: Double?, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].emissivity = value
    }
}
