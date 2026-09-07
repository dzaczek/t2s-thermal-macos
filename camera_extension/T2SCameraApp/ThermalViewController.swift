import Cocoa
import AVFoundation

/// The live thermal view, its measurement tools and the capture controls.
final class ThermalViewController: NSViewController, NSMenuItemValidation, NSTextFieldDelegate,
                                  NSMenuDelegate {

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

    /// Air temperature and humidity, which the radiometric model needs and
    /// which give the dew point. Changes are pushed to the camera, since the
    /// model reads them back out of the frame metadata.
    private var ambient = Ambient()
    var showDewPoint = false
    /// A surface this close to the dew point is already worth flagging: the
    /// reading has its own error, and damp does not wait for the exact number.
    private var dewPointMargin = 1.0

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
    private var rawToggle = NSButton()
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
    weak var toolbarTrack: NSButton?
    private var trackButton = NSButton()
    private var logButton = NSButton()
    private var logSecondsField = NSTextField()
    private var changeThresholdField = NSTextField()
    private var linePointsField = NSTextField()
    private var airTempField = NSTextField()
    private var humidityField = NSTextField()
    private var dewPointToggle = NSButton()
    private var materialPopup = NSPopUpButton()
    private var referencePopup = NSPopUpButton()
    private var gestureHint = NSTextField(labelWithString: "")
    private var lineModeControl = NSSegmentedControl()
    private var panelView = NSView()
    /// The panel's controls live in here and it scrolls, because they do not
    /// fit. They never did: laid out straight into the panel, the last control
    /// ended up below the bottom edge and the status text was built with a
    /// height of -28, so capture messages had nowhere to appear.
    private let panelScroll = NSScrollView()
    private let panelContent = NSView()
    /// Tall enough for every control with room for the status text underneath.
    private static let panelContentHeight: CGFloat = 996
    private var hasScrolledPanelToTop = false

    /// Latest decoded frame, kept so calibration and capture can act on it.
    private var lastCenterRaw: Double = 0
    private var lastMeta: ThermalDecoder.Metadata?

    /// Written on the capture queue, read on the main queue by the save
    /// actions and the interval timer, so both go through this lock.
    private let frameLock = NSLock()
    private var lastImage: CGImage?
    private var lastTemps: [Double] = []
    /// The sensor's own counts for the latest frame, kept so a capture can be
    /// saved in a form that survives a change of mind about calibration.
    private var lastRawFrame: [UInt16] = []
    /// Temperatures before any rotation, which is the frame the overlay
    /// calibration is expressed in.
    private var lastSensorTemps: [Double] = []
    private var lastResults: [(Measurement, MeasurementResult)] = []
    private var lastLogRow: [String: Double] = [:]

    /// The table shows live numbers, but reloading it at the full 25fps
    /// fights the user for the selection, so it is throttled.
    private var lastTableReload = Date.distantPast

    private var nucInProgress = false

    /// Frames being gathered for a super photo, and the lock that lets the
    /// button start it on the main queue while the capture queue fills it.
    private var superFrames: [[Double]]?
    private let superLock = NSLock()
    /// About a second of frames. Enough shifts to fill a finer grid without
    /// asking anyone to hold a pose.
    private static let superPhotoFrames = 24

    /// The lens, measured from sweeps rather than taken from a datasheet.
    private var optics = Optics.load()

    /// An ordinary camera clamped beside the thermal one, and how its picture
    /// is laid under the thermal image.
    private let visible = VisibleCapture()
    private var overlay = Overlay.load()
    private var visibleCameras: [AVCaptureDevice] = []
    private var visiblePopup = NSPopUpButton()
    private var overlayCalibrateButton = NSButton()
    private var overlayBlendSlider = NSSlider()
    private var overlayWindow: OverlayCalibrationWindow?

    /// A sweep in progress. Frames are added on their own queue: laying one
    /// down costs a couple of milliseconds and the live view should not wait
    /// for it, least of all for the seconds it takes to grow the canvas.
    private var panorama: PanoramaBuilder?
    private let panoramaQueue = DispatchQueue(label: "cat.sysop.t2scamera.panorama")
    private var panoramaButton = NSButton()

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
            self?.measurementsChanged()
        }
        imageView.onAddArea = { [weak self] x, y, w, h in
            self?.measurements.addArea(x: x, y: y, w: w, h: h)
            self?.measurementsChanged()
        }
        imageView.onAddLine = { [weak self] x, y, x2, y2 in
            self?.measurements.addLine(x: x, y: y, x2: x2, y2: y2)
            self?.measurementsChanged()
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
        panelScroll.frame = panelView.bounds
        // A scroll view with unflipped contents opens at the bottom. Put it at
        // the top once, then leave the user's scrolling alone.
        if !hasScrolledPanelToTop, panelScroll.contentSize.height > 0 {
            hasScrolledPanelToTop = true
            let overflow = ThermalViewController.panelContentHeight - panelScroll.contentSize.height
            panelScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, overflow)))
            panelScroll.reflectScrolledClipView(panelScroll.contentView)
        }

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

        airTempField = numberField(String(format: "%.0f", ambient.airTemp), x: 0, y: 0, w: 0,
                                   action: #selector(ambientChanged(_:)))
        humidityField = numberField(String(format: "%.0f", ambient.humidity), x: 0, y: 0, w: 0,
                                    action: #selector(ambientChanged(_:)))

        add("scale min °C", minField, x: 12, w: 62)
        add("scale max °C", maxField, x: 84, w: 62)
        add("alarm > °C", isoAboveField, x: 166, w: 62)
        add("alarm < °C", isoBelowField, x: 238, w: 62)
        add("new spot Δ°C", changeThresholdField, x: 320, w: 62)
        add("air °C", airTempField, x: 402, w: 52)
        add("humidity %", humidityField, x: 464, w: 52)

        dewPointToggle = NSButton(checkboxWithTitle: "Damp risk", target: self,
                                  action: #selector(toggleDewPoint(_:)))
        dewPointToggle.frame = NSRect(x: 528, y: 6, width: 100, height: 22)
        dewPointToggle.toolTip = "Paints every surface at or near the dew point, "
            + "where condensation forms and mould follows."
        controlBar.addSubview(dewPointToggle)

        gestureHint.frame = NSRect(x: 640, y: 8, width: 340, height: 14)
        gestureHint.font = .systemFont(ofSize: 10)
        gestureHint.textColor = .tertiaryLabelColor
        controlBar.addSubview(gestureHint)
        updateGestureHint()

        updateRangeEnabled()
    }

    private func buildPanel() {
        panelView.frame = NSRect(x: 0, y: 0,
                                 width: ThermalViewController.panelWidth,
                                 height: ThermalViewController.contentHeight)
        panelView.wantsLayer = true
        panelView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(panelView)

        let W = ThermalViewController.panelWidth
        panelContent.frame = NSRect(x: 0, y: 0, width: W,
                                    height: ThermalViewController.panelContentHeight)
        panelScroll.documentView = panelContent
        panelScroll.hasVerticalScroller = true
        panelScroll.drawsBackground = false
        panelScroll.autohidesScrollers = true
        panelView.addSubview(panelScroll)

        // Everything below goes into the scrolling content, not the panel.
        let panel = panelContent
        var y = ThermalViewController.panelContentHeight - 28

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

        trackButton = NSButton(title: "Track", target: self,
                               action: #selector(toggleTrackSelected(_:)))
        trackButton.frame = NSRect(x: 12, y: y, width: 84, height: 26)
        trackButton.toolTip = "Sticky: the selected object follows what it was placed on."
        panel.addSubview(trackButton)
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeMeasurement(_:)))
        removeButton.frame = NSRect(x: 102, y: y, width: 88, height: 26)
        panel.addSubview(removeButton)
        let clearButton = NSButton(title: "Clear all", target: self, action: #selector(clearMeasurements(_:)))
        clearButton.frame = NSRect(x: 196, y: y, width: 92, height: 26)
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

        panel.addSubview(label("Compare selected with", x: 12, y: y + 4, w: 140))
        y -= 26
        referencePopup = NSPopUpButton(frame: NSRect(x: 12, y: y, width: W - 24, height: 24))
        referencePopup.target = self
        referencePopup.action = #selector(referenceChanged(_:))
        referencePopup.toolTip = "A difference is what an inspection turns on: "
            + "a warm terminal only means something next to the cold one beside it."
        panel.addSubview(referencePopup)
        rebuildReferencePopup()
        y -= 32

        panel.addSubview(label("Emissivity of selected (blank = global)", x: 12, y: y + 4, w: W - 24))
        y -= 26
        materialPopup = NSPopUpButton(frame: NSRect(x: 12, y: y, width: W - 24, height: 24))
        materialPopup.addItem(withTitle: "Material…")
        for entry in Materials.all {
            materialPopup.addItem(withTitle: String(format: "%@  %.2f", entry.name, entry.emissivity))
        }
        materialPopup.target = self
        materialPopup.action = #selector(materialChosen(_:))
        materialPopup.toolTip = "Typical values. Surface finish matters more than the "
            + "material, so measure against something known when it counts."
        panel.addSubview(materialPopup)
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

        let overlayTitle = NSTextField(labelWithString: "Visible overlay")
        overlayTitle.frame = NSRect(x: 12, y: y, width: W - 24, height: 18)
        overlayTitle.font = .boldSystemFont(ofSize: 12)
        panel.addSubview(overlayTitle)
        y -= 28

        visiblePopup = NSPopUpButton(frame: NSRect(x: 12, y: y, width: W - 24, height: 24))
        visiblePopup.target = self
        visiblePopup.action = #selector(visibleCameraChosen(_:))
        visiblePopup.toolTip = "An ordinary camera clamped beside the thermal one. "
            + "The thermal picture shows where the heat is; this shows what the thing is."
        // Opening the menu is the natural moment to notice a camera plugged
        // in since launch, and NSMenu asks its delegate first.
        visiblePopup.menu?.delegate = self
        panel.addSubview(visiblePopup)
        rebuildVisibleCameraList()
        y -= 32

        overlayCalibrateButton = NSButton(title: "Line Them Up\u{2026}", target: self,
                                          action: #selector(calibrateOverlay(_:)))
        overlayCalibrateButton.frame = NSRect(x: 12, y: y, width: 150, height: 26)
        overlayCalibrateButton.toolTip = "Four points, matched with a fingertip: the thermal "
            + "camera finds it by its warmth and you click it in the webcam picture."
        panel.addSubview(overlayCalibrateButton)
        panel.addSubview(label("blend", x: 172, y: y + 4, w: 40))
        overlayBlendSlider = NSSlider(value: overlay.blend, minValue: 0, maxValue: 1,
                                      target: self, action: #selector(overlayBlendChanged(_:)))
        overlayBlendSlider.frame = NSRect(x: 208, y: y + 2, width: 80, height: 22)
        overlayBlendSlider.toolTip = "All thermal on the left, all webcam on the right."
        panel.addSubview(overlayBlendSlider)
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
        y -= 30

        let superButton = NSButton(title: "Super Photo", target: self,
                                   action: #selector(captureSuperPhoto(_:)))
        superButton.frame = NSRect(x: 12, y: y, width: 130, height: 26)
        superButton.toolTip = "Stacks a second of frames into one larger picture. "
            + "Hold it in your hand: the shake is what makes it work."
        panel.addSubview(superButton)
        rawToggle = NSButton(checkboxWithTitle: "+ raw", target: self,
                             action: #selector(toggleRaw(_:)))
        rawToggle.state = .off
        rawToggle.frame = NSRect(x: 150, y: y + 3, width: 90, height: 22)
        rawToggle.toolTip = "Also save the sensor's own counts, so the capture can be "
            + "decoded again later under different settings."
        panel.addSubview(rawToggle)
        y -= 30

        panoramaButton = NSButton(title: "Panorama (beta)", target: self,
                                  action: #selector(togglePanorama(_:)))
        panoramaButton.frame = NSRect(x: 12, y: y, width: W - 24, height: 26)
        panoramaButton.toolTip = "Beta. Start sweeping, in any direction, and every frame is "
            + "laid onto one growing picture. Press again to finish. Rolling the camera "
            + "is the one movement it cannot follow."
        panel.addSubview(panoramaButton)
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

        // Ask before looking. Without permission macOS does not merely refuse
        // frames, it hides the camera from device discovery altogether -- so
        // the app reported "camera not found" and, never having asked, never
        // got the chance to be allowed. It only ever worked because the
        // permission happened to have been granted already, and it came back
        // the moment the app was signed with a different certificate, which
        // macOS treats as a different app.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginCapture()
        case .notDetermined:
            setStatus("Waiting for permission to use the camera\u{2026}")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.beginCapture() } else { self.reportCameraDenied() }
                }
            }
        default:
            reportCameraDenied()
        }
    }

    private func beginCapture() {
        do {
            try capture.start()
            setStatus(calibration.isCalibrated
                ? String(format: "Running. Using saved calibration (shutter offset %.2f).", calibration.shutterOffset)
                : "Running, but not calibrated - press \u{2318}K aiming at something whose temperature you know.")
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    private func reportCameraDenied() {
        setStatus("No permission to use the camera. Turn it on in System Settings \u{25B8} "
                  + "Privacy & Security \u{25B8} Camera, then start the app again.")
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
        var meta = ThermalDecoder.metadata(from: raw)
        // The air settings are applied here rather than written to the camera.
        // The model runs on this side anyway, and the firmware only reliably
        // accepts one parameter change per session -- so pushing them would
        // work once and then quietly stop, which is worse than not trying.
        // Humidity goes in as a fraction, which is what the vapour-content
        // formula in the decoder expects.
        meta.airTemp = ambient.airTemp
        meta.reflectedTemp = ambient.reflectedTemp
        meta.humidity = ambient.humidity / 100
        meta.distance = ambient.distance
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
        let unrotatedSmoothed = ThermalProcessor.smooth(asUInt16, width: W, height: H)
        let smoothed = turn.apply(unrotatedSmoothed, width: W, height: H)

        // Frames whose metadata cannot drive the model are skipped outright;
        // rendering them would publish a 0C image and poison the readouts.
        guard let table = ThermalDecoder.temperatureTable(
                meta: meta, shutterOffset: calibration.shutterOffset,
                range: measurementRange,
                scale: calibration.scale, bias: calibration.bias) else { return }
        let temps = lookup(smoothed, in: table)

        // The calibration pairs a webcam pixel with a *sensor* pixel, so the
        // untuned field is what it has to be matched against. When nothing is
        // turned the two are the same array and there is nothing to redo.
        let sensorTemps = turn == .none ? temps : lookup(unrotatedSmoothed, in: table)
        frameLock.lock()
        lastSensorTemps = sensorTemps
        frameLock.unlock()

        // The webcam picture is brought into sensor coordinates and then
        // turned with everything else, so rotating the view cannot put the
        // two pictures out of step.
        var visibleLayer: [Double]?
        if overlay.isOn, let picture = visible.currentFrame(),
           let aligned = overlay.aligned(picture, thermalWidth: W, thermalHeight: H) {
            visibleLayer = turn.apply(aligned, width: W, height: H)
        }

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
        let results: [(Measurement, MeasurementResult)] = items.map { m in
            let source = m.emissivity.flatMap { perEmissivity[$0] } ?? temps
            return (m, MeasurementEngine.evaluate(m, temps: source, width: fw, height: fh,
                                                  lineExtremeCount: lineExtremeCount,
                                                  lineExtremeMode: lineExtremeMode))
        }

        let deltas = MeasurementStore.deltas(from: results, airTemp: ambient.airTemp)

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
        // The difference is usually the number the log is being kept for.
        for (name, delta) in deltas { row["\(name)_delta"] = delta }

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
            dewPointThreshold: showDewPoint ? ambient.dewPoint + dewPointMargin : nil,
            dewPoint: showDewPoint ? ambient.dewPoint : nil,
            deltas: deltas,
            visible: visibleLayer,
            visibleBlend: overlay.blend,
            recordingNote: note,
            showsMax: showMax,
            showsMin: showMin,
            showsCentre: showCentre,
            changes: changes,
            lostTracks: lostTracks)

        let tBeforeRender = CFAbsoluteTimeGetCurrent()
        guard let image = ThermalRenderer.render(frame) else { return }
        let tRendered = CFAbsoluteTimeGetCurrent()

        lastCenterRaw = smoothed[centerIndex]
        lastMeta = meta
        frameLock.lock()
        lastImage = image
        lastTemps = temps
        lastRawFrame = raw
        lastResults = results
        lastLogRow = row
        frameLock.unlock()

        collectSuperPhotoFrame(temps, width: fw, height: fh)
        collectPanoramaFrame(temps, width: fw, height: fh)

        if publishToVirtualCam { virtualCam.publish(image) }
        let tPublished = CFAbsoluteTimeGetCurrent()
        recorder.appendVideoFrame(image)
        Profile.shared.record(compute: tBeforeRender - tStart,
                              render: tRendered - tBeforeRender,
                              publish: tPublished - tRendered,
                              total: CFAbsoluteTimeGetCurrent() - tStart)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
        if Thread.isMainThread { captureStatus.stringValue = text }
        else { DispatchQueue.main.async { self.captureStatus.stringValue = text } }
    }

    private func currentFrame() -> (CGImage, [Double])? {
        frameLock.lock(); defer { frameLock.unlock() }
        guard let image = lastImage else { return nil }
        return (image, lastTemps)
    }

    private func currentRawFrame() -> [UInt16] {
        frameLock.lock(); defer { frameLock.unlock() }
        return lastRawFrame
    }

    /// What the raw file needs to say about itself for the counts in it to
    /// mean anything later.
    private func rawInfo() -> [String: Any] {
        [
            "width": ThermalCapture.width,
            "imageRows": ThermalCapture.imageHeight,
            "totalRows": ThermalCapture.fullHeight,
            "range": measurementRange == .high ? "high" : "normal",
            "shutterOffset": calibration.shutterOffset,
            "scale": calibration.scale,
            "bias": calibration.bias,
            "calibrated": calibration.isCalibrated,
            "rotationQuarterTurns": rotation.rawValue,
            "emissivity": 0.95,
            "airTemp": ambient.airTemp,
            "humidityPercent": ambient.humidity,
            "reflectedTemp": ambient.reflectedTemp,
            "distanceMetres": ambient.distance,
            "app": "T2SCamera \(About.version) (\(About.build))",
            "note": "Rows beyond imageRows are the camera's own metadata, "
                + "not picture. Rotation is not applied to these samples."
        ]
    }

    // MARK: - Super photo

    /// Adds a frame to a stack being gathered, and finishes when there are
    /// enough. Runs on the capture queue.
    private func collectSuperPhotoFrame(_ temps: [Double], width: Int, height: Int) {
        superLock.lock()
        guard superFrames != nil else { superLock.unlock(); return }
        superFrames?.append(temps)
        let gathered = superFrames?.count ?? 0
        var finished: [[Double]]?
        if gathered >= ThermalViewController.superPhotoFrames {
            finished = superFrames
            superFrames = nil
        }
        superLock.unlock()

        if let finished {
            buildSuperPhoto(finished, width: width, height: height)
        } else {
            setCaptureStatus("Super photo: \(gathered) of "
                             + "\(ThermalViewController.superPhotoFrames) frames\u{2026}")
        }
    }

    // MARK: - Visible overlay

    /// Fills the camera list. Rebuilt on demand rather than watched: cameras
    /// are plugged in rarely and a stale list costs one reopen of the menu.
    private func rebuildVisibleCameraList() {
        visibleCameras = VisibleCapture.candidates()
        visiblePopup.removeAllItems()
        visiblePopup.addItem(withTitle: "No visible camera")
        for device in visibleCameras {
            visiblePopup.addItem(withTitle: device.localizedName)
        }
        if let name = visible.deviceName,
           let index = visibleCameras.firstIndex(where: { $0.localizedName == name }) {
            visiblePopup.selectItem(at: index + 1)
        } else {
            visiblePopup.selectItem(at: 0)
        }
        syncOverlayControls()
    }

    @objc private func visibleCameraChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard index >= 0, index < visibleCameras.count else {
            visible.stop()
            overlay.isOn = false
            syncOverlayControls()
            setCaptureStatus("Visible overlay off.")
            return
        }
        do {
            try visible.start(device: visibleCameras[index])
            overlay.isOn = true
            syncOverlayControls()
            setCaptureStatus(overlay.isCalibrated
                ? "Overlaying \(visibleCameras[index].localizedName)."
                : "\(visibleCameras[index].localizedName) is running, but the two cameras have "
                  + "not been lined up yet \u{2014} press Line Them Up.")
        } catch {
            visiblePopup.selectItem(at: 0)
            setCaptureStatus(error.localizedDescription)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === visiblePopup.menu else { return }
        rebuildVisibleCameraList()
    }

    @objc private func overlayBlendChanged(_ sender: NSSlider) {
        overlay.blend = sender.doubleValue
        overlay.save()
    }

    private func syncOverlayControls() {
        overlayCalibrateButton.isEnabled = visible.isRunning
        overlayBlendSlider.isEnabled = visible.isRunning && overlay.isCalibrated
        overlayBlendSlider.doubleValue = overlay.blend
    }

    @objc func calibrateOverlay(_ sender: Any?) {
        guard visible.isRunning else {
            setCaptureStatus("Choose a visible camera first.")
            return
        }
        let window = overlayWindow ?? OverlayCalibrationWindow()
        overlayWindow = window
        window.visibleFrameProvider = { [weak self] in self?.visible.currentFrame() }
        // Everything the window gets is in sensor coordinates, before any
        // rotation: it does its own turning for viewing, and a calibration
        // built that way survives the picture being turned afterwards.
        window.thermalProvider = { [weak self] in
            guard let self else { return nil }
            self.frameLock.lock()
            let temps = self.lastSensorTemps
            self.frameLock.unlock()
            let w = ThermalCapture.width, h = ThermalCapture.imageHeight
            guard temps.count == w * h else { return nil }
            return OverlayCalibrationWindow.ThermalPreview(
                grey: ThermalProcessor.normalize(temps).map(Double.init),
                width: w, height: h,
                warm: Overlay.warmPoint(temps, width: w, height: h))
        }
        window.onFinished = { [weak self] homography in
            guard let self else { return }
            self.overlay.homography = homography
            self.overlay.isOn = true
            self.overlay.save()
            self.syncOverlayControls()
            self.setCaptureStatus("The two cameras are lined up. Use the blend slider to mix "
                                  + "them. Do it again if you move either one.")
        }
        window.showWindow(nil)
    }

    // MARK: - Panorama

    /// Hands a frame to a sweep in progress, off the capture queue.
    private func collectPanoramaFrame(_ temps: [Double], width: Int, height: Int) {
        guard panorama != nil else { return }
        panoramaQueue.async { [weak self] in
            guard let self, let builder = self.panorama else { return }
            let placed = builder.add(temps)
            if builder.isFull {
                self.setCaptureStatus("Panorama is as large as it can get \u{2014} finishing.")
                self.finishPanorama()
                return
            }
            guard placed else { return }
            let size = builder.canvasSize
            self.setCaptureStatus(String(
                format: "Panorama: %d frames, %d dropped, %dx%d so far, moved %.0f px. "
                        + "Press again to finish.",
                builder.framesUsed, builder.framesRejected, size.width, size.height,
                builder.travel))
        }
    }

    @objc func togglePanorama(_ sender: Any?) {
        if panorama != nil {
            finishPanorama()
            return
        }
        let size = frameSize
        panoramaQueue.sync {
            panorama = PanoramaBuilder(width: size.width, height: size.height, optics: optics)
        }
        panoramaButton.title = "Finish Panorama"
        setCaptureStatus(String(
            format: "Panorama started. Sweep slowly \u{2014} any direction, and back over the "
                    + "same ground if you like. Keep it the same way up: rolling it is the one "
                    + "movement this cannot follow. Lens: %.0f px, %.0f\u{00B0} across%@. "
                    + "Press again when you are done.",
            optics.focalPixels, optics.horizontalFieldOfView(width: size.width),
            optics.isMeasured ? "" : " (still the starting guess)"))
    }

    private func finishPanorama() {
        panoramaQueue.async { [weak self] in
            guard let self, let builder = self.panorama else { return }
            self.panorama = nil
            DispatchQueue.main.async { self.panoramaButton.title = "Panorama (beta)" }

            guard let result = builder.finish() else {
                self.setCaptureStatus("Panorama came to nothing: too few frames could be placed. "
                                      + "It needs something with contrast to line up on, and a "
                                      + "sweep slow enough to overlap.")
                return
            }
            self.setCaptureStatus(String(format: "Panorama: drawing %dx%d\u{2026}",
                                         result.width, result.height))
            self.saveStacked(result, nameHint: "T2S_pano", what: "Panorama")

            // The sweep also says what the lens is. Saved rather than applied
            // now: the frames just laid down were warped with the old value,
            // and changing it half way would have made them disagree.
            if let measured = builder.measuredFocal {
                let sensor = self.frameSize
                var updated = self.optics
                updated.focalPixels = measured
                updated.save()
                DispatchQueue.main.async { self.optics = updated }
                self.setCaptureStatus(String(
                    format: "This sweep measured the lens at %.0f px, %.0f\u{00B0} across. "
                            + "Saved \u{2014} the next panorama will use it.",
                    measured, updated.horizontalFieldOfView(width: sensor.width)))
            }
        }
    }

    @objc func captureSuperPhoto(_ sender: Any?) {
        superLock.lock()
        let alreadyRunning = superFrames != nil
        if !alreadyRunning { superFrames = [] }
        superLock.unlock()
        guard !alreadyRunning else { return }
        setCaptureStatus("Super photo: hold the camera in your hand and let it drift, or "
                         + "pan it slowly for a wider picture. Do not twist it.")
    }

    /// Stacks the gathered frames and saves the result. The stacking is not
    /// quick, so it stays off the capture queue and the live view keeps
    /// running while it happens.
    private func buildSuperPhoto(_ frames: [[Double]], width: Int, height: Int) {
        setCaptureStatus("Super photo: lining up \(frames.count) frames\u{2026}")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let stacked = SuperPhoto.stack(frames, width: width, height: height) else {
                self.setCaptureStatus("Super photo failed: the frames could not be lined up. "
                                      + "A blank wall has nothing to line up on, the camera must "
                                      + "not be turned as it moves, and a burst that travels this "
                                      + "far wants Panorama instead.")
                return
            }
            self.saveStacked(stacked, nameHint: "T2S_super", what: "Super photo")
        }
    }

    /// Draws and saves a stacked picture, whether it came from a burst or a
    /// sweep. They differ only in how the frames were gathered; from here on
    /// there is nothing to tell apart.
    private func saveStacked(_ stacked: SuperPhoto.Result, nameHint: String, what: String) {
        let extremes = ThermalProcessor.extremes(stacked.values)
        let scaleMin = manualRange ? manualMin : extremes.minValue
        let scaleMax = manualRange ? manualMax : extremes.maxValue
        let frame = ThermalRenderer.Frame(
            temperatures: stacked.values,
            normalized: ThermalProcessor.normalize(stacked.values, from: scaleMin, to: scaleMax),
            imageWidth: stacked.width,
            imageHeight: stacked.height,
            extremes: extremes,
            centerTemp: stacked.values[(stacked.height / 2) * stacked.width + stacked.width / 2],
            palette: palette,
            calibrationNote: calibrationNote,
            scaleMin: scaleMin,
            scaleMax: scaleMax,
            // The objects on screen are placed in sensor pixels and this
            // picture is a different size and often a different view, so
            // carrying them over would put them on the wrong things.
            measurements: [],
            dewPointThreshold: showDewPoint ? ambient.dewPoint + dewPointMargin : nil,
            dewPoint: showDewPoint ? ambient.dewPoint : nil,
            showsMax: showMax,
            showsMin: showMin,
            showsCentre: showCentre)

        guard let image = ThermalRenderer.render(frame) else {
            setCaptureStatus("\(what) failed while drawing.")
            return
        }
        do {
            let url = try recorder.savePhoto(image, temperatures: stacked.values,
                                             width: stacked.width, height: stacked.height,
                                             nameHint: nameHint)
            let kind = stacked.travel > 3
                ? String(format: "moved %.0f px", stacked.travel)
                : "stacked in place"
            setCaptureStatus(String(
                format: "%@ saved as %@ \u{2014} %dx%d from %d frames (%d dropped), %@%@.",
                what, url.lastPathComponent, stacked.width, stacked.height,
                stacked.framesUsed, stacked.framesRejected, kind,
                stacked.coverage < 0.995
                    ? String(format: ", %.0f%% covered", stacked.coverage * 100) : ""))
        } catch {
            setCaptureStatus(error.localizedDescription)
        }
    }

    // MARK: - Image actions

    @objc private func noop(_ sender: Any?) {}

    /// Takes numeric fields as they are typed.
    ///
    /// NSTextField only sends its action on Return. The fields were given a
    /// delegate so that a value typed and then clicked away from would still
    /// count, but the delegate method was never written, so `tidy: false` had
    /// no caller and typing 9 into "mark N points" did nothing until you
    /// pressed Return. The action still fires on Return, and that is where
    /// the value gets tidied up and clamped.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === linePointsField { applyLinePoints(tidy: false) }
        else if field === changeThresholdField { applyChangeThreshold(tidy: false) }
        else if field === minField || field === maxField { applyRange(tidy: false) }
        else if field === isoAboveField || field === isoBelowField { isothermChanged(field) }
        else if field === airTempField || field === humidityField { applyAmbient(tidy: false) }
    }

    @objc private func ambientChanged(_ sender: Any?) {
        applyAmbient(tidy: true)
    }

    private func applyAmbient(tidy: Bool) {
        let before = ambient
        if let v = Double(airTempField.stringValue.replacingOccurrences(of: ",", with: ".")) {
            ambient.airTemp = max(-40, min(80, v))
        }
        if let v = Double(humidityField.stringValue.replacingOccurrences(of: ",", with: ".")) {
            ambient.humidity = max(1, min(100, v))
        }
        // Reflected temperature is not asked for separately: for the ordinary
        // indoor case it is the air temperature, and a wrong guess here does
        // less harm than another box to fill in.
        ambient.reflectedTemp = ambient.airTemp
        if tidy {
            airTempField.stringValue = String(format: "%.0f", ambient.airTemp)
            humidityField.stringValue = String(format: "%.0f", ambient.humidity)
        }
        guard ambient != before else { return }
        setCaptureStatus(String(format: "Air %.0f\u{00B0}C at %.0f%% humidity \u{2014} dew point %.1f\u{00B0}C.",
                                ambient.airTemp, ambient.humidity, ambient.dewPoint))
    }

    @objc func toggleDewPoint(_ sender: Any?) {
        showDewPoint.toggle()
        dewPointToggle.state = showDewPoint ? .on : .off
        setCaptureStatus(showDewPoint
            ? String(format: "Damp risk on. Anything at or below %.1f\u{00B0}C is painted "
                     + "\u{2014} dew point %.1f\u{00B0}C plus a %.0f\u{00B0} margin.",
                     ambient.dewPoint + dewPointMargin, ambient.dewPoint, dewPointMargin)
            : "Damp risk off.")
    }

    @objc private func materialChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1     // 0 is the "Material…" prompt
        guard index >= 0, index < Materials.all.count else { return }
        emissivityField.stringValue = String(format: "%.2f", Materials.all[index].emissivity)
        applyEmissivity(sender)
        sender.selectItem(at: 0)
    }

    @objc private func referenceChanged(_ sender: NSPopUpButton) {
        let row = table.selectedRow
        guard measurements.items.indices.contains(row) else {
            setCaptureStatus("Select a measurement in the list first.")
            rebuildReferencePopup()
            return
        }
        let title = sender.titleOfSelectedItem ?? ""
        measurements.setReference(title == "nothing" ? nil : title, at: row)
        setCaptureStatus(title == "nothing"
            ? "\(measurements.items[row].name) is on its own again."
            : "\(measurements.items[row].name) is now read as a difference against \(title).")
    }

    /// Everything that has to catch up after an object is added or removed.
    /// The list of comparisons in particular must not go stale: it would
    /// otherwise offer an object that no longer exists.
    private func measurementsChanged() {
        table.reloadData()
        rebuildReferencePopup()
        syncTrackButton()
    }

    /// The list of things the selected object can be compared against: the
    /// air, or any other object. Rebuilt whenever the objects change, since a
    /// stale list would offer something that no longer exists.
    private func rebuildReferencePopup() {
        let row = table.selectedRow
        let selected = measurements.items.indices.contains(row) ? measurements.items[row] : nil
        referencePopup.removeAllItems()
        referencePopup.addItem(withTitle: "nothing")
        referencePopup.addItem(withTitle: Measurement.airReference)
        for m in measurements.items where m.name != selected?.name {
            referencePopup.addItem(withTitle: m.name)
        }
        referencePopup.selectItem(withTitle: selected?.reference ?? "nothing")
        referencePopup.isEnabled = selected != nil
    }

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
        trackButton.title = tracked ? "Untrack" : "Track"
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
        case #selector(toggleDewPoint(_:)):
            item.state = showDewPoint ? .on : .off
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
        measurementsChanged()
    }

    @objc private func clearMeasurements(_ sender: Any?) {
        measurements.removeAll()
        tracker.stopAll()
        history.clear()
        measurementsChanged()
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

    @objc private func toggleRaw(_ sender: NSButton) {
        recorder.savesRaw = (sender.state == .on)
        setCaptureStatus(recorder.savesRaw
            ? "Saving the sensor's own counts beside each photo, about 100 KB a shot."
            : "Raw sensor counts are no longer saved.")
    }

    @objc func savePhoto(_ sender: Any?) {
        guard let (image, temps) = currentFrame() else {
            setCaptureStatus("No frame to save yet.")
            return
        }
        do {
            let url = try recorder.savePhoto(image, temperatures: temps,
                                             width: frameSize.width,
                                             height: frameSize.height,
                                             raw: currentRawFrame(),
                                             rawInfo: rawInfo())
            var extras: [String] = []
            if recorder.savesCSV { extras.append("CSV") }
            if recorder.savesRaw { extras.append("raw") }
            setCaptureStatus("Saved \(url.lastPathComponent)"
                             + (extras.isEmpty ? "" : " (+ \(extras.joined(separator: ", ")))"))
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
            centerRaw: lastCenterRaw, meta: meta,
            range: measurementRange,
            scale: calibration.scale, bias: calibration.bias)
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
        rebuildReferencePopup()
        guard measurements.items.indices.contains(row) else {
            emissivityField.stringValue = ""
            return
        }
        emissivityField.stringValue = measurements.items[row].emissivity
            .map { String(format: "%.2f", $0) } ?? ""
    }
}
