import Cocoa

enum RGBChecks {
    static func run() throws {
        for mirrored in [false, true] {
            let angle = 0.23, scale = 1.16, tx = 14.0, ty = -8.0
            let pairs: [MotionAlignment.Observation] = (0..<64).map { i in
                let t = Double(i) * 0.19
                let rgb = CGPoint(x: 128 + 60 * cos(t), y: 96 + 42 * sin(t))
                let x = (mirrored ? 256 - rgb.x : rgb.x) - 128, y = rgb.y - 96
                var thermal = CGPoint(x: 128 + scale * (cos(angle) * x - sin(angle) * y) + tx,
                                      y: 96 + scale * (sin(angle) * x + cos(angle) * y) + ty)
                if i % 11 == 3 { thermal = CGPoint(x: Double(i * 23 % 250), y: Double(i * 31 % 180)) }
                return .init(rgb: rgb, thermal: thermal)
            }
            let result = MotionAlignment.fit(pairs, base: RGBAlignment())
            precondition(result != nil, "Good cross-camera motion rejected")
            let s = result!.alignment
            precondition(abs(s.x - tx) < 0.01 && abs(s.y - ty) < 0.01)
            precondition(abs(s.zoom - scale) < 0.001 && abs(s.degrees - angle * 180 / .pi) < 0.01)
            precondition(s.mirrored == mirrored)
        }
        let stationary = (0..<30).map { _ in MotionAlignment.Observation(rgb: .init(x: 100, y: 100), thermal: .init(x: 90, y: 80)) }
        precondition(MotionAlignment.fit(stationary, base: RGBAlignment()) == nil)
        let line = (0..<30).map { i in MotionAlignment.Observation(rgb: .init(x: 40 + i * 4, y: 50), thermal: .init(x: 50 + i * 4, y: 70)) }
        precondition(MotionAlignment.fit(line, base: RGBAlignment()) == nil)
        let wrong = (0..<60).map { i in MotionAlignment.Observation(rgb: .init(x: i * 29 % 250, y: i * 13 % 180), thermal: .init(x: i * i * 17 % 250, y: i * i * 11 % 180)) }
        precondition(MotionAlignment.fit(wrong, base: RGBAlignment()) == nil)
        let flat = [Double](repeating: 0, count: 64 * 48)
        precondition(MotionAlignment.motionCentre(current: flat, previous: flat, threshold: 0.5) == nil)
        precondition(MotionAlignment.motionCentre(current: flat.map { $0 + 20 }, previous: flat, threshold: 0.5) == nil)
        var moving = flat
        for y in 18..<26 { for x in 24..<34 { moving[y * 64 + x] = 10 } }
        let centre = MotionAlignment.motionCentre(current: moving, previous: flat, threshold: 0.5)!
        precondition(abs(centre.x - 116) < 1 && abs(centre.y - 88) < 1)

        let context = CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8,
                                bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        let green = context.makeImage()!
        let samples = [VisibleCamera.Sample(image: green, time: 10), VisibleCamera.Sample(image: green, time: 10.04)]
        var settings = RGBAlignment()
        precondition(VisibleCamera.nearest(samples, to: 10.03, settings: settings)?.time == 10.04)
        precondition(VisibleCamera.nearest(samples, to: 11, settings: settings) == nil)
        settings.timeOffsetMS = 100
        precondition(VisibleCamera.nearest(samples, to: 10.14, settings: settings)?.time == 10.04)

        let temps = [Double](repeating: 25, count: 256 * 192)
        var frame = ThermalRenderer.Frame(temperatures: temps, normalized: [UInt8](repeating: 100, count: temps.count),
                                           extremes: ThermalProcessor.extremes(temps), centerTemp: 25,
                                           palette: .whiteHot, calibrationNote: "RGB TEST FIXTURE", scaleMin: 20, scaleMax: 30)
        frame.showsMax = false; frame.showsMin = false; frame.showsCentre = false
        let thermalOnly = ThermalRenderer.render(frame)!
        frame.rgbImage = green; frame.rgbAlignment.mode = 1
        let rgbOnly = ThermalRenderer.render(frame)!
        precondition(thermalOnly.dataProvider!.data! as Data != rgbOnly.dataProvider!.data! as Data)
        frame.rgbImage = nil
        let fallback = ThermalRenderer.render(frame)!
        precondition(thermalOnly.dataProvider!.data! as Data == fallback.dataProvider!.data! as Data,
                     "Missing RGB must preserve the thermal view")
        frame.rgbImage = green
        frame.histories = ["Sp1": [22, 23, 24, 25, 24, 25, 26]]
        let spot = Measurement(id: 1, kind: .spot, x: 90, y: 80, w: 3, h: 3)
        frame.measurements = [(spot, MeasurementEngine.evaluate(spot, temps: temps, width: 256, height: 192))]
        let withPlot = ThermalRenderer.render(frame)!
        precondition(rgbOnly.dataProvider!.data! as Data != withPlot.dataProvider!.data! as Data,
                     "RGB composition lost measurement overlays")

        let camera = VisibleCamera()
        let panel = RGBAlignmentPanel(camera: camera)
        panel.window?.appearance = NSAppearance(named: .aqua)
        panel.window?.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let view = panel.window!.contentView!
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/t2s-rgb-alignment-panel.png"))
        panel.close()
        print("PASS: RGB arrival pairing/staleness, thermal fallback/overlays, motion fit with outliers/mirroring, rejection of stationary/collinear/unrelated motion.")
    }
}
