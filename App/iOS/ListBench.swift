#if DEBUG || BENCH
@_spi(Bench) import MachCore
import GRDB
import ObjectiveC
import SwiftUI
import UIKit

/// Benchmark scenarios for the iPhone list screen. Compiled out of the app people use.
///
/// Started by `bench/ios-list/run.sh`, which launches the app with `MACH_LIST_BENCH=<scenarios>` (a comma list,
/// run in order). Each scenario does to the model and the list what a finger would and appends its numbers to
/// `bench.jsonl` in the data folder; the last line is `list_bench_done`. Nothing here runs unless the app was
/// started offline on a data folder of its own.
///
/// What is counted exactly: view `body` evaluations by view type (`BodyCount`), layers and UIKit views created,
/// layout passes (`layoutSubviews` and `layoutSublayers` calls), layers drawn (`display` calls), and SQL statements
/// run on the main thread. What is timed: processor time of the main thread, which a busy Mac disturbs far less
/// than the wall clock, and the gaps between screen refreshes.
@MainActor
enum ListBench {
    private static var model: AppModel!

    static func runFromEnvironment(model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard Bootstrap.offline, environment["MACH_DATA_DIR"]?.isEmpty == false else { return }
        self.model = model
        listenForCommands()
        guard let spec = environment["MACH_LIST_BENCH"], !spec.isEmpty else { return }
        Hooks.install(pool: model.service.store.pool)
        Task { @MainActor in
            // Let the launch finish first: the first rows, the first frames, the web view's own start.
            await frames(90)
            for scenario in spec.split(separator: ",").map(String.init) {
                await run(scenario)
                Bench.record("list_scenario_done", ms: 0, ["name": scenario])
            }
            Bench.record("list_bench_done", ms: 0)
        }
    }

    private static func number(_ name: String, _ fallback: Double) -> Double {
        ProcessInfo.processInfo.environment[name].flatMap(Double.init) ?? fallback
    }

    private static func run(_ scenario: String) async {
        switch scenario {
        case "all": model.go(.all); await frames(10)
        case "home": model.go(model.home); await frames(10)
        case "one": if let first = model.accounts.first { model.switchAccount(first.id) }; await frames(10)
        case "every": model.switchAccount(""); await frames(10)
        case "scroll": await scroll()
        case "invalidate": await invalidate()
        case "swipe": await swipe()
        case "loadmore": await loadMore()
        case "jump": await jump()
        case "switch": await switching()
        case "search": await search()
        case "memory": await memory()
        case "lab": await ListLab.run()
        case "eq": await ListEqLab.run()
        default: break
        }
    }

    // MARK: Clocks and counters

    /// Processor time the main thread has used, in milliseconds.
    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    /// Memory charged to the app, in megabytes: the number iOS uses when it decides what to kill.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Calls back once a screen refresh, which is how the scenarios move things "per frame".
    @MainActor
    private final class Frames: NSObject {
        static let shared = Frames()
        private var link: CADisplayLink?
        private var waiting: [CheckedContinuation<Double, Never>] = []
        var interval = 0.0

        func next() async -> Double {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if link == nil {
                    link = CADisplayLink(target: self, selector: #selector(tick))
                    // Ask for the fastest the screen can do, as a scrolling list gets.
                    let top = Float(UIScreen.main.maximumFramesPerSecond)
                    link?.preferredFrameRateRange = CAFrameRateRange(minimum: top, maximum: top, preferred: top)
                    link?.add(to: .main, forMode: .common)
                }
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            interval = (link.targetTimestamp - link.timestamp) * 1000
            let ready = waiting
            waiting = []
            if ready.isEmpty {
                link.invalidate()
                self.link = nil
            }
            for continuation in ready { continuation.resume(returning: link.timestamp * 1000) }
        }
    }

    /// Waits for the next screen refresh and returns its time in milliseconds.
    @discardableResult static func frame() async -> Double { await Frames.shared.next() }

    static func frames(_ count: Int) async {
        for _ in 0 ..< count { await frame() }
    }

    static func wait(upTo seconds: Double, until done: () -> Bool) async {
        let start = Bench.now()
        while !done(), Bench.now() - start < seconds * 1000 { await frame() }
    }

