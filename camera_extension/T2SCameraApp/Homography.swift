import Foundation
import CoreGraphics

/// The mapping between what two cameras see of the same scene.
///
/// Bolt a webcam next to the thermal camera and the two pictures never quite
/// agree: the lenses have different fields of view, the sensors are different
/// shapes, and the two are a few centimetres apart and never perfectly
/// parallel. A shift and a scale cannot express that last part -- looking at
/// the same wall from a slightly different angle turns a rectangle into a
/// trapezium.
///
/// Four matched points are exactly enough to pin down the mapping that can:
/// eight numbers for eight unknowns. That is why the calibration asks for four
/// and not two.
///
/// What it does not model is parallax. The mapping is exact for one plane --
/// the wall you calibrated against -- and everything nearer or further sits
/// slightly off, by more the bigger the gap between the two cameras. Mount
/// them close together and calibrate at roughly the distance you work at.
struct Homography: Equatable {

    /// Row-major, with the last element fixed at 1.
    var m: [Double]

    static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Where a point of the first camera lands in the second.
    func map(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return p }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// Solves for the mapping taking each `from` to its `to`.
    ///
    /// Four pairs, eight equations, eight unknowns -- the ninth is fixed at 1,
    /// since scaling the whole matrix changes nothing. Returns nil when the
    /// points cannot pin a mapping down: three of them in a line, or two on
    /// top of each other, which is what a careless calibration looks like.
    static func solve(_ pairs: [(from: CGPoint, to: CGPoint)]) -> Homography? {
        guard pairs.count == 4 else { return nil }

        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for (i, pair) in pairs.enumerated() {
            let x = Double(pair.from.x), y = Double(pair.from.y)
            let u = Double(pair.to.x), v = Double(pair.to.y)
            a[i * 2] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
            a[i * 2 + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
        }

        guard let h = solveLinearSystem(&a) else { return nil }
        let matrix = h + [1.0]
        guard matrix.allSatisfy({ $0.isFinite }) else { return nil }

        let candidate = Homography(m: matrix)
        // Trust it only if it actually reproduces the points it was built
        // from. A nearly-degenerate arrangement can squeeze through the
        // elimination and come out as nonsense.
        for pair in pairs {
            let got = candidate.map(pair.from)
            if abs(got.x - pair.to.x) > 0.5 || abs(got.y - pair.to.y) > 0.5 { return nil }
        }
        return candidate
    }

    /// The mapping the other way.
    var inverse: Homography? {
        let a = m
        // Cofactors of the 3x3.
        let c = [
            a[4] * a[8] - a[5] * a[7], a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            a[5] * a[6] - a[3] * a[8], a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            a[3] * a[7] - a[4] * a[6], a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]
        ]
        let determinant = a[0] * c[0] + a[1] * c[3] + a[2] * c[6]
        guard abs(determinant) > 1e-12 else { return nil }
        // Normalise so the last element is 1 again, which keeps `map` simple.
        let scale = c[8] / determinant
        guard abs(scale) > 1e-12 else { return nil }
        let inverted = c.map { $0 / determinant / scale }
        guard inverted.allSatisfy({ $0.isFinite }) else { return nil }
        return Homography(m: inverted)
    }

    /// Gaussian elimination with partial pivoting on an 8x9 augmented matrix.
    private static func solveLinearSystem(_ a: inout [[Double]]) -> [Double]? {
        let n = 8
        for column in 0..<n {
            // Pivot on the largest remaining row, which is what keeps this
            // stable when the points are awkwardly placed.
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-10 else { return nil }
            a.swapAt(column, pivot)

            let divisor = a[column][column]
            for k in column...n { a[column][k] /= divisor }
            for row in 0..<n where row != column {
                let factor = a[row][column]
                guard factor != 0 else { continue }
                for k in column...n { a[row][k] -= factor * a[column][k] }
            }
        }
        return (0..<n).map { a[$0][n] }
    }
}
