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
    /// Whether the webcam picture keeps its colour. It should, for anything
    /// where the colour carries information -- a board, a loom of wires, a
    /// labelled panel.
    var colour = true

    var isCalibrated: Bool { homography != nil }

    // MARK: - Keeping it

    private static let matrixKey = "overlayHomography"
    private static let blendKey = "overlayBlend"
    private static let colourKey = "overlayColour"

    static func load() -> Overlay {
        var overlay = Overlay()
        if let stored = UserDefaults.standard.array(forKey: matrixKey) as? [Double],
           stored.count == 9, stored.allSatisfy({ $0.isFinite }) {
            overlay.homography = Homography(m: stored)
        }
        let blend = UserDefaults.standard.double(forKey: blendKey)
        if blend > 0, blend <= 1 { overlay.blend = blend }
        if UserDefaults.standard.object(forKey: colourKey) != nil {
            overlay.colour = UserDefaults.standard.bool(forKey: colourKey)
        }
        return overlay
    }

    func save() {
        UserDefaults.standard.set(homography?.m, forKey: Overlay.matrixKey)
        UserDefaults.standard.set(blend, forKey: Overlay.blendKey)
        UserDefaults.standard.set(colour, forKey: Overlay.colourKey)
    }

    // MARK: - Bringing the webcam picture into the thermal frame

    /// Resamples a visible frame so it lines up with the thermal one, pixel
    /// for pixel, as three bytes a pixel.
    ///
    /// Works in *sensor* coordinates, before any rotation is applied. The
    /// calibration was taken that way and the rotation is applied to this
    /// exactly as it is to the temperatures, so turning the picture cannot
    /// invalidate a calibration.
    func aligned(_ visible: VisibleCapture.Frame,
                 thermalWidth: Int, thermalHeight: Int) -> [UInt8]? {
        guard let homography else { return nil }

        var out = [Double](repeating: 0, count: thermalWidth * thermalHeight * 3)
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude

        for y in 0..<thermalHeight {
            for x in 0..<thermalWidth {
                let source = homography.map(CGPoint(x: Double(x), y: Double(y)))
                let pixel = sample(visible, x: Double(source.x), y: Double(source.y))
                let i = (y * thermalWidth + x) * 3
                out[i] = pixel.r; out[i + 1] = pixel.g; out[i + 2] = pixel.b
                let luma = 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b
                if luma < lowest { lowest = luma }
                if luma > highest { highest = luma }
            }
        }
        guard highest > lowest else { return nil }

        // Stretched to its own range, because a webcam picture of a dim room
        // is otherwise too flat to show anything under a false-coloured image.
        //
        // The stretch is worked out on brightness and then applied to all
        // three channels by the same *factor*. Subtracting the black level
        // from each channel separately, which is the obvious way to write
        // this, quietly changes the colours: take a dim red at (100, 40, 40),
        // subtract 30, and the ratio goes from 2.5:1 to 7:1. In the darkest
        // parts, where channels clamp at zero, the colour is lost altogether
        // -- which is exactly the shadowed corner of a board where you most
        // want to see which wire is which.
        let gain = 255 / (highest - lowest)
        var bytes = [UInt8](repeating: 0, count: out.count)
        for i in stride(from: 0, to: out.count, by: 3) {
            let luma = 0.299 * out[i] + 0.587 * out[i + 1] + 0.114 * out[i + 2]
            let wanted = (luma - lowest) * gain
            // Below this there is no colour left to preserve, and the ratio
            // would be dividing by noise.
            let factor = luma > 1 ? wanted / luma : 0
            for channel in 0..<3 {
                bytes[i + channel] = UInt8(max(0, min(255, out[i + channel] * factor)))
            }
        }
        if !colour {
            // Same picture, drained. Under a strongly false-coloured thermal
            // image this is sometimes easier to read than two sets of colours
            // arguing with each other.
            for i in stride(from: 0, to: bytes.count, by: 3) {
                let luma = 0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1])
                    + 0.114 * Double(bytes[i + 2])
                let grey = UInt8(max(0, min(255, luma)))
                bytes[i] = grey; bytes[i + 1] = grey; bytes[i + 2] = grey
            }
        }
        return bytes
    }

    /// Bilinear, clamped. Anything the thermal camera sees but the webcam does
    /// not comes out as the nearest edge pixel rather than black, which would
    /// otherwise draw a hard frame across the picture.
    private func sample(_ frame: VisibleCapture.Frame,
                        x: Double, y: Double) -> (r: Double, g: Double, b: Double) {
        let cx = min(max(x, 0), Double(frame.width - 1))
        let cy = min(max(y, 0), Double(frame.height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, frame.width - 1), y1 = min(y0 + 1, frame.height - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)

        func channel(_ offset: Int) -> Double {
            let a = Double(frame.rgb[(y0 * frame.width + x0) * 3 + offset]) * (1 - fx)
                + Double(frame.rgb[(y0 * frame.width + x1) * 3 + offset]) * fx
            let b = Double(frame.rgb[(y1 * frame.width + x0) * 3 + offset]) * (1 - fx)
                + Double(frame.rgb[(y1 * frame.width + x1) * 3 + offset]) * fx
            return a * (1 - fy) + b * fy
        }
        return (channel(0), channel(1), channel(2))
    }

    // MARK: - Finding the warm thing

    /// The middle of the warmest thing in the frame, if there is one.
    ///
    /// This started as "the hottest pixel", which was useless in practice:
    /// across a hand several hundred pixels sit within a fraction of a degree
    /// of each other, so noise threw the answer from knuckle to fingertip and
    /// back several times a second and there was nothing to aim at.
    ///
    /// So it finds the warm *thing* instead -- the run of connected pixels
    /// near the top of the range, starting from the hottest one -- and reports
    /// its middle. The middle of a hand does not jitter, and it is just as
    /// good a landmark: what matters is picking the same physical point in
    /// both pictures, not that the point be a fingertip.
    ///
    /// Nothing is reported unless the warm thing genuinely stands out and is
    /// small enough to be something held up, so a radiator across the back of
    /// the scene is not silently calibrated against.
    static func warmPoint(_ temps: [Double], width: Int, height: Int) -> (x: Int, y: Int)? {
        guard let blob = warmBlob(temps, width: width, height: height) else { return nil }
        return (blob.centreX, blob.centreY)
    }

    /// The warm thing itself: which pixels it covers and where its middle is.
    struct WarmBlob {
        var pixels: [Int]
        var centreX: Int, centreY: Int
    }

    static func warmBlob(_ temps: [Double], width: Int, height: Int) -> WarmBlob? {
        guard temps.count == width * height, !temps.isEmpty else { return nil }

        var hottest = -Double.greatestFiniteMagnitude
        var total = 0.0
        for t in temps {
            total += t
            if t > hottest { hottest = t }
        }
        let mean = total / Double(temps.count)
        // Skin runs several degrees above a room. Less than this and there is
        // nothing held up, only the scene.
        guard hottest - mean > 2.5 else { return nil }

        // The threshold comes up from the scene rather than down from the
        // peak. Measuring down from the hottest pixel sounds right and is not:
        // the peak is itself the top of the noise, so the threshold moves
        // frame to frame, and it sits so close to the peak that only the
        // warmest specks qualify.
        let threshold = max(mean + 0.45 * (hottest - mean), mean + 2.0)
        // Bigger than this is not something held up in front of the camera;
        // it is a wall, a window or a heater, and its middle means nothing.
        let biggest = width * height / 6

        // The largest warm region, not the one containing the hottest pixel.
        // At a useful threshold the fingers of a hand are often islands of
        // their own, separate from the palm, and the hottest pixel wanders
        // between them with the noise -- so following it made the answer jump
        // from finger to finger several times a second, which is exactly what
        // this looked like in use. The largest region is the palm, and it
        // stays put.
        var seen = [Bool](repeating: false, count: temps.count)
        var best: WarmBlob?
        var bestSize = 0

        for seed in temps.indices where !seen[seed] && temps[seed] >= threshold {
            var queue = [seed]
            seen[seed] = true
            var pixels: [Int] = []
            var sumX = 0, sumY = 0

            while let index = queue.popLast() {
                pixels.append(index)
                sumX += index % width
                sumY += index / width
                let x = index % width, y = index / width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard !seen[next], temps[next] >= threshold else { continue }
                    seen[next] = true
                    queue.append(next)
                }
            }
            if pixels.count > bestSize {
                bestSize = pixels.count
                best = WarmBlob(pixels: pixels,
                                centreX: sumX / pixels.count, centreY: sumY / pixels.count)
            }
        }

        // A handful of pixels is noise; a third of the picture is furniture.
        guard let best, bestSize >= 12, bestSize <= biggest else { return nil }
        return best
    }
}
