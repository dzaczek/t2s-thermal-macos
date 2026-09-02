import Cocoa

/// The live thermal view, its measurement tools and the capture controls.
final class ThermalViewController: NSViewController, NSMenuItemValidation, NSTextFieldDelegate {

    // Layout. The image keeps its native 858x576 render size; the panel on the
    // right holds the measurement list and capture controls.
    static let panelWidth: CGFloat = 300
    private static let controlsHeight: CGFloat = 46
    private static let statusHeight: CGFloat = 24
    static var contentWidth: CGFloat { CGFloat(ThermalRenderer.displayWidth) + panelWidth }
    static var contentHeight: CGFloat {
        CGFloat(ThermalRenderer.displayHeight) + controlsHeight + statusHeight
    }

    /// Content height for a given plot position; only the docked plots add
    /// height, the inline sparklines are drawn into the image itself.
    static func contentHeight(for position: ChartPosition) -> CGFloat {
        contentHeight + (position == .above || position == .below ? chartHeight : 0)
    }

    private let capture = ThermalCapture()
    private let calibration = Calibration()
    private let virtualCam = VirtualCameraFeed()
    private let measurements = MeasurementStore()
    let recorder = Recorder()
    private let history = TemperatureHistory()

    /// Where the live trend plot goes, if anywhere.
    enum ChartPosition: Int { case off, above, below, inline }
    var chartPosition: ChartPosition = .off
    private static let chartHeight: CGFloat = 170

    var palette: Palette = .ironbow
    private var referenceTemp = Calibration.defaultRoomTemp
    var publishToVirtualCam = true

    var manualRange = false
    private var manualMin = 15.0
    private var manualMax = 40.0
    private var isothermAbove: Double?
    private var isothermBelow: Double?

    /// The built-in readouts. Hiding one removes both its marker and its
    /// trace, so what is on screen is what is plotted and logged.
    var showMax = true
    var showMin = true
    var showCentre = true

    private let changeDetector = ChangeDetector()
    var detectChanges = false

    /// Which measurement range the camera is in. Set explicitly at startup:
    /// the camera keeps whatever it was last put in, and decoding a frame
    /// against the wrong range gives confidently wrong temperatures.
    var measurementRange: ThermalDecoder.Range = .normal

    /// What dragging on the image creates.
    enum DragTool: Int { case area, line }
    var dragTool: DragTool = .area {
        didSet {
            imageView.dragCreatesLine = (dragTool == .line)
            updateGestureHint()
            syncToolbar()
        }
    }

    /// How many peaks a line profile marks, and whether it looks for hot or
    /// cold ones.
    private var lineExtremeCount = 3
    private var lineExtremeMode: MeasurementEngine.ExtremeMode = .hottest

    private var imageView = ThermalImageView()
    private var statusLabel = NSTextField(labelWithString: "")
    private var minField = NSTextField()
    private var maxField = NSTextField()
    private var isoAboveField = NSTextField()
    private var isoBelowField = NSTextField()
    private var table = NSTableView()
    private var emissivityField = NSTextField()
    private var recordButton = NSButton()
    private var intervalButton = NSButton()
    private var intervalSecondsField = NSTextField()
    private var intervalMinutesField = NSTextField()
    private var csvToggle = NSButton()
    private var captureStatus = NSTextField(labelWithString: "")
    private var chartView = ChartView()
    private let controlBar = NSView()

    // Toolbar controls, populated as the toolbar builds them.
    weak var toolbarTool: NSSegmentedControl?
    weak var toolbarPalette: NSPopUpButton?
    weak var toolbarPlot: NSPopUpButton?
    weak var toolbarMarkers: NSSegmentedControl?
    weak var toolbarRange: NSSegmentedControl?
    weak var toolbarNewSpots: NSButton?
    weak var toolbarVirtualCam: NSButton?
    weak var toolbarRecord: NSButton?
    private var logButton = NSButton()
    private var logSecondsField = NSTextField()
    private var changeThresholdField = NSTextField()
    private var linePointsField = NSTextField()
    private var gestureHint = NSTextField(labelWithString: "")
    private var lineModeControl = NSSegmentedControl()
    private var panelView = NSView()

    /// Latest decoded frame, kept so calibration and capture can act on it.
    private var lastCenterRaw: Double = 0
    private var lastMeta: ThermalDecoder.Metadata?

    /// Written on the capture queue, read on the main queue by the save
    /// actions and the interval timer, so both go through this lock.
    private let frameLock = NSLock()
    private var lastImage: CGImage?
    private var lastTemps: [Double] = []
    private var lastResults: [(Measurement, MeasurementResult)] = []
    private var lastLogRow: [String: Double] = [:]

    /// The table shows live numbers, but reloading it at the full 25fps
    /// fights the user for the selection, so it is throttled.
    private var lastTableReload = Date.distantPast

