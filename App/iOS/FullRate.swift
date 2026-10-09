import UIKit

/// Holds the screen at its fastest rate while something on it is moving.
///
/// A 120 Hz iPhone drops to 80 or 60 for slow movement to save power: a slow scroll, a row under the finger, a
/// short finish after letting go. A display link that asks for the top rate keeps the screen there. It runs only
/// while something moves and for a moment after, so a still screen costs nothing.
@MainActor
enum FullRate {
    private final class Ticker: NSObject {
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { FullRate.tick() } }
    }

    private static let ticker = Ticker()
    private static var link: CADisplayLink?
    private static var until: CFTimeInterval = 0

    /// The fastest this screen goes, and nothing less.
    static var range: CAFrameRateRange {
        let top = Float(UIScreen.main.maximumFramesPerSecond)
        return CAFrameRateRange(minimum: top, maximum: top, preferred: top)
    }

    /// Something moved just now. Called on every frame of a movement, so the hold ends shortly after the last one.
    static func keep(for seconds: Double = 0.25) {
        until = max(until, CACurrentMediaTime() + seconds)
        guard link == nil, UIScreen.main.maximumFramesPerSecond > 60 else { return }
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick))
        link.preferredFrameRateRange = range
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Holds the rate for as long as this scroll view moves, under a finger or coasting. Keep what it returns.
    static func follow(_ scroll: UIScrollView) -> NSKeyValueObservation {
        scroll.observe(\.contentOffset) { _, _ in MainActor.assumeIsolated { keep() } }
    }

    private static func tick() {
        guard CACurrentMediaTime() > until else { return }
        link?.invalidate()
        link = nil
    }
}
