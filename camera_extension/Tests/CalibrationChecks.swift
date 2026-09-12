import Foundation

// Standalone radiometry regression checks; no camera or App Group access.
// Compile with Calibration.swift and ThermalDecoder.swift (see run.sh).
enum ThermalCapture {
    static let width = 256
    static let imageHeight = 192
}
enum VirtualCameraFeed {
    static let appGroupID = "calibration-checks-unused"
}

@main
enum CalibrationChecks {
    static func close(_ actual: Double, _ expected: Double, _ message: String) {
        precondition(abs(actual - expected) < 1e-7, "\(message): \(actual) != \(expected)")
    }

    static func metadata(cal00: Double) -> ThermalDecoder.Metadata {
        .init(fpaRaw: 8617, shutterRaw: 0, cal00: cal00, cal01: 1,
              cal02: 0, cal03: 0, cal04: 0, cal05: 1, correction: 0,
              reflectedTemp: 20, airTemp: 20, humidity: 0,
              emissivity: 1, distance: 0)
    }

    static func main() throws {
        try RadiometryChecks.run(fixtures: URL(fileURLWithPath: CommandLine.arguments[1]))
        checkInvalidData()
        checkProcessing()
        for range in [ThermalDecoder.Range.normal, .high] {
            let cal00 = range == .normal ? 8170.0 : 8000.0
            let cold = Calibration.Sample(raw: 8000, meta: metadata(cal00: cal00))
            // The sensor's count baseline moves by 1000 between references.
            let hot = Calibration.Sample(raw: 11304, meta: metadata(cal00: cal00 + 1000))
            // Independent analytic values for this synthetic metadata:
            // sqrt(raw - tableOffset + 36²), followed by the distance correction.
            let coldModel = 36.0 * 0.98875 + 0.225
            let hotModel = 60.0 * 0.98875 + 0.225
            close(cold.modelTemperature(shutterOffset: 36, range: range)!, coldModel, "cold model")
            close(hot.modelTemperature(shutterOffset: 36, range: range)!, hotModel, "hot model")
            let fit = Calibration.twoPointFit(cold: cold, coldTemp: 36, hot: hot, hotTemp: 90,
                                              shutterOffset: 36, range: range)!
            close(fit.scale * coldModel + fit.bias, 36, "cold reference")
            close(fit.scale * hotModel + fit.bias, 90, "hot reference after metadata change")
            let room = Calibration.Sample(raw: 7028, meta: cold.meta)
            close(fit.scale * room.modelTemperature(shutterOffset: 36, range: range)! + fit.bias,
                  -4.5, "unsuitable references can extrapolate below zero")

            // Identical raw counts can still represent different temperatures
            // when the baseline changes. Do not reject them before decoding.
            let sameRawHot = Calibration.Sample(raw: cold.raw, meta: metadata(cal00: cal00 - 2304))
            let sameRawFit = Calibration.twoPointFit(cold: cold, coldTemp: 36,
                hot: sameRawHot, hotTemp: 90, shutterOffset: 36, range: range)!
            close(sameRawFit.scale, fit.scale, "equal raw counts with different metadata")

            // Reproduce the old path: both raw values decoded with cold metadata.
            let staleHot = Calibration.Sample(raw: hot.raw, meta: cold.meta)
            let staleFit = Calibration.twoPointFit(cold: cold, coldTemp: 36,
                hot: staleHot, hotTemp: 90, shutterOffset: 36, range: range)!
            precondition(abs(staleFit.scale * hotModel + staleFit.bias - 90) > 5,
                         "Fixture must expose the old stale-metadata error")

            // Recalibration uses the base model, without compounding an old fit.
            let identity = Calibration.twoPointFit(cold: cold, coldTemp: coldModel,
                hot: hot, hotTemp: hotModel, shutterOffset: 36, range: range)!
            close(identity.scale, 1, "identity scale")
            close(identity.bias, 0, "identity bias")

            precondition(Calibration.twoPointFit(cold: cold, coldTemp: 36, hot: cold,
                hotTemp: 90, shutterOffset: 36, range: range) == nil)
            precondition(Calibration.twoPointFit(cold: hot, coldTemp: 36, hot: cold,
                hotTemp: 90, shutterOffset: 36, range: range) == nil)
            precondition(Calibration.twoPointFit(cold: cold, coldTemp: 36, hot: hot,
                hotTemp: 39, shutterOffset: 36, range: range) == nil)
            precondition(Calibration.twoPointFit(cold: cold, coldTemp: .nan, hot: hot,
                hotTemp: 90, shutterOffset: 36, range: range) == nil)

            let solved = Calibration.solveShutterOffset(startingAt: 30, knownTemp: 90,
                centerRaw: hot.raw, meta: hot.meta, range: range,
                scale: fit.scale, bias: fit.bias)
            let solvedTemp = hot.modelTemperature(shutterOffset: solved, range: range)!
            precondition(abs(fit.scale * solvedTemp + fit.bias - 90) < 0.05)
        }
        print("Calibration checks passed (both ranges, metadata drift, invalid fits, one-point solve).")
    }