    /// Everything that is counted, at one moment.
    @MainActor
    struct Snapshot {
        var bodies = BodyCount.counts
        var hooks = Hooks.read()
        var classes = Hooks.readClasses()
        var cpu = ListBench.cpu()
    }

    /// What was counted since `before`, as fields for a result line. `per` divides every count (per row, per frame).
    static func counted(since before: Snapshot, per: Double = 1) -> [String: Any] {
        let now = Snapshot()
        var fields: [String: Any] = [:]
        func put(_ name: String, _ value: Int) {
            guard value != 0 else { return }
            fields[name] = per == 1 ? Double(value) : (Double(value) / per * 1000).rounded() / 1000
        }
        for (name, grown) in BodyCount.since(before.bodies) { put("body_" + name, grown) }
        put("layersMade", now.hooks.layersMade - before.hooks.layersMade)
        put("viewsMade", now.hooks.viewsMade - before.hooks.viewsMade)
        put("viewLayouts", now.hooks.viewLayouts - before.hooks.viewLayouts)
        put("layerLayouts", now.hooks.layerLayouts - before.hooks.layerLayouts)
        put("layerDraws", now.hooks.draws - before.hooks.draws)
        put("mainSQL", now.hooks.mainStatements - before.hooks.mainStatements)
        for (name, value) in now.classes { put(name, value - (before.classes[name] ?? 0)) }
        return fields
    }

