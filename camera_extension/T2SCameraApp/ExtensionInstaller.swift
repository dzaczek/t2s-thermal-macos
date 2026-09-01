// Install / manage the camera extension. The OSSystemExtensionRequest flow
// follows ldenoue/cameraextension (github.com/ldenoue/cameraextension).
//
// Two things macOS enforces here that are easy to trip over:
//   * The containing app must be in /Applications, and macOS resolves it by
//     bundle ID -- so a stale copy registered elsewhere (a DerivedData build,
//     say) makes this fail with a misleading "cannot allow apps outside
//     /Applications". build.sh cleans that up.
//   * Approving the extension is a manual step in System Settings that no
//     amount of code can bypass.

import Cocoa
import SystemExtensions

final class ExtensionInstallerWindowController: NSWindowController {

    private var statusLabel: NSTextField!
    private var activating = false

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Camera Extension"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)

        let content = NSView(frame: window.contentLayoutRect)

        let activate = NSButton(title: "Activate", target: self, action: #selector(activate(_:)))
        activate.frame = NSRect(x: 20, y: 180, width: 180, height: 32)
        content.addSubview(activate)

        let deactivate = NSButton(title: "Deactivate", target: self, action: #selector(deactivate(_:)))
        deactivate.frame = NSRect(x: 210, y: 180, width: 180, height: 32)
        content.addSubview(deactivate)

        statusLabel = NSTextField(wrappingLabelWithString:
            "Activate installs the virtual camera, then macOS asks you to approve it in "
            + "System Settings > General > Login Items & Extensions > Camera Extensions. "
            + "Once approved, \"T2S+ Thermal Camera\" appears as a camera in Teams, Zoom and "
            + "FaceTime while this app is running.")
        statusLabel.frame = NSRect(x: 20, y: 16, width: 420, height: 150)
        statusLabel.isEditable = false
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        content.addSubview(statusLabel)

        window.contentView = content
    }

    private func report(_ text: String) {
        FileHandle.standardError.write("EXT: \(text)\n".data(using: .utf8)!)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusLabel.stringValue = text + "\n\n" + self.statusLabel.stringValue
        }
    }

    private static func extensionBundle() -> Bundle? {
        let dir = URL(fileURLWithPath: "Contents/Library/SystemExtensions",
                      relativeTo: Bundle.main.bundleURL)
        guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
              let first = urls.first else { return nil }
        return Bundle(url: first)
    }

    @objc func activate(_ sender: Any?) {
        guard let bundle = Self.extensionBundle(), let identifier = bundle.bundleIdentifier else {
            report("Could not find the camera extension inside this app bundle.")
            return
        }
        activating = true
        report("Activating \(identifier)…")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    @objc private func deactivate(_ sender: Any?) {
        guard let bundle = Self.extensionBundle(), let identifier = bundle.bundleIdentifier else { return }
        activating = false
        report("Deactivating \(identifier)…")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension ExtensionInstallerWindowController: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        report("Replacing version \(existing.bundleShortVersion) with \(ext.bundleShortVersion).")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        report("Waiting for your approval in System Settings > General > "
               + "Login Items & Extensions > Camera Extensions.")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        if result == .completed {
            report(activating ? "Activated." : "Deactivated.")
        } else {
            report("Finished with result \(result.rawValue); a reboot may be needed.")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        report("Failed: \(error.localizedDescription)")
    }
}
