#if DEBUG || BENCH
import Foundation

/// Counts how often a view is rebuilt, for benchmark runs: `let _ = BodyCount.bump("ComposeView")` at the top of a
/// `body`. Compiled out of the app people use.
@MainActor
enum BodyCount {
    private(set) static var counts: [String: Int] = [:]

    static func bump(_ name: String) { counts[name, default: 0] += 1 }

    /// How much each count grew since `before`.
    static func since(_ before: [String: Int]) -> [String: Int] {
        counts.reduce(into: [:]) { result, item in
            let grown = item.value - (before[item.key] ?? 0)
            if grown > 0 { result[item.key] = grown }
        }
    }
}
#endif
