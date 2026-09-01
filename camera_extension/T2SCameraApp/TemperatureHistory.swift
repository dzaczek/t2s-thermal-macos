import AppKit
import Foundation

/// Rolling temperature history for the measurement objects, for live plotting.
///
/// Written from the capture queue and read from the main queue by the chart,
/// so every access goes through the lock.
final class TemperatureHistory {

    struct Sample {
        var time: CFAbsoluteTime
        var value: Double
    }

    /// How far back the plot reaches. Samples arrive at the camera's 25fps, so
    /// this is ~3000 points per series -- cheap to hold, and downsampled at
    /// draw time to the width of the chart.
    static let window: TimeInterval = 120

    /// Distinguishable series colours, reused cyclically.
    static let colors: [NSColor] = [
        .systemYellow, .systemGreen, .systemTeal, .systemPink,
        .systemPurple, .systemOrange, .systemBlue, .systemRed,
    ]

    private let lock = NSLock()
    private var samples: [String: [Sample]] = [:]
    /// Insertion order, so a series keeps its colour as others come and go.
    private var order: [String] = []

    func append(_ value: Double, for key: String, at time: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard value.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        if samples[key] == nil {
            samples[key] = []
            order.append(key)
        }
        samples[key]?.append(Sample(time: time, value: value))
        let cutoff = time - TemperatureHistory.window
        if let first = samples[key]?.first, first.time < cutoff {
            samples[key] = samples[key]?.filter { $0.time >= cutoff }
        }
    }

    /// Drops series that no longer correspond to a live measurement object.
    func retain(keys: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for key in order where !keys.contains(key) {
            samples[key] = nil
        }
        order.removeAll { !keys.contains($0) }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
        order.removeAll()
    }

    struct Series {
        var key: String
        var color: NSColor
        var samples: [Sample]
    }

    func snapshot() -> [Series] {
        lock.lock(); defer { lock.unlock() }
        return order.enumerated().compactMap { index, key in
            guard let s = samples[key], !s.isEmpty else { return nil }
            return Series(key: key,
                          color: TemperatureHistory.colors[index % TemperatureHistory.colors.count],
                          samples: s)
        }
    }

    /// Last `count` values for one series, evenly downsampled -- for the
    /// inline sparklines, which are far too small to want every sample.
    func recent(_ key: String, count: Int) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        guard let s = samples[key], !s.isEmpty else { return [] }
        guard s.count > count else { return s.map(\.value) }
        let stride = Double(s.count) / Double(count)
        return (0..<count).map { s[min(s.count - 1, Int(Double($0) * stride))].value }
    }
}
