import MachCore
import MachSynthetic
import Foundation

// Benchmarks for the parts of Mach that have no screen. Never touches the network.
//
//   machbench generate <data-dir> [messages] [seed]    a made-up mailbox in <data-dir>/mail.sqlite
//   machbench demo <data-dir>                           a small made-up inbox for screenshots
//   machbench pictures <data-dir>                       adds three conversations with real pictures to a working copy
//   machbench <name> <data-dir> [args...]               one benchmark; prints JSON lines
//
// Each benchmark lives in its own file in this folder and adds itself to `benchmarks` below.

typealias Benchmark = (_ store: Store, _ args: [String]) throws -> Void

/// Runs `body` `runs` times after a warm-up and prints the median and the slowest decile, in milliseconds.
func measure(_ name: String, runs: Int = 50, warmup: Int = 3, _ body: () throws -> Void) rethrows {
    for _ in 0..<warmup { try body() }
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    samples.sort()
    report(name, ["median_ms": samples[samples.count / 2], "p90_ms": samples[min(samples.count - 1, samples.count * 9 / 10)], "min_ms": samples[0], "runs": Double(runs)])
}

func report(_ name: String, _ values: [String: Double]) {
    let fields = values.keys.sorted().map { "\"\($0)\":\(String(format: "%.3f", values[$0]!))" }.joined(separator: ",")
    print("{\"metric\":\"\(name)\",\(fields)}")
}

var benchmarks: [String: Benchmark] = [:]
benchmarks["store"] = storeBench
benchmarks["compose"] = composeBenchmark

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    print("usage: machbench generate <data-dir> [messages] [seed] | machbench <name> <data-dir> [args...]")
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mach").standardizedFileURL.path
guard directory.standardizedFileURL.path != real else {
    print("refusing to run against the real mailbox; copy it first (bench/copy-real.sh)")
    exit(2)
}
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let store = try Store(path: directory.appendingPathComponent("mail.sqlite").path)
registerSyncBenchmarks(directory: directory)

if arguments[0] == "generate" {
    let count = arguments.count > 2 ? Int(arguments[2]) ?? 50_000 : 50_000
    let seed = arguments.count > 3 ? UInt64(arguments[3]) ?? 1 : 1
    let start = Date()
    let written = try SyntheticMailbox.generate(into: store, messages: count, seed: seed)
    _ = try store.pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    report("generate", ["messages": Double(written), "seconds": Date().timeIntervalSince(start)])
} else if arguments[0] == "demo" {
    // A small, tidy, made-up inbox for the screenshots in the README.
    try SyntheticMailbox.demo(into: store)
    _ = try store.pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    print(SyntheticMailbox.demoAccount)
} else if arguments[0] == "pictures" {
    // Their attachments' bytes go to <data-dir>/bench-pictures; `bench/ios-thread` tells the app where they are.
    try SyntheticMailbox.addPictureMail(into: store, pictures: directory.appendingPathComponent("bench-pictures", isDirectory: true))
    for (shape, thread) in SyntheticMailbox.pictureThreads { print("\(shape)\t\(SyntheticMailbox.accounts[0])\t\(thread)") }
} else if let benchmark = benchmarks[arguments[0]] {
    try benchmark(store, Array(arguments.dropFirst(2)))
} else {
    print("unknown benchmark \(arguments[0]); known: \(benchmarks.keys.sorted().joined(separator: ", "))")
    exit(2)
}
