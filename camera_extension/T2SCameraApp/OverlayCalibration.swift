import Cocoa

/// Lining the webcam up with the thermal camera, four points at a time.
///
/// The two pictures have nothing obviously in common: one shows where the
/// heat is, the other where the light is, and an edge that is sharp in one is
/// routinely invisible in the other. Matching them automatically on their own
/// content is unreliable in exactly the cases that matter.
///
/// So a person does the matching. Both pictures are shown side by side and
/// you click the same thing in each: a corner, a screw head, a fingertip,
/// whatever you can make out in both. Four points and the mapping is pinned
/// down.
///
/// A fingertip is offered as a shortcut, because it is the one landmark the
/// thermal camera can find on its own -- skin runs well above room
/// temperature, so it is simply the hottest thing in shot. When one is in
/// view it is marked, and clicking only the webcam side uses it. Clicking the
/// thermal picture yourself overrides that, which is what you want as soon as
/// the scene has anything else hot in it.
///
/// Either picture can be turned. The mapping could express a right angle on
/// its own, but clicking accurately on a picture lying on its side is another
/// matter, and the two cameras are often clamped together that way.
final class OverlayCalibrationWindow: NSWindowController {

    /// What the thermal side has to say right now. Everything is in the
    /// sensor's own coordinates, unturned; the views do their own turning.
    struct ThermalPreview {
        /// Three bytes a pixel, the same in each: the thermal picture is grey
        /// here on purpose, so the eye is not asked to match two sets of
        /// false colours against each other.
        var rgb: [UInt8]
        var width: Int, height: Int
        /// The warmest thing in shot, when something is warm enough to be a
        /// finger.
        var warm: (x: Int, y: Int)?
    }

    var thermalProvider: (() -> ThermalPreview?)?
    var visibleFrameProvider: (() -> VisibleCapture.Frame?)?
    var onFinished: ((Homography) -> Void)?

    private let thermalView = CalibrationImageView()
    private let visibleView = CalibrationImageView()
    private let promptLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var undoButton = NSButton()
    private var timer: Timer?

    private var pairs: [(from: CGPoint, to: CGPoint)] = []
    /// The thermal half of the point being taken: whatever was clicked on the
    /// thermal picture, or failing that the fingertip found in it.
    private var chosenThermal: CGPoint?
    private var detectedWarm: CGPoint?

