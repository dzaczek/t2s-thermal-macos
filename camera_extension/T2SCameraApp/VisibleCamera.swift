import AppKit
import AVFoundation
import CoreImage

struct RGBAlignment: Codable, Equatable {
    // Native IR-pixel coordinates; independent of the display quarter-turn.
    var x = 0.0
    var y = 0.0
    var zoom = 1.0
    var degrees = 0.0
    var mirrored = false
    var alpha = 0.5
    var mode = 0 // thermal / RGB with measurements / blend
    var timeOffsetMS = 0.0
    var toleranceMS = 100.0

    var isValid: Bool {
        [x, y, zoom, degrees, alpha, timeOffsetMS, toleranceMS].allSatisfy(\.isFinite)
            && abs(x) <= 256 && abs(y) <= 192 && (0.2...5).contains(zoom)
            && abs(degrees) <= 180 && (0...1).contains(alpha) && (0...2).contains(mode)
            && abs(timeOffsetMS) <= 500 && (10...500).contains(toleranceMS)
    }
}

/// Independent RGB capture. Arrival-time matching is software alignment, not
/// hardware synchronisation of exposure; unmatched images are never reused.
final class VisibleCamera {
    struct Sample { let image: CGImage; let time: TimeInterval }
    struct Pair { let image: CGImage?; let alignment: RGBAlignment; let note: String }
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cat.sysop.t2scamera.rgb.session")
    private let framesQueue = DispatchQueue(label: "cat.sysop.t2scamera.rgb.frames")
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var settings = RGBAlignment()
    private var generation = 0
    private var receiver: RGBReceiver?
    private var selectedID = ""
    private var cameraStatus = "RGB stopped"
    private var motion: MotionAlignmentSession?
    private var candidate: MotionAlignment.Result?
    private var beforePreview: RGBAlignment?
    private var motionMessage = "Keep both cameras fixed. Move your hand left/right and up/down."

    var motionState: (message: String, hasCandidate: Bool, running: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let motion {
            let elapsed = ProcessInfo.processInfo.systemUptime - motion.started
            if elapsed >= 10 {
                candidate = MotionAlignment.fit(motion.observations, base: settings)
                self.motion = nil
                motionMessage = candidate.map { String(format: "Candidate: %d matches · residual %.1f IR pixels. Preview before accepting.", $0.inliers, $0.error) }
                    ?? "No reliable match. Keep cameras fixed; move one hand in both directions, with a clear background."
            } else {
                motionMessage = "Move hand left/right AND up/down · \(max(0, 10 - Int(elapsed))) s · \(motion.observations.count) matching motion samples"
            }
        }
        return (motionMessage, candidate != nil, motion != nil)
    }

    func beginMotion() {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard let last = samples.last, now - last.time < 0.5 else {
            motionMessage = "Start RGB and wait for a live image first."; return
        }
        if let previous = beforePreview { settings = previous; beforePreview = nil }
        candidate = nil
        motion = MotionAlignmentSession(started: now)
    }

    func previewMotion() {
        lock.lock(); defer { lock.unlock() }
        guard let candidate else { return }
        if beforePreview == nil { beforePreview = settings }
        settings = candidate.alignment
    }

    func acceptMotion() {
        lock.lock()
        guard let candidate else { lock.unlock(); return }
        settings = candidate.alignment; beforePreview = nil; self.candidate = nil
        motionMessage = "Alignment accepted. Check edge agreement at the working distance."
        lock.unlock(); saveAlignment()
    }

    func cancelMotion() {
        lock.lock(); defer { lock.unlock() }
        if let previous = beforePreview { settings = previous }
        beforePreview = nil; candidate = nil; motion = nil
        motionMessage = "Motion alignment cancelled; previous alignment preserved."
    }

