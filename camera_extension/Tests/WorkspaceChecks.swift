import Cocoa

/// Runs the real native controller without opening USB/cameras. This checks
/// geometry and shared control state; physical capture is tested separately.
@main
enum WorkspaceChecks {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let controller = ThermalViewController(startsCapture: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.title = "T2S native UI layout verification"
        window.setContentSize(NSSize(width: 1380, height: 900))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let root = controller.view
        let all = descendants(root)
        let workspace = all.compactMap { $0 as? NativeWorkspace }.first!
        precondition(workspace.irPower.action == #selector(ThermalViewController.toggleIRCamera(_:)))
        precondition(!controller.isIRRunning && workspace.irPower.title == "IR OFF · Start")
        let popups = all.compactMap { $0 as? NSPopUpButton }
        let plots = popups.first { $0.itemTitles.contains("On image") }!
        let palettes = popups.first { $0.itemTitles.contains("Ironbow") }!
        let modes = all.compactMap { $0 as? NSSegmentedControl }.first {
            $0.segmentCount == 4 && $0.label(forSegment: 0) == "Inspection"
        }!
        let image = all.compactMap { $0 as? ThermalImageView }.first!
        let chart = all.compactMap { $0 as? ChartView }.first!
        let table = all.compactMap { $0 as? NSTableView }.first!
        image.onAddSpot?(100, 80)
        image.onAddArea?(120, 60, 25, 20)
        image.onAddLine?(50, 50, 160, 130)
        precondition(table.numberOfRows == 3, "Native gestures must retain all measurement kinds")
        precondition(palettes.numberOfItems == 6, "All six palettes must be present")

        for (index, position) in [ThermalViewController.ChartPosition.off, .above, .below, .inline].enumerated() {
            plots.selectItem(at: index)
            NSApp.sendAction(plots.action!, to: plots.target, from: plots)
            precondition(controller.chartPosition == position)
            for mode in 0..<4 {
                modes.selectedSegment = mode
                NSApp.sendAction(modes.action!, to: modes.target, from: modes)
                root.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                precondition(controller.chartPosition == position, "Workspace reset the user's plot selection")
                precondition(table.numberOfRows == 3, "Workspace discarded measurements")
                precondition(workspace.imageHost.bounds.height > 100)
                precondition(!workspace.irPower.isHiddenOrHasHiddenAncestor,
                             "IR ON/OFF must be available in every workspace")
                precondition(!chart.isHidden == (mode == 2 || position == .above || position == .below),
                             "Analysis must show history even when the user's plot selection is off or inline")
            }
        }
        for index in 0..<6 {
            palettes.selectItem(at: index)
            NSApp.sendAction(palettes.action!, to: palettes.target, from: palettes)
            precondition(controller.palette.rawValue == index)
        }
        let menuChoice = NSMenuItem()
        menuChoice.tag = 3
        controller.selectChartPosition(menuChoice)
        precondition(plots.indexOfSelectedItem == 3, "Menu and native plot selector diverged")
        let stick = all.compactMap { $0 as? NSButton }.first { $0.action == #selector(ThermalViewController.toggleTrackSelected(_:)) }!
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.toggleTrackSelected(nil)
        precondition(stick.title == "Unstick object")
        modes.selectedSegment = 1
        NSApp.sendAction(modes.action!, to: modes.target, from: modes)
        precondition(stick.title == "Unstick object", "Workspace reset tracking")

        // Stopping twice must be harmless, release capture timers and clear
        // live displays while keeping the user's objects and settings.
        controller.recorder.startInterval(every: 60, forMinutes: 1,
                                          frame: { nil }, onShot: { _ in }, onFinish: {})
        precondition(controller.recorder.isRunningInterval)
        controller.stopIRCamera()
        controller.stopIRCamera()
        precondition(!controller.isIRRunning && image.image == nil && chart.series.isEmpty)
        precondition(image.emptyMessage.contains("OFF"))
        precondition(!controller.recorder.isRunningInterval && table.numberOfRows == 3)
        precondition(controller.palette.rawValue == 5 && controller.chartPosition == .inline)
        controller.toggleVideo(nil)
        controller.toggleInterval(nil)
        controller.toggleLog(nil)
        controller.runNUC(nil)
        precondition(!controller.recorder.isRecordingVideo && !controller.recorder.isRunningInterval
                     && !controller.recorder.isLogging, "IR OFF must reject captures without live data")
        print("PASS: IR OFF clears live displays, stops time-lapse, preserves objects/settings, rejects recording and remains visible in all modes.")

        let feedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: feedDirectory) }
        let feed = VirtualCameraFeed(container: feedDirectory)
        let frameContext = CGContext(data: nil, width: ThermalRenderer.outputWidth,
                                     height: ThermalRenderer.outputHeight, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let publishedImage = frameContext.makeImage()!
        let frameFile = feedDirectory.appendingPathComponent("frame.raw")
        feed.publish(publishedImage)
        precondition(FileManager.default.fileExists(atPath: frameFile.path) && feed.framesPublished == 1)
        feed.clear()
        precondition(!FileManager.default.fileExists(atPath: frameFile.path))
        feed.publish(publishedImage)
        precondition(try! Data(contentsOf: frameFile).count == ThermalRenderer.outputWidth * ThermalRenderer.outputHeight * 4)
        precondition(feed.framesPublished == 2, "Virtual output must resume after IR OFF clears the shared frame")
        print("PASS: virtual camera publishes on first start and after OFF/ON.")

        var modeRects: [Int: NSRect] = [:]
        for mode in 0..<4 {
            modes.selectedSegment = mode
            NSApp.sendAction(modes.action!, to: modes.target, from: modes)
            root.layoutSubtreeIfNeeded()
            modeRects[mode] = workspace.imageHost.frame
            precondition(workspace.showsInspector == (mode != 3))
            precondition(workspace.showsCaptureSettings == (mode == 1 || mode == 2))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: "/tmp/t2s-native-mode-\(mode).png"))
        }
        precondition(modeRects[3]!.width > modeRects[0]!.width + 250, "Presentation must noticeably enlarge the image")
        precondition(modeRects[0]!.height > modeRects[1]!.height + 100, "Inspection must have more image height than full capture layouts")
        precondition(modeRects[1]!.width < modeRects[0]!.width - 60, "Electronics must expand the measurement inspector")
        let inspector = all.compactMap { $0 as? NSButton }.first { $0.title == "Inspector" }!
        inspector.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(workspace.showsInspector, "Presentation inspector must be accessible in one click")
        inspector.performClick(nil)
        let captureSettings = all.compactMap { $0 as? NSButton }.first { $0.title == "Capture settings" }!
        captureSettings.performClick(nil)
        root.layoutSubtreeIfNeeded()
        precondition(workspace.showsCaptureSettings, "Presentation capture settings must remain accessible")
        captureSettings.performClick(nil)
        modes.selectedSegment = 1
        NSApp.sendAction(modes.action!, to: modes.target, from: modes)

