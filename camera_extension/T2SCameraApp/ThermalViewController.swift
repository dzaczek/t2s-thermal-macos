import Cocoa

/// The live thermal view, its measurement tools and the capture controls.
final class ThermalViewController: NSViewController, NSMenuItemValidation, NSTextFieldDelegate {

    // Window geometry is independent of the shared renderer's output size.
    static let panelWidth: CGFloat = 300
    static var contentWidth: CGFloat { 1380 }
    static var contentHeight: CGFloat {
        900
    }

    /// Content height for a given plot position; only the docked plots add
    /// height, the inline sparklines are drawn into the image itself.
    static func contentHeight(for position: ChartPosition) -> CGFloat {
        contentHeight + (position == .above || position == .below ? chartHeight : 0)
    }

    private let capture = ThermalCapture()
    private let calibration = Calibration()
    private let virtualCam = VirtualCameraFeed()
    private let rgbCamera = VisibleCamera()
    private var rgbPanel: RGBAlignmentPanel?
    private let measurements = MeasurementStore()
    let recorder = Recorder()
    private let history = TemperatureHistory()

    /// Where the live trend plot goes, if anywhere.
    enum ChartPosition: Int { case off, above, below, inline }
    var chartPosition: ChartPosition = .off { didSet { syncWorkspace(); layoutImageAndChart() } }
    private static let chartHeight: CGFloat = 170

    var palette: Palette = .ironbow { didSet { syncWorkspace() } }
    private var referenceTemp = Calibration.defaultRoomTemp
    var publishToVirtualCam = true { didSet { syncWorkspace() } }

    var manualRange = false { didSet { syncWorkspace() } }
    private var manualMin = 15.0
    private var manualMax = 40.0
    private var isothermAbove: Double?
    private var isothermBelow: Double?

    /// The built-in readouts. Hiding one removes both its marker and its
    /// trace, so what is on screen is what is plotted and logged.
    var showMax = true { didSet { syncWorkspace() } }
    var showMin = true { didSet { syncWorkspace() } }
    var showCentre = true { didSet { syncWorkspace() } }

    private let changeDetector = ChangeDetector()
    var detectChanges = false { didSet { syncWorkspace() } }

    /// Which measurement range the camera is in. Set explicitly at startup:
    /// the camera keeps whatever it was last put in, and decoding a frame
    /// against the wrong range gives confidently wrong temperatures.
    var measurementRange: ThermalDecoder.Range = .normal

    /// Quarter turns applied to the temperature field before anything is
    /// measured, drawn or published. Not persisted: the mounting changes with
    /// the job, and a rotation carried over from last time is more surprising
    /// than useful.
    var rotation: ImageRotation = .none

    /// Follows objects that were marked sticky. Templates are seeded by the
    /// capture pipeline from whichever frame first sees the flag set.
    private let tracker = ObjectTracker()

    /// The frame as it is rendered: the sensor, turned.
    private var frameSize: (width: Int, height: Int) {
        rotation.size(width: ThermalCapture.width, height: ThermalCapture.imageHeight)
    }

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

    // Toolbar controls, populated as the toolbar builds them.
    weak var toolbarTool: NSSegmentedControl?
    weak var toolbarPalette: NSPopUpButton?
    weak var toolbarPlot: NSPopUpButton?
    weak var toolbarMarkers: NSSegmentedControl?
    weak var toolbarRange: NSSegmentedControl?
    weak var toolbarNewSpots: NSButton?
    weak var toolbarVirtualCam: NSButton?
    weak var toolbarRecord: NSButton?
    weak var toolbarTrack: NSButton?
    private var trackButton = NSButton()
    private var logButton = NSButton()
    private var logSecondsField = NSTextField()
    private var changeThresholdField = NSTextField()
    private var linePointsField = NSTextField()
    private var gestureHint = NSTextField(labelWithString: "")
    private var lineModeControl = NSSegmentedControl()
    private var workspace: NativeWorkspace?
    private let workspacePalette = NSPopUpButton()
    private let workspacePlot = NSPopUpButton()
    private let workspaceRange = NSSegmentedControl()
    private let workspaceMarkers = NSSegmentedControl()
    private let workspaceHardwareRange = NSPopUpButton()
    private var workspaceVirtual = NSButton()
    private var workspaceChanges = NSButton()
    private var workspaceTools = NSSegmentedControl()
    private var quickVideo = NSButton()
    private var quickInterval = NSButton()
    private var quickLog = NSButton()

    /// Kept together under frameLock so calibration cannot mix two frames.
    private var lastCalibrationSample: Calibration.Sample?
    private var lastCalibrationTime = Date.distantPast

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
    private(set) var isIRRunning = false
    /// Invalidates queued UI updates and a pending NUC when capture stops.
    private var captureGeneration = UUID() // protected by frameLock
    private let startsCapture: Bool

