import AVFoundation
import Cocoa
import CoreVideo

/// Saving: stills, radiometric CSV, H.264 video, and interval capture.
///
/// Everything lands in ~/Pictures/T2S+ Thermal. The app is sandboxed, so that
/// path only works because of com.apple.security.assets.pictures.read-write --
/// without it the writes fail with a permission error rather than a prompt.
final class Recorder {

    enum RecorderError: LocalizedError {
        case cannotCreateDirectory(String)
        case encodingFailed
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory(let p): return "Could not create \(p)."
            case .encodingFailed:               return "Could not encode the image."
            case .writerFailed(let m):          return "Video recording failed: \(m)."
            }
        }
    }

    static let outputDirectory: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("T2S+ Thermal")
    }()

    /// Also write the temperature matrix next to each still.
    var savesCSV = true
    /// Keep the sensor's own counts alongside the picture. Off by default:
    /// it is 100 KB a shot and only earns its keep if you might want to
    /// decode the capture again under different settings.
    var savesRaw = false

    private(set) var isRecordingVideo = false
    private(set) var isRunningInterval = false
    private(set) var intervalShotsTaken = 0

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var videoStart: CFTimeInterval = 0

    private var intervalTimer: Timer?
    private var intervalDeadline: Date?

    // MARK: - Paths

    private static func ensureDirectory() throws {
        let dir = outputDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw RecorderError.cannotCreateDirectory(dir.path)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    // MARK: - Stills

    /// Writes a PNG, plus the temperature matrix as CSV when `savesCSV` is on.
    /// A PNG is only a picture; the CSV is what makes the capture radiometric,
    /// i.e. still measurable after the fact.
    @discardableResult
    func savePhoto(_ image: CGImage, temperatures: [Double]?,
                   width: Int, height: Int,
                   raw: [UInt16]? = nil, rawInfo: [String: Any] = [:],
                   nameHint: String = "T2S") throws -> URL {
        try Recorder.ensureDirectory()
        let base = nameHint + "_" + Recorder.timestamp()
        let url = Recorder.outputDirectory.appendingPathComponent(base + ".png")

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw RecorderError.encodingFailed
        }
        try png.write(to: url)

        if savesCSV, let temps = temperatures {
            let csv = Recorder.outputDirectory.appendingPathComponent(base + ".csv")
            try Recorder.writeCSV(temps, width: width, height: height, to: csv)
        }
        if savesRaw, let raw {
            let file = Recorder.outputDirectory.appendingPathComponent(base + ".t2sraw")
            try Recorder.writeRaw(raw, info: rawInfo, to: file)
        }
        return url
    }

    /// Writes the sensor's own output, untouched.
    ///
    /// The CSV holds temperatures, and a temperature is already an
    /// interpretation: it depends on the emissivity, the calibration and the
    /// air settings in force when the shutter went. Those are judgements, and
    /// judgements turn out to be wrong. The raw counts are not an
    /// interpretation, so a capture kept this way can be decoded again later
    /// with better numbers -- including the metadata rows the camera appends,
    /// which carry its own calibration constants for that frame.
    ///
    /// The layout is deliberately dull, so anything can read it:
    ///
    ///     "T2SRAW01"            8 bytes
    ///     header length         uint32, little endian
    ///     header                that many bytes of JSON
    ///     samples               width * rows uint16, little endian, row major
    ///
    /// The header says how to read the rest and under what settings it was
    /// taken.
    static func writeRaw(_ raw: [UInt16], info: [String: Any], to url: URL) throws {
        var header = info
        header["format"] = "t2sraw"
        header["version"] = 1
        header["samples"] = raw.count
        header["byteOrder"] = "little"
        header["sampleBits"] = 16
        header["taken"] = ISO8601DateFormatter().string(from: Date())

        let json = try JSONSerialization.data(withJSONObject: header,
                                              options: [.sortedKeys, .prettyPrinted])
        var out = Data("T2SRAW01".utf8)
        var length = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(json)

        var samples = Data(capacity: raw.count * 2)
        for value in raw {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { samples.append(contentsOf: $0) }
        }
        out.append(samples)
        try out.write(to: url, options: .atomic)
    }

    private static func writeCSV(_ temps: [Double], width: Int, height: Int, to url: URL) throws {
        var out = ""
        out.reserveCapacity(width * height * 7)
        for y in 0..<height {
            var row = [String]()
            row.reserveCapacity(width)
            for x in 0..<width {
                let i = y * width + x
                row.append(i < temps.count ? String(format: "%.2f", temps[i]) : "")
            }
            out += row.joined(separator: ",")
            out += "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Video

    func startVideo(width: Int, height: Int) throws {
        guard !isRecordingVideo else { return }
        try Recorder.ensureDirectory()
        let url = Recorder.outputDirectory
            .appendingPathComponent("T2S_" + Recorder.timestamp() + ".mov")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed("writer rejected the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
        self.videoStart = CACurrentMediaTime()
        self.isRecordingVideo = true
    }

    /// Frames are stamped with real elapsed time rather than a frame counter,
    /// so a dropped frame shows as a pause instead of speeding the video up.
    func appendVideoFrame(_ image: CGImage) {
        guard isRecordingVideo, let adaptor, let input = writerInput,
              input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
           let ctx = CGContext(data: base,
                               width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer),
                               bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CVPixelBufferGetWidth(pixelBuffer),
                                       height: CVPixelBufferGetHeight(pixelBuffer)))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let elapsed = CACurrentMediaTime() - videoStart
        adaptor.append(pixelBuffer, withPresentationTime:
                        CMTime(seconds: elapsed, preferredTimescale: 600))
    }

    func stopVideo(completion: @escaping (URL?) -> Void) {
        guard isRecordingVideo, let writer, let input = writerInput else {
            completion(nil); return
        }
        isRecordingVideo = false
        input.markAsFinished()
        let url = writer.outputURL
        writer.finishWriting { [weak self] in
            self?.writer = nil
            self?.writerInput = nil
            self?.adaptor = nil
            DispatchQueue.main.async { completion(url) }
        }
    }

    // MARK: - Interval capture

    /// Saves a still every `interval` seconds for `minutes`, then stops itself.
    func startInterval(every interval: TimeInterval, forMinutes minutes: Double,
                       frame: @escaping () -> (CGImage, [Double])?,
                       onShot: @escaping (Int) -> Void,
                       onFinish: @escaping () -> Void) {
        stopInterval()
        guard interval > 0, minutes > 0 else { return }
        isRunningInterval = true
        intervalShotsTaken = 0
        intervalDeadline = Date().addingTimeInterval(minutes * 60)

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.isRunningInterval else { return }
            if let deadline = self.intervalDeadline, Date() >= deadline {
                self.stopInterval()
                onFinish()
                return
            }
            if let (image, temps) = frame() {
                try? self.savePhoto(image, temperatures: temps,
                                    width: ThermalCapture.width,
                                    height: ThermalCapture.imageHeight)
                self.intervalShotsTaken += 1
                onShot(self.intervalShotsTaken)
            }
        }
        // .common so the timer keeps firing while a menu or control is tracking.
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
        intervalTimer = timer
    }

    // MARK: - Time-series logging

    private var logTimer: Timer?
    private var logHandle: FileHandle?
    private var logColumns: [String] = []
    private var logStart = Date()
    private(set) var isLogging = false
    private(set) var logRowsWritten = 0
    private(set) var logURL: URL?

    /// Appends one row per tick with the current value of each column.
    ///
    /// Columns are fixed when logging starts: a CSV whose header stops
    /// matching its rows halfway down is worse than one that ignores an object
    /// added mid-run, so objects placed later are simply not logged.
    func startLog(every interval: TimeInterval, columns: [String],
                  sample: @escaping () -> [String: Double],
                  onTick: @escaping (Int) -> Void) throws {
        stopLog()
        guard interval > 0, !columns.isEmpty else { return }
        try Recorder.ensureDirectory()

        let url = Recorder.outputDirectory
            .appendingPathComponent("T2S_log_" + Recorder.timestamp() + ".csv")
        let header = (["timestamp", "elapsed_s"] + columns).joined(separator: ",") + "\n"
        guard FileManager.default.createFile(atPath: url.path,
                                             contents: header.data(using: .utf8)) else {
            throw RecorderError.cannotCreateDirectory(url.path)
        }
        logHandle = try FileHandle(forWritingTo: url)
        logHandle?.seekToEndOfFile()

        logColumns = columns
        logStart = Date()
        logRowsWritten = 0
        logURL = url
        isLogging = true

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.isLogging, let handle = self.logHandle else { return }
            let values = sample()
            var row = [stamp.string(from: Date()),
                       String(format: "%.2f", Date().timeIntervalSince(self.logStart))]
            for column in self.logColumns {
                row.append(values[column].map { String(format: "%.2f", $0) } ?? "")
            }
            if let data = (row.joined(separator: ",") + "\n").data(using: .utf8) {
                handle.write(data)
                self.logRowsWritten += 1
                onTick(self.logRowsWritten)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timer.fire()
        logTimer = timer
    }

    func stopLog() {
        logTimer?.invalidate()
        logTimer = nil
        try? logHandle?.close()
        logHandle = nil
        isLogging = false
    }

    func stopInterval() {
        intervalTimer?.invalidate()
        intervalTimer = nil
        intervalDeadline = nil
        isRunningInterval = false
    }

    var intervalRemaining: TimeInterval {
        guard let deadline = intervalDeadline else { return 0 }
        return max(0, deadline.timeIntervalSinceNow)
    }
}
