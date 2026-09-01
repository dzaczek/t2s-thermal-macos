import Foundation
import CoreGraphics

/// Publishes rendered frames to the camera extension.
///
/// The extension polls a file in the shared App Group container: it must be
/// sandboxed (macOS rejects camera extensions otherwise), and that container
/// is the one place both processes can reach. Frames are written to a temp
/// file and renamed, because rename is atomic on the same filesystem, so the
/// extension never catches a half-written frame -- there is no locking
/// between the two processes.
final class VirtualCameraFeed {

    /// Must match appGroupID in the extension's Config.swift.
    static let appGroupID = AppIdentity.appGroupID

    private let frameURL: URL?
    private let tempURL: URL?
    private(set) var isAvailable = false
    private(set) var framesPublished = 0

    init() {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: VirtualCameraFeed.appGroupID)
        frameURL = container?.appendingPathComponent("frame.raw")
        tempURL = container?.appendingPathComponent("frame.tmp")
        isAvailable = container != nil
        if let container {
            try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        }
    }

    func publish(_ image: CGImage) {
        guard let frameURL, let tempURL,
              image.width == ThermalRenderer.outputWidth,
              image.height == ThermalRenderer.outputHeight,
              let data = ThermalRenderer.bgraBytes(from: image) else { return }
        do {
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(frameURL, withItemAt: tempURL)
            framesPublished += 1
        } catch {
            // A dropped frame is not worth interrupting the live view for;
            // the extension simply re-shows the previous one.
        }
    }

    /// Removes the published frame so the virtual camera falls back to its
    /// "no signal" grey rather than freezing on the last thermal image.
    func clear() {
        guard let frameURL else { return }
        try? FileManager.default.removeItem(at: frameURL)
    }
}