    static func checkInvalidData() {
        let good = metadata(cal00: 8170)
        let mutations: [(inout ThermalDecoder.Metadata) -> Void] = [
            { $0.cal01 = 0 }, { $0.cal01 = .nan }, { $0.cal05 = .infinity },
            { $0.emissivity = 0 }, { $0.emissivity = -0.1 }, { $0.emissivity = 1.1 },
            { $0.emissivity = .nan }, { $0.humidity = -1 }, { $0.humidity = 45 },
            { $0.distance = -1 }, { $0.airTemp = -.infinity }, { $0.reflectedTemp = -300 }
        ]
        for mutate in mutations {
            var meta = good
            mutate(&meta)
            precondition(ThermalDecoder.temperatureTable(meta: meta, shutterOffset: 36) == nil)
        }
        precondition(ThermalDecoder.temperatureTable(meta: good, shutterOffset: .nan) == nil)
        precondition(ThermalDecoder.temperatureTable(meta: good, shutterOffset: 36, scale: 0) == nil)
        precondition(ThermalDecoder.temperatureTable(meta: good, shutterOffset: 36, emissivity: .nan) == nil)

        var reflective = good
        reflective.emissivity = 0.1
        reflective.reflectedTemp = 100
        let invalid = Calibration.Sample(raw: 8000, meta: reflective)
        precondition(invalid.modelTemperature(shutterOffset: 36, range: .normal) == nil,
                     "Negative inferred radiance must not become an absolute-zero temperature")
        let table = ThermalDecoder.temperatureTable(meta: reflective, shutterOffset: 36)!
        precondition(table[8000].isNaN)

        var values = [20.0, 20, 20, 20, .nan, 20, 20, 20, 20]
        let area = Measurement(id: 1, kind: .area, x: 0, y: 0, w: 3, h: 3, emissivity: nil)
        precondition(!MeasurementEngine.evaluate(area, temps: values, width: 3, height: 3).average.isFinite)
        let line = Measurement(id: 1, kind: .line, x: 0, y: 1, w: 1, h: 1,
                               x2: 2, y2: 1, emissivity: nil)
        precondition(!MeasurementEngine.evaluate(line, temps: values, width: 3, height: 3).average.isFinite)
        // Invalid data outside a measured area must not invalidate that area.
        values[4] = 20
        values[8] = .nan
        let patch = Measurement(id: 2, kind: .area, x: 0, y: 0, w: 2, h: 2, emissivity: nil)
        close(MeasurementEngine.evaluate(patch, temps: values, width: 3, height: 3).average,
              20, "valid local emissivity region")
        print("Invalid metadata, radiance and measurement checks passed.")
    }

    static func checkProcessing() {
        let w = ThermalCapture.width, h = ThermalCapture.imageHeight
        let calibration = Calibration()
        let reference = (0..<(w * h)).map { UInt16(8000 + $0 % 8) }
        _ = calibration.buildReference(from: [reference, reference])
        let corrected = calibration.applyCorrection(reference.map { $0 + 2000 })
        precondition(corrected.allSatisfy { abs($0 - 10003.5) < 1e-7 },
                     "NUC must remove pixel offsets without destroying the mean signal")
        _ = calibration.buildReference(from: [[1]])
        close(calibration.referenceMean, 8003.5, "truncated NUC sample preserves prior reference")

        var deadReference = [UInt16](repeating: 8000, count: w * h)
        deadReference[0] = 1
        precondition(calibration.buildReference(from: [deadReference]).deadCount == 1)
        var repaired = [Double](repeating: 20, count: w * h)
        repaired[0] = -200
        calibration.repairDeadPixels(&repaired)
        close(repaired[0], 20, "dead corner pixel")

        var hotPatch = [UInt16](repeating: 20, count: w * h)
        for y in 20..<40 { for x in 30..<50 { hotPatch[y * w + x] = 60 } }
        let smooth = ThermalProcessor.smooth(hotPatch, width: w, height: h)
        for rotation in ImageRotation.allCases {
            let turned = rotation.apply(smooth, width: w, height: h)
            let extremes = ThermalProcessor.extremes(turned)
            close(extremes.minValue, 20, "room survives smoothing/rotation")
            close(extremes.maxValue, 60, "small hot target survives smoothing/rotation")
        }
        print("NUC, dead pixel, smoothing, small target and rotation checks passed.")
    }
}
