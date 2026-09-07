import Foundation

/// A quarter turn applied to the sensor image.
///
/// The camera ends up mounted whichever way the job allows -- upside down
/// under a shelf, on its side to see down a rack -- and it has no rotation of
/// its own. The turn is applied to the temperature field rather than to the
/// finished picture, so the markers, the measurement objects and the mouse all
/// land in the same place, and the labels stay the right way up.
enum ImageRotation: Int, CaseIterable {
    /// Clockwise quarter turns.
    case none = 0, right = 1, upsideDown = 2, left = 3

    func turnedLeft() -> ImageRotation { ImageRotation(rawValue: (rawValue + 3) % 4)! }
    func turnedRight() -> ImageRotation { ImageRotation(rawValue: (rawValue + 1) % 4)! }

    /// The turn that undoes this one, for mapping a point on a turned picture
    /// back to where it came from.
    var inverse: ImageRotation { ImageRotation(rawValue: (4 - rawValue) % 4)! }

    /// A quarter turn puts the image on its side, so the axes swap.
    var swapsAxes: Bool { rawValue % 2 == 1 }

    func size(width: Int, height: Int) -> (width: Int, height: Int) {
        swapsAxes ? (height, width) : (width, height)
    }

    var displayName: String {
        switch self {
        case .none: return "0\u{00B0}"
        case .right: return "90\u{00B0}"
        case .upsideDown: return "180\u{00B0}"
        case .left: return "270\u{00B0}"
        }
    }

    /// Where a pixel of the source frame ends up once turned.
    func map(x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        switch self {
        case .none:       return (x, y)
        case .right:      return (height - 1 - y, x)
        case .upsideDown: return (width - 1 - x, height - 1 - y)
        case .left:       return (y, width - 1 - x)
        }
    }

    /// Turns a per-pixel buffer. `width`/`height` describe the input.
    ///
    /// `components` covers buffers that hold more than one value a pixel --
    /// three bytes for a colour picture, say -- which are turned as whole
    /// pixels rather than as loose numbers.
    func apply<T>(_ values: [T], width: Int, height: Int, components: Int = 1) -> [T] {
        guard self != .none, components >= 1,
              values.count == width * height * components else { return values }
        let out = size(width: width, height: height)
        var result = values
        for y in 0..<height {
            for x in 0..<width {
                let p = map(x: x, y: y, width: width, height: height)
                let from = (y * width + x) * components
                let to = (p.y * out.width + p.x) * components
                for c in 0..<components { result[to + c] = values[from + c] }
            }
        }
        return result
    }
}
