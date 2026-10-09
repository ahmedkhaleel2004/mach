#if DEBUG || BENCH
import SwiftUI
import UIKit

/// Finds out, on the system the app is running on, which ways of telling SwiftUI "this view has not changed" really
/// stop its `body` being run again. Compiled out of the app people use.
///
/// A parent view is rebuilt ten times; each child is given the same values every time (as equal text held in a new
/// piece of memory, the way a row read again from the database is). A child whose count stays at 1 was skipped.
@MainActor
enum ListEqLab {
    @Observable
    final class Ticker {
        var count = 0
    }

    static let constant = fresh("one piece of memory, handed to the view again and again, never copied")
    nonisolated(unsafe) static var equalsCalls: [String: Int] = [:]

    /// The same characters in memory of their own each time, so two values are equal but not the same bytes.
    static func fresh(_ text: String) -> String { String(Array(text)) }

    static func run() async {
        guard let scene = ListBench.window?.windowScene else { return }
        let ticker = Ticker()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: EqParent(ticker: ticker))
        window.windowLevel = .normal + 1
        window.isHidden = false
        await ListBench.frames(10)
        let before = BodyCount.counts
        for _ in 0 ..< 10 {
            ticker.count += 1
            await ListBench.frames(2)
        }
        var fields: [String: Any] = [:]
        for (name, grown) in BodyCount.since(before) where name.hasPrefix("Eq") { fields[name] = grown }
        for (name, calls) in equalsCalls { fields["equalsCalls_" + name] = calls }
        Bench.record("eq", ms: 0, fields)
        window.isHidden = true
        window.rootViewController = nil
        await ListBench.frames(4)
    }
}

private struct EqParent: View {
    let ticker: ListEqLab.Ticker

    var body: some View {
        let _ = BodyCount.bump("EqParent")
        let text = ListEqLab.fresh("the same words every time, long enough not to be stored inline")
        VStack {
            Text("\(ticker.count)")
            // Not Equatable, no property wrappers: SwiftUI's own comparison.
            EqPlain(text: text)
            // Equatable, with and without `.equatable()`.
            EqEquatable(text: text)
            EqEquatable2(text: text).equatable()
            // With a setting read by @AppStorage, as the list row has.
            EqStorage(text: text)
            EqStorageEquatable(text: text)
            EqStorageEquatable2(text: text).equatable()
            // With @State, as the sender's picture has.
            EqStateEquatable(text: text)
            EqStateEquatable2(text: text).equatable()
            // A plain Equatable view around one with a setting.
            EqShield(text: text).equatable()
            // The very same piece of memory every time.
            EqSame(text: ListEqLab.constant)
            EqSameStorage(text: ListEqLab.constant)
            // Only a number.
            EqNumber(number: 7)
            // Does SwiftUI call == at all?
            EqCounted(text: text)
            EqCounted2(text: text).equatable()
            EquatableView(content: EqCounted3(text: text))
        }
    }
}

private struct EqPlain: View {
    let text: String
    var body: some View {
        let _ = BodyCount.bump("EqPlain")
        Text(text)
    }
}

private struct EqEquatable: View, Equatable {
    let text: String
    var body: some View {
        let _ = BodyCount.bump("EqEquatable")
        Text(text)
    }
}

private struct EqEquatable2: View, Equatable {
    let text: String
    var body: some View {
        let _ = BodyCount.bump("EqEquatableWrapped")
        Text(text)
    }
}

private struct EqStorage: View {
    let text: String
    @AppStorage("rowStyle") private var style = 1
    var body: some View {
        let _ = BodyCount.bump("EqStorage")
        Text(text + String(style))
    }
}

private struct EqStorageEquatable: View, Equatable {
    let text: String
    @AppStorage("rowStyle") private var style = 1
    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text }
    var body: some View {
        let _ = BodyCount.bump("EqStorageEquatable")
        Text(text + String(style))
    }
}

private struct EqStorageEquatable2: View, Equatable {
    let text: String
    @AppStorage("rowStyle") private var style = 1
    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text }
    var body: some View {
        let _ = BodyCount.bump("EqStorageEquatableWrapped")
        Text(text + String(style))
    }
}

private struct EqStateEquatable: View, Equatable {
    let text: String
    @State private var flag = false
    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text }
    var body: some View {
        let _ = BodyCount.bump("EqStateEquatable")
        Text(text + String(flag))
    }
}

private struct EqStateEquatable2: View, Equatable {
    let text: String
    @State private var flag = false
    nonisolated static func == (a: Self, b: Self) -> Bool { a.text == b.text }
    var body: some View {
        let _ = BodyCount.bump("EqStateEquatableWrapped")
        Text(text + String(flag))
    }
}

private struct EqShield: View, Equatable {
    let text: String
    var body: some View {
        let _ = BodyCount.bump("EqShield")
        EqStorage2(text: text)
    }
}

private struct EqStorage2: View {
    let text: String
    @AppStorage("rowStyle") private var style = 1
    var body: some View {
        let _ = BodyCount.bump("EqShielded")
        Text(text + String(style))
    }
}

private struct EqSame: View {
    let text: String
    var body: some View {
        let _ = BodyCount.bump("EqSame")
        Text(text)
    }
}

private struct EqSameStorage: View {
    let text: String
    @AppStorage("rowStyle") private var style = 1
    var body: some View {
        let _ = BodyCount.bump("EqSameStorage")
        Text(text + String(style))
    }
}

private struct EqNumber: View {
    let number: Int
    var body: some View {
        let _ = BodyCount.bump("EqNumber")
        Text(String(number))
    }
}

struct EqCounted: View, Equatable {
    let text: String
    nonisolated static func == (a: Self, b: Self) -> Bool {
        ListEqLab.equalsCalls["plain", default: 0] += 1
        return a.text == b.text
    }
    var body: some View {
        let _ = BodyCount.bump("EqCounted")
        Text(text)
    }
}

struct EqCounted2: View, Equatable {
    let text: String
    nonisolated static func == (a: Self, b: Self) -> Bool {
        ListEqLab.equalsCalls["modifier", default: 0] += 1
        return a.text == b.text
    }
    var body: some View {
        let _ = BodyCount.bump("EqCountedModifier")
        Text(text)
    }
}

struct EqCounted3: View, Equatable {
    let text: String
    nonisolated static func == (a: Self, b: Self) -> Bool {
        ListEqLab.equalsCalls["wrapper", default: 0] += 1
        return a.text == b.text
    }
    var body: some View {
        let _ = BodyCount.bump("EqCountedWrapper")
        Text(text)
    }
}
#endif
