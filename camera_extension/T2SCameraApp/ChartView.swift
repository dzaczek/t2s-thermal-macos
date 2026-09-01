import Cocoa

/// Live temperature-vs-time plot for the measurement objects.
///
/// Autoscales the temperature axis to the data on screen: a trend of a few
/// tenths of a degree is exactly what you are watching for, and a fixed axis
/// would flatten it into a straight line.
final class ChartView: NSView {

    var series: [TemperatureHistory.Series] = [] {
        didSet { needsDisplay = true }
    }

    /// Seconds shown, matching the history buffer. Not `window` -- that name
    /// is already NSView's reference to its NSWindow.
    var windowSeconds: TimeInterval = TemperatureHistory.window

    private let leftGutter: CGFloat = 46
    private let rightGutter: CGFloat = 8
    private let topGutter: CGFloat = 18
    private let bottomGutter: CGFloat = 18

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        let plot = CGRect(x: leftGutter, y: bottomGutter,
                          width: max(1, bounds.width - leftGutter - rightGutter),
                          height: max(1, bounds.height - topGutter - bottomGutter))

        let live = series.filter { !$0.samples.isEmpty }
        guard !live.isEmpty else {
            drawText("No measurement objects — click the image to add a spot.",
                     at: CGPoint(x: leftGutter, y: bounds.midY - 6), size: 11,
                     color: .secondaryLabelColor)
            return
        }

        // Temperature bounds across every series, padded so lines don't sit on
        // the frame.
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for s in live {
            for sample in s.samples {
                lo = Swift.min(lo, sample.value)
                hi = Swift.max(hi, sample.value)
            }
        }
        if hi - lo < 0.5 { let mid = (hi + lo) / 2; lo = mid - 0.25; hi = mid + 0.25 }
        let pad = (hi - lo) * 0.12
        lo -= pad; hi += pad

        let now = CFAbsoluteTimeGetCurrent()
        let tMin = now - windowSeconds

        func point(_ time: CFAbsoluteTime, _ value: Double) -> CGPoint {
            let fx = (time - tMin) / windowSeconds
            let fy = (value - lo) / (hi - lo)
            return CGPoint(x: plot.minX + CGFloat(fx) * plot.width,
                           y: plot.minY + CGFloat(fy) * plot.height)
        }

        // Grid and temperature labels.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        ctx.setLineWidth(1)
        for i in 0...4 {
            let f = Double(i) / 4.0
            let y = plot.minY + CGFloat(f) * plot.height
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
            drawText(String(format: "%.1f", lo + f * (hi - lo)),
                     at: CGPoint(x: 6, y: y - 6), size: 9, color: .secondaryLabelColor)
        }
        ctx.strokePath()

        drawText("-\(Int(windowSeconds))s", at: CGPoint(x: plot.minX, y: 4), size: 9,
                 color: .secondaryLabelColor)
        drawText("now", at: CGPoint(x: plot.maxX - 22, y: 4), size: 9,
                 color: .secondaryLabelColor)

        ctx.saveGState()
        ctx.clip(to: plot)
        for s in live {
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineJoin(.round)
            // One point per horizontal pixel is plenty; at 25fps a two-minute
            // window holds far more samples than the chart has columns.
            let stride = Swift.max(1, s.samples.count / Swift.max(1, Int(plot.width)))
            var started = false
            for i in Swift.stride(from: 0, to: s.samples.count, by: stride) {
                let p = point(s.samples[i].time, s.samples[i].value)
                if started { ctx.addLine(to: p) } else { ctx.move(to: p); started = true }
            }
            if let last = s.samples.last {
                ctx.addLine(to: point(last.time, last.value))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Legend with the current value of each series.
        var x = plot.minX
        for s in live {
            guard let last = s.samples.last else { continue }
            let text = String(format: "%@ %.1fC", s.key, last.value)
            ctx.setFillColor(s.color.cgColor)
            ctx.fill(CGRect(x: x, y: bounds.height - 13, width: 8, height: 8))
            drawText(text, at: CGPoint(x: x + 12, y: bounds.height - 15), size: 10, color: .labelColor)
            x += 12 + text.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(
                ofSize: 10, weight: .regular)]).width + 14
            if x > plot.maxX - 40 { break }
        }
    }

    private func drawText(_ text: String, at p: CGPoint, size: CGFloat, color: NSColor) {
        (text as NSString).draw(at: p, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
        ])
    }
}