        for size in [NSSize(width: 1380, height: 900), NSSize(width: 1100, height: 740)] {
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
            for card in descendants(root).compactMap({ $0 as? WorkspaceCard }) {
                precondition(card.frame.width > 220 && card.frame.height > 70,
                             "Collapsed native card: \(card.frame)")
                for sibling in card.superview?.subviews ?? [] where sibling !== card && sibling is WorkspaceCard {
                    let overlap = card.frame.intersection(sibling.frame)
                    precondition(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                                 "Native cards overlap: \(card.frame) / \(sibling.frame)")
                }
            }
            for view in descendants(root) where view is NSControl && !(view is NSTableView) {
                if view.isHiddenOrHasHiddenAncestor { continue }
                // A scrolling sidebar can be taller than its viewport. Each control
                // must still fit its own parent and have a real, usable frame.
                if view is NSTextField, (view as! NSTextField).stringValue.isEmpty { continue }
                precondition(view.frame.width > 0 && view.frame.height > 0,
                             "Zero-sized control: \(view)")
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                root.appearance = NSAppearance(named: appearance)
                root.layoutSubtreeIfNeeded()
                root.displayIfNeeded()
                let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let path = "/tmp/t2s-native-\(Int(size.width))-\(appearance.rawValue).png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
                print("Native layout preview: \(path)")
            }
        }
        print("PASS: native controls, six palettes, four plot placements, modes preserving plots/objects/tracking, two window sizes, light/dark rendering.")
        try RGBChecks.run()
    }
}