    /// Called on the IR queue only after valid temperatures are available.
    func observeMotion(temperatures: [Double], rotation: ImageRotation, arrival: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let motion, arrival - motion.lastTime >= 0.12,
              arrival - motion.started < 10,
              let rgb = Self.nearest(samples, to: arrival, settings: settings) else { return }
        motion.lastTime = arrival
        let size = rotation.size(width: 256, height: 192)
        let inverse = ImageRotation(rawValue: (4 - rotation.rawValue) % 4)!
        let native = inverse.apply(temperatures, width: size.width, height: size.height)
        guard native.count == 256 * 192 else { return }
        var ir = [Double](repeating: 0, count: 64 * 48)
        for y in 0..<48 { for x in 0..<64 {
            var sum = 0.0
            for dy in 0..<4 { for dx in 0..<4 { sum += native[(y * 4 + dy) * 256 + x * 4 + dx] } }
            ir[y * 64 + x] = sum / 16
        }}
        var bytes = [UInt8](repeating: 0, count: 64 * 48)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 64, height: 48, bitsPerComponent: 8,
                                      bytesPerRow: 64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            let scale = min(64 / Double(rgb.image.width), 48 / Double(rgb.image.height))
            let w = Double(rgb.image.width) * scale, h = Double(rgb.image.height) * scale
            ctx.draw(rgb.image, in: CGRect(x: (64 - w) / 2, y: (48 - h) / 2, width: w, height: h))
            return true
        }
        guard drawn else { return }
        let visible = bytes.map(Double.init)
        if let previousIR = motion.previousIR, let previousRGB = motion.previousRGB,
           let a = MotionAlignment.motionCentre(current: ir, previous: previousIR, threshold: 0.5),
           let b = MotionAlignment.motionCentre(current: visible, previous: previousRGB, threshold: 14) {
            motion.observations.append(.init(rgb: b, thermal: a))
        }
        motion.previousIR = ir; motion.previousRGB = visible
    }

    static func devices() -> [AVCaptureDevice] {
        let thermalID = ThermalCapture.findDevice()?.uniqueID
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                                mediaType: .video, position: .unspecified).devices.filter {
            $0.uniqueID != thermalID && !$0.localizedName.lowercased().contains("t2s")
        }
    }

    var alignment: RGBAlignment {
        get { lock.lock(); defer { lock.unlock() }; return settings }
        set { guard newValue.isValid else { return }; lock.lock(); settings = newValue; lock.unlock() }
    }
    var status: String { lock.lock(); defer { lock.unlock() }; return cameraStatus }

    func select(_ deviceID: String) {
        stop()
        lock.lock()
        selectedID = deviceID
        settings = RGBAlignment()
        if let data = UserDefaults.standard.data(forKey: "rgbAlignment." + deviceID),
           let saved = try? JSONDecoder().decode(RGBAlignment.self, from: data), saved.isValid {
            settings = saved
            settings.mode = 0 // Never enable another camera automatically on launch.
        }
        lock.unlock()
    }

    func saveAlignment() {
        lock.lock(); let id = selectedID, value = settings; lock.unlock()
        guard !id.isEmpty, let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: "rgbAlignment." + id)
    }

    func start() {
        lock.lock(); generation += 1; let token = generation, id = selectedID
        cameraStatus = "Opening RGB camera…"; samples.removeAll(); lock.unlock()
        let open: (Bool) -> Void = { [weak self] allowed in
            guard let self else { return }
            self.sessionQueue.async { [weak self] in self?.configure(id: id, token: token, allowed: allowed) }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: open(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video, completionHandler: open)
        default: open(false)
        }
    }

    private func configure(id: String, token: Int, allowed: Bool) {
        lock.lock(); let current = token == generation; lock.unlock()
        guard current else { return }
        session.stopRunning()
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        do {
            guard allowed else { throw NSError(domain: "RGB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera permission denied. Enable camera access in macOS Settings."]) }
            guard let device = Self.devices().first(where: { $0.uniqueID == id }) else {
                throw NSError(domain: "RGB", code: 2, userInfo: [NSLocalizedDescriptionKey: "Select an available RGB camera."])
            }
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw NSError(domain: "RGB", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot open this RGB camera."])
            }
            session.addInput(input)
            if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            output.alwaysDiscardsLateVideoFrames = true
            let receiver = RGBReceiver { [weak self] buffer in self?.receive(buffer, token: token) }
            self.receiver = receiver
            output.setSampleBufferDelegate(receiver, queue: framesQueue)
            session.addOutput(output)
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
            session.startRunning()
            lock.lock(); if token == generation { cameraStatus = "RGB running · " + device.localizedName }; lock.unlock()
        } catch {
            session.commitConfiguration()
            lock.lock(); if token == generation { cameraStatus = error.localizedDescription }; lock.unlock()
        }
    }

    private func receive(_ buffer: CMSampleBuffer, token: Int) {
        let arrival = ProcessInfo.processInfo.systemUptime
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let rgb = ci.createCGImage(image, from: image.extent) else { return }
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return }
        samples.append(Sample(image: rgb, time: arrival))
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
    }

    static func nearest(_ samples: [Sample], to time: TimeInterval, settings: RGBAlignment) -> Sample? {
        guard time.isFinite, settings.isValid else { return nil }
        let target = time - settings.timeOffsetMS / 1000
        guard let sample = samples.min(by: { abs($0.time - target) < abs($1.time - target) }),
              abs(sample.time - target) <= settings.toleranceMS / 1000,
              abs(time - sample.time) <= 0.65 else { return nil }
        return sample
    }

    func pair(at arrival: TimeInterval) -> Pair {
        lock.lock(); defer { lock.unlock() }
        guard settings.mode != 0 else { return Pair(image: nil, alignment: settings, note: "") }
        guard let sample = Self.nearest(samples, to: arrival, settings: settings) else {
            return Pair(image: nil, alignment: settings, note: "RGB unavailable / not matched — thermal view")
        }
        return Pair(image: sample.image, alignment: settings,
                    note: String(format: "IR + RGB BETA · arrival Δt %+.0f ms", (sample.time + settings.timeOffsetMS / 1000 - arrival) * 1000))
    }

    func stop() {
        cancelMotion()
        lock.lock(); generation += 1; samples.removeAll(); cameraStatus = "RGB stopped"; lock.unlock()
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }
}

private final class RGBReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let callback: (CMSampleBuffer) -> Void
    init(_ callback: @escaping (CMSampleBuffer) -> Void) { self.callback = callback }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        callback(sampleBuffer)
    }
}