    private static func stats(_ values: [Double], _ name: String, into fields: inout [String: Any]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        fields[name + "Median"] = round3(sorted[sorted.count / 2])
        fields[name + "P90"] = round3(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))])
        fields[name + "Max"] = round3(sorted[sorted.count - 1])
    }

    // MARK: Finding the list on screen

    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// The list's own scroll view: the tallest one in the window that is not part of the web view.
    static var listScroll: UIScrollView? { scroll(in: window) }

    static var shared: AppModel? { model }

    static func scroll(in window: UIWindow?) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if NSStringFromClass(type(of: view)).hasPrefix("WK") { return }
            if let scroll = view as? UIScrollView, !(view is UITextView) { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let window { walk(window) }
        return found.max { $0.contentSize.height < $1.contentSize.height }
    }

    static func layers(under layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return 1 + (layer.sublayers ?? []).reduce(0) { $0 + layers(under: $1) }
    }

    static func views(under view: UIView?) -> Int {
        guard let view else { return 0 }
        return 1 + view.subviews.reduce(0) { $0 + views(under: $1) }
    }

    private static func onScreen(into fields: inout [String: Any]) {
        fields["layersInList"] = layers(under: listScroll?.layer)
        fields["viewsInList"] = views(under: listScroll)
        fields["layersInWindow"] = layers(under: window?.layer)
        fields["layersAlive"] = Hooks.read().layersMade - Hooks.read().layersGone
    }

    private static var realRows: [MailThread] { model.rows.filter { !$0.id.hasPrefix("draft:") } }

    // MARK: 1. Scrolling

    /// Moves a scroll view a fixed distance every screen refresh, like a fling at constant speed, and reports what
    /// each row that went past cost. `rows` is how many rows should go past; `rowHeight` their height.
    static func fling(_ list: UIScrollView, by step: CGFloat, rows target: Double, rowHeight: CGFloat, grows: (() -> Int)? = nil) async -> [String: Any] {
        let before = Snapshot()
        var last = await frame()
        var lastCPU = cpu()
        var gaps: [Double] = [], costs: [Double] = [], loadFrames: [Double] = []
        var stuck = 0, moved: CGFloat = 0
        var rowCount = grows?() ?? 0
        while Double(moved / rowHeight) < target, stuck < 40, gaps.count < 20000 {
            let bottom = max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
            let top = -list.adjustedContentInset.top
            let next = min(max(list.contentOffset.y + step, top), bottom)
            if next == list.contentOffset.y { stuck += 1 } else { stuck = 0 }
            moved += abs(next - list.contentOffset.y)
            list.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            let now = await frame()
            let nowCPU = cpu()
            gaps.append(now - last)
            costs.append(nowCPU - lastCPU)
            if let grows {
                let count = grows()
                if count != rowCount { loadFrames.append(nowCPU - lastCPU) }
                rowCount = count
            }
            last = now
            lastCPU = nowCPU
        }
        let passed = max(1, Double(moved / rowHeight))
        var fields = counted(since: before, per: passed)
        fields["rows"] = passed.rounded()
        fields["frames"] = gaps.count
        fields["cpuTotal"] = (costs.reduce(0, +) * 100).rounded() / 100
        fields["cpuPerRow"] = (costs.reduce(0, +) / passed * 1000).rounded() / 1000
        stats(costs, "frameCPU", into: &fields)
        stats(gaps, "gap", into: &fields)
        // A 120 Hz screen gives each frame 8.3 ms. The simulator's screen may refresh slower; the processor time a
        // frame needed is what says whether it would have fitted.
        fields["framesOver8ms"] = costs.filter { $0 > 8.33 }.count
        fields["framesOver16ms"] = costs.filter { $0 > 16.67 }.count
        fields["refresh"] = (Frames.shared.interval * 100).rounded() / 100
        fields["lateFrames"] = gaps.filter { $0 > Frames.shared.interval * 1.5 }.count
        if !loadFrames.isEmpty {
            fields["loads"] = loadFrames.count
            stats(loadFrames, "loadFrameCPU", into: &fields)
        }
        return fields
    }

    private static func rowHeight(_ list: UIScrollView) -> CGFloat {
        max(1, (list.contentSize.height - 90) / CGFloat(max(1, model.rows.count)))
    }

    /// Down through the list and back up, twice. The first trip down also loads older rows on the way, as it does
    /// for a finger; the later ones are scrolling alone.
    private static func scroll() async {
        guard let list = listScroll else { return Bench.record("scroll.error", ms: 0) }
        let step = CGFloat(number("MACH_LIST_STEP", 120))
        let target = number("MACH_LIST_ROWS", 1000)
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        await frames(6)
        for pass in ["down1", "up1", "down2", "up2"] {
            let height = rowHeight(list)
            var fields = await fling(list, by: pass.hasPrefix("down") ? step : -step, rows: target, rowHeight: height) { model.rows.count }
            fields["rowsLoaded"] = model.rows.count
            fields["rowHeight"] = Double(height)
            onScreen(into: &fields)
            Bench.record("scroll." + pass, ms: fields["cpuPerRow"] as? Double ?? 0, fields)
            await frames(6)
        }
    }

    // MARK: 2. What a change invalidates

    /// Does one thing, lets the screen settle, and records which views were rebuilt and what it cost the main thread.
    private static func measure(_ name: String, settle: Int = 3, _ action: () -> Void, until done: (() -> Bool)? = nil) async {
        await frames(3)
        let before = Snapshot()
        action()
        if let done { await wait(upTo: 2, until: done) }
        await frames(settle)
        var fields = counted(since: before)
        fields["frames"] = settle
        Bench.record("inv." + name, ms: cpu() - before.cpu, fields)
    }

    private static var mailNumber = 0

    /// Puts one new conversation in the inbox the way sync does: a write to the database from another thread.
    private static func deliver() async -> String {
        mailNumber += 1
        let account = model.accounts.first?.id ?? ""
        let id = "bench-new-\(mailNumber)-\(Int(Bench.now()))"
        let store = model.service.store
        let message = Message.bench(accountId: account, id: id, threadId: id, internalDate: Int64(Date().timeIntervalSince1970 * 1000), sender: "Bench Sender <bench@example.com>",
                                    toList: account, subject: "Benchmark message \(mailNumber)", snippet: "A made-up message that arrives while the list is on screen.",
                                    labelIds: [SystemLabel.inbox, SystemLabel.unread], refs: "", bodyHTML: "<p>Hello</p>")
        await Task.detached { try? store.benchSaveThreads(account: account, threads: [(id: id, messages: [message])]) }.value
        return id
    }

    private static func invalidate() async {
        let rounds = Int(number("MACH_LIST_ROUNDS", 5))
        guard let list = listScroll else { return Bench.record("inv.error", ms: 0) }
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        await frames(6)
        // What a frame costs when nothing moves: the floor under every number here.
        let idle = cpu()
        await frames(60)
        Bench.record("inv.idleFrame", ms: (cpu() - idle) / 60)
        let swipe = RowSwipe.shared
        let width = UIScreen.main.bounds.width

        for _ in 0 ..< rounds {
            let rows = realRows
            guard rows.count > 8 else { return }
            let row = rows[2]
            await measure("tick") { model.toggleSelect(row.id) }
            await measure("tickSecond") { model.toggleSelect(rows[4].id) }
            await measure("untick") { model.toggleSelect(rows[4].id) }
            await measure("untickLast") { model.toggleSelect(row.id) }

            await measure("swipeBegin") { swipe.begin(row.id) }
            await frames(2)
            var before = Snapshot()
            for step in 1 ... 20 {
                swipe.drag(to: -CGFloat(step) * 3)
                await frame()
            }
            Bench.record("inv.swipeFrame", ms: (cpu() - before.cpu) / 20, counted(since: before, per: 20))
            // Let go before the swipe has "taken": the row settles back and stays.
            await measure("swipeReleaseStays", settle: 4, { swipe.release(velocity: 0, width: width, model: model) }, until: { swipe.id == nil })

            // A change in the database to one row that is on screen: a star from another device, say.
            let target = rows[5]
            let star = !target.starred
            await measure("databaseStar", { model.service.modify(account: target.accountId, threadIds: [target.id], add: star ? [SystemLabel.starred] : [], remove: star ? [] : [SystemLabel.starred]) },
                          until: { model.rows.first { $0.id == target.id }?.starred == star })

            model.setCursor(rows[3].id)
            await measure("markRead") { model.toggleRead() }
            await measure("toastGone") { model.toast = nil }
            await measure("star") { model.toggleStar() }
            await measure("toastReplaced") { model.show(Toast(text: "A second toast.")) }
            await measure("toastGone2") { model.toast = nil }
            await measure("cursorMove") { model.moveCursor(by: 1) }
            // Midnight: every row on screen that shows a date has to write it again.
            await measure("dayChange") { NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil) }

            var arrived = ""
            await frames(3)
            before = Snapshot()
            arrived = await deliver()
            await wait(upTo: 2) { model.rows.first?.id == arrived }
            await frames(3)
            Bench.record("inv.newMail", ms: cpu() - before.cpu, counted(since: before))

            await measure("composeOpen", settle: 6) { model.startCompose() }
            await measure("composeClose", settle: 6) { model.closeCompose(discard: true) }
            await measure("toastGone3") { model.toast = nil }

            // Swiped far enough that letting go acts and the row leaves (with the default setting: Mark Done).
            let leaving = realRows[1]
            swipe.begin(leaving.id)
            await frames(2)
            for step in 1 ... 20 {
                swipe.drag(to: -CGFloat(step) * 6)
                await frame()
            }
            await measure("swipeReleaseLeaves", settle: 6, { swipe.release(velocity: -300, width: width, model: model) },
                          until: { swipe.id == nil && !model.rows.contains { $0.id == leaving.id } })
            await measure("toastGone4") { model.toast = nil }

            // Opening a conversation over the list, dragging it back, and letting go.
            if ProcessInfo.processInfo.environment["MACH_LIST_NO_OPEN"] != "1" {
                let opened = realRows[2]
                await measure("openThread", settle: 12) { model.show(opened) }
                before = Snapshot()
                for step in 1 ... 30 {
                    model.web.onBackDrag?(CGFloat(step) * 6, nil)
                    await frame()
                }
                Bench.record("inv.backDragFrame", ms: (cpu() - before.cpu) / 30, counted(since: before, per: 30))
                await measure("backRelease", settle: 6, { model.web.onBackDrag?(180, 600) }, until: { model.openThread == nil && !model.sliding })
            }
        }

        // Search: opening it, the keyboard, each letter, closing it.
        for _ in 0 ..< rounds {
            let word = Array(searchWord())
            await measure("searchOpen", settle: 6) { model.startSearch() }
            if let field = textField() {
                await measure("keyboardUp", settle: 40) { field.becomeFirstResponder() }
            }
            var typed = ""
            let before = Snapshot()
            for letter in word {
                typed.append(letter)
                model.searchText = typed
                await frames(3)
            }
            var fields = counted(since: before, per: Double(word.count))
            fields["letters"] = word.count
            fields["results"] = model.rows.count
            Bench.record("inv.searchLetter", ms: (cpu() - before.cpu) / Double(max(1, word.count)), fields)
            await measure("searchClose", settle: 30) {
                window?.endEditing(true)
                model.endSearch()
            }
        }
    }

    private static func textField() -> UITextField? {
        func walk(_ view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return window.flatMap(walk)
    }

    /// A word that is in the mailbox, to type into search: the longest word of the first rows' subjects. It is
    /// never written anywhere, only its length is.
    private static func searchWord() -> String {
        let words = model.rows.prefix(20).flatMap { $0.subject.lowercased().split { !$0.isLetter }.map(String.init) }
        return String((words.filter { $0.count >= 5 }.first ?? "inbox").prefix(8))
    }

    // MARK: 3. The swipe

    private static func swipe() async {
        let rounds = Int(number("MACH_LIST_ROUNDS", 5)) * 2
        guard let list = listScroll else { return }
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        await frames(6)
        let swipe = RowSwipe.shared
        let width = UIScreen.main.bounds.width
        for round in 0 ..< rounds {
            guard let row = realRows.dropFirst(1).first else { return }
            await frames(4)
            var before = Snapshot()
            swipe.begin(row.id)
            swipe.drag(to: -2)
            await frame()
            Bench.record("swipe.first", ms: cpu() - before.cpu, counted(since: before))
            before = Snapshot()
            var costs: [Double] = []
            var last = cpu()
            // Out past the point where it "takes" and back under it, so both looks of the strip behind are drawn.
            let steps = 60
            for step in 1 ... steps {
                swipe.drag(to: -CGFloat(step) * 2.5)
                await frame()
                let now = cpu()
                costs.append(now - last)
                last = now
            }
            var fields = counted(since: before, per: Double(steps))
            stats(costs, "frameCPU", into: &fields)
            fields["framesOver8ms"] = costs.filter { $0 > 8.33 }.count
            Bench.record("swipe.drag", ms: costs.reduce(0, +) / Double(steps), fields)
            before = Snapshot()
            let lifted = Bench.now()
            // Every other round the row is let go early and stays.
            if round % 2 == 1 {
                swipe.drag(to: -30)
                await frame()
                swipe.release(velocity: 0, width: width, model: model)
                await wait(upTo: 2) { swipe.id == nil }
                await frames(2)
                fields = counted(since: before)
                fields["wall"] = Bench.now() - lifted
                Bench.record("swipe.releaseStays", ms: cpu() - before.cpu, fields)
            } else {
                swipe.release(velocity: -300, width: width, model: model)
                await wait(upTo: 2) { swipe.id == nil && !model.rows.contains { $0.id == row.id } }
                let gone = Bench.now() - lifted
                await frames(2)
                fields = counted(since: before)
                fields["wall"] = gone
                Bench.record("swipe.releaseLeaves", ms: cpu() - before.cpu, fields)
            }
            model.toast = nil
            await frames(10)
        }
        // Tap to open, from the list's side: the call a tap makes, to the frame after.
        if ProcessInfo.processInfo.environment["MACH_LIST_NO_OPEN"] != "1" {
            for index in 0 ..< rounds {
                let rows = realRows
                guard index + 2 < rows.count else { break }
                await frames(4)
                let before = Snapshot()
                let began = Bench.now()
                model.show(rows[index + 2])
                let call = Bench.now() - began
                await frame()
                var fields = counted(since: before)
                fields["showCall"] = call
                Bench.record("tap.open", ms: cpu() - before.cpu, fields)
                await frames(10)
                await measure("tapClose") { model.closeThread() }
            }
        }
    }

    // MARK: 4. Loading older rows, and new mail while scrolled down

    private static func loadMore() async {
        guard let list = listScroll else { return }
        let rounds = Int(number("MACH_LIST_LOADS", 6))
        for round in 0 ..< rounds {
            // Sit a few rows above the bottom, as a finger is when the last row comes into view.
            let bottom = max(0, list.contentSize.height - list.bounds.height)
            list.setContentOffset(CGPoint(x: 0, y: max(0, bottom - 400)), animated: false)
            await frames(8)
            let rowsBefore = model.rows.count
            let anchor = anchorRow(list)
            var before = Snapshot()
            let began = Bench.now()
            model.loadOlder()
            let call = Bench.now() - began
            let callCPU = cpu() - before.cpu
            var fields = counted(since: before)
            // The frames that follow, while the list is still moving: the worst one is the hitch.
            before = Snapshot()
            var costs: [Double] = []
            var last = cpu()
            var lastTick = await frame()
            var gaps: [Double] = []
            for _ in 0 ..< 40 {
                list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y + 20), animated: false)
                let tick = await frame()
                let now = cpu()
                costs.append(now - last)
                gaps.append(tick - lastTick)
                last = now
                lastTick = tick
            }
            for (key, value) in counted(since: before) { fields["after_" + key] = value }
            fields["call"] = call
            fields["callCPU"] = callCPU
            fields["rowsBefore"] = rowsBefore
            fields["rowsAfter"] = model.rows.count
            fields["round"] = round
            stats(costs, "frameCPU", into: &fields)
            stats(gaps, "gap", into: &fields)
            if let anchor { fields["anchorMoved"] = Double(anchorPosition(anchor.id, list) - anchor.position + 800) }
            // The hitch is the load itself plus the worst frame after it.
            Bench.record("loadmore", ms: callCPU + (costs.max() ?? 0), fields)
            guard model.rows.count > rowsBefore else { break }
        }
    }

    /// A row on screen and how far below the top of the screen it sits.
    private static func anchorRow(_ list: UIScrollView) -> (id: String, position: CGFloat)? {
        let top = list.contentOffset.y
        guard let frame = RowSwipe.shared.frames.filter({ $0.value.minY >= top }).min(by: { $0.value.minY < $1.value.minY }) else { return nil }
        return (frame.key, frame.value.minY - top)
    }

    private static func anchorPosition(_ id: String, _ list: UIScrollView) -> CGFloat {
        (RowSwipe.shared.frames[id]?.minY ?? .nan) - list.contentOffset.y
    }

    /// New mail arrives while the list is scrolled down: the rows on screen should stay where they are.
    private static func jump() async {
        guard let list = listScroll else { return }
        for depth in [0.0, 12, 60, 250] {
            let height = rowHeight(list)
            list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top + CGFloat(depth) * height), animated: false)
            await frames(10)
            for _ in 0 ..< 3 {
                guard let anchor = anchorRow(list) else { continue }
                let offset = list.contentOffset.y
                let before = Snapshot()
                let id = await deliver()
                // Looked at on every frame, so a jump that is put right a frame later is still seen.
                var worst: CGFloat = 0
                let began = Bench.now()
                var settled = 0
                while settled < 6, Bench.now() - began < 2000 {
                    await frame()
                    let now = anchorPosition(anchor.id, list) - anchor.position
                    if !now.isNaN, abs(now) > abs(worst) { worst = now }
                    if model.rows.first?.id == id { settled += 1 }
                }
                var fields = counted(since: before)
                fields["worst"] = Double(worst)
                fields["depthRows"] = depth
                fields["offsetMoved"] = Double(list.contentOffset.y - offset)
                fields["cpu"] = cpu() - before.cpu
                // How far the row that was on screen moved on screen: zero means nothing jumped.
                Bench.record("jump", ms: Double(anchorPosition(anchor.id, list) - anchor.position), fields)
            }
        }
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        await frames(4)
    }

    // MARK: 5. Switching lists and accounts, search

    private static func switching() async {
        let rounds = Int(number("MACH_LIST_ROUNDS", 5))
        await frames(10)
        for _ in 0 ..< rounds {
            for (name, target) in [("toAll", MailList.all), ("toSent", .sent), ("toStarred", .starred), ("toSnoozedEmpty", .snoozed), ("toHome", model.home)] {
                await measure("switch." + name, settle: 4, { model.go(target) })
            }
            if model.accounts.count > 1 {
                await measure("account.one", settle: 4) { model.switchAccount(model.accounts[0].id) }
                await measure("account.other", settle: 4) { model.switchAccount(model.accounts[1].id) }
                await measure("account.every", settle: 4) { model.switchAccount("") }
            }
            await measure("switcher.open", settle: 4) { model.overlay = .lists }
            await measure("switcher.close", settle: 4) { model.overlay = nil }
        }
    }

    /// Typing into search on the big mailbox: the whole cost of a letter on the main thread, and how much of it
    /// is the query (measured by running the same query again by itself).
    private static func search() async {
        let rounds = Int(number("MACH_LIST_ROUNDS", 5))
        for _ in 0 ..< rounds {
            let word = Array(searchWord())
            await measure("searchOpen", settle: 6) { model.startSearch() }
            textField()?.becomeFirstResponder()
            await frames(40)
            var typed = ""
            for (index, letter) in word.enumerated() {
                typed.append(letter)
                await frames(2)
                let before = Snapshot()
                model.searchText = typed
                await frames(3)
                var fields = counted(since: before)
                let whole = cpu() - before.cpu
                let began = cpu()
                let found = (try? model.service.store.search(account: nil, text: typed)) ?? []
                fields["queryCPU"] = cpu() - began
                fields["letter"] = index + 1
                fields["results"] = found.count
                Bench.record("search.letter", ms: whole, fields)
            }
            await measure("search.clear", settle: 4) { model.searchText = "" }
            await measure("searchClose", settle: 30) {
                window?.endEditing(true)
                model.endSearch()
            }
        }
    }

    // MARK: 6. Memory

    /// What a long scroll leaves behind: memory, layers, views.
    private static func memory() async {
        guard let list = listScroll else { return }
        var fields: [String: Any] = ["rows": model.rows.count]
        onScreen(into: &fields)
        Bench.record("memory.before", ms: footprint(), fields)
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        await frames(6)
        let target = number("MACH_LIST_MEMORY_ROWS", 3000)
        _ = await fling(list, by: 240, rows: target, rowHeight: rowHeight(list))
        await frames(30)
        fields = ["rows": model.rows.count]
        onScreen(into: &fields)
        Bench.record("memory.bottom", ms: footprint(), fields)
        list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
        await frames(60)
        fields = ["rows": model.rows.count]
        onScreen(into: &fields)
        Bench.record("memory.backAtTop", ms: footprint(), fields)
    }

    // MARK: Commands from the script (for screenshots)

    /// `xcrun simctl spawn <device> notifyutil -p com.ahmedkhaleel.machbench.list.<command>`: puts the list in a state and holds
    /// it there, so a screenshot can be taken. Each command writes one `list_command` line when it has been drawn.
    private static func listenForCommands() {
        let commands = ["tick", "untick", "hold-left-40", "hold-left-100", "hold-right-40", "hold-right-100", "drop", "all", "home", "snoozed", "search", "searchEnd",
                        "one", "every", "lists", "toast", "toastGone", "down", "top"]
        for command in commands {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
                guard let raw = name?.rawValue as String?, let command = raw.split(separator: ".").last.map(String.init) else { return }
                DispatchQueue.main.async { ListBench.command(command) }
            }, "com.ahmedkhaleel.machbench.list.\(command)" as CFString, nil, .deliverImmediately)
        }
    }

    private static func command(_ command: String) {
        let swipe = RowSwipe.shared
        let rows = realRows
        switch command {
        case "tick": if rows.count > 3 { model.toggleSelect(rows[1].id); model.toggleSelect(rows[3].id) }
        case "untick": model.selected = []
        case "drop": swipe.cancel()
        case "all": model.go(.all)
        case "home": model.go(model.home)
        case "snoozed": model.go(.snoozed)
        case "search":
            model.startSearch()
            model.searchText = "invoice"
        case "searchEnd": model.endSearch()
        case "one": if let first = model.accounts.first { model.switchAccount(first.id) }
        case "every": model.switchAccount("")
        case "lists": model.overlay = model.overlay == .lists ? nil : .lists
        case "toast": model.show(Toast(text: "Marked Done.", undo: {}))
        case "toastGone": model.toast = nil
        case "down": listScroll.map { $0.setContentOffset(CGPoint(x: 0, y: 2000), animated: false) }
        case "top": listScroll.map { $0.setContentOffset(CGPoint(x: 0, y: -$0.adjustedContentInset.top), animated: false) }
        default:
            // hold-<side>-<distance>: a swipe held still part of the way.
            let parts = command.split(separator: "-")
            guard parts.count == 3, let distance = Double(parts[2]), rows.count > 2 else { return }
            swipe.begin(rows[2].id)
            swipe.drag(to: CGFloat(parts[1] == "left" ? -distance : distance))
        }
        Task { @MainActor in
            await frames(8)
            Bench.record("list_command", ms: 0, ["name": command])
        }
    }
}

