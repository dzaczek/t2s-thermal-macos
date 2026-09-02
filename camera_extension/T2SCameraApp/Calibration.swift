import Foundation

/// Flat-field (NUC) correction and the shutter-offset solve.
final class Calibration {

    /// Per-pixel shutter-closed reference; corrected = raw - reference + mean.
    private(set) var reference: [Double]?
    private(set) var referenceMean: Double = 0
    private(set) var deadPixels: Set<Int> = []

    /// Corrects the shutter-temperature register this hardware reports
    /// uselessly. Solved against a known temperature; this default came out
    /// of testing as roughly room temperature and is only a starting point.
    /// Corrects the V2 hardware's unusable shutter temperature. 76.0 is only a
    /// starting guess -- a real value comes from calibrating against a known
    /// temperature, so it is persisted and reloaded rather than re-solved on
    /// every launch (the Python prototype does the same via shutter_offset.json).
    /// Which measurement range the stored offsets belong to. The camera
    /// reports different calibration metadata per range, so an offset solved
    /// in one is meaningless in the other and they are kept apart.
    var range: ThermalDecoder.Range = .normal {
        didSet {
            guard range != oldValue else { return }
            shutterOffsetStorage = Calibration.loadShutterOffset(for: range) ?? 76.0
            isCalibrated = Calibration.loadShutterOffset(for: range) != nil
        }
    }

    private var shutterOffsetStorage: Double = Calibration.loadShutterOffset(for: .normal) ?? 76.0

    var shutterOffset: Double {
        get { shutterOffsetStorage }
        set {
            shutterOffsetStorage = newValue
            Calibration.saveShutterOffset(newValue, for: range)
        }
    }

    /// True when the offset came from an actual calibration rather than the guess.
    private(set) var isCalibrated: Bool = Calibration.loadShutterOffset(for: .normal) != nil

    func markCalibrated() { isCalibrated = true }

    /// The app is sandboxed, so this lives in the App Group container -- the
    /// one location both the app and the extension can reach.
    private static var offsetURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: VirtualCameraFeed.appGroupID)?
            .appendingPathComponent("shutter_offset.json")
    }

    private static func key(for range: ThermalDecoder.Range) -> String {
        // The original single-range file used this name; keep it for the
        // normal range so an existing calibration is not lost.
        range == .normal ? "offset_temp_shutter" : "offset_temp_shutter_high"
    }

    private static func stored() -> [String: Double] {
        guard let url = offsetURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double]
        else { return [:] }
        return json
    }

    private static func loadShutterOffset(for range: ThermalDecoder.Range) -> Double? {
        stored()[key(for: range)]
    }

    private static func saveShutterOffset(_ value: Double, for range: ThermalDecoder.Range) {
        var all = stored()
        all[key(for: range)] = value
        guard let url = offsetURL,
              let data = try? JSONSerialization.data(withJSONObject: all) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Real defects on this sensor have always been a handful of pixels.
    /// A run flagging hundreds means the reference was captured while the
    /// shutter was still moving, and inpainting against it would smear a
    /// chunk of real scene into every later frame -- so it's discarded.
    private static let deadPixelCap = 50

    static let defaultRoomTemp = 20.0

    func applyCorrection(_ raw: [UInt16]) -> [Double] {
        let count = ThermalCapture.width * ThermalCapture.imageHeight
        var out = [Double](repeating: 0, count: count)
        if let reference, reference.count == count {
            for i in 0..<count {
                out[i] = Double(raw[i]) - reference[i] + referenceMean
            }
        } else {
            for i in 0..<count { out[i] = Double(raw[i]) }
        }
        return out
    }

    /// Builds the reference from frames captured with the shutter closed.
    ///
    /// The upstream library used a single frame, which bakes that one
    /// sample's own noise into every corrected frame; averaging removes most
    /// of it. `frames` must have been captured while the shutter was shut and
    /// the signal had gone flat.
    func buildReference(from frames: [[UInt16]]) -> (deadCount: Int, applied: Bool) {
        let count = ThermalCapture.width * ThermalCapture.imageHeight
        guard !frames.isEmpty else { return (0, false) }

        var mean = [Double](repeating: 0, count: count)
        for frame in frames {
            for i in 0..<count { mean[i] += Double(frame[i]) }
        }
        let n = Double(frames.count)
        for i in 0..<count { mean[i] /= n }

        reference = mean
        referenceMean = mean.reduce(0, +) / Double(count)

        let lo = mean.min() ?? 0, hi = mean.max() ?? 0
        let threshold = lo + (hi - lo) * 0.05
        let flagged = (0..<count).filter { mean[$0] < threshold }
        if !flagged.isEmpty && flagged.count <= Calibration.deadPixelCap {
            deadPixels = Set(flagged)
            return (flagged.count, true)
        }
        deadPixels = []
        return (flagged.count, false)
    }

    /// Replaces known-bad pixels with the average of their neighbours.
    func repairDeadPixels(_ values: inout [Double]) {
        guard !deadPixels.isEmpty else { return }
        let w = ThermalCapture.width, h = ThermalCapture.imageHeight
        for index in deadPixels {
            let x = index % w, y = index / w
            var sum = 0.0, n = 0.0
            for dy in -1...1 {
                for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let neighbour = yy * w + xx
                    guard !deadPixels.contains(neighbour) else { continue }
                    sum += values[neighbour]; n += 1
                }
            }
            if n > 0 { values[index] = sum / n }
        }
    }

    /// Solves for the shutter offset that makes the centre pixel read
    /// `knownTemp`.
    ///
    /// Newton's method rather than a fixed step: the relationship isn't 1:1,
    /// its slope varies with operating point, so the model's own local slope
    /// is probed each iteration.
    static func solveShutterOffset(startingAt offset: Double, knownTemp: Double,
                                   centerRaw: Double, meta: ThermalDecoder.Metadata,
                                   maxIterations: Int = 8, tolerance: Double = 0.05) -> Double {
        var current = offset
        let probeStep = 5.0
        let index = Int(max(0, min(Double(ThermalDecoder.tableSize - 1), centerRaw.rounded())))

        for _ in 0..<maxIterations {
            // An unusable frame cannot improve the estimate; keep what we have.
            guard let table = ThermalDecoder.temperatureTable(meta: meta, shutterOffset: current),
                  let probedTable = ThermalDecoder.temperatureTable(meta: meta,
                                                                    shutterOffset: current + probeStep)
            else { return current }
            let value = table[index]
            if abs(value - knownTemp) < tolerance { break }

            let probed = probedTable[index]
            var slope = (probed - value) / probeStep
            if abs(slope) < 0.05 { slope = 1.0 }
            current += (knownTemp - value) / slope
        }
        return current
    }
}
