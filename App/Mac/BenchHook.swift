#if DEBUG || BENCH
import AppKit
import BlitzCore
import SwiftUI

/// Benchmark commands for the Mac window. Compiled out of the app people use.
///
/// Commands arrive on the debug channel as `bench:<command>` or, for a whole run, in `BLITZ_BENCH_SCRIPT`
/// (commands separated by `;`), and run one after another. Every timing is main-thread time: from the key
/// reaching the model to the end of that turn of the run loop, after SwiftUI has updated and Core Animation
/// has committed the frame. `busy` is everything the main thread did until it next went idle, per key.
///
///     wait:<ms>                       do nothing for a while
///     size:<w>x<h>                    give the window a fixed size
///     front | back                    show the window without activating the app, or put it behind again
///     limit:<n>                       load n rows into the list on screen
///     select:<n>                      tick the first n rows
///     key:<metric>:<key>              press one key and time it (`j`, `special:tab`, `cmd:k`, as on the debug channel)
///     repeat:<n>:<metric>:<key>       the same key n times, one per turn of the run loop
///     settle:<metric>:<ms>:<key>      one key, then watch the main thread for ms (the database answering, the list re-applied)
///     palette:<text> | search:<text>  type into the command bar or the search field, one letter a turn
///     scroll:<frames>:<points>        scroll the list by that many points a frame
///     churn:<n>                       n writes to a conversation that is not in the list, as a sync would make
///     web                             record how much the open conversation's page holds
///     info | done | quit              record the window and row count; mark the end of a script; leave
@MainActor
final class BenchRunner {
    static let shared = BenchRunner()
    private weak var model: AppModel?
    private var queue: [String] = []
    private var running = false
    private var wakeStart: Double?
    private var busyTotal = 0.0
    private var busyMax = 0.0
    private var awake: NSObjectProtocol?

    private var window: NSWindow? { NSApp.windows.first { $0.frame.width > 700 } }

