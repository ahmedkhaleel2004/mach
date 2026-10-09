import UIKit

/// The small ticks under a swipe and a long press. The generators are made once and told a touch is under way
/// (`prepare`), which keeps the phone's tick motor awake for a second or two; a generator made at the very moment
/// of the tick, as before, first had to wake it, and the tick came late.
@MainActor
enum Haptics {
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)

    /// A swipe or back-drag has begun and may tick soon.
    static func prepare() {
        rigid.prepare()
        soft.prepare()
    }

    /// The tick the moment a swipe "takes" (firm), or stops taking (soft).
    static func arm(_ armed: Bool) {
        if armed { rigid.impactOccurred(intensity: 0.9) } else { soft.impactOccurred(intensity: 0.5) }
        // Still under the finger: the next tick may follow at once.
        prepare()
    }

    /// The tick of a long press selecting a row.
    static func select() { medium.impactOccurred() }
}
