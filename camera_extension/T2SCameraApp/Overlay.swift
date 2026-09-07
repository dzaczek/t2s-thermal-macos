import CoreGraphics
import Foundation

/// Laying an ordinary picture under the thermal one.
///
/// Holds the mapping between the two cameras, how strongly to blend them, and
/// the bit of image work that turns a webcam frame into something the renderer
/// can mix in.
struct Overlay: Equatable {

    /// Thermal sensor pixels to visible camera pixels. Nil until calibrated.
    var homography: Homography?
    /// 0 is all thermal, 1 is all webcam.
    var blend: Double = 0.4
    var isOn = false

    var isCalibrated: Bool { homography != nil }

    // MARK: - Keeping it

    private static let matrixKey = "overlayHomography"
    private static let blendKey = "overlayBlend"

    static func load() -> Overlay {
        var overlay = Overlay()
        if let stored = UserDefaults.standard.array(forKey: matrixKey) as? [Double],
           stored.count == 9, stored.allSatisfy({ $0.isFinite }) {
            overlay.homography = Homography(m: stored)
        }
        let blend = UserDefaults.standard.double(forKey: blendKey)
        if blend > 0, blend <= 1 { overlay.blend = blend }
        return overlay
    }

    func save() {
        UserDefaults.standard.set(homography?.m, forKey: Overlay.matrixKey)
        UserDefaults.standard.set(blend, forKey: Overlay.blendKey)
    }

    // MARK: - Bringing the webcam picture into the thermal frame

    /// Resamples a visible frame so it lines up with the thermal one, pixel
    /// for pixel, and scales it to 0...255.
    ///
    /// Works in *sensor* coordinates, before any rotation is applied. The
    /// calibration was taken that way and the rotation is applied to this
    /// exactly as it is to the temperatures, so turning the picture cannot
    /// invalidate a calibration.
    func aligned(_ visible: VisibleCapture.Frame,
                 thermalWidth: Int, thermalHeight: Int) -> [Double]? {
        guard let homography else { return nil }

        var out = [Double](repeating: 0, count: thermalWidth * thermalHeight)
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude

        for y in 0..<thermalHeight {
            for x in 0..<thermalWidth {
                let source = homography.map(CGPoint(x: Double(x), y: Double(y)))
                let value = sample(visible, x: Double(source.x), y: Double(source.y))
                out[y * thermalWidth + x] = value
                if value < lowest { lowest = value }
                if value > highest { highest = value }
            }
        }
        guard highest > lowest else { return nil }

        // Stretched to its own range: a webcam picture of a dim room is
        // otherwise too flat to show anything under a false-coloured image.
        let scale = 255 / (highest - lowest)
        for i in out.indices { out[i] = (out[i] - lowest) * scale }
        return out
    }

    /// Bilinear, clamped. Anything the thermal camera sees but the webcam does
    /// not comes out as the nearest edge pixel rather than black, which would
    /// otherwise draw a hard frame across the picture.
    private func sample(_ frame: VisibleCapture.Frame, x: Double, y: Double) -> Double {
        let cx = min(max(x, 0), Double(frame.width - 1))
        let cy = min(max(y, 0), Double(frame.height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, frame.width - 1), y1 = min(y0 + 1, frame.height - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)
        let top = frame.grey[y0 * frame.width + x0] * (1 - fx)
            + frame.grey[y0 * frame.width + x1] * fx
        let bottom = frame.grey[y1 * frame.width + x0] * (1 - fx)
            + frame.grey[y1 * frame.width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: - Finding the fingertip

    /// Where the warmest small thing in the frame is, if there is one.
    ///
    /// A fingertip held up in front of the camera is the easiest landmark
    /// there is on this side: skin runs well above room temperature, so the
    /// hottest pixel is the finger. It is only reported when it genuinely
    /// stands out, so pointing at a radiator does not silently calibrate
    /// against the radiator.
    static func warmPoint(_ temps: [Double], width: Int, height: Int) -> (x: Int, y: Int)? {
        guard temps.count == width * height, !temps.isEmpty else { return nil }
        var hottest = -Double.greatestFiniteMagnitude
        var index = 0
        var total = 0.0
        for (i, t) in temps.enumerated() {
            total += t
            if t > hottest { hottest = t; index = i }
        }
        let mean = total / Double(temps.count)
        // Skin is several degrees above a room. Less than this and there is
        // no fingertip in shot, only the scene.
        guard hottest - mean > 2.5 else { return nil }
        return (index % width, index / width)
    }
}