    func start(model: AppModel) {
        self.model = model
        // A window behind others would otherwise be put to sleep (App Nap) and its timers held back.
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "benchmark")
        // Time the main thread spends awake: from the run loop waking to it going back to sleep.
        let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { BenchRunner.shared.wakeStart = Bench.now() }
        }
        let slept = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                let runner = BenchRunner.shared
                guard let start = runner.wakeStart else { return }
                let spent = Bench.now() - start
                runner.busyTotal += spent
                runner.busyMax = max(runner.busyMax, spent)
                runner.wakeStart = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), woke, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), slept, .commonModes)
        Bench.record("launch.pid", ms: 0, ["pid": Int(getpid())])
        watchFirstFrame()
        if let script = ProcessInfo.processInfo.environment["BLITZ_BENCH_SCRIPT"], !script.isEmpty {
            // Wait for the first frame, so launch is timed with nothing else going on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.enqueue(script.split(separator: ";").map(String.init)) }
        }
    }

    func enqueue(_ commands: [String]) {
        queue += commands
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        run(queue.removeFirst()) {
            self.running = false
            self.pump()
        }
    }

    /// Runs the block once this turn of the run loop is over: views updated, layout done, frame committed.
    private func afterCommit(_ block: @escaping () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, false, CFIndex.max - 1) { _, _ in
            block()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The first frame with mail in it: the window is on screen and the list has been laid out and committed.
    private func watchFirstFrame() {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max - 2) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible, let list = self.listScroll(), (list.documentView?.frame.height ?? 0) > 100 else { return }
                Bench.record("launch.firstFrame", ms: Bench.sinceProcessStart(), ["rows": self.model?.rows.count ?? 0, "occluded": !window.occlusionState.contains(.visible)])
                if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The scroll view behind the list of conversations.
    private func listScroll() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, String(describing: type(of: view)).contains("WK") == false { return scroll }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        return window?.contentView.flatMap(find)
    }

    private func press(_ command: String) {
        guard let model else { return }
        let specials: [String: AppModel.Key.Special] = ["enter": .enter, "escape": .escape, "up": .up, "down": .down, "tab": .tab, "space": .space, "delete": .delete,
                                                        "pageDown": .pageDown, "pageUp": .pageUp, "home": .home, "end": .end]
        if command.hasPrefix("special:"), let special = specials[String(command.dropFirst(8))] {
            _ = model.handle(AppModel.Key(characters: "", special: special))
        } else if command.hasPrefix("cmd:") {
            _ = model.handle(AppModel.Key(characters: String(command.dropFirst(4)), command: true))
        } else if command.hasPrefix("ctrl:") {
            _ = model.handle(AppModel.Key(characters: String(command.dropFirst(5)), control: true))
        } else {
            _ = model.handle(AppModel.Key(characters: command))
        }
    }

    private func timed(_ action: () -> Void, done: @escaping (Double) -> Void) {
        let start = Bench.now()
        action()
        afterCommit { done(Bench.now() - start) }
    }

    /// Runs `action(i)` n times, one a turn, and records the median, the 90th centile, the worst, how many took
    /// longer than a frame, and the main thread's whole awake time per step.
    private func series(_ metric: String, count: Int, action: @escaping (Int) -> Void, done: @escaping () -> Void) {
        var samples: [Double] = []
        // Starts from an idle main thread, so `busy` holds only this series.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let busyBefore = self.busyTotal
            @MainActor func step(_ index: Int) {
                guard index < count else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let sorted = samples.sorted()
                        Bench.record(metric, ms: sorted[sorted.count / 2], [
                            "p90": sorted[min(sorted.count - 1, sorted.count * 9 / 10)], "max": sorted.last ?? 0, "n": count,
                            "busy": (self.busyTotal - busyBefore) / Double(max(count, 1)),
                            "over8": sorted.filter { $0 > 8.33 }.count, "over16": sorted.filter { $0 > 16.67 }.count,
                            "rows": self.model?.rows.count ?? 0,
                        ])
                        done()
                    }
                    return
                }
                self.timed({ action(index) }) { ms in
                    samples.append(ms)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { step(index + 1) }
                }
            }
            step(0)
        }
    }

    private func run(_ command: String, done: @escaping () -> Void) {
        guard let model else { return done() }
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0]
        let rest = parts.count > 1 ? parts[1] : ""
        switch name {
        case "wait":
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(rest) ?? 100) / 1000) { done() }
        case "size":
            let size = rest.split(separator: "x").compactMap { Double($0) }
            if size.count == 2, let window {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size[1], width: size[0], height: size[1]), display: true)
            }
            afterCommit(done)
        case "front":
            window?.orderFrontRegardless()
            afterCommit(done)
        case "back":
            window?.orderBack(nil)
            afterCommit(done)
        case "limit":
            model.benchSetLimit(Int(rest) ?? 300)
            afterCommit(done)
        case "select":
            model.selected = Set(model.rows.prefix(Int(rest) ?? 1).map(\.id))
            afterCommit(done)
        case "key":
            let pieces = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.timed({ self.press(pieces[1]) }) { ms in
                    Bench.record(pieces[0], ms: ms, ["rows": model.rows.count])
                    done()
                }
            }
        case "repeat":
            let pieces = rest.split(separator: ":", maxSplits: 2).map(String.init)
            guard pieces.count == 3, let count = Int(pieces[0]) else { return done() }
            series(pieces[1], count: count, action: { _ in self.press(pieces[2]) }, done: done)
        case "settle":
            let pieces = rest.split(separator: ":", maxSplits: 2).map(String.init)
            guard pieces.count == 3, let wait = Double(pieces[1]) else { return done() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let busyBefore = self.busyTotal
                let appliesBefore = ApplyCount.applies
                let skippedBefore = ApplyCount.skipped
                self.busyMax = 0
                self.timed({ self.press(pieces[2]) }) { ms in
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000) {
                        Bench.record(pieces[0], ms: ms, ["busy": self.busyTotal - busyBefore, "maxTurn": self.busyMax, "rows": model.rows.count,
                                                         "applies": ApplyCount.applies - appliesBefore, "skipped": ApplyCount.skipped - skippedBefore])
                        done()
                    }
                }
            }
        case "palette":
            model.openPalette()
            let letters = Array(rest)
            series("palette.keystroke", count: letters.count, action: { index in model.paletteQuery = String(letters.prefix(index + 1)) }) {
                model.overlay = nil
                done()
            }
        case "search":
            model.startSearch()
            let letters = Array(rest)
            let began = Bench.now()
            var typed = 0.0
            series("search.keystroke", count: letters.count, action: { index in
                model.searchText = String(letters.prefix(index + 1))
                model.searchChanged()
                typed = Bench.now()
            }) {}
            // From the first letter, and from the last, to the list holding results for the whole text
            // (they may arrive after typing ends). Known by the list no longer changing for 4 s.
            var last = model.rows.map(\.id)
            var changed = Bench.now()
            @MainActor func poll() {
                let now = model.rows.map(\.id)
                if now != last {
                    last = now
                    changed = Bench.now()
                }
                if typed > 0, Bench.now() - max(changed, typed) > 4000 {
                    Bench.record("search.shown", ms: changed - began - 50, ["rows": now.count, "afterTyping": max(0, changed - typed)])
                    model.endSearch()
                    return done()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { poll() }
            }
            poll()
        case "scroll":
            let pieces = rest.split(separator: ":").compactMap { Double($0) }
            guard pieces.count == 2, let scroll = listScroll() else { return done() }
            let clip = scroll.contentView
            series("scroll.frame", count: Int(pieces[0]), action: { _ in
                let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                clip.scroll(to: NSPoint(x: 0, y: min(clip.bounds.origin.y + pieces[1], limit)))
                scroll.reflectScrolledClipView(clip)
            }, done: done)
        case "churn":
            let shown = Set(model.rows.map(\.id))
            guard let other = ((try? model.service.store.threads(account: nil, label: SystemLabel.all, limit: 3000)) ?? []).last(where: { !shown.contains($0.id) }) else { return done() }
            let count = Int(rest) ?? 10
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let busyBefore = self.busyTotal
                let appliesBefore = ApplyCount.applies
                let skippedBefore = ApplyCount.skipped
                for index in 0..<count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                        model.service.modify(account: other.accountId, threadIds: [other.id], add: index % 2 == 0 ? [SystemLabel.unread] : [], remove: index % 2 == 0 ? [] : [SystemLabel.unread])
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(count) * 0.05 + 0.5) {
                    Bench.record("churn.write", ms: (self.busyTotal - busyBefore) / Double(max(count, 1)),
                                 ["n": count, "rows": model.rows.count, "applies": ApplyCount.applies - appliesBefore, "skipped": ApplyCount.skipped - skippedBefore])
                    done()
                }
            }
        case "stress":
            // Random cursor keys at random pacing; after each burst the row under the cursor must be wholly in view.
            var seed = UInt64(rest) ?? 1
            func random(_ bound: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(bound))
            }
            let keys = ["j", "j", "j", "k", "k", "k", "special:pageDown", "special:pageUp", "special:pageDown", "special:pageUp", "j", "k"]
            var failures = 0
            var bursts = 0
            @MainActor func burst() {
                guard bursts < 60 else {
                    Bench.record("stress.failures", ms: Double(failures), ["bursts": bursts, "rows": model.rows.count])
                    return done()
                }
                bursts += 1
                let count = 1 + random(12)
                let pacing = random(3)
                @MainActor func settle() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        if let scroll = self.listScroll(), let index = model.cursorIndex {
                            let seen = scroll.documentVisibleRect
                            let top = CGFloat(index) * 38
                            if top < seen.minY - 0.5 || top + 38 > seen.maxY + 0.5 {
                                failures += 1
                                Bench.record("stress.miss", ms: 0, ["pacing": pacing, "keys": count, "top": top, "minY": seen.minY, "maxY": seen.maxY])
                            }
                        }
                        burst()
                    }
                }
                @MainActor func next(_ left: Int) {
                    guard left > 0 else { return settle() }
                    self.press(keys[random(keys.count)])
                    switch pacing {
                    case 0: next(left - 1)
                    case 1: DispatchQueue.main.async { next(left - 1) }
                    default: self.afterCommit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { next(left - 1) } }
                    }
                }
                next(count)
            }
            burst()
        case "web":
            // How much the conversation's page holds, asked from inside it (a window behind others does not paint it).
            model.web.webView.evaluateJavaScript("document.querySelectorAll('*').length * 1000000 + document.body.innerText.length") { value, _ in
                MainActor.assumeIsolated {
                    let number = (value as? NSNumber)?.intValue ?? -1
                    Bench.record("web.content", ms: 0, ["elements": number / 1_000_000, "letters": number % 1_000_000, "open": model.openThread != nil])
                    done()
                }
            }
        case "info":
            Bench.record("info", ms: 0, ["window": window?.windowNumber ?? 0, "rows": model.rows.count, "list": model.list.label,
                                         "occluded": !(window?.occlusionState.contains(.visible) ?? false)])
            done()
        case "done":
            // Written after everything before it, since records are appended in order.
            Bench.record("done", ms: 0)
            done()
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
        default:
            // One key a turn, the way real key presses arrive.
            press(command)
            afterCommit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { done() } }
        }
    }
}
#endif
