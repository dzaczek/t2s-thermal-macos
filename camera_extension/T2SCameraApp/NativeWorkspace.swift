import Cocoa

/// Native window furniture only. The controller and renderer still own all
/// measurements, histories and recording sessions when the workspace changes.
final class NativeWorkspace: NSView {
    enum Mode: Int, CaseIterable {
        case inspection, electronics, analysis, presentation
        var title: String {
            ["Inspection", "Electronics", "Analysis", "Presentation"][rawValue]
        }
    }

    private(set) var mode: Mode = .inspection
    var onLayoutChanged: (() -> Void)?
    let imageHost = NSView()
    let irPower = NSButton(title: "IR OFF · Start", target: nil, action: nil)
    private let modeControl: NSSegmentedControl
    private let modeHint = NSTextField(labelWithString: "")
    private let tools: NSStackView
    private let display: NSStackView
    private let capture: NSStackView
    private let quickCapture: NSStackView
    private let inspectorToggle = NSButton(title: "Inspector", target: nil, action: nil)
    private let captureToggle = NSButton(title: "Capture settings", target: nil, action: nil)
    private let sidebarCards: [NSView]
    private var inspectorPreferences: [Mode: Bool] = [:]
    private var capturePreferences: [Mode: Bool] = [:]
    var showsInspector: Bool { inspectorPreferences[mode] ?? (mode != .presentation) }
    var showsCaptureSettings: Bool { capturePreferences[mode] ?? (mode == .electronics || mode == .analysis) }
    private let sidebar = NSScrollView()
    private let document = WorkspaceDocument()
    private let sidebarStack: NSStackView
    private let captureStatus: NSTextField
    private let status: NSTextField

