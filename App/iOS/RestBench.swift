#if DEBUG || BENCH
import BlitzCore
import SQLite3
import SwiftUI
import UIKit

/// Benchmarks for the parts of the phone app that are not launch, the list or the open conversation: writing mail,
/// the search field, the overlays, memory, and what the app does while idle. Compiled out of the app people use.
///
/// `BLITZ_REST_BENCH="compose search"` at launch runs the named scenarios in order and appends their numbers to
/// `bench.jsonl` in the data folder, ending with a `rest_bench_done` line. See `bench/ios-rest/run.sh`.
///
/// Typing goes through the real text field (`insertText` on whichever field has the keyboard), so a letter costs
/// here what it costs under a finger. Counts (view bodies rebuilt, database lookups) are exact; times are
/// processor time of the main thread, which is steadier in a simulator than a wall clock.
@MainActor
enum RestBench {
    static func runFromEnvironment(model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["BLITZ_REST_BENCH"], !spec.isEmpty, Bootstrap.offline else { return }
        watchPhases()
        Task { @MainActor in
            // Let launch finish first: rows on screen, the conversation page loaded.
            await wait(upTo: 10) { !model.rows.isEmpty }
            for _ in 0..<300 where (try? await model.web.webView.evaluateJavaScript("typeof window.blitz")) as? String != "object" { await frames(2) }
            await frames(30)
            // Past the moment the app warms the text system by itself (1.5 s after launch), so every run starts alike.
            await sleep(seconds: 2.5)
            for scenario in spec.split(separator: " ").map(String.init) {
                let parts = scenario.split(separator: ":").map(String.init)
                let count = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                switch parts[0] {
                case "compose": await compose(model, rounds: count > 0 ? count : 6)
                case "reply": await reply(model, rounds: count > 0 ? count : 5)
                case "send": await send(model, rounds: count > 0 ? count : 5)
                case "search": await search(model, rounds: count > 0 ? count : 5)
                case "overlays": await overlays(model, rounds: count > 0 ? count : 8)
                case "memory": await memory(model, idleSeconds: count)
                case "idle": await idle(seconds: count > 0 ? count : 30)
                case "warning": await warning(model)
                case "shots": await shots(model)
                case "resume": await sleep(seconds: Double(count > 0 ? count : 20))
                case "warm": await warm(parts.count > 1 ? parts[1] : "main")
                case "looks": await looks(model, rounds: count > 0 ? count : 6)
                default: break
                }
            }
            Bench.record("rest_bench_done", ms: 0)
        }
    }

    // MARK: Clocks and counters

