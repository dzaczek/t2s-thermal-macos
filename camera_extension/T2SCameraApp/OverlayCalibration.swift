import Cocoa

/// Lining the webcam up with the thermal camera, four points at a time.
///
/// The two pictures have nothing obviously in common: one shows where the
/// heat is, the other where the light is, and an edge that is sharp in one is
/// routinely invisible in the other. Matching them automatically on their own
/// content is therefore unreliable in exactly the cases that matter.
///
/// A fingertip is visible to both, and that is the way through. Hold one up
/// and the thermal side finds it on its own -- skin is well above room
/// temperature, so it is simply the hottest thing in shot -- while you click
/// the same fingertip in the webcam picture here. Four points at four
/// well-spread places and the mapping is pinned down.
final class OverlayCalibrationWindow: NSWindowController {

    /// Asked for the live thermal frame at the moment of a click, and told
    /// when four pairs have been gathered.
    var warmPointProvider: (() -> (x: Int, y: Int)?)?
    var visibleFrameProvider: (() -> VisibleCapture.Frame?)?
    var onFinished: ((Homography) -> Void)?

    private let imageView = CalibrationImageView()
    private let promptLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var undoButton = NSButton()
    private var timer: Timer?

    private var pairs: [(from: CGPoint, to: CGPoint)] = []

    /// Where to hold the finger for each point. Spread out on purpose: four
    /// points bunched together pin the mapping down badly, and the corners of
    /// the view are where the two cameras disagree most.
    private static let places = ["top left", "top right", "bottom right", "bottom left"]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Line Up the Webcam"
        self.init(window: window)
        build()
    }

    private func build() {
        guard let window, let content = window.contentView else { return }

        promptLabel.frame = NSRect(x: 16, y: 570, width: 688, height: 36)
        promptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        promptLabel.maximumNumberOfLines = 2
        promptLabel.lineBreakMode = .byWordWrapping
        content.addSubview(promptLabel)

        imageView.frame = NSRect(x: 16, y: 70, width: 688, height: 492)
        imageView.onClick = { [weak self] point in self?.record(visiblePoint: point) }
        content.addSubview(imageView)

        statusLabel.frame = NSRect(x: 16, y: 44, width: 688, height: 20)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        undoButton = NSButton(title: "Undo Last Point", target: self, action: #selector(undo(_:)))
        undoButton.frame = NSRect(x: 16, y: 10, width: 150, height: 26)
        content.addSubview(undoButton)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 600, y: 10, width: 104, height: 26)
        content.addSubview(cancel)

        window.center()
        updatePrompt()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        pairs.removeAll()
        updatePrompt()
        // The webcam picture has to be live, or you would be clicking on a
        // still of where your finger used to be.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        imageView.show(visibleFrameProvider?())
        let warm = warmPointProvider?()
        imageView.hasWarmPoint = warm != nil
        statusLabel.stringValue = warm.map {
            "Thermal camera: warmest point at \($0.x), \($0.y) \u{2014} that is what will be paired "
                + "with your click."
        } ?? "Thermal camera: nothing warm enough in shot. Hold a fingertip up in front of it."
    }

    private func updatePrompt() {
        let index = pairs.count
        if index >= OverlayCalibrationWindow.places.count {
            promptLabel.stringValue = "Done."
            return
        }
        promptLabel.stringValue = "Point \(index + 1) of 4. Hold a fingertip towards the "
            + "\(OverlayCalibrationWindow.places[index]) of the scene, where both cameras can see "
            + "it, then click that fingertip in the picture below."
        undoButton.isEnabled = index > 0
    }

    private func record(visiblePoint: CGPoint) {
        guard pairs.count < OverlayCalibrationWindow.places.count else { return }
        guard let warm = warmPointProvider?() else {
            statusLabel.stringValue = "Nothing warm enough in the thermal camera yet \u{2014} "
                + "hold a fingertip up before clicking."
            NSSound.beep()
            return
        }
        pairs.append((from: CGPoint(x: warm.x, y: warm.y), to: visiblePoint))
        imageView.marks.append(visiblePoint)
        updatePrompt()

        guard pairs.count == OverlayCalibrationWindow.places.count else { return }
        guard let homography = Homography.solve(pairs) else {
            // Four points that cannot pin a mapping down: bunched together,
            // or three in a line. Better to say so and start again than to
            // save something that will put the pictures in the wrong place.
            statusLabel.stringValue = "Those four points do not pin the mapping down \u{2014} "
                + "they are too close together or three are in a line. Starting again."
            NSSound.beep()
            pairs.removeAll()
            imageView.marks.removeAll()
            updatePrompt()
            return
        }
        onFinished?(homography)
        close()
    }

    @objc private func undo(_ sender: Any?) {
        guard !pairs.isEmpty else { return }
        pairs.removeLast()
        if !imageView.marks.isEmpty { imageView.marks.removeLast() }
        updatePrompt()
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}

/// The webcam picture, with the points already taken marked on it.
private final class CalibrationImageView: NSView {

    var onClick: ((CGPoint) -> Void)?
    var marks: [CGPoint] = [] { didSet { needsDisplay = true } }
    var hasWarmPoint = false { didSet { needsDisplay = true } }

    private var image: CGImage?
    private var frameSize = CGSize.zero

    override var isFlipped: Bool { true }

    func show(_ frame: VisibleCapture.Frame?) {
        guard let frame else { image = nil; needsDisplay = true; return }
        frameSize = CGSize(width: frame.width, height: frame.height)

        var pixels = [UInt8](repeating: 255, count: frame.width * frame.height * 4)
        for i in 0..<(frame.width * frame.height) {
            let v = UInt8(max(0, min(255, frame.grey[i])))
            pixels[i * 4 + 0] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v
        }
        if let provider = CGDataProvider(data: Data(pixels) as CFData) {
            image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil,
                            shouldInterpolate: true, intent: .defaultIntent)
        }
        needsDisplay = true
    }

    /// Where the picture actually sits: aspect-fit, so a click can be turned
    /// back into a webcam pixel without guessing.
    private var pictureRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        let aspect = frameSize.width / frameSize.height
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        guard let image else {
            let text = "No picture from the webcam yet."
            (text as NSString).draw(at: CGPoint(x: 16, y: 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: pictureRect)

        for (i, mark) in marks.enumerated() {
            let p = viewPoint(mark)
            ctx.setStrokeColor(NSColor.systemGreen.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            (String(i + 1) as NSString).draw(at: CGPoint(x: p.x + 11, y: p.y - 7), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.systemGreen])
        }

        // A quiet reminder of whether the other camera is ready, right where
        // the eye already is.
        let note = hasWarmPoint ? "thermal: fingertip found" : "thermal: no fingertip"
        (note as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: hasWarmPoint ? NSColor.systemGreen : NSColor.systemOrange])
    }

    private func viewPoint(_ framePoint: CGPoint) -> CGPoint {
        let r = pictureRect
        return CGPoint(x: r.minX + framePoint.x / frameSize.width * r.width,
                       y: r.minY + framePoint.y / frameSize.height * r.height)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = pictureRect
        guard r.contains(p), frameSize.width > 0 else { return }
        onClick?(CGPoint(x: (p.x - r.minX) / r.width * frameSize.width,
                         y: (p.y - r.minY) / r.height * frameSize.height))
    }
}