/// Counters hung on UIKit and Core Animation themselves, so nothing in the code being measured has to change.
enum Hooks {
    struct Counts {
        var layersMade = 0, layersGone = 0, viewsMade = 0, viewLayouts = 0, layerLayouts = 0, draws = 0, mainStatements = 0
    }

    nonisolated(unsafe) private static var counts = Counts()
    nonisolated(unsafe) private static var lock = os_unfair_lock()
    nonisolated(unsafe) private static var installed = false

    static func read() -> Counts {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return counts
    }

    private static func bump(_ path: WritableKeyPath<Counts, Int>) {
        os_unfair_lock_lock(&lock)
        counts[keyPath: path] += 1
        os_unfair_lock_unlock(&lock)
    }

    /// With `MACH_LIST_CLASSES=1`, which kinds of layer were made and drawn: "made CGDrawingLayer" and so on.
    static let byClass = ProcessInfo.processInfo.environment["MACH_LIST_CLASSES"] == "1"
    nonisolated(unsafe) private static var classes: [String: Int] = [:]

    private static func note(_ what: String, _ object: UnsafeMutableRawPointer) {
        guard byClass else { return }
        let name = what + NSStringFromClass(object_getClass(Unmanaged<AnyObject>.fromOpaque(object).takeUnretainedValue())!)
        os_unfair_lock_lock(&lock)
        classes[name, default: 0] += 1
        os_unfair_lock_unlock(&lock)
    }

