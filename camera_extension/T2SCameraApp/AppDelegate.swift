import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var thermalController: ThermalViewController!
    private var extensionController: ExtensionInstallerWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        buildMenu()

        thermalController = ThermalViewController()
        // Canonical programmatic window creation: pass styleMask to the
        // initializer rather than mutating it after the fact.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: ThermalViewController.contentWidth,
                                height: ThermalViewController.contentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "T2S+ Thermal Camera \(About.version) (\(About.build))"
        window.contentViewController = thermalController
        window.setContentSize(NSSize(width: ThermalViewController.contentWidth,
                                     height: ThermalViewController.contentHeight))
        // Below this the side panel and the control bar stop fitting.
        window.contentMinSize = NSSize(width: ThermalViewController.panelWidth + 460, height: 420)
        // Quick access to the settings that get changed constantly. The menu
        // still holds everything, but a toolbar is one click and, sitting in
        // the title bar, costs the video area nothing.
        let toolbar = NSToolbar(identifier: "T2SCameraToolbar")
        toolbar.delegate = thermalController
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--install-extension") {
            showExtensionInstaller(nil)
        }
        // The camera extension hard-codes the frame size, so it must be
        // replaced whenever the render resolution changes -- otherwise it
        // rejects the larger frames and publishes flat grey.
        if CommandLine.arguments.contains("--activate-extension") {
            showExtensionInstaller(nil)
            extensionController?.activate(nil)
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        /// Menu actions target the responder chain, so the view controller
        /// receives them and supplies the checkmarks via validateMenuItem.
        func item(_ menu: NSMenu, _ title: String, _ action: Selector,
                  _ key: String = "", tag: Int = 0) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.tag = tag
            menu.addItem(i)
        }

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        item(appMenu, "About T2S+ Thermal Camera", #selector(showAbout(_:)))
        appMenu.addItem(.separator())
        item(appMenu, "Install / Manage Camera Extension…", #selector(showExtensionInstaller(_:)))
        appMenu.addItem(.separator())
        item(appMenu, "Hide", #selector(NSApplication.hide(_:)), "h")
        item(appMenu, "Quit", #selector(NSApplication.terminate(_:)), "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let captureItem = NSMenuItem()
        let capture = NSMenu(title: "Capture")
        item(capture, "Save Photo", #selector(ThermalViewController.savePhoto(_:)), "s")
        item(capture, "Start Recording", #selector(ThermalViewController.toggleVideo(_:)), "R")
        item(capture, "Start Time-lapse", #selector(ThermalViewController.toggleInterval(_:)))
        item(capture, "Start CSV Log", #selector(ThermalViewController.toggleLog(_:)))
        capture.addItem(.separator())
        item(capture, "Open Output Folder", #selector(ThermalViewController.openOutputFolder(_:)), "O")
        captureItem.submenu = capture
        mainMenu.addItem(captureItem)

        let cameraItem = NSMenuItem()
        let camera = NSMenu(title: "Camera")
        item(camera, "Calibrate Temperature…",
             #selector(ThermalViewController.calibrateTemperature(_:)), "k")
        item(camera, "Recalibrate Sensor (NUC)", #selector(ThermalViewController.runNUC(_:)), "r")
        camera.addItem(.separator())

        let measRange = NSMenu(title: "Measurement Range")
        item(measRange, "Normal (−20 to 120 °C)",
             #selector(ThermalViewController.selectRange(_:)), "", tag: 0)
        item(measRange, "High (−20 to 450 °C)",
             #selector(ThermalViewController.selectRange(_:)), "", tag: 1)
        let measRangeItem = NSMenuItem(title: "Measurement Range", action: nil, keyEquivalent: "")
        measRangeItem.submenu = measRange
        camera.addItem(measRangeItem)

        camera.addItem(.separator())
        item(camera, "Publish to Virtual Camera",
             #selector(ThermalViewController.toggleVirtualCamera(_:)))
        cameraItem.submenu = camera
        mainMenu.addItem(cameraItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let palette = NSMenu(title: "Palette")
        for (i, p) in Palette.allCases.enumerated() {
            item(palette, p.displayName, #selector(ThermalViewController.selectPalette(_:)),
                 "\(i + 1)", tag: i)
        }
        let paletteItem = NSMenuItem(title: "Palette", action: nil, keyEquivalent: "")
        paletteItem.submenu = palette
        viewMenu.addItem(paletteItem)

        let tool = NSMenu(title: "Drag Creates")
        item(tool, "Area", #selector(ThermalViewController.selectDragTool(_:)), "", tag: 0)
        item(tool, "Line", #selector(ThermalViewController.selectDragTool(_:)), "", tag: 1)
        let toolItem = NSMenuItem(title: "Drag Creates", action: nil, keyEquivalent: "")
        toolItem.submenu = tool
        viewMenu.addItem(toolItem)

        let markers = NSMenu(title: "Markers")
        for (i, name) in ["Hottest Point", "Coldest Point", "Centre Point"].enumerated() {
            item(markers, name, #selector(ThermalViewController.toggleMarker(_:)), tag: i)
        }
        let markersItem = NSMenuItem(title: "Markers", action: nil, keyEquivalent: "")
        markersItem.submenu = markers
        viewMenu.addItem(markersItem)

        let plot = NSMenu(title: "Live Plot")
        for (i, name) in ["Off", "Above Image", "Below Image", "Next to Points"].enumerated() {
            item(plot, name, #selector(ThermalViewController.selectChartPosition(_:)), tag: i)
        }
        let plotItem = NSMenuItem(title: "Live Plot", action: nil, keyEquivalent: "")
        plotItem.submenu = plot
        viewMenu.addItem(plotItem)

        let scale = NSMenu(title: "Colour Scale")
        item(scale, "Auto", #selector(ThermalViewController.selectRangeMode(_:)), tag: 0)
        item(scale, "Manual", #selector(ThermalViewController.selectRangeMode(_:)), tag: 1)
        let scaleItem = NSMenuItem(title: "Colour Scale", action: nil, keyEquivalent: "")
        scaleItem.submenu = scale
        viewMenu.addItem(scaleItem)

        viewMenu.addItem(.separator())
        item(viewMenu, "Highlight New Hot / Cold Spots",
             #selector(ThermalViewController.toggleChangeDetection(_:)))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        item(windowMenu, "Minimize", #selector(NSWindow.miniaturize(_:)), "m")
        item(windowMenu, "Zoom", #selector(NSWindow.zoom(_:)))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc func showAbout(_ sender: Any?) {
        About.show()
    }

    @objc func showExtensionInstaller(_ sender: Any?) {
        if extensionController == nil {
            extensionController = ExtensionInstallerWindowController()
        }
        extensionController?.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        thermalController?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
