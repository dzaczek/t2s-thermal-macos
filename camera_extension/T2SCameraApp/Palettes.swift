import Foundation

/// False-colour palettes, ported from the Python prototype so the two render
/// identically. Each builds a 256-entry RGB lookup table.
enum Palette: Int, CaseIterable {
    case ironbow, whiteHot, blackHot, rainbow, hot, inferno

    var displayName: String {
        switch self {
        case .ironbow:  return "Ironbow"
        case .whiteHot: return "White Hot"
        case .blackHot: return "Black Hot"
        case .rainbow:  return "Rainbow"
        case .hot:      return "Hot"
        case .inferno:  return "Inferno"
        }
    }

    /// Control points, interpolated to 256 entries. Ironbow matches the
    /// Python build_ironbow_lut() stops; the rest approximate the OpenCV
    /// colormaps the prototype used (JET / HOT / INFERNO).
    private var stops: [(Double, (Double, Double, Double))] {
        switch self {
        case .ironbow:
            return [(0.00, (0, 0, 0)), (0.10, (20, 0, 45)), (0.25, (85, 0, 90)),
                    (0.40, (160, 10, 70)), (0.55, (215, 55, 15)), (0.70, (245, 120, 0)),
                    (0.85, (250, 200, 30)), (1.00, (255, 255, 200))]
        case .whiteHot:
            return [(0.0, (0, 0, 0)), (1.0, (255, 255, 255))]
        case .blackHot:
            return [(0.0, (255, 255, 255)), (1.0, (0, 0, 0))]
        case .rainbow:  // JET
            return [(0.00, (0, 0, 128)), (0.125, (0, 0, 255)), (0.375, (0, 255, 255)),
                    (0.625, (255, 255, 0)), (0.875, (255, 0, 0)), (1.00, (128, 0, 0))]
        case .hot:
            return [(0.00, (0, 0, 0)), (0.37, (255, 0, 0)),
                    (0.75, (255, 255, 0)), (1.00, (255, 255, 255))]
        case .inferno:
            return [(0.00, (0, 0, 4)), (0.20, (44, 12, 90)), (0.40, (114, 31, 129)),
                    (0.60, (183, 55, 121)), (0.80, (240, 105, 78)), (0.90, (252, 165, 46)),
                    (1.00, (252, 255, 164))]
        }
    }

    /// 256 * 3 bytes, RGB order.
    var lut: [UInt8] {
        let s = stops
        var table = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let x = Double(i) / 255.0
            var lower = s[0], upper = s[s.count - 1]
            for j in 0..<(s.count - 1) where x >= s[j].0 && x <= s[j + 1].0 {
                lower = s[j]; upper = s[j + 1]
                break
            }
            let span = upper.0 - lower.0
            let t = span > 0 ? (x - lower.0) / span : 0
            table[i * 3 + 0] = UInt8(max(0, min(255, lower.1.0 + t * (upper.1.0 - lower.1.0))))
            table[i * 3 + 1] = UInt8(max(0, min(255, lower.1.1 + t * (upper.1.1 - lower.1.1))))
            table[i * 3 + 2] = UInt8(max(0, min(255, lower.1.2 + t * (upper.1.2 - lower.1.2))))
        }
        return table
    }
}
