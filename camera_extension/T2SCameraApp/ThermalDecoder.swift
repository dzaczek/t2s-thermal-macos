import Foundation

/// Turns a raw T2S+ frame into per-pixel temperatures.
///
/// Ported from irpythermal.py (github.com/diminDDL/IR-Py-Thermal, GPLv3),
/// which reverse-engineered this camera family's radiometry. The model uses
/// the unit's own factory calibration constants (cal00..cal05), read out of
/// the 4 metadata rows the sensor appends below each image.
///
/// Two things that model needs, both learned the hard way with the Python
/// prototype:
///   * Emissivity and friends must actually be committed to the camera (see
///     UVCControl.saveParameters) or they sit at a bogus default (0.02) and
///     the table comes out full of NaN.
///   * `shutterOffset` corrects the V2 hardware's unusable shutter-temperature
///     register, which the upstream library gave up on ("left that as hard
///     coded room temperature"). It's solved for against a known reference
///     temperature -- see Calibrator.
struct ThermalDecoder {

    static let zeroC = 273.15
    /// Table covers the sensor's 14-bit raw range.
    static let tableSize = 16384

    struct Metadata {
        var fpaRaw: UInt16
        var shutterRaw: UInt16
        var cal00: Double
        var cal01: Double
        var cal02: Double
        var cal03: Double
        var cal04: Double
        var cal05: Double
        var correction: Double
        var reflectedTemp: Double
        var airTemp: Double
        var humidity: Double
        var emissivity: Double
        var distance: Double
    }

    /// Layout constants for the 256-wide sensor, from irpythermal's
    /// init_parameters()/info() for width == 256.
    private static let amountPixels = 256
    private static let fpaOffset = 8617.0
    private static let fpaDivisor = 37.682
    private static let cal00Offset = 170.0
    private static let cal00FpaMultiplier = 0.0
    private static var userArea: Int { amountPixels + 127 }

    private static func readU16(_ raw: [UInt16], _ index: Int) -> UInt16 {
        (index >= 0 && index < raw.count) ? raw[index] : 0
    }

    /// The metadata rows store some values as little-endian float32 spread
    /// across two consecutive u16 slots.
    private static func readF32(_ raw: [UInt16], _ index: Int) -> Double {
        guard index >= 0, index + 1 < raw.count else { return 0 }
        let bits = UInt32(raw[index]) | (UInt32(raw[index + 1]) << 16)
        return Double(Float(bitPattern: bits))
    }

    static func metadata(from raw: [UInt16]) -> Metadata {
        let base = ThermalCapture.width * ThermalCapture.imageHeight
        return Metadata(
            fpaRaw: readU16(raw, base + 1),
            shutterRaw: readU16(raw, base + amountPixels + 1),
            cal00: Double(readU16(raw, base + amountPixels)),
            cal01: readF32(raw, base + amountPixels + 3),
            cal02: readF32(raw, base + amountPixels + 5),
            cal03: readF32(raw, base + amountPixels + 7),
            cal04: readF32(raw, base + amountPixels + 9),
            cal05: readF32(raw, base + amountPixels + 11),
            correction: readF32(raw, base + userArea),
            reflectedTemp: readF32(raw, base + userArea + 2),
            airTemp: readF32(raw, base + userArea + 4),
            humidity: readF32(raw, base + userArea + 6),
            emissivity: readF32(raw, base + userArea + 8),
            distance: Double(readU16(raw, base + userArea + 10))
        )
    }

    /// Water vapour content from relative humidity and air temperature.
    private static func waterVapourContent(_ h: Double, _ tAtm: Double) -> Double {
        let h1 = 1.5587, h2 = 0.06939, h3 = -2.7816e-4, h4 = 6.8455e-7
        return h * exp(h1 + h2 * tAtm + h3 * pow(tAtm, 2) + h4 * pow(tAtm, 3))
    }

    /// Atmospheric transmittance over the given distance.
    private static func atmosphericTransmittance(_ h: Double, _ tAtm: Double, _ d: Double) -> Double {
        let kAtm = 1.9
        let nsqd = -sqrt(d)
        let sqw = sqrt(waterVapourContent(h, tAtm))
        let a1 = 0.006569, a2 = 0.01262
        let b1 = -0.002276, b2 = -0.00667
        return kAtm * exp(nsqd * (a1 + b1 * sqw)) + (1.0 - kAtm) * exp(nsqd * (a2 + b2 * sqw))
    }

    /// Lookup table mapping raw sensor count -> temperature in Celsius.
    /// Index it with the (NUC-corrected) pixel value.
    /// `emissivity` overrides the camera-wide value, for measuring a patch of a
    /// different material without disturbing the rest of the frame. The
    /// override is applied host-side only -- the camera keeps its own setting.
    /// Returns nil when the model cannot be evaluated for this frame.
    ///
    /// This happens for real: the first frames after opening the device, and
    /// frames caught mid-shutter, carry metadata with cal01 or emissivity at
    /// zero. Previously such a frame yielded an all-zero table, so the whole
    /// image read as 0C and those zeros leaked into the min/max markers, the
    /// CSV export and the trend history. Callers must skip the frame instead.
    static func temperatureTable(meta: Metadata, shutterOffset: Double, userOffset: Double = 0,
                                 emissivity: Double? = nil) -> [Double]? {
        let fpaTemp = 20.0 - (Double(meta.fpaRaw) - fpaOffset) / fpaDivisor
        let ts = shutterOffset
        let distance = min(meta.distance, 20.0)
        let atm = atmosphericTransmittance(meta.humidity, meta.airTemp, distance)
        let emis = emissivity ?? meta.emissivity

        let numeratorSub = (1.0 - emis) * atm * pow(meta.reflectedTemp + zeroC, 4)
            + (1.0 - atm) * pow(meta.airTemp + zeroC, 4)
        let denominator = emis * atm

        let calA = meta.cal02 / (meta.cal01 + meta.cal01)
        let calB = meta.cal02 * meta.cal02 / (meta.cal01 * meta.cal01 * 4.0)
        let calC = meta.cal01 * pow(ts, 2) + ts * meta.cal02
        let calD = meta.cal03 * pow(fpaTemp, 2) + meta.cal04 * fpaTemp + meta.cal05

        let cal00Corr = Int(cal00Offset - fpaTemp * cal00FpaMultiplier)
        let tableOffset = meta.cal00 - Double(cal00Corr > 0 ? cal00Corr : 0)

        guard meta.cal01 != 0, denominator != 0 else { return nil }
        var table = [Double](repeating: 0, count: tableSize)

        for i in 0..<tableSize {
            var n = ((Double(i) - tableOffset) * calD + calC) / meta.cal01 + calB
            n = sqrt(abs(n))
            if n.isNaN { n = 0 }
            let wtot = pow(n - calA + zeroC, 4)
            let inner = (wtot - numeratorSub) / denominator
            // Fourth root of a negative is NaN; clamp rather than propagate,
            // otherwise a slice of the table poisons min/max lookups.
            var t = inner > 0 ? pow(inner, 0.25) - zeroC : -zeroC
            t = t + (distance * 0.85 - 1.125) * (t - meta.airTemp) / 100.0 + meta.correction
            table[i] = t + userOffset
        }
        return table
    }
}
