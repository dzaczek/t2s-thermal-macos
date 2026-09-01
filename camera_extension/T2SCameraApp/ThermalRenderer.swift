import Foundation
import CoreGraphics
import AppKit

/// Draws a finished thermal frame: false-coloured image, min/max/centre
/// markers, and the temperature scale bar.
///
/// One render feeds both the on-screen view and the virtual camera, so what
/// a Teams participant sees is exactly what's in the window.
struct ThermalRenderer {

    /// Sensor pixels per rendered pixel. The frame is rendered at twice the
    /// size it is shown at, because this same image is what the virtual camera
    /// publishes: a video-call client scales the feed up to its tile, and at
    /// the old 858x576 that turned the readouts into mush.
    static let scale = 6
    static let barWidth = 180
    static var outputWidth: Int { ThermalCapture.width * scale + barWidth }
    static var outputHeight: Int { ThermalCapture.imageHeight * scale }

    /// The window shows the render downscaled by this much; downsampling is
    /// sharp, so the on-screen view loses nothing.
    static let displayScale = 2
    static var displayWidth: Int { outputWidth / displayScale }
    static var displayHeight: Int { outputHeight / displayScale }

    /// Overlay scaling: text, strokes and marker sizes. Deliberately larger
    /// than `displayScale`, so the readouts take up more of the frame than
    /// they used to -- in a small video tile the old ones were unreadable
    /// however sharp they were.
    private static let ui: CGFloat = 2.6
    private static func u(_ v: CGFloat) -> CGFloat { v * ui }

    struct Frame {
        var temperatures: [Double]      // per pixel, Celsius
        var normalized: [UInt8]         // per pixel, 0...255 for display
        var extremes: ThermalProcessor.Extremes
        var centerTemp: Double
        var palette: Palette
        var calibrationNote: String
        /// Ends of the colour ramp, which are the frame's own extremes under
        /// auto-exposure but fixed values under manual level/span.
        var scaleMin: Double
        var scaleMax: Double
        var measurements: [(Measurement, MeasurementResult)] = []
        /// Recent values per object name, drawn as a sparkline beside each
        /// marker when inline plotting is on. Empty otherwise.
        var histories: [String: [Double]] = [:]
        /// Alarm thresholds: pixels above/below are painted a flat colour.
        var isothermAbove: Double?
        var isothermBelow: Double?
        var recordingNote: String?
        /// The three built-in markers are independently hideable: on a scene
        /// with user-placed objects they are mostly clutter, and the global
        /// max in particular tends to sit on a reflection.
        var showsMax = true
        var showsMin = true
        var showsCentre = true
        /// Areas that recently changed relative to the baseline.
        var changes: [ChangeDetector.Region] = []
    }

