import Cocoa

/// Shows the rendered frame and turns mouse input into sensor coordinates.
///
/// Click drops a spot, drag draws an area -- no mode buttons, which keeps the
/// toolbar from growing another pair of radio buttons for something the
/// gesture already distinguishes.
final class ThermalImageView: NSView {

    var onAddSpot: ((Int, Int) -> Void)?
    var onAddArea: ((Int, Int, Int, Int) -> Void)?

    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Live drag rectangle, in view coordinates.
    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        if let image {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: imageRect)
        }
        if let a = dragOrigin, let b = dragCurrent {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
        }
    }

    /// Where the frame actually lands inside the view: aspect-fit, so the
    /// thermal image is never stretched when the window is resized. Letterbox
    /// bars fall outside this rect.
    var imageRect: CGRect {
        let aspect = CGFloat(ThermalRenderer.outputWidth) / CGFloat(ThermalRenderer.outputHeight)
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The rendered frame is the thermal image plus the scale bar on the
    /// right, so only the left part maps to sensor pixels.
    private var thermalRect: CGRect {
        let r = imageRect
        let fraction = CGFloat(ThermalCapture.width * ThermalRenderer.scale)
            / CGFloat(ThermalRenderer.outputWidth)
        return CGRect(x: r.minX, y: r.minY, width: r.width * fraction, height: r.height)
    }

    /// View point -> sensor pixel, or nil outside the thermal image (over the
    /// scale bar or the letterbox).
    private func sensorPoint(_ p: CGPoint) -> (Int, Int)? {
        let r = thermalRect
        guard r.width > 0, r.height > 0, r.contains(p) else { return nil }
        let fx = (p.x - r.minX) / r.width
        // View is bottom-up, sensor rows are top-down.
        let fy = 1.0 - ((p.y - r.minY) / r.height)
        let x = Int(fx * CGFloat(ThermalCapture.width))
        let y = Int(fy * CGFloat(ThermalCapture.imageHeight))
        guard x >= 0, x < ThermalCapture.width,
              y >= 0, y < ThermalCapture.imageHeight else { return nil }
        return (x, y)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragCurrent = dragOrigin
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil; dragCurrent = nil; needsDisplay = true }
        guard let start = dragOrigin else { return }
        let end = convert(event.locationInWindow, from: nil)

        // Below this the gesture is a click, not a drag: a few pixels of
        // travel while pressing the button shouldn't create a 2x2 area.
        let isDrag = abs(end.x - start.x) > 4 || abs(end.y - start.y) > 4
        guard let a = sensorPoint(start) else { return }

        if !isDrag {
            onAddSpot?(a.0, a.1)
            return
        }
        guard let b = sensorPoint(end) else { return }
        let x0 = min(a.0, b.0), x1 = max(a.0, b.0)
        let y0 = min(a.1, b.1), y1 = max(a.1, b.1)
        onAddArea?(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }
}