    init(startsCapture: Bool = true) {
        self.startsCapture = startsCapture
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0,
                                    width: ThermalViewController.contentWidth,
                                    height: ThermalViewController.contentHeight))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        if startsCapture { start() }
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
        buildNativeWorkspace()
    }

    /// Single source of truth for geometry: every frame is derived from the
    /// current view size, so resizing cannot leave a control sitting on top of
    /// the video the way fixed frames did.
    override func viewDidLayout() {
        super.viewDidLayout()
        workspace?.frame = view.bounds
        workspace?.layoutSubtreeIfNeeded()
        layoutImageAndChart()
    }

    private func layoutImageAndChart() {
        guard let workspace else { return }
        let b = workspace.imageHost.bounds
        let mainW = b.width, free = b.height
        let chartH = min(workspace.mode == .analysis ? 420 : 170,
                         free * workspace.preferredChartFraction)
        // Analysis adds a docked history view without disabling the user's
        // inline plots or changing the plot placement restored in other modes.
        let placement: ChartPosition = workspace.mode == .analysis && (chartPosition == .off || chartPosition == .inline)
            ? .below : chartPosition
        switch placement {
        case .off, .inline:
            chartView.isHidden = true
            imageView.frame = b
        case .below:
            chartView.isHidden = false
            chartView.frame = NSRect(x: 0, y: 0, width: mainW, height: chartH)
            imageView.frame = NSRect(x: 0, y: chartH, width: mainW, height: free - chartH)
        case .above:
            chartView.isHidden = false
            imageView.frame = NSRect(x: 0, y: 0, width: mainW, height: free - chartH)
            chartView.frame = NSRect(x: 0, y: free - chartH, width: mainW, height: chartH)
        }
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

    /// All controls reuse the existing actions and state. Moving between workspaces
    /// never replaces the measurement store, recorder, history or renderer.
    private func buildNativeWorkspace() {
        func text(_ title: String) -> NSTextField {
            let result = NSTextField(labelWithString: title)
            result.font = .systemFont(ofSize: 11)
            result.textColor = .secondaryLabelColor
            return result
        }
        func hint(_ title: String) -> NSTextField {
            let result = NSTextField(wrappingLabelWithString: title)
            result.font = .systemFont(ofSize: 10)
            result.textColor = .secondaryLabelColor
            return result
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let result = NSButton(title: title, target: self, action: action)
            result.bezelStyle = .rounded
            result.font = .systemFont(ofSize: 11)
            return result
        }
        func field(_ value: String, _ action: Selector, width: CGFloat = 55) -> NSTextField {
            let result = numberField(value, x: 0, y: 0, w: width, action: action)
            result.translatesAutoresizingMaskIntoConstraints = false
            result.widthAnchor.constraint(equalToConstant: width).isActive = true
            return result
        }
        func row(_ views: NSView...) -> NSStackView { NativeWorkspace.stack(views) }
        func controlGroup(_ title: String, _ control: NSView) -> NSStackView {
            NativeWorkspace.stack([text(title), control])
        }

        workspacePalette.addItems(withTitles: Palette.allCases.map(\.displayName))
        workspacePalette.target = self
        workspacePalette.action = #selector(toolbarPaletteChanged(_:))
        workspacePalette.setAccessibilityLabel("Colour palette")
        workspacePlot.addItems(withTitles: ["Off", "Above image", "Below image", "On image"])
        workspacePlot.target = self
        workspacePlot.action = #selector(toolbarPlotChanged(_:))
        workspacePlot.toolTip = "On image: plots stay in photos, video and the virtual camera."
        workspacePlot.setAccessibilityLabel("Plot placement")
        workspaceRange.segmentCount = 2
        workspaceRange.setLabel("Auto", forSegment: 0)
        workspaceRange.setLabel("Manual", forSegment: 1)
        workspaceRange.trackingMode = .selectOne
        workspaceRange.target = self
        workspaceRange.action = #selector(toolbarRangeChanged(_:))
        workspaceMarkers.segmentCount = 3
        workspaceMarkers.trackingMode = .selectAny
        for (i, title) in ["Max", "Min", "Centre"].enumerated() {
            workspaceMarkers.setLabel(title, forSegment: i)
        }
        workspaceMarkers.target = self
        workspaceMarkers.action = #selector(toolbarMarkersChanged(_:))

        minField = field(String(format: "%.1f", manualMin), #selector(rangeFieldChanged(_:)))
        maxField = field(String(format: "%.1f", manualMax), #selector(rangeFieldChanged(_:)))
        isoAboveField = field("", #selector(isothermChanged(_:)))
        isoBelowField = field("", #selector(isothermChanged(_:)))
        isoAboveField.placeholderString = "off"
        isoBelowField.placeholderString = "off"
        minField.setAccessibilityLabel("Colour scale minimum Celsius")
        maxField.setAccessibilityLabel("Colour scale maximum Celsius")
        isoAboveField.setAccessibilityLabel("Highlight above Celsius")
        isoBelowField.setAccessibilityLabel("Highlight below Celsius")
        changeThresholdField = field("2.0", #selector(changeThresholdChanged(_:)))
        changeThresholdField.setAccessibilityLabel("Change threshold Celsius")
        workspaceChanges = NSButton(checkboxWithTitle: "New changes", target: self,
                                    action: #selector(toggleChangeDetection(_:)))
        workspaceChanges.font = .systemFont(ofSize: 11)
        let displayTop = row(controlGroup("Palette", workspacePalette),
                             controlGroup("Plots", workspacePlot), workspaceMarkers)
        let displayBottom = row(workspaceRange, minField, text("—"), maxField, text("°C"),
                                text("Hot >"), isoAboveField, text("Cold <"), isoBelowField)
        displayTop.spacing = 12
        displayBottom.spacing = 5

        workspaceTools = NSSegmentedControl(labels: ["Area", "Line"], trackingMode: .selectOne,
                                             target: self, action: #selector(toolbarToolChanged(_:)))
        // Click always places a point; a drag uses the selected area/line tool.
        let toolViews: [NSView] = [
            text("MEASURE"),
            hint("Click: point\nDrag: tool"),
            workspaceTools,
            button("↺ Left", #selector(rotateLeft(_:))),
            button("↻ Right", #selector(rotateRight(_:))),
            button("Reset", #selector(resetRotation(_:))),
            button("NUC", #selector(runNUC(_:))),
            button("IR + RGB", #selector(showRGBAlignment(_:)))
        ]
        workspaceTools.setWidth(30, forSegment: 0)
        workspaceTools.setWidth(30, forSegment: 1)
        workspaceTools.controlSize = .small

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 25
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("name", "Object", 55.0), ("min", "Min", 49.0),
                                    ("avg", "Avg", 49.0), ("max", "Max", 49.0), ("emis", "ε", 42.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = table
        tableScroll.heightAnchor.constraint(equalToConstant: 175).isActive = true
        trackButton = button("Stick to object", #selector(toggleTrackSelected(_:)))
        trackButton.toolTip = "Track the selected point, area or line as the camera or object moves."
        linePointsField = field("3", #selector(linePointsChanged(_:)), width: 38)
        linePointsField.setAccessibilityLabel("Number of line profile markers")
        lineModeControl = NSSegmentedControl(labels: ["Hot", "Cold", "Avg", "Med"],
                                              trackingMode: .selectOne, target: self,
                                              action: #selector(lineModeChanged(_:)))
        lineModeControl.selectedSegment = 0
        lineModeControl.toolTip = "Hot/cold: peaks. Avg/med: crossings of the average or median."
        emissivityField = field("", #selector(applyEmissivity(_:)), width: 58)
        emissivityField.placeholderString = "global"
        emissivityField.setAccessibilityLabel("Selected object emissivity, empty uses global")
        let measurementCard = WorkspaceCard("Measurements", views: [
            tableScroll,
            row(trackButton, button("Unstick all", #selector(stopAllTracking(_:)))),
            row(button("Remove", #selector(removeMeasurement(_:))),
                button("Clear all", #selector(clearMeasurements(_:)))),
            row(text("Emissivity ε"), emissivityField, button("Apply", #selector(applyEmissivity(_:)))),
            row(text("Line markers"), linePointsField),
            lineModeControl,
            hint("Click = point · drag = area/line · Shift switches the drag tool.")
        ])
        workspaceHardwareRange.addItems(withTitles: ["Normal  −20…120 °C", "High  −20…450 °C"])
        workspaceHardwareRange.target = self
        workspaceHardwareRange.action = #selector(workspaceHardwareRangeChanged(_:))
        let cameraCard = WorkspaceCard("Sensor & temperature", views: [
            workspaceHardwareRange,
            row(button("NUC", #selector(runNUC(_:))),
                button("1 reference", #selector(calibrateTemperature(_:))),
                button("2 references", #selector(calibrateTwoPoint(_:)))),
            button("Reset calibration for this range", #selector(resetCalibration(_:))),
            hint("NUC evens out pixels. Temperature calibration uses a known reference."),
            row(workspaceChanges, changeThresholdField, text("Δ°C"))
        ])
        workspaceVirtual = NSButton(checkboxWithTitle: "Publish virtual camera", target: self,
                                    action: #selector(toggleVirtualCamera(_:)))
        let sharingCard = WorkspaceCard("Sharing", views: [
            workspaceVirtual,
            button("Install / manage extension…", #selector(workspaceManageExtension(_:))),
            hint("Measurements and on-image plots are included in the shared frame.")
        ])

        csvToggle = NSButton(checkboxWithTitle: "+ temperature matrix CSV", target: self,
                             action: #selector(toggleCSV(_:)))
        csvToggle.state = recorder.savesCSV ? .on : .off
        csvToggle.font = .systemFont(ofSize: 11)
        let photoCard = WorkspaceCard("Photo", views: [
            csvToggle,
            button("Save photo  ⌘S", #selector(savePhoto(_:))),
            button("Open output folder", #selector(openOutputFolder(_:)))
        ])
        recordButton = button("Record video", #selector(toggleVideo(_:)))
        let videoCard = WorkspaceCard("Video", views: [
            hint("H.264 MOV · includes measurements\nand plots placed on the image"),
            recordButton,
            hint("CSV log can run alongside video.")
        ])
        intervalSecondsField = field("10", #selector(noop(_:)), width: 44)
        intervalMinutesField = field("5", #selector(noop(_:)), width: 44)
        intervalSecondsField.setAccessibilityLabel("Time-lapse interval seconds")
        intervalMinutesField.setAccessibilityLabel("Time-lapse duration minutes")
        intervalButton = button("Start time-lapse", #selector(toggleInterval(_:)))
        let intervalCard = WorkspaceCard("Time-lapse", views: [
            row(text("Every"), intervalSecondsField, text("s · for"), intervalMinutesField, text("min")),
            intervalButton,
            hint("PNG + CSV when the photo matrix option is enabled.")
        ])
        logSecondsField = field("1", #selector(noop(_:)), width: 44)
        logSecondsField.setAccessibilityLabel("CSV log interval seconds")
        logButton = button("Start CSV log", #selector(toggleLog(_:)))
        let logCard = WorkspaceCard("Measurement log", views: [
            row(text("Sample every"), logSecondsField, text("s")),
            logButton,
            hint("Markers and objects over time.\nSeparate from the full pixel matrix.")
        ])
        quickVideo = button("Record video", #selector(toggleVideo(_:)))
        quickInterval = button("Start time-lapse", #selector(toggleInterval(_:)))
        quickLog = button("Start CSV log", #selector(toggleLog(_:)))
        let workspace = NativeWorkspace(tools: toolViews, display: [displayTop, displayBottom],
                                        sidebar: [measurementCard, cameraCard, sharingCard],
                                        capture: [photoCard, videoCard, intervalCard, logCard],
                                        quickCapture: [text("CAPTURE"), button("Save photo", #selector(savePhoto(_:))),
                                                       quickVideo, quickInterval, quickLog,
                                                       button("Output folder", #selector(openOutputFolder(_:)))],
                                        status: statusLabel, captureStatus: captureStatus)
        self.workspace = workspace
        workspace.irPower.target = self
        workspace.irPower.action = #selector(toggleIRCamera(_:))
        workspace.imageHost.addSubview(imageView)
        workspace.imageHost.addSubview(chartView)
        workspace.onLayoutChanged = { [weak self] in self?.layoutImageAndChart() }
        view.addSubview(workspace)
        syncWorkspace()
        updateRangeEnabled()
    }

    func syncWorkspace() {
        guard workspace != nil else { return }
        workspace?.irPower.title = isIRRunning ? "IR ON · Stop" : "IR OFF · Start"
        workspace?.irPower.toolTip = isIRRunning
            ? "Stop IR capture, video, time-lapse and CSV logging"
            : "Start the thermal camera"
        workspacePalette.selectItem(at: palette.rawValue)
        workspacePlot.selectItem(at: chartPosition.rawValue)
        workspaceRange.selectedSegment = manualRange ? 1 : 0
        workspaceMarkers.setSelected(showMax, forSegment: 0)
        workspaceMarkers.setSelected(showMin, forSegment: 1)
        workspaceMarkers.setSelected(showCentre, forSegment: 2)
        workspaceTools.selectedSegment = dragTool.rawValue
        workspaceChanges.state = detectChanges ? .on : .off
        workspaceVirtual.state = publishToVirtualCam ? .on : .off
        workspaceHardwareRange.selectItem(at: measurementRange == .high ? 1 : 0)
        minField.isEnabled = manualRange
        maxField.isEnabled = manualRange
        quickVideo.title = recorder.isRecordingVideo ? "Stop video" : "Record video"
        quickInterval.title = recorder.isRunningInterval ? "Stop time-lapse" : "Start time-lapse"
        quickLog.title = recorder.isLogging ? "Stop CSV log" : "Start CSV log"
    }

    @objc private func workspaceHardwareRangeChanged(_ sender: NSPopUpButton) {
        let item = NSMenuItem()
        item.tag = sender.indexOfSelectedItem
        selectRange(item)
        syncWorkspace()
    }

    @objc private func workspaceManageExtension(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showExtensionInstaller(sender)
    }

    @objc func showRGBAlignment(_ sender: Any?) {
        if rgbPanel == nil { rgbPanel = RGBAlignmentPanel(camera: rgbCamera) }
        rgbPanel?.showWindow(sender)
        rgbPanel?.window?.makeKeyAndOrderFront(nil)
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

    @objc func toggleIRCamera(_ sender: Any?) {
        if isIRRunning { stopIRCamera() } else { start() }
    }

    private func isCurrentCapture(_ generation: UUID) -> Bool {
        frameLock.lock(); defer { frameLock.unlock() }
        return captureGeneration == generation
    }

    private func closeShutter(for generation: UUID) -> Bool {
        frameLock.lock(); defer { frameLock.unlock() }
        guard captureGeneration == generation else { return false }
        try? UVCControl.send(UVCControl.cmdShutterClose)
        return true
    }

    /// Release the physical input and discard live values; measurement
    /// objects, palette and calibration remain available for the next run.
    func stopIRCamera() {
        frameLock.lock(); captureGeneration = UUID(); frameLock.unlock()
        isIRRunning = false
        capture.onFrame = nil // drains in-flight rendering before state is cleared
        capture.stop()
        nucInProgress = false
        rgbCamera.cancelMotion()
        recorder.stopLog()
        recorder.stopInterval()
        if recorder.isRecordingVideo { toggleVideo(nil) }
        intervalButton.title = "Start time-lapse"
        logButton.title = "Start CSV log"
        frameLock.lock()
        lastImage = nil
        lastTemps = []
        lastResults = []
        lastLogRow = [:]
        lastCalibrationSample = nil
        lastCalibrationTime = .distantPast
        frameLock.unlock()
        history.clear()
        chartView.series = []
        tracker.stopAll()
        changeDetector.reset()
        imageView.image = nil
        imageView.emptyMessage = "IR camera is OFF — click IR OFF · Start above"
        table.reloadData()
        virtualCam.clear()
        setStatus("IR camera OFF · capture and live measurements stopped")
        syncToolbar()
    }

    private func start() {
        guard !isIRRunning else { return }
        frameLock.lock()
        captureGeneration = UUID()
        let generation = captureGeneration
        frameLock.unlock()
        imageView.emptyMessage = "Starting IR camera…"
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
            self?.handle(raw: raw, generation: generation)
        }
        do {
            try capture.start()
            isIRRunning = true
            syncToolbar()
            setStatus(calibration.isCalibrated
                ? String(format: "Running. Using saved calibration (shutter offset %.2f).", calibration.shutterOffset)
                : "Running, but not calibrated - press \u{2318}K aiming at something whose temperature you know.")
        } catch {
            stopIRCamera()
            imageView.emptyMessage = "IR unavailable — connect camera and click Start"
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

    private func handle(raw: [UInt16], generation: UUID) {
        guard !nucInProgress else { return }
        guard raw.count == ThermalCapture.width * ThermalCapture.fullHeight else { return }
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
        // Turn the corrected counts, not the finished picture: everything
        // downstream -- markers, measurements, the mouse, the CSV -- then
        // works in one orientation without knowing there was a rotation.
        let turn = rotation
        let (fw, fh) = turn.size(width: W, height: H)
        let smoothed = turn.apply(ThermalProcessor.smooth(asUInt16, width: W, height: H),
                                  width: W, height: H)

        // Frames whose metadata cannot drive the model are skipped outright;
        // rendering them would publish a 0C image and poison the readouts.
        guard let table = ThermalDecoder.temperatureTable(
                meta: meta, shutterOffset: calibration.shutterOffset,
                range: measurementRange,
                scale: calibration.scale, bias: calibration.bias) else {
            rejectTemperatureFrame(generation: generation)
            return
        }
        let temps = lookup(smoothed, in: table)
        guard temps.allSatisfy({ $0.isFinite }) else {
            rejectTemperatureFrame(generation: generation)
            return
        }
        rgbCamera.observeMotion(temperatures: temps, rotation: turn, arrival: capture.frameArrivalTime)

        let extremes = ThermalProcessor.extremes(temps)
        let centerIndex = (fh / 2) * fw + fw / 2

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
        let results: [(Measurement, MeasurementResult)] = items.compactMap { m in
            let source: [Double]
            if let e = m.emissivity {
                // A failed override must not silently fall back to a different
                // material's emissivity. Invalid measurements remain absent.
                guard let adjusted = perEmissivity[e] else { return nil }
                source = adjusted
            } else { source = temps }
            let result = MeasurementEngine.evaluate(m, temps: source, width: fw, height: fh,
                                                  lineExtremeCount: lineExtremeCount,
                                                  lineExtremeMode: lineExtremeMode)
            guard result.average.isFinite, result.minValue.isFinite, result.maxValue.isFinite
            else { return nil }
            return (m, result)
        }

        // Sticky objects. Seeding and following both happen here, on the
        // frame everyone else is looking at; the store itself is only ever
        // touched on the main queue, so the move lands on the next frame.
        var moves: [(name: String, dx: Int, dy: Int)] = []
        var untrackable: [String] = []
        for m in items where m.tracked {
            let c = m.centre
            if tracker.isTracking(m.name) {
                if let d = tracker.follow(m.name, centreX: c.x, centreY: c.y,
                                          temps: temps, width: fw, height: fh),
                   d.dx != 0 || d.dy != 0 {
                    moves.append((m.name, d.dx, d.dy))
                }
            } else if !tracker.start(m.name, centreX: c.x, centreY: c.y,
                                     halfWidth: c.halfW, halfHeight: c.halfH,
                                     temps: temps, width: fw, height: fh) {
                untrackable.append(m.name)
            }
        }
        let lostTracks = tracker.lost

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
            ? changeDetector.update(temps, width: fw, height: fh)
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

        let rgb = rgbCamera.pair(at: capture.frameArrivalTime)
        let frame = ThermalRenderer.Frame(
            temperatures: temps,
            normalized: normalized,
            imageWidth: fw,
            imageHeight: fh,
            extremes: extremes,
            centerTemp: temps[centerIndex],
            palette: palette,
            calibrationNote: calibrationNote,
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
            changes: changes,
            lostTracks: lostTracks,
            rgbImage: rgb.image,
            rgbAlignment: rgb.alignment,
            rotation: rotation,
            fusionNote: rgb.note)

        let tBeforeRender = CFAbsoluteTimeGetCurrent()
        guard let image = ThermalRenderer.render(frame) else { return }
        let tRendered = CFAbsoluteTimeGetCurrent()

        frameLock.lock()
        lastCalibrationSample = Calibration.Sample(raw: smoothed[centerIndex], meta: meta)
        lastCalibrationTime = Date()
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
            guard let self, self.isCurrentCapture(generation) else { return }
            for move in moves {
                self.measurements.move(name: move.name, dx: move.dx, dy: move.dy,
                                       width: fw, height: fh)
            }
            for name in untrackable {
                if let i = self.measurements.index(ofName: name) {
                    self.measurements.setTracked(false, at: i)
                }
            }
            if let name = untrackable.first {
                self.setCaptureStatus("\(name) has nothing to lock onto — that patch is too "
                                      + "even. Put the object over something with visible "
                                      + "contrast and track it again.")
                self.syncTrackButton()
            }
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

    /// What the overlay says about how much the numbers can be trusted.
    private var calibrationNote: String {
        if measurementRange == .high && !calibration.hasTwoPoint {
            return "HIGH RANGE NOT CALIBRATED - temperatures are not valid, "
                + "use Calibrate with Two References"
        }
        if calibration.isCalibrated {
            return String(format: "calibrated (offset %.1f)", calibration.shutterOffset)
        }
        return "uncalibrated - press \u{2318}K on a known temperature"
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
        if Thread.isMainThread { captureStatus.stringValue = text; syncToolbar() }
        else { DispatchQueue.main.async { self.captureStatus.stringValue = text; self.syncToolbar() } }
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

    @objc func rotateLeft(_ sender: Any?) { setRotation(rotation.turnedLeft()) }
    @objc func rotateRight(_ sender: Any?) { setRotation(rotation.turnedRight()) }
    @objc func resetRotation(_ sender: Any?) { setRotation(.none) }

    /// Turning the image turns the objects on it with it, so a marker stays on
    /// the thing it was measuring instead of jumping to a different part of
    /// the scene.
    private func setRotation(_ new: ImageRotation) {
        guard new != rotation else { return }
        let old = frameSize
        let delta = ImageRotation(rawValue: (new.rawValue - rotation.rawValue + 4) % 4) ?? .none
        measurements.rotate(delta, width: old.width, height: old.height)
        rotation = new

        let size = frameSize
        imageView.sensorWidth = size.width
        imageView.sensorHeight = size.height
        // Both of these hold a picture of the scene in the old orientation.
        // The tracker re-seeds itself from the next frame; the change baseline
        // has to be taken again deliberately.
        tracker.stopAll()
        changeDetector.reset()
        table.reloadData()
        setStatus("Rotation \(rotation.displayName).")
    }

    /// Sticky tracking for the selected object.
    ///
    /// The measurement keeps its size and its readouts; only where it sits
    /// changes. Templates are seeded by the capture pipeline, so this just
    /// sets the flag and lets the next frame do the work.
    @objc func toggleTrackSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard measurements.items.indices.contains(row) else {
            setCaptureStatus("Select a measurement in the list first, then track it.")
            return
        }
        let m = measurements.items[row]
        measurements.setTracked(!m.tracked, at: row)
        if m.tracked { tracker.stop(m.name) }
        setCaptureStatus(m.tracked
            ? "\(m.name) is no longer following anything."
            : "\(m.name) is sticky: it follows what it is on until it loses it.")
        syncTrackButton()
        table.reloadData()
    }

    @objc func stopAllTracking(_ sender: Any?) {
        for i in measurements.items.indices { measurements.setTracked(false, at: i) }
        tracker.stopAll()
        syncTrackButton()
        table.reloadData()
        setCaptureStatus("Tracking off for every object.")
    }

    /// The button is the readout for the selected object's state, so it has to
    /// follow the selection as well as the toggle.
    func syncTrackButton() {
        let row = table.selectedRow
        let tracked = measurements.items.indices.contains(row)
            && measurements.items[row].tracked
        trackButton.title = tracked ? "Unstick object" : "Stick to object"
        trackButton.isEnabled = measurements.items.indices.contains(row)
        toolbarTrack?.title = tracked ? "Untrack" : "Track"
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
        case #selector(toggleTrackSelected(_:)):
            let row = table.selectedRow
            let tracked = measurements.items.indices.contains(row)
                && measurements.items[row].tracked
            item.title = tracked ? "Stop Tracking Selected Object" : "Track Selected Object"
            return measurements.items.indices.contains(row)
        case #selector(stopAllTracking(_:)):
            return measurements.items.contains { $0.tracked }
        case #selector(resetRotation(_:)):
            return rotation != .none
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
        guard measurements.items.indices.contains(row) else { return }
        tracker.stop(measurements.items[row].name)
        measurements.remove(at: row)
        table.reloadData()
        syncTrackButton()
    }

    @objc private func clearMeasurements(_ sender: Any?) {
        measurements.removeAll()
        tracker.stopAll()
        history.clear()
        table.reloadData()
        syncTrackButton()
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
                                             width: frameSize.width,
                                             height: frameSize.height)
            setCaptureStatus("Saved \(url.lastPathComponent)"
                             + (recorder.savesCSV ? " (+ CSV)" : ""))
        } catch {
            setCaptureStatus(error.localizedDescription)
        }
    }

    @objc func toggleVideo(_ sender: Any?) {
        defer { syncToolbar() }
        if recorder.isRecordingVideo {
            recorder.stopVideo { [weak self] url in
                self?.recordButton.title = "Record Video"
                self?.setCaptureStatus(url.map { "Saved \($0.lastPathComponent)" }
                                       ?? "Recording stopped.")
            }
            return
        }
        guard isIRRunning, currentFrame() != nil else {
            setCaptureStatus("Start the IR camera and wait for a valid frame first.")
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
        defer { syncToolbar() }
        if recorder.isRunningInterval {
            recorder.stopInterval()
            intervalButton.title = "Start Time-lapse"
            setCaptureStatus("Time-lapse stopped after \(recorder.intervalShotsTaken) shots.")
            return
        }
        guard isIRRunning, currentFrame() != nil else {
            setCaptureStatus("Start the IR camera and wait for a valid frame first.")
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
        defer { syncToolbar() }
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

    private func rejectTemperatureFrame(generation: UUID) {
        frameLock.lock()
        lastCalibrationSample = nil
        lastImage = nil
        lastTemps = []
        lastResults = []
        lastLogRow = [:]
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentCapture(generation) else { return }
            self.setStatus("Temperature unavailable: invalid sensor data or measurement parameters.")
        }
    }

    private func calibrationSample() -> Calibration.Sample? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard Date().timeIntervalSince(lastCalibrationTime) < 2 else { return nil }
        return lastCalibrationSample
    }

    @objc func calibrateTemperature(_ sender: Any?) {
        guard calibrationSample() != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Calibrate against a known temperature"
        alert.informativeText = "Aim at a large, uniform, matte surface whose temperature you "
            + "have measured independently. Keep aiming there when you click Calibrate. "
            + "Do not assume a forehead is 36C or a metal pot is at the water temperature. "
            + "This adjusts the whole scene and keeps any existing two-point scale."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = String(format: "%.1f", referenceTemp)
        alert.accessoryView = field
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let known = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")),
              known.isFinite,
              let sample = calibrationSample() else { return }

        let offset = Calibration.solveShutterOffset(
            startingAt: calibration.shutterOffset, knownTemp: known,
            centerRaw: sample.raw, meta: sample.meta,
            range: measurementRange,
            scale: calibration.scale, bias: calibration.bias)
        guard offset.isFinite,
              let model = sample.modelTemperature(shutterOffset: offset, range: measurementRange),
              abs(calibration.scale * model + calibration.bias - known) < 0.1 else {
            setStatus("Calibration did not converge. Check the reference temperature and try again.")
            return
        }
        calibration.shutterOffset = offset
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
        guard calibrationSample() != nil else { return }

        func ask(_ which: String, _ hint: String) -> (sample: Calibration.Sample, temp: Double)? {
            let alert = NSAlert()
            alert.messageText = "Two-point calibration: \(which) reference"
            alert.informativeText = hint + "\n\nAim the centre crosshair at it, hold "
                + "steady, then type its independently measured surface temperature. "
                + "Keep aiming there when you click Use this. Avoid bare metal and "
                + "assumed forehead temperatures; both references need similar, high emissivity."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Use this")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,
                  let t = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")),
                  t.isFinite, let sample = calibrationSample()
            else { return nil }
            return (sample, t)
        }

        guard let cold = ask("cooler", "Something around room temperature works well.") else { return }
        guard let hot = ask("warmer", "The wider apart the two are, the better the fit.") else { return }

        guard hot.temp - cold.temp >= 5 else {
            setStatus("The warmer reference must be at least 5C above the cooler reference.")
            return
        }
        guard let fit = Calibration.twoPointFit(
            cold: cold.sample, coldTemp: cold.temp, hot: hot.sample, hotTemp: hot.temp,
            shutterOffset: calibration.shutterOffset, range: measurementRange) else {
            setStatus("Cannot fit these references: model readings must increase from cool "
                      + "to warm. Check the targets and let the camera settle, then try again.")
            return
        }
        calibration.setTwoPoint(scale: fit.scale, bias: fit.bias)
        setStatus(String(format: "Two-point calibration: scale %.4f, bias %.1f "
                         + "(from %.1fC and %.1fC).", fit.scale, fit.bias, cold.temp, hot.temp))
    }

    /// Closes the shutter, waits for the signal to actually go flat, averages
    /// a reference, then waits for the shutter to reopen.
    ///
    /// The waits are not decoration: shutter timing on this hardware is
    /// wildly variable (measured 0.15s to 7.6s just to reopen), and capturing
    /// the reference too early yields a reference full of real scene, which
    /// then gets subtracted out of every later frame.
    @objc func runNUC(_ sender: Any?) {
        guard isIRRunning, !nucInProgress else { return }
        frameLock.lock(); let generation = captureGeneration; frameLock.unlock()
        // Replace and drain the normal callback before changing calibration state.
        capture.onFrame = nil
        nucInProgress = true
        setStatus("Recalibrating sensor — closing shutter…")

        var collected: [[UInt16]] = []
        let lock = NSLock()
        var settledFrames = 0
        capture.onFrame = { raw in
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                // The generation check and USB command are atomic with OFF,
                // so a cancelled NUC cannot close the shutter on a new run.
                guard self.closeShutter(for: generation) else { return }
                Thread.sleep(forTimeInterval: 0.25)
                lock.lock(); let enough = collected.count >= 15; lock.unlock()
                if enough { break }
            }

            lock.lock(); let frames = collected; lock.unlock()

            // Let the shutter physically reopen before resuming the view.
            Thread.sleep(forTimeInterval: 2.0)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentCapture(generation) else { return }
                self.capture.onFrame = nil
                let result = self.calibration.buildReference(from: frames)
                self.nucInProgress = false
                self.capture.onFrame = { [weak self] raw in
                    self?.handle(raw: raw, generation: generation)
                }

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
    }

    func shutdown() {
        rgbCamera.stop()
        stopIRCamera()
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
        // A tracked object is marked in the list too, so the state is visible
        // without hunting for the object on the image.
        case "name": text = m.tracked ? m.name + " \u{25CE}" : m.name
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
        syncTrackButton()
        guard measurements.items.indices.contains(row) else {
            emissivityField.stringValue = ""
            return
        }
        emissivityField.stringValue = measurements.items[row].emissivity
            .map { String(format: "%.2f", $0) } ?? ""
    }
}
