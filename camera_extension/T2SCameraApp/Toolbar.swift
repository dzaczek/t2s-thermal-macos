import Cocoa

/// Toolbar with the controls that get used constantly.
///
/// The menu bar keeps every setting and its keyboard shortcut, but reaching
/// for a menu to change palette or drop a marker is friction on something you
/// adjust all the time. The toolbar sits in the title bar, so unlike another
/// row of buttons it costs the video area nothing.
///
/// It is user-customisable: right-click it to add, remove or rearrange.
extension ThermalViewController: NSToolbarDelegate {

    enum ToolbarID {
        static let palette = NSToolbarItem.Identifier("palette")
        static let markers = NSToolbarItem.Identifier("markers")
        static let plot = NSToolbarItem.Identifier("plot")
        static let range = NSToolbarItem.Identifier("range")
        static let newSpots = NSToolbarItem.Identifier("newSpots")
        static let calibrate = NSToolbarItem.Identifier("calibrate")
        static let nuc = NSToolbarItem.Identifier("nuc")
        static let photo = NSToolbarItem.Identifier("photo")
        static let record = NSToolbarItem.Identifier("record")
        static let virtualCam = NSToolbarItem.Identifier("virtualCam")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.palette, ToolbarID.markers, ToolbarID.plot, ToolbarID.range,
         .flexibleSpace,
         ToolbarID.calibrate, ToolbarID.nuc,
         .space,
         ToolbarID.photo, ToolbarID.record]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.palette, ToolbarID.markers, ToolbarID.plot, ToolbarID.range,
         ToolbarID.newSpots, ToolbarID.calibrate, ToolbarID.nuc,
         ToolbarID.photo, ToolbarID.record, ToolbarID.virtualCam,
         .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)

        switch id {
        case ToolbarID.palette:
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 130, height: 24))
            popup.addItems(withTitles: Palette.allCases.map(\.displayName))
            popup.selectItem(at: palette.rawValue)
            popup.target = self
            popup.action = #selector(toolbarPaletteChanged(_:))
            item.view = popup
            item.label = "Palette"
            toolbarPalette = popup

        case ToolbarID.markers:
            let seg = NSSegmentedControl(labels: ["Max", "Min", "Centre"],
                                        trackingMode: .selectAny,
                                        target: self, action: #selector(toolbarMarkersChanged(_:)))
            seg.setSelected(showMax, forSegment: 0)
            seg.setSelected(showMin, forSegment: 1)
            seg.setSelected(showCentre, forSegment: 2)
            item.view = seg
            item.label = "Markers"
            toolbarMarkers = seg

        case ToolbarID.plot:
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
            popup.addItems(withTitles: ["Plot: off", "Plot: above", "Plot: below", "Plot: inline"])
            popup.selectItem(at: chartPosition.rawValue)
            popup.target = self
            popup.action = #selector(toolbarPlotChanged(_:))
            item.view = popup
            item.label = "Live plot"
            toolbarPlot = popup

        case ToolbarID.range:
            let seg = NSSegmentedControl(labels: ["Auto", "Manual"],
                                        trackingMode: .selectOne,
                                        target: self, action: #selector(toolbarRangeChanged(_:)))
            seg.setSelected(true, forSegment: manualRange ? 1 : 0)
            item.view = seg
            item.label = "Range"
            toolbarRange = seg

        case ToolbarID.newSpots:
            let button = NSButton(title: "New spots", target: self,
                                  action: #selector(toolbarNewSpotsToggled(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.state = detectChanges ? .on : .off
            item.view = button
            item.label = "New spots"
            toolbarNewSpots = button

        case ToolbarID.calibrate:
            item.view = NSButton(title: "Calibrate", target: self,
                                 action: #selector(calibrateTemperature(_:)))
            item.label = "Calibrate"

        case ToolbarID.nuc:
            item.view = NSButton(title: "NUC", target: self, action: #selector(runNUC(_:)))
            item.label = "Recalibrate sensor"

        case ToolbarID.photo:
            item.view = NSButton(title: "Photo", target: self, action: #selector(savePhoto(_:)))
            item.label = "Save photo"

        case ToolbarID.record:
            let button = NSButton(title: "Record", target: self, action: #selector(toggleVideo(_:)))
            item.view = button
            item.label = "Record"
            toolbarRecord = button

        case ToolbarID.virtualCam:
            let button = NSButton(title: "Virtual cam", target: self,
                                  action: #selector(toolbarVirtualCamToggled(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded
            button.state = publishToVirtualCam ? .on : .off
            item.view = button
            item.label = "Virtual camera"
            toolbarVirtualCam = button

        default:
            return nil
        }

        item.paletteLabel = item.label
        return item
    }

    // MARK: - Actions

    @objc func toolbarPaletteChanged(_ sender: NSPopUpButton) {
        palette = Palette(rawValue: sender.indexOfSelectedItem) ?? .ironbow
    }

    @objc func toolbarMarkersChanged(_ sender: NSSegmentedControl) {
        showMax = sender.isSelected(forSegment: 0)
        showMin = sender.isSelected(forSegment: 1)
        showCentre = sender.isSelected(forSegment: 2)
    }

    @objc func toolbarPlotChanged(_ sender: NSPopUpButton) {
        chartPosition = ChartPosition(rawValue: sender.indexOfSelectedItem) ?? .off
        view.needsLayout = true
    }

    @objc func toolbarRangeChanged(_ sender: NSSegmentedControl) {
        manualRange = sender.selectedSegment == 1
        updateRangeEnabled()
    }

    @objc func toolbarNewSpotsToggled(_ sender: NSButton) {
        toggleChangeDetection(sender)
    }

    @objc func toolbarVirtualCamToggled(_ sender: NSButton) {
        toggleVirtualCamera(sender)
    }

    /// Pushes state back into the toolbar, so changing something from the menu
    /// or a keyboard shortcut does not leave the buttons showing stale values.
    func syncToolbar() {
        toolbarPalette?.selectItem(at: palette.rawValue)
        toolbarPlot?.selectItem(at: chartPosition.rawValue)
        toolbarMarkers?.setSelected(showMax, forSegment: 0)
        toolbarMarkers?.setSelected(showMin, forSegment: 1)
        toolbarMarkers?.setSelected(showCentre, forSegment: 2)
        toolbarRange?.setSelected(true, forSegment: manualRange ? 1 : 0)
        toolbarNewSpots?.state = detectChanges ? .on : .off
        toolbarVirtualCam?.state = publishToVirtualCam ? .on : .off
        toolbarRecord?.title = recorder.isRecordingVideo ? "Stop" : "Record"
    }
}
