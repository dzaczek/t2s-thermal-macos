import Foundation

/// Frame-rate and per-stage timing, printed to stderr with T2S_PROFILE=1.
///
/// Worth keeping rather than measuring from outside: polling the published
/// frame file's mtime from a shell undercounts badly (it reported 20fps for a
/// pipeline that was actually running at a full 25), and the window is the
/// app's only other output. `arrived` vs `processed` is the number that
/// matters -- if they match, nothing is being dropped and the camera is the
/// ceiling.
final class Profile {
    static let shared = Profile()

    private let enabled = ProcessInfo.processInfo.environment["T2S_PROFILE"] != nil
    private let lock = NSLock()
    private var arrivals = 0
    private var compute = 0.0, render = 0.0, publish = 0.0, total = 0.0, n = 0.0
    private var windowStart = CFAbsoluteTimeGetCurrent()

    var isEnabled: Bool { enabled }

    func frameArrived() {
        guard enabled else { return }
        lock.lock(); arrivals += 1; lock.unlock()
    }

    func record(compute c: Double, render r: Double, publish p: Double, total t: Double) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        compute += c; render += r; publish += p; total += t; n += 1

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - windowStart
        guard elapsed >= 5, n > 0 else { return }
        FileHandle.standardError.write(String(format:
            "PROF arrived=%.1f/s processed=%.1f/s | compute=%.1f render=%.1f publish=%.1f total=%.1f ms\n",
            Double(arrivals) / elapsed, n / elapsed,
            compute / n * 1000, render / n * 1000,
            publish / n * 1000, total / n * 1000).data(using: .utf8)!)
        arrivals = 0; compute = 0; render = 0; publish = 0; total = 0; n = 0
        windowStart = now
    }
}
