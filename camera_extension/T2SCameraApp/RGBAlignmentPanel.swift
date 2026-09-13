import Cocoa
import AVFoundation

/// A non-modal panel: the real combined image stays visible while it is aligned.
final class RGBAlignmentPanel: NSWindowController, NSTextFieldDelegate {
    private let camera: VisibleCamera
    private var devices: [AVCaptureDevice] = []
    private let devicePicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let alpha = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let mirror = NSButton(checkboxWithTitle: "Mirror RGB horizontally", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "RGB stopped")
    private let motionStatus = NSTextField(wrappingLabelWithString: "Move a hand to match both views automatically.")
    private var previewButton = NSButton()
    private var acceptButton = NSButton()
    private var fields: [String: NSTextField] = [:]
    private var timer: Timer?

    init(camera: VisibleCamera) {
        self.camera = camera
        let height = min(800, (NSScreen.main?.visibleFrame.height ?? 900) - 90)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 510, height: height),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "IR + RGB — alignment beta"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        refreshDevices(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }; self.status.stringValue = self.camera.status
            let motion = self.camera.motionState
            self.motionStatus.stringValue = motion.message
            self.previewButton.isEnabled = motion.hasCandidate
            self.acceptButton.isEnabled = motion.hasCandidate
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    private func build() {
        func label(_ value: String) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            return field
        }
        func button(_ name: String, _ action: Selector) -> NSButton {
            let result = NSButton(title: name, target: self, action: action)
            result.bezelStyle = .rounded
            return result
        }
        func number(_ key: String, _ title: String, _ value: String) -> NSStackView {
            let field = NSTextField(string: value)
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            field.target = self
            field.action = #selector(apply(_:))
            field.delegate = self
            field.setAccessibilityLabel(title)
            fields[key] = field
            return NativeWorkspace.stack([label(title), field])
        }
        devicePicker.target = self
        devicePicker.action = #selector(selectDevice(_:))
        modePicker.addItems(withTitles: ["Thermal only", "RGB + temperature markers", "Blend IR + RGB"])
        modePicker.target = self
        modePicker.action = #selector(apply(_:))
        alpha.target = self
        alpha.action = #selector(apply(_:))
        alpha.isContinuous = true
        alpha.setAccessibilityLabel("Thermal image opacity")
        mirror.target = self
        mirror.action = #selector(apply(_:))
        status.font = .systemFont(ofSize: 11)
        motionStatus.font = .systemFont(ofSize: 11)
        previewButton = button("Preview match", #selector(previewMotion(_:)))
        acceptButton = button("Accept match", #selector(acceptMotion(_:)))
        previewButton.isEnabled = false
        acceptButton.isEnabled = false
        let root = NativeWorkspace.stack([
            label("1 · Select the ordinary camera"),
            devicePicker,
            NativeWorkspace.stack([button("Refresh cameras", #selector(refreshDevices(_:))),
                                   button("Start RGB", #selector(start(_:))), button("Stop RGB", #selector(stop(_:)))]),
            status,
            button("Match by hand movement · 10 seconds", #selector(startMotion(_:))),
            motionStatus,
            NativeWorkspace.stack([previewButton, acceptButton, button("Cancel", #selector(cancelMotion(_:)))]),
            label("2 · Choose the combined view"), modePicker,
            NativeWorkspace.stack([label("Thermal opacity"), alpha]),
            label("3 · Align a warm, clearly outlined object at your working distance"),
            NativeWorkspace.stack([number("x", "X · IR pixels", "0"), number("y", "Y · IR pixels", "0")]),
            NativeWorkspace.stack([number("zoom", "RGB scale %", "100"), number("angle", "Rotation °", "0")]),
            mirror,
            label("Use Blend at 50%, then match the object's edges with X, Y, scale and rotation. Use RGB + temperature markers when aligned."),
            label("4 · Software timing adjustment"),
            NativeWorkspace.stack([number("offset", "RGB offset ms", "0"), number("tolerance", "Tolerance ms", "100")]),
            label("Pairs use frame arrival times, not synchronised exposures. Unmatched RGB frames fall back to thermal. Changing distance or camera mounting can require realignment."),
            NativeWorkspace.stack([button("Reset alignment", #selector(reset(_:))), button("Save for this camera", #selector(save(_:)))])])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let content = RGBPanelContent(frame: NSRect(x: 0, y: 0, width: 510, height: 850))
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ])
        let scroll = NSScrollView(frame: window!.contentView!.bounds)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        window?.contentView = scroll
        content.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(850, root.fittingSize.height + 36)))
    }

    @objc private func refreshDevices(_ sender: Any?) {
        let previous = devicePicker.selectedItem?.representedObject as? String
        devices = VisibleCamera.devices()
        devicePicker.removeAllItems()
        for device in devices {
            devicePicker.addItem(withTitle: device.localizedName)
            devicePicker.lastItem?.representedObject = device.uniqueID
        }
        if let index = devices.firstIndex(where: { $0.uniqueID == previous }) {
            devicePicker.selectItem(at: index)
        } else { selectDevice(nil) }
        if devices.isEmpty { status.stringValue = "No ordinary camera found. Connect one and refresh." }
    }

    @objc private func selectDevice(_ sender: Any?) {
        camera.select(devicePicker.selectedItem?.representedObject as? String ?? "")
        sync()
    }
    @objc private func start(_ sender: Any?) {
        guard devicePicker.selectedItem != nil else { return }
        if camera.alignment.mode == 0 { modePicker.selectItem(at: 2); apply(nil) }
        camera.start()
    }
    @objc private func stop(_ sender: Any?) { camera.stop() }
    @objc private func startMotion(_ sender: Any?) { camera.beginMotion(); motionStatus.stringValue = camera.motionState.message }
    @objc private func previewMotion(_ sender: Any?) { camera.previewMotion(); sync() }
    @objc private func acceptMotion(_ sender: Any?) { camera.acceptMotion(); sync() }
    @objc private func cancelMotion(_ sender: Any?) { camera.cancelMotion(); sync() }
    @objc private func save(_ sender: Any?) { apply(nil); camera.saveAlignment(); status.stringValue = "Alignment saved for this camera." }
    @objc private func reset(_ sender: Any?) {
        let mode = camera.alignment.mode
        camera.alignment = RGBAlignment()
        var settings = camera.alignment; settings.mode = mode; camera.alignment = settings
        sync()
    }
    func controlTextDidEndEditing(_ obj: Notification) { apply(nil) }

    @objc private func apply(_ sender: Any?) {
        func value(_ key: String) -> Double? { Double(fields[key]!.stringValue.replacingOccurrences(of: ",", with: ".")) }
        guard let x = value("x"), let y = value("y"), let zoom = value("zoom"), let angle = value("angle"),
              let offset = value("offset"), let tolerance = value("tolerance") else { return }
        let settings = RGBAlignment(x: x, y: y, zoom: zoom / 100, degrees: angle,
                                    mirrored: mirror.state == .on, alpha: alpha.doubleValue,
                                    mode: modePicker.indexOfSelectedItem, timeOffsetMS: offset, toleranceMS: tolerance)
        guard settings.isValid else { status.stringValue = "Check values: scale 20–500%, tolerance 10–500 ms, offset ±500 ms."; return }
        camera.alignment = settings
    }
    private func sync() {
        let s = camera.alignment
        for (key, value) in ["x":s.x, "y":s.y, "zoom":s.zoom * 100, "angle":s.degrees, "offset":s.timeOffsetMS, "tolerance":s.toleranceMS] {
            fields[key]?.stringValue = String(format: "%.1f", value)
        }
        modePicker.selectItem(at: s.mode)
        alpha.doubleValue = s.alpha
        mirror.state = s.mirrored ? .on : .off
    }
}

private final class RGBPanelContent: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
