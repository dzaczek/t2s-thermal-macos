import AVFoundation
import CoreVideo
import Foundation

/// Live picture from an ordinary camera, to lay the thermal image over.
///
/// A thermal picture tells you where the heat is and almost nothing about
/// what the thing *is*: a warm rectangle could be a breaker, a socket or a
/// sandwich. Every commercial imager therefore blends in a visible-light
/// picture, and this camera has no second sensor -- so it borrows one. Clamp
/// a webcam beside the T2S+, point them the same way, and the app can line
/// the two up.
///
/// Frames are handed over in colour, at whatever size the camera gives.
/// Colour was left out at first, on the grounds that a picture blended under
/// a false-coloured thermal image only needs to supply outlines. That is
/// wrong for the work people actually do with this: inspecting a board, half
/// the information is in the colour -- which wire, which marking, which
/// component. Grey is still available as a choice, not as the only option.
final class VisibleCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    struct Frame {
        /// Three bytes a pixel, red first.
        var rgb: [UInt8]
        var width: Int
        var height: Int

        /// Brightness of one pixel. The usual luma weights: the eye is far
        /// more sensitive to green, and a flat average of the channels comes
        /// out muddy.
        func luma(_ index: Int) -> Double {
            let p = index * 3
            guard p + 2 < rgb.count else { return 0 }
            return 0.299 * Double(rgb[p]) + 0.587 * Double(rgb[p + 1]) + 0.114 * Double(rgb[p + 2])
        }
    }

    /// The latest frame, or nil until one arrives.
    private(set) var latest: Frame?
    private let lock = NSLock()

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cat.sysop.t2scamera.visible")
    private(set) var deviceName: String?

    var isRunning: Bool { session.isRunning }

    /// Every camera that could serve as the visible one.
    ///
    /// The thermal camera itself is excluded -- it is a camera as far as
    /// macOS is concerned -- and so is this app's own virtual camera, which
    /// would otherwise let the picture be laid over itself.
    static func candidates() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video, position: .unspecified)
            .devices
            .filter { device in
                !device.modelID.contains("VendorID_\(ThermalCapture.vendorID)")
                    && !device.localizedName.contains("T2S+ Thermal")
            }
    }

    func start(device: AVCaptureDevice) throws {
        stop()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        deviceName = device.localizedName
        session.startRunning()
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        lock.lock(); latest = nil; lock.unlock()
        deviceName = nil
    }

    func currentFrame() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    enum CaptureError: LocalizedError {
        case cannotAddInput, cannotAddOutput
        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "That camera would not open."
            case .cannotAddOutput: return "The camera opened but would not deliver frames."
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels), width > 0, height > 0 else { return }

        // A 4K webcam is far larger than anything this needs. Taking every
        // nth pixel keeps it to a sensible size and costs almost nothing.
        let step = max(1, min(width / 640, height / 480))
        let outW = width / step, outH = height / step
        var rgb = [UInt8](repeating: 0, count: outW * outH * 3)

        for y in 0..<outH {
            let row = base.advanced(by: y * step * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<outW {
                let p = (x * step) * 4          // BGRA from the camera
                let out = (y * outW + x) * 3
                rgb[out] = row[p + 2]
                rgb[out + 1] = row[p + 1]
                rgb[out + 2] = row[p]
            }
        }

        lock.lock()
        latest = Frame(rgb: rgb, width: outW, height: outH)
        lock.unlock()
    }
}