    private var nucInProgress = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0,
                                    width: ThermalViewController.contentWidth,
                                    height: ThermalViewController.contentHeight))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        start()
    }

    // MARK: - UI

    private func buildUI() {
        imageView.onAddSpot = { [weak self] x, y in
            self?.measurements.addSpot(x: x, y: y)
            self?.table.reloadData()
        }
        imageView.onAddArea = { [weak self] x, y, w, h in
            self?.measurements.addArea(x: x, y: y, w: w, h: h)
            self?.table.reloadData()
        }
        imageView.onAddLine = { [weak self] x, y, x2, y2 in
            self?.measurements.addLine(x: x, y: y, x2: x2, y2: y2)
            self?.table.reloadData()
        }
        view.addSubview(imageView)
        view.addSubview(chartView)

        buildControls()
        buildPanel()

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(statusLabel)
    }

    /// Single source of truth for geometry: every frame is derived from the
    /// current view size, so resizing cannot leave a control sitting on top of
    /// the video the way fixed frames did.
    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let panelW = ThermalViewController.panelWidth
        let mainW = max(320, b.width - panelW)

        panelView.frame = NSRect(x: b.width - panelW, y: 0, width: panelW, height: b.height)

        statusLabel.frame = NSRect(x: 12, y: 5, width: mainW - 24, height: 16)
        controlBar.frame = NSRect(x: 0, y: ThermalViewController.statusHeight,
                                  width: mainW, height: ThermalViewController.controlsHeight)

        let top = ThermalViewController.statusHeight + ThermalViewController.controlsHeight
        let free = max(0, b.height - top)

        switch chartPosition {
        case .off, .inline:
            chartView.isHidden = true
            imageView.frame = NSRect(x: 0, y: top, width: mainW, height: free)
        case .below:
            chartView.isHidden = false
            let chartH = min(ThermalViewController.chartHeight, free * 0.4)
            chartView.frame = NSRect(x: 0, y: top, width: mainW, height: chartH)
            imageView.frame = NSRect(x: 0, y: top + chartH, width: mainW, height: free - chartH)
        case .above:
            chartView.isHidden = false
            let chartH = min(ThermalViewController.chartHeight, free * 0.4)
            imageView.frame = NSRect(x: 0, y: top, width: mainW, height: free - chartH)
            chartView.frame = NSRect(x: 0, y: top + free - chartH, width: mainW, height: chartH)
        }
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 70) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: x, y: y, width: w, height: 17)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func numberField(_ value: String, x: CGFloat, y: CGFloat, w: CGFloat,
                             action: Selector) -> NSTextField {
        let f = NSTextField(frame: NSRect(x: x, y: y, width: w, height: 22))
        f.stringValue = value
        f.alignment = .right
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.target = self
        f.action = action
        // NSTextField only sends its action on Return. Typing a value and
        // clicking away left the setting untouched, which looked exactly like
        // the field being ignored -- so take the value as it is typed too.
        f.delegate = self
        return f
    }

    /// Only the numeric inputs live in the window. Palettes, markers, plot
    /// placement, range mode and the toggles are menu items instead -- they
    /// are choices, not values, and three rows of controls crowding the video
    /// is not what a Mac app looks like.
    private func buildControls() {
        controlBar.autoresizingMask = [.width]
        view.addSubview(controlBar)

        func add(_ title: String, _ field: NSTextField, x: CGFloat, w: CGFloat) {
            let l = NSTextField(labelWithString: title)
            l.frame = NSRect(x: x, y: 26, width: w + 30, height: 14)
            l.font = .systemFont(ofSize: 10)
            l.textColor = .secondaryLabelColor
            controlBar.addSubview(l)
            field.frame = NSRect(x: x, y: 4, width: w, height: 21)
            controlBar.addSubview(field)
        }

        minField = numberField(String(format: "%.1f", manualMin), x: 0, y: 0, w: 0,
                               action: #selector(rangeFieldChanged(_:)))
        maxField = numberField(String(format: "%.1f", manualMax), x: 0, y: 0, w: 0,
                               action: #selector(rangeFieldChanged(_:)))
        isoAboveField = numberField("", x: 0, y: 0, w: 0, action: #selector(isothermChanged(_:)))
        isoBelowField = numberField("", x: 0, y: 0, w: 0, action: #selector(isothermChanged(_:)))
        changeThresholdField = numberField("2.0", x: 0, y: 0, w: 0,
                                           action: #selector(changeThresholdChanged(_:)))
        isoAboveField.placeholderString = "off"
        isoBelowField.placeholderString = "off"

        add("scale min °C", minField, x: 12, w: 62)
        add("scale max °C", maxField, x: 84, w: 62)
        add("alarm > °C", isoAboveField, x: 166, w: 62)
        add("alarm < °C", isoBelowField, x: 238, w: 62)
        add("new spot Δ°C", changeThresholdField, x: 320, w: 62)

        gestureHint.frame = NSRect(x: 400, y: 8, width: 340, height: 14)
        gestureHint.font = .systemFont(ofSize: 10)
        gestureHint.textColor = .tertiaryLabelColor
        controlBar.addSubview(gestureHint)
        updateGestureHint()

        updateRangeEnabled()
    }

    private func buildPanel() {
        let panel = panelView
        panel.frame = NSRect(x: 0, y: 0,
                             width: ThermalViewController.panelWidth,
                             height: ThermalViewController.contentHeight)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(panel)

        let W = ThermalViewController.panelWidth
        var y = ThermalViewController.contentHeight - 28

        let title = NSTextField(labelWithString: "Measurements")
        title.frame = NSRect(x: 12, y: y, width: W - 24, height: 18)
        title.font = .boldSystemFont(ofSize: 12)
        panel.addSubview(title)
        y -= 190

        let scroll = NSScrollView(frame: NSRect(x: 12, y: y, width: W - 24, height: 182))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 17
        table.usesAlternatingRowBackgroundColors = true
        for (id, titleText, w) in [("name", "Obj", 44.0), ("min", "min", 52.0),
                                   ("avg", "avg", 52.0), ("max", "max", 52.0),
                                   ("emis", "ε", 40.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = titleText
            col.width = w
            table.addTableColumn(col)
        }
        scroll.documentView = table
        panel.addSubview(scroll)
        y -= 34

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeMeasurement(_:)))
        removeButton.frame = NSRect(x: 12, y: y, width: 130, height: 26)
        panel.addSubview(removeButton)
        let clearButton = NSButton(title: "Clear all", target: self, action: #selector(clearMeasurements(_:)))
        clearButton.frame = NSRect(x: 150, y: y, width: 138, height: 26)
        panel.addSubview(clearButton)
        y -= 32

        panel.addSubview(label("Line: mark", x: 12, y: y + 4, w: 70))
        linePointsField = numberField("3", x: 84, y: y, w: 36,
                                      action: #selector(linePointsChanged(_:)))
        panel.addSubview(linePointsField)
        panel.addSubview(label("points that are", x: 128, y: y + 4, w: 110))
        y -= 28

        lineModeControl = NSSegmentedControl(labels: ["hot", "cold", "avg", "med"],
                                             trackingMode: .selectOne, target: self,
                                             action: #selector(lineModeChanged(_:)))
        lineModeControl.frame = NSRect(x: 12, y: y, width: W - 24, height: 23)
        lineModeControl.setSelected(true, forSegment: 0)
        lineModeControl.toolTip = "hot/cold mark peaks; avg/med mark where the "
            + "profile crosses its own average or median."
        panel.addSubview(lineModeControl)
        y -= 32

        panel.addSubview(label("Emissivity of selected (blank = global)", x: 12, y: y + 4, w: W - 24))
        y -= 28
        emissivityField = numberField("", x: 12, y: y, w: 80,
                                      action: #selector(applyEmissivity(_:)))
        emissivityField.alignment = .left
        emissivityField.placeholderString = "0.95"
        panel.addSubview(emissivityField)
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(applyEmissivity(_:)))
        applyButton.frame = NSRect(x: 100, y: y - 3, width: 80, height: 26)
        panel.addSubview(applyButton)
        y -= 40

        let capTitle = NSTextField(labelWithString: "Capture")
        capTitle.frame = NSRect(x: 12, y: y, width: W - 24, height: 18)
        capTitle.font = .boldSystemFont(ofSize: 12)
        panel.addSubview(capTitle)
        y -= 32

        let photoButton = NSButton(title: "Save Photo", target: self, action: #selector(savePhoto(_:)))
        photoButton.frame = NSRect(x: 12, y: y, width: 130, height: 26)
        panel.addSubview(photoButton)
        csvToggle = NSButton(checkboxWithTitle: "+ CSV", target: self,
                             action: #selector(toggleCSV(_:)))
        csvToggle.state = .on
        csvToggle.frame = NSRect(x: 150, y: y + 3, width: 90, height: 22)
        csvToggle.toolTip = "Also save the temperature matrix, so the capture stays measurable."
        panel.addSubview(csvToggle)
        y -= 32

        recordButton = NSButton(title: "Record Video", target: self, action: #selector(toggleVideo(_:)))
        recordButton.frame = NSRect(x: 12, y: y, width: W - 24, height: 26)
        panel.addSubview(recordButton)
        y -= 34

        panel.addSubview(label("Every", x: 12, y: y + 4, w: 40))
        intervalSecondsField = numberField("10", x: 56, y: y, w: 44, action: #selector(noop(_:)))
        panel.addSubview(intervalSecondsField)
        panel.addSubview(label("s, for", x: 106, y: y + 4, w: 40))
        intervalMinutesField = numberField("5", x: 148, y: y, w: 44, action: #selector(noop(_:)))
        panel.addSubview(intervalMinutesField)
        panel.addSubview(label("min", x: 198, y: y + 4, w: 30))
        y -= 32

        intervalButton = NSButton(title: "Start Time-lapse", target: self,
                                  action: #selector(toggleInterval(_:)))
        intervalButton.frame = NSRect(x: 12, y: y, width: W - 24, height: 26)
        panel.addSubview(intervalButton)
        y -= 30

        panel.addSubview(label("Log every", x: 12, y: y + 4, w: 62))
        logSecondsField = numberField("1", x: 78, y: y, w: 44, action: #selector(noop(_:)))
        panel.addSubview(logSecondsField)
        panel.addSubview(label("s", x: 128, y: y + 4, w: 14))
        y -= 32

        logButton = NSButton(title: "Start CSV Log", target: self, action: #selector(toggleLog(_:)))
        logButton.frame = NSRect(x: 12, y: y, width: W - 24, height: 26)
        logButton.toolTip = "Logs every visible marker and measurement object over time."
        panel.addSubview(logButton)
        y -= 30

        let openButton = NSButton(title: "Open Output Folder", target: self,
                                  action: #selector(openOutputFolder(_:)))
        openButton.frame = NSRect(x: 12, y: y, width: W - 24, height: 26)
        panel.addSubview(openButton)
        y -= 40

        captureStatus.frame = NSRect(x: 12, y: 12, width: W - 24, height: y)
        captureStatus.font = .systemFont(ofSize: 10)
        captureStatus.textColor = .secondaryLabelColor
        captureStatus.maximumNumberOfLines = 6
        captureStatus.lineBreakMode = .byWordWrapping
        panel.addSubview(captureStatus)

        // Contents are laid out from the panel's top, so they must keep their
        // distance from it rather than from the bottom when the window grows.
        for child in panel.subviews { child.autoresizingMask = [.minYMargin] }
    }

    /// Spells out what the current tool does, so the mode is never a guess.
    private func updateGestureHint() {
        gestureHint.stringValue = dragTool == .area
            ? "Click = spot · drag = area · \u{21E7}shift-drag = line"
            : "Click = spot · drag = line · \u{21E7}shift-drag = area"
    }

    @objc func selectDragTool(_ sender: NSMenuItem) {
        dragTool = DragTool(rawValue: sender.tag) ?? .area
    }

    func updateRangeEnabled() {
        minField.isEnabled = manualRange
        maxField.isEnabled = manualRange
    }

    // MARK: - Capture pipeline

    private func start() {
        // Put the sensor in raw mode and commit sane radiometric parameters.
        // saveParameters is what makes these actually stick; without it
        // emissivity sits at a bogus default and the temperature table comes
        // out full of NaN.
        do {
            try UVCControl.send(UVCControl.cmdRawMode)
            try applyRange()
            try UVCControl.applyParameters(emissivity: 0.95, distanceMeters: 1,
                                           airTemp: 20, reflectedTemp: 20)
        } catch {
            setStatus("USB setup failed: \(error.localizedDescription)")
        }

        capture.onFrame = { [weak self] raw in
            self?.handle(raw: raw)
        }
        do {
            try capture.start()
            setStatus(calibration.isCalibrated
                ? String(format: "Running. Using saved calibration (shutter offset %.2f).", calibration.shutterOffset)
                : "Running, but not calibrated - press \u{2318}K aiming at something whose temperature you know.")
        } catch {
            setStatus(error.localizedDescription)
        }

    }

    /// Puts the camera into the selected range and points the calibration at
    /// that range's saved offset.
    private func applyRange() throws {
        try UVCControl.send(measurementRange == .high
                            ? UVCControl.cmdRangeHigh : UVCControl.cmdRangeNormal)
        calibration.range = measurementRange
        // The camera restabilises after a range change; upstream waits up to
        // 20s for it. Frames arriving before it settles are not meaningful.
        Thread.sleep(forTimeInterval: 3)
    }

    /// Puts scale, bias and the shutter offset for this range back to their
    /// starting values. Needed because a bad calibration is otherwise sticky:
    /// it is stored, reloaded on launch, and there was no way out of it.
    @objc func resetCalibration(_ sender: Any?) {
        calibration.resetToDefaults()
        setStatus(String(format: "Calibration for this range reset to defaults "
                         + "(scale %.3f, offset %.1f). Calibrate again when ready.",
                         calibration.scale, calibration.shutterOffset))
    }

    @objc func selectRange(_ sender: NSMenuItem) {
        let wanted: ThermalDecoder.Range = sender.tag == 1 ? .high : .normal
        guard wanted != measurementRange else { return }
        measurementRange = wanted
        changeDetector.reset()
        do {
            try applyRange()
            setStatus(measurementRange == .normal
                ? "Range: -20 to 120C." + (calibration.isCalibrated ? "" : " Not calibrated for this range yet — press \u{2318}K.")
                : "Range: -20 to 450C. The high-range correction is unverified upstream; check it against a known temperature."
                  + (calibration.isCalibrated ? "" : " Not calibrated for this range yet — press \u{2318}K."))
        } catch {
            setStatus("Could not switch range: \(error.localizedDescription)")
        }
    }

    private func handle(raw: [UInt16]) {
        guard !nucInProgress else { return }
        let tStart = CFAbsoluteTimeGetCurrent()
        Profile.shared.frameArrived()
        let W = ThermalCapture.width, H = ThermalCapture.imageHeight
        let meta = ThermalDecoder.metadata(from: raw)
        var corrected = calibration.applyCorrection(raw)
        calibration.repairDeadPixels(&corrected)

        var asUInt16 = [UInt16](repeating: 0, count: corrected.count)
        for i in 0..<corrected.count {
            asUInt16[i] = UInt16(max(0, min(Double(ThermalDecoder.tableSize - 1), corrected[i].rounded())))
        }
        let smoothed = ThermalProcessor.smooth(asUInt16, width: W, height: H)

        // Frames whose metadata cannot drive the model are skipped outright;
        // rendering them would publish a 0C image and poison the readouts.
        guard let table = ThermalDecoder.temperatureTable(
                meta: meta, shutterOffset: calibration.shutterOffset,
                range: measurementRange,
                scale: calibration.scale, bias: calibration.bias) else { return }
        let temps = lookup(smoothed, in: table)

        let extremes = ThermalProcessor.extremes(temps)
        let centerIndex = (H / 2) * W + W / 2

        // Objects with their own emissivity need their own table; build one
        // per distinct value rather than per object.
        var perEmissivity: [Double: [Double]] = [:]
        let items = measurements.items
        for m in items {
            guard let e = m.emissivity, perEmissivity[e] == nil else { continue }
            guard let t = ThermalDecoder.temperatureTable(
                    meta: meta, shutterOffset: calibration.shutterOffset,
                    emissivity: e, range: measurementRange,
                    scale: calibration.scale, bias: calibration.bias) else { continue }
            perEmissivity[e] = lookup(smoothed, in: t)
        }
        let results: [(Measurement, MeasurementResult)] = items.map { m in
            let source = m.emissivity.flatMap { perEmissivity[$0] } ?? temps
            return (m, MeasurementEngine.evaluate(m, temps: source, width: W, height: H,
                                                  lineExtremeCount: lineExtremeCount,
                                                  lineExtremeMode: lineExtremeMode))
        }

        // Trend history. A spot contributes its own value, an area its
        // average; with nothing placed, the centre is plotted so the chart
        // still shows something useful.
        let now = CFAbsoluteTimeGetCurrent()
        var live = Set<String>()
        if showMax { history.append(extremes.maxValue, for: "Max", at: now); live.insert("Max") }
        if showMin { history.append(extremes.minValue, for: "Min", at: now); live.insert("Min") }
        if showCentre { history.append(temps[centerIndex], for: "Centre", at: now); live.insert("Centre") }
        for (m, r) in results {
            history.append(r.average, for: m.name, at: now)
            live.insert(m.name)
        }
        history.retain(keys: live)

        // Snapshot for the CSV logger, which samples on its own timer.
        var row: [String: Double] = [:]
        if showMax { row["Max"] = extremes.maxValue }
        if showMin { row["Min"] = extremes.minValue }
        if showCentre { row["Centre"] = temps[centerIndex] }
        for (m, r) in results {
            if m.kind == .spot {
                row[m.name] = r.average
            } else {
                row["\(m.name)_min"] = r.minValue
                row["\(m.name)_avg"] = r.average
                row["\(m.name)_max"] = r.maxValue
            }
        }

        var sparklines: [String: [Double]] = [:]
        if chartPosition == .inline {
            for (m, _) in results {
                sparklines[m.name] = history.recent(m.name, count: 48)
            }
        }

        let changes = detectChanges
            ? changeDetector.update(temps, width: W, height: H)
            : []
        let scaleMin = manualRange ? manualMin : extremes.minValue
        let scaleMax = manualRange ? manualMax : extremes.maxValue
        let normalized = ThermalProcessor.normalize(temps, from: scaleMin, to: scaleMax)

        var note: String?
        if recorder.isRecordingVideo { note = "REC" }
        if recorder.isRunningInterval {
            note = (note.map { $0 + " · " } ?? "")
                + "TIMELAPSE \(recorder.intervalShotsTaken)"
        }
        if recorder.isLogging {
            note = (note.map { $0 + " · " } ?? "") + "LOG \(recorder.logRowsWritten)"
        }

        let frame = ThermalRenderer.Frame(
            temperatures: temps,
            normalized: normalized,
            extremes: extremes,
            centerTemp: temps[centerIndex],
            palette: palette,
            calibrationNote: calibration.isCalibrated
                ? String(format: "calibrated (offset %.1f)", calibration.shutterOffset)
                : "uncalibrated - press \u{2318}K on a known temperature",
            scaleMin: scaleMin,
            scaleMax: scaleMax,
            measurements: results,
            histories: sparklines,
            isothermAbove: isothermAbove,
            isothermBelow: isothermBelow,
            recordingNote: note,
            showsMax: showMax,
            showsMin: showMin,
            showsCentre: showCentre,
            changes: changes)

        let tBeforeRender = CFAbsoluteTimeGetCurrent()
        guard let image = ThermalRenderer.render(frame) else { return }
        let tRendered = CFAbsoluteTimeGetCurrent()

        lastCenterRaw = smoothed[centerIndex]
        lastMeta = meta
        frameLock.lock()
        lastImage = image
        lastTemps = temps
        lastResults = results
        lastLogRow = row
        frameLock.unlock()

        if publishToVirtualCam { virtualCam.publish(image) }
        let tPublished = CFAbsoluteTimeGetCurrent()
        recorder.appendVideoFrame(image)
        Profile.shared.record(compute: tBeforeRender - tStart,
                              render: tRendered - tBeforeRender,
                              publish: tPublished - tRendered,
                              total: CFAbsoluteTimeGetCurrent() - tStart)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageView.image = image
            self.setStatus(String(format: "min %.1fC   centre %.1fC   max %.1fC   %@",
                                  extremes.minValue, frame.centerTemp, extremes.maxValue,
                                  self.publishToVirtualCam
                                      ? "virtual camera: \(self.virtualCam.framesPublished) frames"
                                      : "virtual camera: off"))
            if !self.chartView.isHidden {
                self.chartView.series = self.history.snapshot()
            }
            if Date().timeIntervalSince(self.lastTableReload) > 0.2 {
                self.lastTableReload = Date()
                let selected = self.table.selectedRow
                self.table.reloadData()
                if selected >= 0 && selected < self.measurements.items.count {
                    self.table.selectRowIndexes([selected], byExtendingSelection: false)
                }
            }
        }
    }

    private func lookup(_ values: [Double], in table: [Double]) -> [Double] {
        let maxIndex = Double(ThermalDecoder.tableSize - 1)
        return values.map { table[Int(max(0, min(maxIndex, $0.rounded())))] }
    }

    private func setStatus(_ text: String) {
        if Thread.isMainThread { statusLabel.stringValue = text }
        else { DispatchQueue.main.async { self.statusLabel.stringValue = text } }
    }

    private func setCaptureStatus(_ text: String) {
        if Thread.isMainThread { captureStatus.stringValue = text }
        else { DispatchQueue.main.async { self.captureStatus.stringValue = text } }
    }

    private func currentFrame() -> (CGImage, [Double])? {
        frameLock.lock(); defer { frameLock.unlock() }
        guard let image = lastImage else { return nil }
        return (image, lastTemps)
    }

    // MARK: - Image actions

    @objc private func noop(_ sender: Any?) {}

    @objc private func linePointsChanged(_ sender: Any?) {
        applyLinePoints(tidy: true)
    }

    private func applyLinePoints(tidy: Bool) {
        guard let v = Int(linePointsField.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        lineExtremeCount = max(1, min(10, v))
        guard tidy else { return }
        linePointsField.stringValue = String(lineExtremeCount)
    }

    @objc private func lineModeChanged(_ sender: NSSegmentedControl) {
        lineExtremeMode = MeasurementEngine.ExtremeMode(rawValue: sender.selectedSegment) ?? .hottest
    }

    @objc private func changeThresholdChanged(_ sender: Any?) {
        applyChangeThreshold(tidy: true)
    }

    private func applyChangeThreshold(tidy: Bool) {
        let v = Double(changeThresholdField.stringValue.replacingOccurrences(of: ",", with: "."))
        changeDetector.threshold = max(0.2, v ?? 2.0)
        guard tidy else { return }
        changeThresholdField.stringValue = String(format: "%.1f", changeDetector.threshold)
    }

    @objc private func rangeFieldChanged(_ sender: Any?) {
        applyRange(tidy: true)
    }

    private func applyRange(tidy: Bool) {
        manualMin = Double(minField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? manualMin
        manualMax = Double(maxField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? manualMax
        if manualMax <= manualMin { manualMax = manualMin + 1 }
        guard tidy else { return }
        minField.stringValue = String(format: "%.1f", manualMin)
        maxField.stringValue = String(format: "%.1f", manualMax)
    }

    @objc private func isothermChanged(_ sender: Any?) {
        isothermAbove = Double(isoAboveField.stringValue.replacingOccurrences(of: ",", with: "."))
        isothermBelow = Double(isoBelowField.stringValue.replacingOccurrences(of: ",", with: "."))
    }

    // MARK: - Menu actions

    @objc func selectPalette(_ sender: NSMenuItem) {
        defer { syncToolbar() }
        palette = Palette(rawValue: sender.tag) ?? .ironbow
    }

    @objc func selectChartPosition(_ sender: NSMenuItem) {
        defer { syncToolbar() }
        chartPosition = ChartPosition(rawValue: sender.tag) ?? .off
        view.needsLayout = true
    }

    @objc func selectRangeMode(_ sender: NSMenuItem) {
        defer { syncToolbar() }
        manualRange = sender.tag == 1
        updateRangeEnabled()
    }

    @objc func toggleMarker(_ sender: NSMenuItem) {
        defer { syncToolbar() }
        switch sender.tag {
        case 0: showMax.toggle()
        case 1: showMin.toggle()
        default: showCentre.toggle()
        }
    }

    @objc func toggleVirtualCamera(_ sender: Any?) {
        defer { syncToolbar() }
        publishToVirtualCam.toggle()
        if !publishToVirtualCam { virtualCam.clear() }
    }

    @objc func toggleChangeDetection(_ sender: Any?) {
        defer { syncToolbar() }
        detectChanges.toggle()
        // Re-baseline on every switch-on, so the highlight always means
        // "changed since you asked".
        changeDetector.reset()
        setStatus(detectChanges
                  ? "Watching for new hot/cold spots relative to the scene as it is now."
                  : "New-spot detection off.")
    }

    /// Checkmarks in the menus, so the menu is the readout for these settings
    /// now that they have no on-screen control.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectPalette(_:)):
            item.state = item.tag == palette.rawValue ? .on : .off
        case #selector(selectChartPosition(_:)):
            item.state = item.tag == chartPosition.rawValue ? .on : .off
        case #selector(selectRangeMode(_:)):
            item.state = item.tag == (manualRange ? 1 : 0) ? .on : .off
        case #selector(toggleMarker(_:)):
            let on = [showMax, showMin, showCentre]
            item.state = on[min(item.tag, 2)] ? .on : .off
        case #selector(toggleVirtualCamera(_:)):
            item.state = publishToVirtualCam ? .on : .off
            return virtualCam.isAvailable
        case #selector(toggleChangeDetection(_:)):
            item.state = detectChanges ? .on : .off
        case #selector(selectDragTool(_:)):
            item.state = item.tag == dragTool.rawValue ? .on : .off
        case #selector(selectRange(_:)):
            item.state = item.tag == (measurementRange == .high ? 1 : 0) ? .on : .off
        case #selector(toggleVideo(_:)):
            item.title = recorder.isRecordingVideo ? "Stop Recording" : "Start Recording"
        case #selector(toggleInterval(_:)):
            item.title = recorder.isRunningInterval ? "Stop Time-lapse" : "Start Time-lapse"
        case #selector(toggleLog(_:)):
            item.title = recorder.isLogging ? "Stop CSV Log" : "Start CSV Log"
        default:
            break
        }
        return true
    }

    // MARK: - Measurement actions

    @objc private func removeMeasurement(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        measurements.remove(at: row)
        table.reloadData()
    }

    @objc private func clearMeasurements(_ sender: Any?) {
        measurements.removeAll()
        history.clear()
        table.reloadData()
    }

    @objc private func applyEmissivity(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0 else {
            setCaptureStatus("Select a measurement in the list first.")
            return
        }
        let text = emissivityField.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            measurements.setEmissivity(nil, at: row)
        } else if let v = Double(text.replacingOccurrences(of: ",", with: ".")),
                  v >= 0.01, v <= 1.0 {
            measurements.setEmissivity(v, at: row)
        } else {
            setCaptureStatus("Emissivity must be between 0.01 and 1.0.")
            return
        }
        table.reloadData()
    }

    // MARK: - Capture actions

    @objc private func toggleCSV(_ sender: NSButton) {
        recorder.savesCSV = (sender.state == .on)
    }

    @objc func savePhoto(_ sender: Any?) {
        guard let (image, temps) = currentFrame() else {
            setCaptureStatus("No frame to save yet.")
            return
        }
        do {
            let url = try recorder.savePhoto(image, temperatures: temps,
                                             width: ThermalCapture.width,
                                             height: ThermalCapture.imageHeight)
            setCaptureStatus("Saved \(url.lastPathComponent)"
                             + (recorder.savesCSV ? " (+ CSV)" : ""))
        } catch {
            setCaptureStatus(error.localizedDescription)
        }
    }

    @objc func toggleVideo(_ sender: Any?) {
        if recorder.isRecordingVideo {
            recorder.stopVideo { [weak self] url in
                self?.recordButton.title = "Record Video"
                self?.setCaptureStatus(url.map { "Saved \($0.lastPathComponent)" }
                                       ?? "Recording stopped.")
            }
            return
        }
        do {
            try recorder.startVideo(width: ThermalRenderer.outputWidth,
                                    height: ThermalRenderer.outputHeight)
            recordButton.title = "Stop Recording"
            setCaptureStatus("Recording…")
        } catch {
            setCaptureStatus(error.localizedDescription)
        }
    }

    @objc func toggleInterval(_ sender: Any?) {
        if recorder.isRunningInterval {
            recorder.stopInterval()
            intervalButton.title = "Start Time-lapse"
            setCaptureStatus("Time-lapse stopped after \(recorder.intervalShotsTaken) shots.")
            return
        }
        let seconds = Double(intervalSecondsField.stringValue) ?? 0
        let minutes = Double(intervalMinutesField.stringValue) ?? 0
        guard seconds > 0, minutes > 0 else {
            setCaptureStatus("Set an interval in seconds and a duration in minutes.")
            return
        }
        intervalButton.title = "Stop Time-lapse"
        let expected = Int((minutes * 60) / seconds)
        setCaptureStatus("Time-lapse: every \(Int(seconds))s for \(Int(minutes)) min "
                         + "(~\(expected) shots).")
        recorder.startInterval(every: seconds, forMinutes: minutes,
                               frame: { [weak self] in self?.currentFrame() },
                               onShot: { [weak self] n in
            guard let self else { return }
            let left = Int(self.recorder.intervalRemaining)
            self.setCaptureStatus("Time-lapse: \(n) saved, \(left / 60)m \(left % 60)s left.")
        }, onFinish: { [weak self] in
            guard let self else { return }
            self.intervalButton.title = "Start Time-lapse"
            self.setCaptureStatus("Time-lapse finished: \(self.recorder.intervalShotsTaken) photos "
                                  + "in \(Recorder.outputDirectory.lastPathComponent).")
        })
    }

    @objc func toggleLog(_ sender: Any?) {
        if recorder.isLogging {
            recorder.stopLog()
            logButton.title = "Start CSV Log"
            setCaptureStatus("Log stopped: \(recorder.logRowsWritten) rows in "
                             + (recorder.logURL?.lastPathComponent ?? "the output folder") + ".")
            return
        }
        let seconds = Double(logSecondsField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0
        guard seconds > 0 else {
            setCaptureStatus("Set a logging interval in seconds.")
            return
        }
        frameLock.lock(); let columns = lastLogRow.keys.sorted(); frameLock.unlock()
        guard !columns.isEmpty else {
            setCaptureStatus("Nothing to log: enable a marker or place a measurement object.")
            return
        }
        do {
            try recorder.startLog(every: seconds, columns: columns, sample: { [weak self] in
                guard let self else { return [:] }
                self.frameLock.lock(); defer { self.frameLock.unlock() }
                return self.lastLogRow
            }, onTick: { [weak self] n in
                self?.setCaptureStatus("Logging \(columns.count) columns — \(n) rows.")
            })
            logButton.title = "Stop CSV Log"
        } catch {
            setCaptureStatus(error.localizedDescription)
        }
    }

    @objc func openOutputFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: Recorder.outputDirectory,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(Recorder.outputDirectory)
    }

    // MARK: - Calibration

    @objc func calibrateTemperature(_ sender: Any?) {
        guard let meta = lastMeta else { return }
        let alert = NSAlert()
        alert.messageText = "Calibrate against a known temperature"
        alert.informativeText = "Point the centre crosshair at something whose real temperature "
            + "you know, then enter that temperature. Everything else is scaled from this point."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = String(format: "%.1f", referenceTemp)
        alert.accessoryView = field
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let known = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) else { return }

        calibration.shutterOffset = Calibration.solveShutterOffset(
            startingAt: calibration.shutterOffset, knownTemp: known,
            centerRaw: lastCenterRaw, meta: meta)
        referenceTemp = known
        calibration.markCalibrated()
        setStatus(String(format: "Calibrated: centre = %.1fC (shutter offset %.2f)",
                         known, calibration.shutterOffset))
    }

    /// Solves the linear correction from two references at known
    /// temperatures.
    ///
    /// One point can only shift the readings. The high range comes out with
    /// the wrong *span* as well, and nothing you do to a single offset will
    /// stretch it, so two points are needed: they give scale and bias exactly.
    @objc func calibrateTwoPoint(_ sender: Any?) {
        guard let meta = lastMeta else { return }

        func ask(_ which: String, _ hint: String) -> (raw: Double, temp: Double)? {
            let alert = NSAlert()
            alert.messageText = "Two-point calibration: \(which) reference"
            alert.informativeText = hint + "\n\nAim the centre crosshair at it, hold "
                + "steady, then type its real temperature."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Use this")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,
                  let t = Double(field.stringValue.replacingOccurrences(of: ",", with: "."))
            else { return nil }
            return (lastCenterRaw, t)
        }

        guard let cold = ask("cooler", "Something around room temperature works well.") else { return }
        guard let hot = ask("warmer", "The wider apart the two are, the better the fit.") else { return }

        guard abs(hot.temp - cold.temp) >= 5 else {
            setStatus("Those two temperatures are within 5C of each other. The fit "
                      + "needs them far apart, and entering the same value twice "
                      + "would flatten the whole image to one temperature.")
            return
        }
        guard abs(hot.raw - cold.raw) > 1 else {
            setStatus("Both readings came from the same sensor value. Aim at two "
                      + "genuinely different temperatures.")
            return
        }

        // Model output with the correction removed, then fit a*model + b.
        guard let plain = ThermalDecoder.temperatureTable(
                meta: meta, shutterOffset: calibration.shutterOffset,
                range: measurementRange, scale: 1.0, bias: 0.0) else { return }
        let index = { (r: Double) -> Int in
            Int(max(0, min(Double(ThermalDecoder.tableSize - 1), r.rounded())))
        }
        let mCold = plain[index(cold.raw)], mHot = plain[index(hot.raw)]
        guard abs(mHot - mCold) > 1e-6 else {
            setStatus("The model gives both points the same temperature; cannot fit.")
            return
        }
        let a = (hot.temp - cold.temp) / (mHot - mCold)
        let b = cold.temp - a * mCold
        // A degenerate fit flattens every pixel to one value, which looks like
        // the camera has died. Refuse it rather than store it.
        guard a.isFinite, b.isFinite, a > 1e-4 else {
            setStatus(String(format: "That fit came out degenerate (scale %.5f) and "
                             + "would show a single flat temperature, so it was not "
                             + "saved. Try two references further apart.", a))
            return
        }
        calibration.setTwoPoint(scale: a, bias: b)
        setStatus(String(format: "Two-point calibration: scale %.4f, bias %.1f "
                         + "(from %.1fC and %.1fC).", a, b, cold.temp, hot.temp))
    }

    /// Closes the shutter, waits for the signal to actually go flat, averages
    /// a reference, then waits for the shutter to reopen.
    ///
    /// The waits are not decoration: shutter timing on this hardware is
    /// wildly variable (measured 0.15s to 7.6s just to reopen), and capturing
    /// the reference too early yields a reference full of real scene, which
    /// then gets subtracted out of every later frame.
    @objc func runNUC(_ sender: Any?) {
        guard !nucInProgress else { return }
        nucInProgress = true
        setStatus("Recalibrating sensor — closing shutter…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer {
                self.nucInProgress = false
            }

            var collected: [[UInt16]] = []
            let lock = NSLock()
            var settledFrames = 0

            self.capture.onFrame = { raw in
                lock.lock(); defer { lock.unlock() }
                let image = Array(raw[0..<(ThermalCapture.width * ThermalCapture.imageHeight)])
                let mean = image.reduce(0.0) { $0 + Double($1) } / Double(image.count)
                let variance = image.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(image.count)
                // Flat frame => shutter is genuinely closed.
                if sqrt(variance) < 6.0 {
                    settledFrames += 1
                    if settledFrames > 3 && collected.count < 15 { collected.append(raw) }
                } else {
                    settledFrames = 0
                }
            }

            for _ in 0..<40 {
                try? UVCControl.send(UVCControl.cmdShutterClose)   // must be re-sent to stay shut
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock(); let enough = collected.count >= 15; lock.unlock()
                if enough { break }
            }

            lock.lock(); let frames = collected; lock.unlock()
            let result = self.calibration.buildReference(from: frames)

            // Let the shutter physically reopen before resuming the view.
            Thread.sleep(forTimeInterval: 2.0)
            self.capture.onFrame = { [weak self] raw in self?.handle(raw: raw) }

            let note: String
            if frames.isEmpty {
                note = "Sensor recalibration failed: shutter never settled."
            } else if result.applied {
                note = "Sensor recalibrated (\(result.deadCount) dead pixels corrected)."
            } else if result.deadCount > 0 {
                note = "Sensor recalibrated. \(result.deadCount) pixels looked defective — far more "
                    + "than normal, so that correction was skipped rather than smear the image."
            } else {
                note = "Sensor recalibrated."
            }
            self.setStatus(note)
        }
    }

    func shutdown() {
        recorder.stopLog()
        recorder.stopInterval()
        if recorder.isRecordingVideo { recorder.stopVideo { _ in } }
        capture.stop()
        virtualCam.clear()
    }
}

// MARK: - Measurement table

extension ThermalViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        measurements.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        frameLock.lock()
        let results = lastResults
        frameLock.unlock()
        guard measurements.items.indices.contains(row) else { return nil }
        let m = measurements.items[row]
        let r = results.first { $0.0.id == m.id && $0.0.kind == m.kind }?.1

        let text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = m.name
        case "min":  text = r.map { String(format: "%.1f", $0.minValue) } ?? "-"
        case "avg":  text = r.map { String(format: "%.1f", $0.average) } ?? "-"
        case "max":  text = r.map { String(format: "%.1f", $0.maxValue) } ?? "-"
        case "emis": text = m.emissivity.map { String(format: "%.2f", $0) } ?? "—"
        default:     text = ""
        }

        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = tableColumn?.identifier.rawValue == "name" ? .left : .right
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard measurements.items.indices.contains(row) else {
            emissivityField.stringValue = ""
            return
        }
        emissivityField.stringValue = measurements.items[row].emissivity
            .map { String(format: "%.2f", $0) } ?? ""
    }
}