    static func readClasses() -> [String: Int] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return classes
    }

    private typealias Plain = @convention(c) (UnsafeMutableRawPointer, Selector) -> Void
    private typealias Maker = @convention(c) (UnsafeMutableRawPointer, Selector) -> UnsafeMutableRawPointer?
    private typealias FrameMaker = @convention(c) (UnsafeMutableRawPointer, Selector, CGRect) -> UnsafeMutableRawPointer?

    /// Counts calls of a method that takes nothing and returns nothing.
    private static func count(_ type: AnyClass, _ name: String, _ path: WritableKeyPath<Counts, Int>) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Plain.self)
        let block: @convention(block) (UnsafeMutableRawPointer) -> Void = { object in
            bump(path)
            original(object, selector)
        }
        class_replaceMethod(type, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    static func install(pool: DatabasePool) {
        guard !installed else { return }
        installed = true
        count(UIView.self, "layoutSubviews", \.viewLayouts)
        count(CALayer.self, "layoutSublayers", \.layerLayouts)
        let display = NSSelectorFromString("display")
        if let method = class_getInstanceMethod(CALayer.self, display) {
            let original = unsafeBitCast(method_getImplementation(method), to: Plain.self)
            let block: @convention(block) (UnsafeMutableRawPointer) -> Void = { object in
                bump(\.draws)
                note("drawn_", object)
                original(object, display)
            }
            class_replaceMethod(CALayer.self, display, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        count(CALayer.self, "dealloc", \.layersGone)
        let initialise = NSSelectorFromString("init")
        if let method = class_getInstanceMethod(CALayer.self, initialise) {
            let original = unsafeBitCast(method_getImplementation(method), to: Maker.self)
            let block: @convention(block) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { object in
                bump(\.layersMade)
                note("made_", object)
                return original(object, initialise)
            }
            class_replaceMethod(CALayer.self, initialise, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        let withFrame = NSSelectorFromString("initWithFrame:")
        if let method = class_getInstanceMethod(UIView.self, withFrame) {
            let original = unsafeBitCast(method_getImplementation(method), to: FrameMaker.self)
            let block: @convention(block) (UnsafeMutableRawPointer, CGRect) -> UnsafeMutableRawPointer? = { object, frame in
                bump(\.viewsMade)
                return original(object, withFrame, frame)
            }
            class_replaceMethod(UIView.self, withFrame, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        traceDatabase(pool)
    }

    /// Counts every SQL statement that runs on the main thread. A read made from the main thread runs on it
    /// (the database's queue lends it the thread), so this is exactly the reads the screen waits for.
    private static func traceDatabase(_ pool: DatabasePool) {
        let trace: @Sendable (Database) -> Void = { db in
            db.trace(options: .statement) { _ in
                if pthread_main_np() != 0 { bump(\.mainStatements) }
            }
        }
        // Every reading connection has to be told. Holding them all at once makes the pool hand out each one.
        let readers = 5
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        for _ in 0 ..< readers {
            DispatchQueue.global().async {
                try? pool.read { db in
                    trace(db)
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
            }
        }
        for _ in 0 ..< readers { _ = entered.wait(timeout: .now() + 2) }
        for _ in 0 ..< readers { release.signal() }
        pool.writeWithoutTransaction { trace($0) }
    }
}
#endif