    /// Where to put each point. Spread out on purpose: four points bunched
    /// together pin the mapping down badly, and the corners are where the two
    /// cameras disagree most.
    private static let places = ["top left", "top right", "bottom right", "bottom left"]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Line Up the Webcam"
        self.init(window: window)
        build()
    }

    private func build() {
        guard let window, let content = window.contentView else { return }

        promptLabel.frame = NSRect(x: 16, y: 508, width: 908, height: 40)
        promptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        promptLabel.maximumNumberOfLines = 2
        promptLabel.lineBreakMode = .byWordWrapping
        content.addSubview(promptLabel)

        func caption(_ text: String, x: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: x, y: 486, width: 446, height: 18)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        content.addSubview(caption("Thermal camera", x: 16))
        content.addSubview(caption("Webcam", x: 478))

        thermalView.frame = NSRect(x: 16, y: 128, width: 446, height: 352)
        thermalView.onClick = { [weak self] point in self?.chooseThermal(point) }
        content.addSubview(thermalView)

        visibleView.frame = NSRect(x: 478, y: 128, width: 446, height: 352)
        visibleView.onClick = { [weak self] point in self?.completePoint(visible: point) }
        content.addSubview(visibleView)

        func turnControl(x: CGFloat, action: Selector) -> NSSegmentedControl {
            let control = NSSegmentedControl(labels: ["\u{21BA}", "\u{21BB}"],
                                             trackingMode: .momentary,
                                             target: self, action: action)
            control.frame = NSRect(x: x, y: 96, width: 90, height: 24)
            return control
        }
        content.addSubview(turnControl(x: 16, action: #selector(turnThermal(_:))))
        content.addSubview(turnControl(x: 478, action: #selector(turnVisible(_:))))

        statusLabel.frame = NSRect(x: 120, y: 94, width: 340, height: 28)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        content.addSubview(statusLabel)

        undoButton = NSButton(title: "Undo Last Point", target: self, action: #selector(undo(_:)))
        undoButton.frame = NSRect(x: 16, y: 20, width: 150, height: 26)
        content.addSubview(undoButton)

        let hint = NSTextField(labelWithString:
            "Click the same thing in both pictures. A fingertip is found for you on the left; "
            + "click there yourself to use something else.")
        hint.frame = NSRect(x: 178, y: 24, width: 630, height: 18)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        content.addSubview(hint)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 820, y: 20, width: 104, height: 26)
        content.addSubview(cancel)

        window.center()
        updatePrompt()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reset(message: nil)
        // Both pictures have to be live, or you would be clicking on a still
        // of where your finger used to be.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        visibleView.show(visibleFrameProvider?())

        guard let thermal = thermalProvider?() else {
            detectedWarm = nil
            thermalView.show(nil)
            return
        }
        thermalView.show(VisibleCapture.Frame(rgb: thermal.rgb,
                                              width: thermal.width, height: thermal.height))
        detectedWarm = thermal.warm.map { CGPoint(x: $0.x, y: $0.y) }
        // A point you picked yourself stays put; otherwise the marker follows
        // whatever is warmest.
        thermalView.highlight = chosenThermal ?? detectedWarm
        thermalView.highlightIsChosen = chosenThermal != nil
        updateStatus()
    }

    private func updateStatus() {
        if chosenThermal != nil {
            statusLabel.stringValue = "Thermal point set. Now click the same thing on the right."
        } else if detectedWarm != nil {
            statusLabel.stringValue = "Fingertip found on the left. Click the same fingertip on "
                + "the right, or click the left picture to pick a different point."
        } else {
            statusLabel.stringValue = "Click a point on the left, then the same one on the right. "
                + "A fingertip would be found for you."
        }
    }

    private func updatePrompt() {
        let index = pairs.count
        guard index < OverlayCalibrationWindow.places.count else {
            promptLabel.stringValue = "Done."
            return
        }
        promptLabel.stringValue = "Point \(index + 1) of 4 \u{2014} somewhere towards the "
            + "\(OverlayCalibrationWindow.places[index]) of the scene."
        undoButton.isEnabled = index > 0
    }

    private func chooseThermal(_ point: CGPoint) {
        chosenThermal = point
        updateStatus()
    }

    private func completePoint(visible: CGPoint) {
        guard pairs.count < OverlayCalibrationWindow.places.count else { return }
        guard let thermal = chosenThermal ?? detectedWarm else {
            statusLabel.stringValue = "Nothing chosen on the left yet. Click the point there "
                + "first, or hold a fingertip up so it can be found."
            NSSound.beep()
            return
        }

        pairs.append((from: thermal, to: visible))
        thermalView.marks.append(thermal)
        visibleView.marks.append(visible)
        chosenThermal = nil
        updatePrompt()

        guard pairs.count == OverlayCalibrationWindow.places.count else { return }
        guard let homography = Homography.solve(pairs) else {
            // Four points that cannot pin a mapping down: bunched together, or
            // three in a line. Better to say so and start again than to save
            // something that puts the pictures in the wrong place.
            reset(message: "Those four points do not pin the mapping down \u{2014} they are too "
                  + "close together, or three are in a line. Starting again; spread them into "
                  + "the corners.")
            NSSound.beep()
            return
        }
        onFinished?(homography)
        close()
    }

    private func reset(message: String?) {
        pairs.removeAll()
        chosenThermal = nil
        thermalView.marks.removeAll()
        visibleView.marks.removeAll()
        updatePrompt()
        if let message { statusLabel.stringValue = message }
    }

    @objc private func turnThermal(_ sender: NSSegmentedControl) {
        thermalView.turn(clockwise: sender.selectedSegment == 1)
    }

    @objc private func turnVisible(_ sender: NSSegmentedControl) {
        visibleView.turn(clockwise: sender.selectedSegment == 1)
    }

    @objc private func undo(_ sender: Any?) {
        guard !pairs.isEmpty else { return }
        pairs.removeLast()
        if !visibleView.marks.isEmpty { visibleView.marks.removeLast() }
        if !thermalView.marks.isEmpty { thermalView.marks.removeLast() }
        chosenThermal = nil
        updatePrompt()
    }

    @objc private func cancel(_ sender: Any?) { close() }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}

/// A grey picture with marks on it.
///
/// It can be turned for viewing, and that is all the turning does: everything
/// it is given and everything it reports is in the camera's own coordinates,
/// so which way round it happens to be shown cannot leak into a calibration.
private final class CalibrationImageView: NSView {

    var onClick: ((CGPoint) -> Void)?
    /// Points already taken, in camera coordinates.
    var marks: [CGPoint] = [] { didSet { needsDisplay = true } }
    /// The point being considered, in camera coordinates.
    var highlight: CGPoint? { didSet { needsDisplay = true } }
    /// Drawn differently once a person has picked it rather than the app.
    var highlightIsChosen = false { didSet { needsDisplay = true } }

    private var rotation = ImageRotation.none
    private var image: CGImage?
    /// The camera's own size, and the size as shown after any turn.
    private var cameraSize = CGSize.zero
    private var shownSize = CGSize.zero

    override var isFlipped: Bool { true }

    func turn(clockwise: Bool) {
        rotation = clockwise ? rotation.turnedRight() : rotation.turnedLeft()
        needsDisplay = true
    }

    func show(_ frame: VisibleCapture.Frame?) {
        guard let frame, frame.rgb.count == frame.width * frame.height * 3 else {
            image = nil
            needsDisplay = true
            return
        }
        cameraSize = CGSize(width: frame.width, height: frame.height)
        let turned = rotation.apply(frame.rgb, width: frame.width, height: frame.height,
                                    components: 3)
        let size = rotation.size(width: frame.width, height: frame.height)
        shownSize = CGSize(width: size.width, height: size.height)

        var pixels = [UInt8](repeating: 255, count: size.width * size.height * 4)
        for i in 0..<(size.width * size.height) {
            pixels[i * 4 + 0] = turned[i * 3]
            pixels[i * 4 + 1] = turned[i * 3 + 1]
            pixels[i * 4 + 2] = turned[i * 3 + 2]
        }
        if let provider = CGDataProvider(data: Data(pixels) as CFData) {
            image = CGImage(width: size.width, height: size.height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: size.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil,
                            shouldInterpolate: true, intent: .defaultIntent)
        }
        needsDisplay = true
    }

    /// Where the picture sits: aspect-fit, so a click maps back to a pixel
    /// without guesswork.
    private var pictureRect: CGRect {
        guard shownSize.width > 0, shownSize.height > 0 else { return bounds }
        let aspect = shownSize.width / shownSize.height
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
            ("Waiting for a picture\u{2026}" as NSString).draw(
                at: CGPoint(x: 12, y: 12),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                                 .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: pictureRect)

        if let highlight, let p = viewPoint(highlight) {
            ctx.setStrokeColor((highlightIsChosen ? NSColor.systemBlue : NSColor.systemGreen).cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
            for (dx, dy) in [(-20.0, 0.0), (6.0, 0.0)] {
                ctx.move(to: CGPoint(x: p.x + dx, y: p.y + dy))
                ctx.addLine(to: CGPoint(x: p.x + dx + 14, y: p.y + dy))
            }
            for (dx, dy) in [(0.0, -20.0), (0.0, 6.0)] {
                ctx.move(to: CGPoint(x: p.x + dx, y: p.y + dy))
                ctx.addLine(to: CGPoint(x: p.x + dx, y: p.y + dy + 14))
            }
            ctx.strokePath()
        }

        for (i, mark) in marks.enumerated() {
            guard let p = viewPoint(mark) else { continue }
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
            (String(i + 1) as NSString).draw(at: CGPoint(x: p.x + 10, y: p.y - 7), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.systemYellow])
        }
    }

    /// Camera coordinates to somewhere on screen, through whatever turn is in
    /// effect.
    private func viewPoint(_ cameraPoint: CGPoint) -> CGPoint? {
        guard cameraSize.width > 0, shownSize.width > 0 else { return nil }
        let turned = rotation.map(x: Int(cameraPoint.x), y: Int(cameraPoint.y),
                                  width: Int(cameraSize.width), height: Int(cameraSize.height))
        let r = pictureRect
        return CGPoint(x: r.minX + (Double(turned.x) + 0.5) / shownSize.width * r.width,
                       y: r.minY + (Double(turned.y) + 0.5) / shownSize.height * r.height)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = pictureRect
        guard r.contains(p), shownSize.width > 0 else { return }
        let shown = CGPoint(x: (p.x - r.minX) / r.width * shownSize.width,
                            y: (p.y - r.minY) / r.height * shownSize.height)
        let back = rotation.inverse.map(x: Int(shown.x), y: Int(shown.y),
                                        width: Int(shownSize.width), height: Int(shownSize.height))
        onClick?(CGPoint(x: back.x, y: back.y))
    }
}