    /// Processor time the main thread has used, in milliseconds.
    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
    /// Processor time of every thread in the app.
    static func cpuAll() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e6 }

    /// Memory charged to the app, in megabytes: the number iOS uses when it decides what to kill.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// How often the system had to wake a processor for this app since it started.
    static func wakeups() -> Double {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.task_interrupt_wakeups + info.task_platform_idle_wakeups) : -1
    }

    private final class Frames: NSObject {
        static let shared = Frames()
        private var link: CADisplayLink?
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func next() async {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if link == nil {
                    link = CADisplayLink(target: self, selector: #selector(tick))
                    link?.add(to: .main, forMode: .common)
                }
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            let ready = waiting
            waiting = []
            if ready.isEmpty {
                link.invalidate()
                self.link = nil
            }
            for continuation in ready { continuation.resume() }
        }
    }

    static func frames(_ count: Int) async {
        for _ in 0..<count { await Frames.shared.next() }
    }

    private static func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private static func wait(upTo seconds: Double, until done: () -> Bool) async {
        let start = Bench.now()
        while !done(), Bench.now() - start < seconds * 1000 { await frames(1) }
    }

    /// What a stretch of work cost: main-thread time, and how often each counted view was rebuilt.
    @MainActor
    private struct Lap {
        let cpu = RestBench.cpu()
        let clock = Bench.now()
        let bodies = BodyCount.counts

        func fields(per count: Int = 1) -> [String: Any] {
            var result: [String: Any] = ["wall": (Bench.now() - clock) / Double(count)]
            for (name, grown) in BodyCount.since(bodies) { result["n_" + name] = (Double(grown) / Double(count) * 100).rounded() / 100 }
            return result
        }

        func ms(per count: Int = 1) -> Double { (RestBench.cpu() - cpu) / Double(count) }
    }

    /// What a frame costs when nothing happens: the floor under every per-letter number.
    private static func idleFloor(_ label: String) async {
        await frames(10)
        let lap = Lap()
        await frames(60)
        Bench.record("\(label).idle_frame", ms: lap.ms(per: 60))
    }

    // MARK: Finding things on screen

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    private static func all<T: UIView>(_ type: T.Type, in root: UIView? = nil) -> [T] {
        guard let view = root ?? window else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    private static func typing() -> (UIView & UIKeyInput)? {
        func find(_ view: UIView) -> (UIView & UIKeyInput)? {
            if view.isFirstResponder, let input = view as? (UIView & UIKeyInput) { return input }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return window.flatMap(find)
    }

    /// Types `text` one letter a frame into the field that has the keyboard and records what a letter cost.
    private static func type(_ text: String, metric: String, extra: [String: Any] = [:]) async {
        guard let field = typing() else {
            Bench.record(metric, ms: -1, ["error": "no field has the keyboard"])
            return
        }
        await frames(2)
        let lap = Lap()
        for letter in text {
            field.insertText(String(letter))
            await frames(1)
        }
        var fields = lap.fields(per: text.count)
        for (key, value) in extra { fields[key] = value }
        fields["letters"] = text.count
        Bench.record(metric, ms: lap.ms(per: text.count), fields)
    }

    // MARK: Writing mail

    private final class Keyboard: @unchecked Sendable {
        var will: Double?
        var did: Double?
        private var tokens: [NSObjectProtocol] = []

        init(since start: Double) {
            tokens.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                if self?.will == nil { self?.will = Bench.now() - start }
            })
            tokens.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] _ in
                if self?.did == nil { self?.did = Bench.now() - start }
            })
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    /// Opens something that takes the keyboard and records: the first frame, when a field took the keyboard, and
    /// when the system said the keyboard was coming and had arrived.
    private static func opening(_ metric: String, extra: [String: Any] = [:], _ action: () -> Void) async {
        await frames(4)
        let lap = Lap()
        let keyboard = Keyboard(since: lap.clock)
        action()
        let call = Bench.now() - lap.clock
        await frames(1)
        var fields: [String: Any] = ["call": call, "first_frame": Bench.now() - lap.clock, "cpu_first_frame": lap.ms()]
        var responder: Double?
        await wait(upTo: 1.5) {
            if responder == nil, typing() != nil { responder = Bench.now() - lap.clock }
            return responder != nil && keyboard.did != nil
        }
        fields["responder"] = responder ?? -1
        fields["keyboard_will"] = keyboard.will ?? -1
        fields["keyboard_did"] = keyboard.did ?? -1
        for (key, value) in lap.fields() where key != "wall" { fields[key] = value }
        for (key, value) in extra { fields[key] = value }
        Bench.record(metric, ms: lap.ms(), fields)
        await frames(10)
    }

    /// The start of the most-used contact's name, so the suggestions really have something to find.
    private static func contactPrefix(_ model: AppModel) -> String {
        let account = model.compose?.accountId ?? model.accounts.first?.id ?? ""
        let name = try? model.service.store.pool.read { db in
            try String.fetchOne(db, sql: "SELECT lower(name) FROM contact WHERE accountId = ? AND length(name) >= 8 AND name NOT LIKE '%,%' ORDER BY uses DESC LIMIT 1", arguments: [account])
        }
        return String((name ?? "alexander").prefix(8))
    }

    private static func compose(_ model: AppModel, rounds: Int) async {
        await idleFloor("compose")
        for round in 0..<rounds {
            // The first one in the life of the process also pays for the text system and the keyboard starting up.
            await opening(round == 0 ? "compose.open.cold" : "compose.open.warm") { model.startCompose() }
            guard model.compose != nil else { return }

            // "To" has the keyboard in a new message.
            let name = contactPrefix(model)
            await type(name, metric: "compose.type.to")
            let typedTo = model.compose?.to.count ?? -1

            let fields = all(UITextField.self)
            // Subject is the last single-line field.
            fields.last?.becomeFirstResponder()
            await frames(4)
            await type("quarterly numbers ok", metric: "compose.type.subject")

            all(UITextView.self).first?.becomeFirstResponder()
            await frames(4)
            await type("a few words of an ordinary reply, typed one at a ", metric: "compose.type.body")
            // The same again once the message is long: a body of about 2,000 characters.
            model.compose?.body += String(repeating: "Another ordinary sentence of the message. ", count: 48)
            await frames(4)
            await type("and a few more words at the end ", metric: "compose.type.body_long")
            Bench.record("compose.typed", ms: 0, ["to": typedTo, "subject": model.compose?.subject.count ?? -1, "body": model.compose?.body.count ?? -1])

            await frames(2)
            let lap = Lap()
            model.closeCompose(discard: true)
            await frames(1)
            Bench.record("compose.close", ms: lap.ms(), lap.fields())
            model.toast = nil
            await frames(20)
        }
    }

    private static func chosen(_ shape: String) -> (account: String, thread: String)? {
        let text = (try? String(contentsOf: Bootstrap.directory.appendingPathComponent("bench-threads.tsv"), encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            if fields.count == 3, fields[0] == shape { return (fields[1], fields[2]) }
        }
        return nil
    }

    /// Reply, reply all and forward on a 200-message conversation and on a 150 KB newsletter.
    private static func reply(_ model: AppModel, rounds: Int) async {
        for shape in ["thread200", "news150"] {
            guard let pick = chosen(shape), let thread = try? model.service.store.thread(account: pick.account, id: pick.thread) else { continue }
            model.show(thread)
            await frames(40)
            for round in 0..<rounds {
                for (name, action) in [("reply", { model.startReply(all: false) }), ("reply_all", { model.startReply(all: true) }), ("forward", { model.startForward() })] {
                    await opening("\(name).\(shape)", extra: ["round": round], action)
                    await type("thanks, got it ", metric: "\(name).\(shape).type")
                    let lap = Lap()
                    model.closeCompose(discard: true)
                    await frames(1)
                    Bench.record("\(name).\(shape).close", ms: lap.ms(), lap.fields())
                    model.toast = nil
                    await frames(10)
                }
            }
            model.closeThread()
            await frames(10)
        }
    }

    /// Send: from the tap to the compose view being gone. Nothing leaves: the app is offline and the address is not real.
    private static func send(_ model: AppModel, rounds: Int) async {
        for shape in ["new", "thread200", "news150"] {
            if shape != "new" {
                guard let pick = chosen(shape), let thread = try? model.service.store.thread(account: pick.account, id: pick.thread) else { continue }
                model.show(thread)
                await frames(40)
            }
            for _ in 0..<rounds {
                if shape == "new" { model.startCompose() } else { model.startReply(all: false) }
                await wait(upTo: 1.5) { typing() != nil }
                model.compose?.to = "nobody@example.invalid"
                model.compose?.subject = "Benchmark"
                model.compose?.body = String(repeating: "A few words. ", count: 20)
                await frames(6)
                let lap = Lap()
                model.sendCompose()
                let call = lap.ms()
                await frames(1)
                var fields = lap.fields()
                fields["call"] = call
                fields["gone"] = model.compose == nil ? 1 : 0
                Bench.record("send.\(shape)", ms: lap.ms(), fields)
                // Take it back before the five seconds are up, so nothing waits in the outbox.
                await wait(upTo: 3) { model.toast?.undo != nil }
                model.toast?.undo?()
                await frames(6)
                model.closeCompose(discard: true)
                model.toast = nil
                await frames(10)
            }
            model.closeThread()
            await frames(10)
        }
    }

    // MARK: Search and overlays

    private static func search(_ model: AppModel, rounds: Int) async {
        await idleFloor("search")
        for round in 0..<rounds {
            await opening(round == 0 ? "search.open.cold" : "search.open.warm") {
                model.startSearch()
                // The magnifying glass asks for the keyboard in the same turn; here the field is asked directly a frame later.
                Task { @MainActor in
                    await frames(1)
                    all(UITextField.self).first?.becomeFirstResponder()
                }
            }
            // What the lookup alone costs for the same letters, to take off the per-letter number.
            let word = "invoice re"
            var lookups = 0.0
            for end in 1...word.count {
                let start = cpu()
                _ = try? model.service.store.search(account: nil, text: String(word.prefix(end)))
                lookups += cpu() - start
            }
            await type(word, metric: "search.type", extra: ["lookup_alone": lookups / Double(word.count), "results": model.rows.count])
            let lap = Lap()
            model.dropFocus()
            model.endSearch()
            await frames(1)
            Bench.record("search.close", ms: lap.ms(), lap.fields())
            await frames(20)
        }
    }

    private static func overlays(_ model: AppModel, rounds: Int) async {
        let kinds: [(String, Overlay)] = [("palette", .palette), ("snooze", .snooze), ("accounts", .accounts), ("lists", .lists), ("more", .more)]
        for (name, kind) in kinds {
            for round in 0..<rounds {
                await frames(6)
                var lap = Lap()
                if kind == .palette { model.openPalette() } else { model.overlay = kind }
                await frames(1)
                Bench.record("overlay.\(name).open", ms: lap.ms(), lap.fields().merging(["round": round]) { a, _ in a })
                await frames(12)
                if kind == .palette {
                    await wait(upTo: 1) { typing() != nil }
                    await type("mark", metric: "overlay.palette.type")
                }
                lap = Lap()
                model.dropFocus()
                model.overlay = nil
                await frames(1)
                Bench.record("overlay.\(name).close", ms: lap.ms(), lap.fields())
            }
        }
        for _ in 0..<rounds {
            await frames(6)
            var lap = Lap()
            model.show(Toast(text: "Marked Done."))
            await frames(1)
            Bench.record("toast.show", ms: lap.ms(), lap.fields())
            await frames(6)
            lap = Lap()
            model.toast = nil
            await frames(1)
            Bench.record("toast.hide", ms: lap.ms(), lap.fields())
        }
    }

    // MARK: An experiment: starting the text machinery before it is needed

    /// The first text field of a launch costs far more than the ones after it. This tries paying that ahead of
    /// time, in one of several ways, and records what the paying itself costs; a `compose` scenario after it shows
    /// what is left of the cold start.
    private static func warm(_ how: String) async {
        let before = footprint(), all = cpuAll()
        let lap = Lap()
        switch how {
        case "main":
            // A text field that takes the keyboard for an instant, with an empty view where the keyboard would be.
            let field = UITextField(frame: .zero)
            field.inputView = UIView(frame: .zero)
            field.alpha = 0
            window?.addSubview(field)
            field.becomeFirstResponder()
            field.resignFirstResponder()
            field.removeFromSuperview()
        case "views":
            // Only the text views themselves, laid out off screen; the keyboard is not asked for.
            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
            field.text = "a"
            field.layoutIfNeeded()
            let editor = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
            editor.text = "a"
            editor.layoutIfNeeded()
        case "swiftui":
            // The same SwiftUI field types compose uses, drawn once in a host that is never shown.
            let host = UIHostingController(rootView: VStack {
                TextField("", text: .constant("a"))
                TextEditor(text: .constant("a"))
            })
            host.view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            host.view.alpha = 0
            window?.addSubview(host.view)
            host.view.layoutIfNeeded()
            await frames(2)
            host.view.removeFromSuperview()
        default:
            break
        }
        let call = lap.ms()
        await frames(3)
        Bench.record("warm.\(how)", ms: lap.ms(), ["call": call, "all_threads": cpuAll() - all, "footprint_added": footprint() - before])
        await frames(30)
    }

    // MARK: Light and dark

    /// Switches between light and dark the way the system does at sunset, on the list and with a message being written.
    private static func looks(_ model: AppModel, rounds: Int) async {
        for place in ["list", "compose"] {
            if place == "compose" {
                model.startCompose()
                await wait(upTo: 1.5) { typing() != nil }
                await frames(30)
            }
            for round in 0..<rounds {
                await frames(6)
                let lap = Lap()
                window?.overrideUserInterfaceStyle = round % 2 == 0 ? .dark : .light
                await frames(2)
                Bench.record("looks.\(place)", ms: lap.ms(), lap.fields())
            }
            window?.overrideUserInterfaceStyle = .unspecified
            if place == "compose" { model.closeCompose(discard: true) }
            model.toast = nil
            await frames(10)
        }
    }

    // MARK: Memory

    private static func snapshot(_ label: String, _ model: AppModel) {
        Bench.record("mem.\(label)", ms: footprint(), ["sqlite_mb": Double(sqlite3_memory_used()) / 1_048_576, "sqlite_peak_mb": Double(sqlite3_memory_highwater(0)) / 1_048_576, "rows": model.rows.count])
    }

    private static func list() -> UIScrollView? {
        all(UIScrollView.self).filter { !($0 is UITextView) && String(describing: Swift.type(of: $0)).contains("Scroll") && $0.contentSize.height > $0.bounds.height }
            .max { $0.contentSize.height < $1.contentSize.height }
    }

    /// Scrolls the list down a fixed step every frame until `rows` rows have gone past or the list ends.
    private static func scroll(_ model: AppModel, rows: Int) async {
        guard let list = list() else { return }
        let rowHeight = max(1, list.contentSize.height - 90) / CGFloat(max(1, model.rows.count))
        var moved: CGFloat = 0, stuck = 0
        while moved < rowHeight * CGFloat(rows), stuck < 40 {
            let bottom = max(0, list.contentSize.height - list.bounds.height)
            let next = min(list.contentOffset.y + 240, bottom)
            if next <= list.contentOffset.y { stuck += 1 } else { stuck = 0 }
            moved += max(0, next - list.contentOffset.y)
            list.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            await frames(1)
        }
        Bench.record("mem.scrolled_rows", ms: Double(moved / rowHeight), ["loaded": model.rows.count])
    }

    private static func memory(_ model: AppModel, idleSeconds: Int) async {
        await sleep(seconds: 2)
        snapshot("launch", model)
        model.go(.all)
        await frames(10)
        await scroll(model, rows: 1000)
        await sleep(seconds: 1)
        snapshot("scrolled_1000", model)
        list()?.setContentOffset(.zero, animated: false)
        await frames(10)
        let rows = model.rows.filter { !$0.id.hasPrefix("draft:") }.prefix(20)
        for row in rows {
            model.show(row)
            await frames(20)
        }
        snapshot("opened_20", model)
        model.closeThread()
        await frames(30)
        snapshot("closed", model)
        model.startCompose()
        await wait(upTo: 1.5) { typing() != nil }
        await type("a few words of an ordinary message ", metric: "mem.typed")
        await frames(20)
        snapshot("compose", model)
        model.closeCompose(discard: true)
        model.toast = nil
        await frames(30)
        snapshot("compose_closed", model)
        await sleep(seconds: Double(idleSeconds > 0 ? idleSeconds : 20))
        snapshot("idle", model)
        await warn()
        snapshot("after_warning", model)
        // And it must all still work afterwards.
        model.go(model.home)
        await frames(20)
        snapshot("back_home", model)
    }

    /// Tells the app memory is short, the way the system does, and waits for it to react.
    private static func warn() async {
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        await sleep(seconds: 1.5)
    }

    private static func warning(_ model: AppModel) async {
        snapshot("before_warning", model)
        await warn()
        snapshot("after_warning", model)
    }

    // MARK: Idle and the background

    /// Sits on the list doing nothing and records what the app used.
    private static func idle(seconds: Int) async {
        await sleep(seconds: 3)
        let main = cpu(), every = cpuAll(), woke = wakeups(), bodies = BodyCount.counts
        await sleep(seconds: Double(seconds))
        var fields: [String: Any] = ["seconds": seconds, "cpu_main": cpu() - main, "wakeups_per_minute": (wakeups() - woke) * 60 / Double(seconds)]
        for (name, grown) in BodyCount.since(bodies) { fields["n_" + name] = grown }
        Bench.record("idle.cpu", ms: (cpuAll() - every) / Double(seconds) * 60, fields)
    }

    /// Notes each time the app goes to the background and comes back, with what coming back cost.
    private static func watchPhases() {
        let center = NotificationCenter.default
        var left = 0.0, leftCPU = 0.0
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                left = Bench.now()
                leftCPU = cpuAll()
                Bench.record("phase.background", ms: 0, ["footprint": footprint()])
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Launch also "enters the foreground"; only a return counts.
                guard left > 0 else { return }
                let lap = Lap()
                let away = Bench.now() - left, used = cpuAll() - leftCPU
                Task { @MainActor in
                    await frames(3)
                    var fields = lap.fields()
                    fields["away_ms"] = away
                    fields["cpu_while_away"] = used
                    Bench.record("phase.foreground", ms: lap.ms(), fields)
                }
            }
        }
    }

    // MARK: Pictures of each screen, to compare before and after (made-up mailbox only)

    private static func shot(_ name: String) async {
        Bench.record("shot", ms: 0, ["name": name])
        // The script takes the picture when it sees the line, then writes this file to say it has.
        let taken = Bootstrap.directory.appendingPathComponent("shot-\(name).taken")
        await wait(upTo: 10) { FileManager.default.fileExists(atPath: taken.path) }
    }

    private static func shots(_ model: AppModel) async {
        await shot("list")
        model.startCompose()
        await wait(upTo: 1.5) { typing() != nil }
        await frames(30)
        await sleep(seconds: 1)
        await shot("compose_empty")
        await type("al", metric: "shot.type")
        await frames(10)
        await shot("compose_suggestions")
        model.compose?.to = "someone@example.invalid, "
        all(UITextField.self).last?.becomeFirstResponder()
        await frames(4)
        await type("Hello", metric: "shot.type")
        all(UITextView.self).first?.becomeFirstResponder()
        await frames(4)
        await type("First line of the message.", metric: "shot.type")
        await frames(10)
        await shot("compose_filled")
        model.closeCompose(discard: true)
        await frames(10)
        await shot("toast")
        model.toast = nil
        model.dropFocus()
        await sleep(seconds: 1)
        for (name, kind) in [("snooze", Overlay.snooze), ("accounts", .accounts), ("lists", .lists), ("more", .more)] {
            model.overlay = kind
            await frames(10)
            await shot("overlay_\(name)")
            model.overlay = nil
            await frames(4)
        }
        model.openPalette()
        await wait(upTo: 1.5) { typing() != nil }
        await sleep(seconds: 1)
        await shot("overlay_palette")
        model.dropFocus()
        model.overlay = nil
        await sleep(seconds: 1)
        model.startSearch()
        await frames(2)
        all(UITextField.self).first?.becomeFirstResponder()
        await wait(upTo: 1.5) { typing() != nil }
        await type("invoice", metric: "shot.type")
        await sleep(seconds: 1)
        await shot("search")
        model.dropFocus()
        model.endSearch()
        await frames(10)
    }
}
#endif