    init(tools: [NSView], display: [NSView], sidebar: [NSView], capture: [NSView], quickCapture: [NSView],
         status: NSTextField, captureStatus: NSTextField) {
        modeControl = NSSegmentedControl(labels: Mode.allCases.map(\.title),
                                         trackingMode: .selectOne, target: nil, action: nil)
        self.tools = Self.stack(tools, vertical: true)
        self.display = Self.stack(display, vertical: true)
        self.capture = Self.stack(capture)
        self.quickCapture = Self.stack(quickCapture)
        self.sidebarCards = sidebar
        self.capture.distribution = .fillEqually
        self.sidebarStack = Self.stack(sidebar, vertical: true)
        self.status = status
        self.captureStatus = captureStatus
        super.init(frame: .zero)

        wantsLayer = true
        modeControl.target = self
        modeControl.action = #selector(changeMode(_:))
        modeControl.selectedSegment = 0
        modeControl.setAccessibilityLabel("Workspace mode")
        for button in [inspectorToggle, captureToggle] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.target = self
        }
        inspectorToggle.action = #selector(toggleInspector(_:))
        captureToggle.action = #selector(toggleCapture(_:))
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.textColor = .secondaryLabelColor
        modeHint.lineBreakMode = .byTruncatingTail
        self.tools.alignment = .leading
        self.display.alignment = .leading
        sidebarStack.alignment = .leading
        for card in sidebar {
            card.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }
        self.sidebar.drawsBackground = false
        self.sidebar.hasVerticalScroller = true
        self.sidebar.autohidesScrollers = true
        self.sidebar.documentView = document
        sidebarStack.translatesAutoresizingMaskIntoConstraints = true
        document.addSubview(sidebarStack)
        if sidebarCards.count == 3 {
            sidebarStack.setViews([sidebarCards[1], sidebarCards[0], sidebarCards[2]], in: .top)
        }
        irPower.bezelStyle = .rounded
        irPower.setAccessibilityLabel("IR camera on or off")
        for child in [modeControl, modeHint, irPower, inspectorToggle, captureToggle,
                      self.tools, self.display, self.capture, self.quickCapture,
                      self.sidebar, imageHost, status, captureStatus] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        imageHost.wantsLayer = true
        imageHost.layer?.cornerRadius = 10
        imageHost.layer?.masksToBounds = true
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        captureStatus.font = .systemFont(ofSize: 11)
        captureStatus.textColor = .secondaryLabelColor
        captureStatus.lineBreakMode = .byTruncatingTail
        captureStatus.maximumNumberOfLines = 1
        updateHint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    static func stack(_ views: [NSView], vertical: Bool = false) -> NSStackView {
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false }
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = 8
        stack.detachesHiddenViews = true
        return stack
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        mode = Mode(rawValue: sender.selectedSegment) ?? .inspection
        let order = mode == .inspection && sidebarCards.count == 3
            ? [sidebarCards[1], sidebarCards[0], sidebarCards[2]] : sidebarCards
        sidebarStack.setViews(order, in: .top)
        sidebar.contentView.scroll(to: .zero)
        updateHint()
        needsLayout = true
        onLayoutChanged?()
    }

    @objc private func toggleInspector(_ sender: NSButton) {
        inspectorPreferences[mode] = !showsInspector
        needsLayout = true
    }

    @objc private func toggleCapture(_ sender: NSButton) {
        capturePreferences[mode] = !showsCaptureSettings
        needsLayout = true
    }

    private func updateHint() {
        modeHint.stringValue = [
            "Large image · sensor settings first · quick capture below",
            "Expanded measurement inspector · tracking and line profiles · full capture controls",
            "Image + large live history chart · on-image plots remain enabled if selected",
            "Maximum image area · inspector and capture settings available with one click"
        ][mode.rawValue]
    }

    /// Modes affect geometry; none of them modify plot selection or stop a session.
    var preferredChartFraction: CGFloat { mode == .analysis ? 0.52 : 0.25 }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let sidebarWidth: CGFloat = showsInspector ? (mode == .electronics ? 410 : 332) : 0
        let left: CGFloat = mode == .presentation && !showsInspector ? 16 : 94
        let mainWidth = max(300, width - left - sidebarWidth - (showsInspector ? 32 : 16))
        let captureHeight: CGFloat = showsCaptureSettings ? 174 : 38
        let bottom: CGFloat = captureHeight + 64
        let displayHeight: CGFloat = 74
        let top: CGFloat = 82
        let mainHeight = max(150, height - bottom - displayHeight - top)

        modeControl.frame = NSRect(x: 16, y: height - 42, width: 484, height: 28)
        irPower.frame = NSRect(x: width - 408, y: height - 42, width: 132, height: 28)
        modeHint.frame = NSRect(x: 18, y: height - 65, width: width - 36, height: 18)
        inspectorToggle.frame = NSRect(x: width - 270, y: height - 42, width: 110, height: 28)
        captureToggle.frame = NSRect(x: width - 150, y: height - 42, width: 134, height: 28)
        inspectorToggle.state = showsInspector ? .on : .off
        captureToggle.state = showsCaptureSettings ? .on : .off
        tools.isHidden = mode == .presentation && !showsInspector
        sidebar.isHidden = !showsInspector
        capture.isHidden = !showsCaptureSettings
        quickCapture.isHidden = showsCaptureSettings
        let toolsHeight = min(mainHeight, tools.fittingSize.height)
        tools.frame = NSRect(x: 12, y: height - top - toolsHeight,
                             width: 70, height: toolsHeight)
        imageHost.frame = NSRect(x: left, y: bottom + displayHeight,
                                 width: mainWidth, height: mainHeight)
        display.frame = NSRect(x: left, y: bottom + 3, width: mainWidth, height: displayHeight - 8)
        sidebar.frame = NSRect(x: width - sidebarWidth - 16, y: bottom,
                               width: max(300, sidebarWidth), height: height - top - bottom)
        let docWidth = sidebar.contentSize.width
        sidebarStack.setFrameSize(NSSize(width: docWidth, height: sidebarStack.fittingSize.height))
        sidebarStack.layoutSubtreeIfNeeded()
        let docHeight = max(sidebar.contentSize.height, sidebarStack.fittingSize.height)
        document.frame = NSRect(x: 0, y: 0, width: docWidth, height: docHeight)
        sidebarStack.frame = NSRect(x: 0, y: 0, width: docWidth, height: sidebarStack.fittingSize.height)
        capture.frame = NSRect(x: 16, y: 56, width: width - 32, height: 174)
        quickCapture.frame = NSRect(x: 18, y: 56, width: width - 36, height: 36)
        captureStatus.frame = NSRect(x: 18, y: 32, width: width - 36, height: 18)
        status.frame = NSRect(x: 18, y: 9, width: width - 36, height: 17)
        onLayoutChanged?()
    }
}

private final class WorkspaceDocument: NSView {
    override var isFlipped: Bool { true }
}

final class WorkspaceCard: NSView {
    init(_ heading: String, views: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 9
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let stack = NativeWorkspace.stack([title] + views, vertical: true)
        stack.alignment = .leading
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
