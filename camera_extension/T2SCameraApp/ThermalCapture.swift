import Foundation
import AVFoundation
import CoreMedia

/// Live capture from the physical T2S+ over AVFoundation.
///
/// The Python proof-of-concept shells out to ffmpeg because OpenCV's
/// AVFoundation backend crashes opening this device. That turned out to be
/// OpenCV's wrapper, not the device: a plain AVCaptureSession requesting the
/// sensor's native `yuvs` format delivers the raw 16-bit counts directly
/// (verified: 256x196, bytesPerRow 512, values ~5188 straight out of the
/// buffer), so there is no subprocess or pipe copy here.
final class ThermalCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Sensor geometry. The frame carries 4 extra rows of metadata below the
    /// image, which the decoder splits off.
    static let width = 256
    static let fullHeight = 196
    static let imageHeight = 192
    static let metadataRows = 4

    /// Exact name match matters: with the virtual camera installed there is
    /// also a device called "T2S+ Thermal Camera", and it sorts *first* in
    /// the device list.
    static let deviceName = "T2S+"

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "cat.sysop.t2scamera.capture")

    /// Called on `queue` with one frame's worth of raw 16-bit values,
    /// width*fullHeight of them (image rows first, then metadata rows).
    var onFrame: (([UInt16]) -> Void)?

    enum CaptureError: LocalizedError {
        case deviceNotFound
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "Thermal camera \"\(ThermalCapture.deviceName)\" not found. Is it plugged in?"
            case .cannotAddInput:  return "Could not add the camera as a capture input."
            case .cannotAddOutput: return "Could not add a video output to the capture session."
            }
        }
    }

    /// USB identity of this camera family, as macOS spells it in `modelID`
    /// ("UVC Camera VendorID_5396 ProductID_1" = 0x1514:0x0001).
    static let vendorID = 5396
    static let productID = 1

    /// Finds the camera without relying on its name.
    ///
    /// Matching on the name alone is fragile in both directions: another unit
    /// or firmware revision may not call itself exactly "T2S+", and our own
    /// virtual camera is called "T2S+ Thermal Camera" and sorts *first* in the
    /// device list, so a loose name match grabs it and feeds the app its own
    /// output. USB VID/PID is the reliable signal; the 256x196 format is the
    /// fallback, and it is just as decisive -- nothing else on the machine
    /// offers that size.
    static func findDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified).devices

        if let byUSB = devices.first(where: {
            $0.modelID.contains("VendorID_\(vendorID)") && $0.modelID.contains("ProductID_\(productID)")
        }) {
            return byUSB
        }
        if let byFormat = devices.first(where: { device in
            device.formats.contains { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return Int(d.width) == width && Int(d.height) == fullHeight
            }
        }) {
            return byFormat
        }
        return devices.first { $0.localizedName == deviceName }
    }

    func start() throws {
        guard let device = ThermalCapture.findDevice() else { throw CaptureError.deviceNotFound }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Native 422 ('yuvs'), NOT BGRA: asking for BGRA would make CoreVideo
        // colour-convert the buffer and destroy the raw sensor counts that are
        // smuggled through the YUY2 container.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    Int(kCVPixelFormatType_422YpCbCr8_yuvs)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        session.startRunning()
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let handler = onFrame,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let height = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }

        // Copy out row by row: bytesPerRow can exceed width*2 if the buffer is
        // padded, so don't assume the rows are contiguous.
        let valuesPerRow = ThermalCapture.width
        var raw = [UInt16](repeating: 0, count: valuesPerRow * height)
        raw.withUnsafeMutableBufferPointer { dst in
            for row in 0..<height {
                let src = base.advanced(by: row * bytesPerRow)
                    .assumingMemoryBound(to: UInt16.self)
                for col in 0..<valuesPerRow {
                    dst[row * valuesPerRow + col] = src[col]
                }
            }
        }
        handler(raw)
    }
}
