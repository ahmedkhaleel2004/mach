#if DEBUG || BENCH
import Foundation

/// Timing for benchmark runs. Compiled out of the app people use.
///
/// Results are appended to `bench.jsonl` in the data folder, one JSON object a line: `{"metric": ..., "ms": ...}`.
enum Bench {
    /// Milliseconds on a clock that never jumps.
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    /// Milliseconds since the system started this process, measured from before any of our code ran.
    static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let started = Double(info.kp_proc.p_starttime.tv_sec) * 1000 + Double(info.kp_proc.p_starttime.tv_usec) / 1000
        return Date().timeIntervalSince1970 * 1000 - started
    }

    private static let queue = DispatchQueue(label: "blitz.bench")
    private static let file = Bootstrap.directory.appendingPathComponent("bench.jsonl")

    static func record(_ metric: String, ms: Double, _ extra: [String: Any] = [:]) {
        var object = extra
        object["metric"] = metric
        object["ms"] = (ms * 1000).rounded() / 1000
        queue.async {
            guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }

    /// Records each named moment once, as time since the process started. For launch timings.
    private static var seen = Set<String>()
    /// Each line also carries the processor time the main thread has used so far (`cpu`, steadier than the clock in a
    /// simulator) and the wall clock (`wall`, to line up with what a script outside the app saw).
    @MainActor static func once(_ metric: String, _ extra: [String: Any] = [:]) {
        guard seen.insert(metric).inserted else { return }
        var extra = extra
        extra["cpu"] = (Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e3).rounded() / 1e3
        extra["wall"] = (Date().timeIntervalSince1970 * 1000).rounded()
        record(metric, ms: sinceProcessStart(), extra)
    }
}
#endif