    private static let alarmHot = NSColor(calibratedRed: 1.0, green: 0.15, blue: 0.15, alpha: 1)
    private static let alarmCold = NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 1)

    static func render(_ frame: Frame) -> CGImage? {
        let w = outputWidth, h = outputHeight
        let imgW = ThermalCapture.width, imgH = ThermalCapture.imageHeight
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Thermal image, upscaled.
        let lut = frame.palette.lut
        var rgba = [UInt8](repeating: 255, count: imgW * imgH * 4)
        let hot = rgbComponents(alarmHot), cold = rgbComponents(alarmCold)
        for i in 0..<(imgW * imgH) {
            let t = frame.temperatures[i]
            if let above = frame.isothermAbove, t >= above {
                rgba[i * 4 + 0] = hot.0; rgba[i * 4 + 1] = hot.1; rgba[i * 4 + 2] = hot.2
                continue
            }
            if let below = frame.isothermBelow, t <= below {
                rgba[i * 4 + 0] = cold.0; rgba[i * 4 + 1] = cold.1; rgba[i * 4 + 2] = cold.2
                continue
            }
            let v = Int(frame.normalized[i])
            rgba[i * 4 + 0] = lut[v * 3 + 0]
            rgba[i * 4 + 1] = lut[v * 3 + 1]
            rgba[i * 4 + 2] = lut[v * 3 + 2]
        }
        if let provider = CGDataProvider(data: Data(rgba) as CFData),
           let thermal = CGImage(width: imgW, height: imgH, bitsPerComponent: 8,
                                 bitsPerPixel: 32, bytesPerRow: imgW * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil,
                                 shouldInterpolate: true, intent: .defaultIntent) {
            ctx.interpolationQuality = .high
            ctx.draw(thermal, in: CGRect(x: 0, y: 0, width: imgW * scale, height: imgH * scale))
        }

        drawScaleBar(ctx, frame: frame, x: imgW * scale, width: barWidth, height: h)

        // Markers. Pixel rows run top-down; CoreGraphics is bottom-up.
        let canvas = CGSize(width: CGFloat(imgW * scale), height: CGFloat(h))
        let maxPt = point(for: frame.extremes.maxIndex, imgW: imgW, imgH: imgH)
        let minPt = point(for: frame.extremes.minIndex, imgW: imgW, imgH: imgH)
        let centerPt = CGPoint(x: CGFloat(imgW / 2 * scale),
                               y: CGFloat((imgH - imgH / 2) * scale))
        if frame.showsMax {
            marker(ctx, at: maxPt, color: .systemRed,
                   label: String(format: "%.1fC", frame.extremes.maxValue), bounds: canvas)
        }
        if frame.showsMin {
            marker(ctx, at: minPt, color: .systemBlue,
                   label: String(format: "%.1fC", frame.extremes.minValue), bounds: canvas)
        }
        if frame.showsCentre {
            marker(ctx, at: centerPt, color: .white,
                   label: String(format: "%.1fC", frame.centerTemp), bounds: canvas)
        }

        drawChanges(ctx, frame: frame, imgH: imgH)
        drawMeasurements(ctx, frame: frame, imgW: imgW, imgH: imgH)

        let hud = "\(frame.palette.displayName)   \(frame.calibrationNote)"
        draw(text: hud, in: ctx, at: CGPoint(x: u(10), y: u(8)), size: u(13), color: .systemYellow)

        if let note = frame.recordingNote {
            let y = CGFloat(h) - u(22)
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.fillEllipse(in: CGRect(x: u(10), y: y + u(3), width: u(10), height: u(10)))
            draw(text: note, in: ctx, at: CGPoint(x: u(26), y: y), size: u(13), color: .white)
        }

        return ctx.makeImage()
    }

    /// Dashed outline around anything that just got hotter or colder, so a
    /// new spot reads differently from the solid boxes of placed objects.
    private static func drawChanges(_ ctx: CGContext, frame: Frame, imgH: Int) {
        for r in frame.changes {
            let rect = CGRect(x: CGFloat(r.x0 * scale),
                              y: CGFloat((imgH - 1 - r.y1) * scale),
                              width: CGFloat((r.x1 - r.x0 + 1) * scale),
                              height: CGFloat((r.y1 - r.y0 + 1) * scale)).insetBy(dx: -u(3), dy: -u(3))
            let color: NSColor = r.isHot ? .systemRed : .systemCyan

            ctx.saveGState()
            ctx.setLineWidth(u(2.5))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor)
            ctx.stroke(rect.insetBy(dx: -u(1), dy: -u(1)))
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineDash(phase: 0, lengths: [u(6), u(4)])
            ctx.stroke(rect)
            ctx.restoreGState()

            let label = String(format: "%@ %+.1fC", r.isHot ? "NEW HOT" : "NEW COLD", r.peakDelta)
            draw(text: label, in: ctx,
                 at: CGPoint(x: rect.minX, y: rect.minY - u(15)), size: u(11), color: color)
        }
    }

    private static func rgbComponents(_ color: NSColor) -> (UInt8, UInt8, UInt8) {
        (UInt8(color.redComponent * 255),
         UInt8(color.greenComponent * 255),
         UInt8(color.blueComponent * 255))
    }

    /// Draws each spot/area with its readout, plus a dot on where the hottest
    /// and coldest pixel inside an area actually sit -- an area average alone
    /// hides a hot spot in the corner, which is usually the thing you're
    /// looking for.
    private static func drawMeasurements(_ ctx: CGContext, frame: Frame, imgW: Int, imgH: Int) {
        for (m, r) in frame.measurements where m.kind == .line {
            drawLine(ctx, m: m, r: r, imgW: imgW, imgH: imgH,
                     canvas: CGSize(width: CGFloat(imgW * scale), height: CGFloat(imgH * scale)))
        }
        for (m, r) in frame.measurements where m.kind != .line {
            let b = m.bounds(width: imgW, height: imgH)
            let rect = CGRect(x: CGFloat(b.x0 * scale),
                              y: CGFloat((imgH - 1 - b.y1) * scale),
                              width: CGFloat((b.x1 - b.x0 + 1) * scale),
                              height: CGFloat((b.y1 - b.y0 + 1) * scale))

            ctx.setLineWidth(u(2))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.stroke(rect.insetBy(dx: -u(1), dy: -u(1)))
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.stroke(rect)

            if m.kind == .area {
                dot(ctx, at: point(for: r.maxIndex, imgW: imgW, imgH: imgH), color: .systemRed)
                dot(ctx, at: point(for: r.minIndex, imgW: imgW, imgH: imgH), color: .systemBlue)
            }

            let label = m.kind == .spot
                ? String(format: "%@ %.1fC", m.name, r.average)
                : String(format: "%@ %.1f/%.1f/%.1fC", m.name, r.minValue, r.average, r.maxValue)
            let suffix = m.emissivity.map { String(format: " e%.2f", $0) } ?? ""
            draw(text: label + suffix, in: ctx,
                 at: CGPoint(x: rect.minX, y: rect.maxY + u(3)), size: u(12), color: .white)

            if let history = frame.histories[m.name], history.count > 1 {
                sparkline(ctx, values: history,
                          in: CGRect(x: rect.minX, y: rect.minY - u(34),
                                     width: u(96), height: u(30)))
            }
        }
    }

    /// A line profile: the line itself, its overall readout, and a marker on
    /// each of the N peaks found along it.
    private static func drawLine(_ ctx: CGContext, m: Measurement, r: MeasurementResult,
                                 imgW: Int, imgH: Int, canvas: CGSize) {
        func pt(_ px: Int, _ py: Int) -> CGPoint {
            CGPoint(x: CGFloat(px * scale) + CGFloat(scale) / 2,
                    y: CGFloat((imgH - 1 - py) * scale) + CGFloat(scale) / 2)
        }
        let a = pt(m.x, m.y), b = pt(m.x2, m.y2)

        ctx.setLineCap(.round)
        ctx.setLineWidth(u(3.5))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.setLineWidth(u(2))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()

        // End caps, so a line is distinguishable from an area's edge.
        for p in [a, b] {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - u(3), y: p.y - u(3), width: u(6), height: u(6)))
        }

        for (rank, e) in r.extrema.enumerated() {
            let p = point(for: e.index, imgW: imgW, imgH: imgH)
            dot(ctx, at: p, color: rank == 0 ? .systemRed : .systemOrange)
            draw(text: String(format: "%.1f", e.value), in: ctx,
                 at: CGPoint(x: p.x + u(6), y: p.y - u(6)), size: u(11), color: .white)
        }

        let label = String(format: "%@ min %.1f  avg %.1f  med %.1f  max %.1fC",
                           m.name, r.minValue, r.average, r.median, r.maxValue)
        var ly = Swift.max(a.y, b.y) + u(4)
        if ly > canvas.height - u(16) { ly = Swift.min(a.y, b.y) - u(16) }
        draw(text: label, in: ctx, at: CGPoint(x: Swift.min(a.x, b.x), y: ly),
             size: u(12), color: .white)
    }

    /// Small trend plot beside a measurement, normalised to its own range so a
    /// fraction of a degree is still visible.
    private static func sparkline(_ ctx: CGContext, values: [Double], in rect: CGRect) {
        guard let lo = values.min(), let hi = values.max() else { return }
        let span = Swift.max(hi - lo, 0.2)

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(u(1))
        ctx.stroke(rect)

        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(u(1.5))
        ctx.setLineJoin(.round)
        let inner = rect.insetBy(dx: u(3), dy: u(4))
        for (i, v) in values.enumerated() {
            let x = inner.minX + inner.width * CGFloat(i) / CGFloat(values.count - 1)
            let y = inner.minY + inner.height * CGFloat((v - lo) / span)
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) }
            else { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.strokePath()

        draw(text: String(format: "%.1f", hi), in: ctx,
             at: CGPoint(x: rect.maxX + u(2), y: rect.maxY - u(11)), size: u(9), color: .white)
        draw(text: String(format: "%.1f", lo), in: ctx,
             at: CGPoint(x: rect.maxX + u(2), y: rect.minY), size: u(9), color: .white)
    }

    private static func dot(_ ctx: CGContext, at p: CGPoint, color: NSColor) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - u(3.5), y: p.y - u(3.5), width: u(7), height: u(7)))
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - u(2.5), y: p.y - u(2.5), width: u(5), height: u(5)))
    }

    private static func point(for index: Int, imgW: Int, imgH: Int) -> CGPoint {
        let px = index % imgW, py = index / imgW
        return CGPoint(x: CGFloat(px * scale), y: CGFloat((imgH - py) * scale))
    }

    private static func drawScaleBar(_ ctx: CGContext, frame: Frame, x: Int, width: Int, height: Int) {
        let lut = frame.palette.lut
        let barX = x + Int(u(10)), barW = Int(u(20))
        for y in 0..<height {
            // Top of the bar is the hot end.
            let t = 1.0 - Double(y) / Double(height - 1)
            let v = Int(max(0, min(255, t * 255)))
            ctx.setFillColor(red: CGFloat(lut[v * 3 + 0]) / 255.0,
                             green: CGFloat(lut[v * 3 + 1]) / 255.0,
                             blue: CGFloat(lut[v * 3 + 2]) / 255.0, alpha: 1)
            ctx.fill(CGRect(x: barX, y: height - 1 - y, width: barW, height: 1))
        }
        // Ends of the bar are the ends of the colour ramp, not the frame's
        // extremes -- under manual level/span those differ, and labelling the
        // bar with anything but the ramp makes the colours mean nothing.
        draw(text: String(format: "%.1f", frame.scaleMax), in: ctx,
             at: CGPoint(x: CGFloat(barX + barW) + u(4), y: CGFloat(height) - u(16)),
             size: u(11), color: .white)
        draw(text: String(format: "%.1f", frame.scaleMin), in: ctx,
             at: CGPoint(x: CGFloat(barX + barW) + u(4), y: u(4)), size: u(11), color: .white)
    }

    private static func marker(_ ctx: CGContext, at p: CGPoint, color: NSColor, label: String,
                               bounds: CGSize) {
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(u(2))
        ctx.strokeEllipse(in: CGRect(x: p.x - u(5), y: p.y - u(5), width: u(10), height: u(10)))
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - u(4), y: p.y - u(4), width: u(8), height: u(8)))
        // Keep the readout inside the frame. A marker that lands near an edge
        // otherwise has its temperature clipped off -- and the hottest point,
        // which is the one you most want to read, is often at the very top.
        let size = label.size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: u(12), weight: .medium)])
        var tx = p.x + u(8)
        var ty = p.y + u(2)
        if tx + size.width > bounds.width - u(4) { tx = p.x - u(8) - size.width }
        ty = Swift.min(Swift.max(ty, u(2)), bounds.height - size.height - u(2))
        draw(text: label, in: ctx, at: CGPoint(x: tx, y: ty), size: u(12), color: .white)
    }

    private static func draw(text: String, in ctx: CGContext, at p: CGPoint,
                             size: CGFloat, color: NSColor) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        (text as NSString).draw(at: p, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .shadow: shadow
        ])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Packs a rendered frame as raw 32BGRA for the camera extension.
    static func bgraBytes(from image: CGImage) -> Data? {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Data(buffer)
    }
}
