import Foundation

/// Measurement objects -- the spots and areas the user drops on the image.
///
/// Named after the convention every thermal package uses (FLIR, HikMicro,
/// Testo): "Sp1" for spots, "Ar1" for areas, so the readouts are familiar.
struct Measurement: Equatable {
    enum Kind: Equatable { case spot, area }

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
    /// Per-object emissivity. nil means "use the camera-wide value" -- the
    /// point of overriding it is a scene with two materials in one frame
    /// (bare metal reads far too cold next to painted steel otherwise).
    var emissivity: Double?

    var name: String { kind == .spot ? "Sp\(id)" : "Ar\(id)" }

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

struct MeasurementResult: Equatable {
    var minValue: Double
    var maxValue: Double
    var average: Double
    /// Frame-wide pixel indices, so the renderer can mark where in the area
    /// the hot and cold points actually are.
    var minIndex: Int
    var maxIndex: Int

    static let zero = MeasurementResult(minValue: 0, maxValue: 0, average: 0,
                                        minIndex: 0, maxIndex: 0)
}

enum MeasurementEngine {

    static func evaluate(_ m: Measurement, temps: [Double],
                         width: Int, height: Int) -> MeasurementResult {
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
}

/// Holds the user's measurement objects and hands out sequential ids.
final class MeasurementStore {
    private(set) var items: [Measurement] = []
    private var nextSpotID = 1
    private var nextAreaID = 1

    @discardableResult
    func addSpot(x: Int, y: Int) -> Measurement {
        let m = Measurement(id: nextSpotID, kind: .spot, x: x, y: y, w: 1, h: 1,
                            emissivity: nil)
        nextSpotID += 1
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
    }

    func setEmissivity(_ value: Double?, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].emissivity = value
    }
}
