#if DEBUG || BENCH
import BlitzCore
import Foundation
import Network
import WebKit

/// Times opening a conversation, from the key press to the page having drawn it. Compiled out of the app people use.
///
/// `bench/thread-open/run.sh` chooses conversations by shape, writes them to `bench-threads.tsv` in the data folder and
/// sends `bench:<scenario>` on the test hook. Every open becomes one line in `bench.jsonl`.
@MainActor
enum ThreadBench {
    // MARK: Hooks called from the code being measured

    static var active = false
    static var start = 0.0
    static var last = 0.0
    static var laps: [String: Double] = [:]
    static var nextId = 0
    /// Every render handed to the page while a measurement runs: its id, its size and when it left.
    static var renders: [(id: Int, bytes: Int, at: Double)] = []
    /// What the page said about each render, by id: when the message arrived here and the page's own timings.
    static var layouts: [Int: (at: Double, build: Double, layout: Double, entered: Double)] = [:]
    /// What else the page said with them: how far the widest open message sticks out sideways, its shrink, and so on.
    static var notes: [Int: [String: Any]] = [:]
    /// When the "painted" message arrived here, and what the page's clock said when it sent it.
    static var paints: [Int: (at: Double, clock: Double)] = [:]
    /// The wall clock at `start`, to compare with the page's clock (which only counts whole milliseconds).
    static var startClock = 0.0

    /// Adds the time since the previous lap to `name`. Once the first render has left, laps go under `later_<name>`:
    /// they belong to the page being drawn again (and `later_wait` is the idle time before that).
    static func lap(_ name: String) {
        guard active else { return }
        let now = Bench.now()
        laps[(firstLeft ? "later_" : "") + name, default: 0] += now - last
        last = now
        if name == "eval" { firstLeft = true }
    }
    static var firstLeft = false

    /// The id the page should report this render under, or nil when nothing is being measured.
    static func renderId(bytes: Int) -> Int? {
        guard active else { return nil }
        nextId += 1
        renders.append((nextId, bytes, Bench.now()))
        return nextId
    }

    /// A timing message from the page (`type: "bench"`).
    static func page(_ body: [String: Any], at arrived: Double) {
        guard let id = body["id"] as? Int, let stage = body["stage"] as? String else { return }
        if stage == "layout" {
            layouts[id] = (arrived, body["build"] as? Double ?? -1, body["layout"] as? Double ?? -1, body["entered"] as? Double ?? -1)
            for key in ["over", "zoom"] { notes[id, default: [:]][key] = body[key] }
        } else {
            paints[id] = (arrived, body["clock"] as? Double ?? -1)
            notes[id, default: [:]]["prepared_at_paint"] = body["prepared"]
        }
    }

    static func begin() {
        laps = [:]
        firstLeft = false
        renders = []
        layouts = [:]
        paints = [:]
        notes = [:]
        active = true
        startClock = Date().timeIntervalSince1970 * 1000
        start = Bench.now()
        last = start
    }

    // MARK: Running

    static var running = false

    /// `opens:20`, `unread:20`, `paint:3`, `rapid`, `memory`, or `all:20`.
    static func run(_ spec: String, model: AppModel) {
        guard !running else { return }
        running = true
        let parts = spec.split(separator: ":").map(String.init)
        let scenario = parts.first ?? "all"
        let count = parts.count > 1 ? Int(parts[1]) ?? 20 : 20
        Task {
            // Offline, the web view refuses every request to the network (`ThreadWeb.loadPage`). Never run without that.
            guard Bootstrap.offline else {
                Bench.record("thread_bench_error", ms: 0, ["what": "set BLITZ_OFFLINE=1"])
                running = false
                return
            }
            // Wait for the page: a benchmark sent right at launch would otherwise time the page load.
            for _ in 0..<500 where (try? await model.web.webView.evaluateJavaScript("typeof window.blitz")) as? String != "object" { await sleep(10) }
            if scenario == "offline" {
                await offlineCheck(model)
                running = false
                return
            }
            let chosen = threads(model)
            let shapes = chosen.filter { $0.shape != "memory" }
            if scenario == "opens" || scenario == "all" { await opens(model, shapes, reps: count, unread: false) }
            if scenario == "unread" || scenario == "all" { await opens(model, shapes, reps: count, unread: true) }
            if scenario == "rapid" || scenario == "all" { await rapid(model) }
            if scenario == "memory" || scenario == "all" { await memory(model, chosen.filter { $0.shape == "memory" }, rounds: scenario == "memory" && parts.count > 1 ? count : 5) }
            if scenario == "paint" { await paint(model, shapes, bursts: count) }
            if scenario == "verify" { verify(model) }
            await phone(scenario, count: parts.count > 1 ? count : nil, model: model, chosen: chosen)
            model.closeThread()
            active = false
            running = false
            Bench.record("thread_bench_done", ms: 0, ["scenario": scenario])
        }
    }

    /// On iPhone there is no test hook to send a command on: `BLITZ_THREAD_BENCH=opens:20` at launch runs it.
    static func runFromEnvironment(model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment["BLITZ_THREAD_BENCH"], !spec.isEmpty else { return }
        // Several scenarios, one after the other: `opens:10,prepare:5`.
        Task {
            for one in spec.split(separator: ",") {
                run(String(one), model: model)
                while running { await sleep(50) }
            }
            Bench.record("thread_bench_all_done", ms: 0)
        }
    }

    struct Chosen {
        var shape: String
        var account: String
        var thread: String
    }

    static func threads(_ model: AppModel) -> [Chosen] {
        let file = Bootstrap.directory.appendingPathComponent("bench-threads.tsv")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t").map(String.init)
            return fields.count == 3 ? Chosen(shape: fields[0], account: fields[1], thread: fields[2]) : nil
        }
    }

    static func sleep(_ milliseconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds * 1e6))
    }

    /// Waits until the page has run everything sent to it so far.
    static func drained(_ model: AppModel) async {
        _ = try? await model.web.webView.evaluateJavaScript("1")
    }

    static func waitLayout(_ id: Int, timeout: Double) async -> Bool {
        let deadline = Bench.now() + timeout
        while layouts[id] == nil, Bench.now() < deadline { await sleep(1) }
        return layouts[id] != nil
    }

    static func waitPaint(_ id: Int, timeout: Double) async -> Bool {
        let deadline = Bench.now() + timeout
        while paints[id] == nil, Bench.now() < deadline { await sleep(1) }
        return paints[id] != nil
    }

    /// Proves the offline web view asks the network for nothing. `offline-check.sh` has put pictures, style sheets, a
    /// font and media pointing at 127.0.0.1:18473 into the newest inbox conversation of a synth copy. This listens
    /// there and counts connections: first from a plain web view given the same HTML (the control, which must
    /// connect, or the count means nothing), then from the real conversation view (which must not).
    static func offlineCheck(_ model: AppModel) async {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 18473)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            Bench.record("thread_bench_error", ms: 0, ["what": "could not listen on 127.0.0.1:18473"])
            return
        }
        connections = 0
        listener.newConnectionHandler = { connection in
            // The listener runs on the main queue.
            MainActor.assumeIsolated { connections += 1 }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
        await sleep(500)
        guard let thread = model.rows.first, let html = (try? model.service.store.messages(account: thread.accountId, threadId: thread.id))?.last?.bodyHTML,
              html.contains("127.0.0.1:18473") else {
            Bench.record("thread_bench_error", ms: 0, ["what": "the newest conversation does not hold the probes"])
            return
        }
        let control = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        control.loadHTMLString(html, baseURL: nil)
        await sleep(3000)
        let fromControl = connections
        control.stopLoading()
        connections = 0
        model.show(thread)
        await sleep(1000)
        model.web.expandAll()
        await sleep(3000)
        let fromPage = connections
        listener.cancel()
        model.closeThread()
        Bench.record("thread_offline_check", ms: 0, ["control": fromControl, "page": fromPage])
    }

    static var connections = 0

    static func setUnread(_ model: AppModel, _ chosen: Chosen, _ unread: Bool) {
        try? model.service.store.modifyThreads(account: chosen.account, threadIds: [chosen.thread], add: unread ? [SystemLabel.unread] : [], remove: unread ? [] : [SystemLabel.unread])
    }

    /// One timed open. Returns the fields for its line in `bench.jsonl`.
    static func open(_ model: AppModel, _ chosen: Chosen, unread: Bool, settle: Double, paintWait: Double) async -> [String: Any]? {
        model.closeThread()
        setUnread(model, chosen, unread)
        await drained(model)
        await sleep(30)
        guard let thread = try? model.service.store.thread(account: chosen.account, id: chosen.thread) else { return nil }
        let cpuBefore = usage(model).cpu
        begin()
        model.show(thread)
        let shown = Bench.now()
        // When the app's own drawing of the change is over and the main thread is free again.
        mainFree = 0
        DispatchQueue.main.async { mainFree = Bench.now() }
        guard let first = renders.first, await waitLayout(first.id, timeout: 10_000), let layout = layouts[first.id] else { return nil }
        let painted = await waitPaint(first.id, timeout: paintWait)
        await sleep(settle)
        await drained(model)
        active = false
        var fields: [String: Any] = ["shape": chosen.shape, "unread": unread, "messages": model.messages.count, "bytes": first.bytes]
        for (name, value) in laps { fields["swift_" + name] = round3(value) }
        fields["swift_payload"] = round3(["signature", "regex", "people", "dates", "rest"].reduce(0) { $0 + (laps[$1] ?? 0) })
        fields["swift_to_script"] = round3(first.at - start + (laps["eval"] ?? 0))
        fields["swift_show"] = round3(shown - start)
        fields["main_free"] = round3(mainFree - start)
        fields["page_build"] = layout.build
        fields["page_layout"] = layout.layout
        // By the page's clock: when it started on this render, when it had laid it out, when two frames had gone by.
        fields["page_entered"] = round3(layout.entered - startClock)
        fields["page_laid_out"] = round3(layout.entered + layout.layout - startClock)
        // When the page's messages reached the app, which also waits for the app's own drawing to let them in.
        fields["e2e_layout"] = round3(layout.at - start)
        if painted, let paint = paints[first.id] {
            fields["page_painted"] = round3(paint.clock - startClock)
            fields["e2e_paint"] = round3(paint.at - start)
        }
        // Anything the page was asked to draw again after the first time (the read mark coming back, for example).
        let later = renders.dropFirst()
        fields["renders"] = renders.count
        // Processor time the page's process spent on this open, everything included (pictures arriving, drawing again).
        fields["web_cpu"] = round3(usage(model).cpu - cpuBefore)
        fields["later_bytes"] = later.reduce(0) { $0 + $1.bytes }
        fields["later_swift_ms"] = round3(laps.filter { $0.key.hasPrefix("later_") && $0.key != "later_wait" }.values.reduce(0, +))
        fields["later_page_ms"] = later.reduce(0.0) { $0 + (layouts[$1.id]?.layout ?? 0) }
        for (key, value) in notes[first.id] ?? [:] { fields[key] = value }
        fields["settled"] = round3((renders.compactMap { layouts[$0.id]?.at }.max() ?? layout.at) - start)
        return fields
    }

    static var mainFree = 0.0

    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    /// Opens each shape `reps` times. The window stays where it is, so the end is "laid out", plus "painted" when the
    /// window happened to be visible.
    static func opens(_ model: AppModel, _ shapes: [Chosen], reps: Int, unread: Bool) async {
        for rep in 0..<reps + 2 {
            for chosen in shapes {
                guard var fields = await open(model, chosen, unread: unread, settle: 200, paintWait: 120) else { continue }
                // The first two rounds warm caches and are not kept.
                guard rep >= 2 else { continue }
                if rep == 2 {
                    fields["dom"] = await domHash(model)
                    await snapshot(model, name: (unread ? "unread-" : "read-") + chosen.shape)
                }
                Bench.record("thread_open", ms: fields["e2e_layout"] as? Double ?? -1, fields)
            }
        }
        for chosen in shapes { setUnread(model, chosen, false) }
    }

    /// Brings the window forward (without activating the app) for under a second at a time so the page really paints.
    static func paint(_ model: AppModel, _ shapes: [Chosen], bursts: Int) async {
        for chosen in shapes { _ = await open(model, chosen, unread: false, settle: 0, paintWait: 0) }
        for _ in 0..<bursts {
            front(true)
            let deadline = Bench.now() + 850
            await sleep(60)
            for chosen in shapes where Bench.now() < deadline - 200 {
                guard let fields = await open(model, chosen, unread: false, settle: 0, paintWait: 150) else { continue }
                if let paint = fields["page_painted"] as? Double { Bench.record("thread_open_paint", ms: paint, fields) }
            }
            front(false)
            await sleep(1200)
        }
    }

    static func front(_ on: Bool) {
        #if os(macOS)
        let window = NSApp.windows.first { $0.frame.width > 700 }
        if on { window?.orderFrontRegardless() } else { window?.orderBack(nil) }
        #endif
    }

    /// Holding j with a conversation open: 30 presses, first as fast as the keyboard repeats and then back to back.
    static func rapid(_ model: AppModel) async {
        for interval in [33.0, 0.0] {
            for round in 0..<4 {
                model.closeThread()
                model.moveCursor(toEnd: false)
                guard model.rows.count > 40 else { return }
                model.show(model.rows[0])
                await sleep(300)
                await drained(model)
                begin()
                var presses: [(at: Double, took: Double, id: Int?)] = []
                for _ in 0..<30 {
                    let at = Bench.now()
                    let before = renders.count
                    _ = model.handle(AppModel.Key(characters: "j"))
                    presses.append((at, Bench.now() - at, renders.count > before ? renders.last?.id : nil))
                    if interval > 0 { await sleep(interval) }
                }
                let lastPress = presses.last?.at ?? start
                if let id = renders.last?.id { _ = await waitLayout(id, timeout: 10_000) }
                await sleep(300)
                await drained(model)
                active = false
                guard round > 0 else { continue }
                let took = presses.map(\.took).sorted()
                let lags = presses.compactMap { press in press.id.flatMap { layouts[$0] }.map { $0.at - press.at } }.sorted()
                let lastId = presses.last?.id ?? -1
                Bench.record("thread_rapid", ms: round3((layouts[lastId]?.at ?? lastPress) - lastPress), [
                    "interval": interval, "press_median": round3(took[took.count / 2]), "press_max": round3(took.last ?? 0),
                    "press_total": round3(took.reduce(0, +)), "lag_median": round3(lags.isEmpty ? -1 : lags[lags.count / 2]),
                    "lag_max": round3(lags.last ?? -1), "sent": renders.count, "drawn": layouts.count,
                    "page_ms": layouts.values.reduce(0.0) { $0 + $1.layout }, "bytes": renders.reduce(0) { $0 + $1.bytes },
                ])
            }
        }
    }

    /// Opens the 50 largest newsletters one after another and reads the web content process's memory.
    static func memory(_ model: AppModel, _ heavy: [Chosen], rounds: Int) async {
        model.closeThread()
        await sleep(500)
        let idle = footprint(model)
        for round in 1...rounds {
            for chosen in heavy {
                guard let thread = try? model.service.store.thread(account: chosen.account, id: chosen.thread) else { continue }
                begin()
                model.show(thread)
                if let id = renders.first?.id { _ = await waitLayout(id, timeout: 10_000) }
                active = false
                await sleep(20)
            }
            await sleep(500)
            let open = footprint(model)
            model.closeThread()
            await sleep(1500)
            Bench.record("thread_memory", ms: 0, ["round": round, "threads": heavy.count, "idle_mb": idle, "after_opens_mb": open, "after_close_mb": footprint(model)])
        }
        // Whether the page gives the memory back when left alone.
        await sleep(20_000)
        Bench.record("thread_memory", ms: 0, ["round": "20 s later", "threads": 0, "idle_mb": idle, "after_opens_mb": "-", "after_close_mb": footprint(model)])
    }

    /// Checks the quick classifying of a message against the patterns alone, on every message listed in
    /// `bench-all-threads.tsv` (account, thread id). Any difference is a bug.
    static func verify(_ model: AppModel) {
        let rich = try! NSRegularExpression(
            pattern: "<style|bgcolor\\s*=\\s*[\"']?(?!#?fff\\b|#?ffffff|white|transparent)[#a-z0-9]|background(-color)?\\s*:\\s*(?!#fff\\b|#ffffff|white|transparent|none|inherit|initial|rgba?\\(\\s*255\\s*,\\s*255\\s*,\\s*255|rgba\\([^)]*,\\s*0\\s*\\))[#a-z]",
            options: [.caseInsensitive])
        let text = (try? String(contentsOf: Bootstrap.directory.appendingPathComponent("bench-all-threads.tsv"), encoding: .utf8)) ?? ""
        var checked = 0, richCount = 0, cidCount = 0, wrong = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 2 else { continue }
            for message in (try? model.service.store.messages(account: fields[0], threadId: fields[1])) ?? [] {
                guard let html = message.bodyHTML, !html.isEmpty else { continue }
                let hints = AppModel.hints(in: html)
                let expectedRich = rich.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil
                let expectedCid = html.range(of: "cid:", options: .caseInsensitive) != nil
                checked += 1
                richCount += expectedRich ? 1 : 0
                cidCount += expectedCid ? 1 : 0
                if AppModel.isRich(html, hints) != expectedRich || hints.cid != expectedCid { wrong += 1 }
            }
        }
        Bench.record("thread_verify", ms: 0, ["checked": checked, "rich": richCount, "cid": cidCount, "wrong": wrong])
    }

    /// Megabytes the web content process is charged for (what Activity Monitor calls Memory).
    static func footprint(_ model: AppModel) -> Double { usage(model).megabytes }

    /// The web content process's memory, and the processor time it has used so far in milliseconds.
    static func usage(_ model: AppModel) -> (megabytes: Double, cpu: Double) {
        #if os(macOS)
        guard let pid = model.web.webView.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0 else { return (-1, -1) }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return (-1, -1) }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return ((Double(info.ri_phys_footprint) / 1_048_576 * 10).rounded() / 10, ticks * Double(timebase.numer) / Double(timebase.denom) / 1e6)
        #elseif targetEnvironment(simulator)
        // In a simulator the page's process is an ordinary process of this Mac, and the call exists though the phone's
        // headers do not list it.
        typealias Usage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer) -> Int32
        guard let pid = model.web.webView.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return (-1, -1) }
        var info = rusage_info_v4()
        guard unsafeBitCast(symbol, to: Usage.self)(pid, 4, &info) == 0 else { return (-1, -1) }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return ((Double(info.ri_phys_footprint) / 1_048_576 * 10).rounded() / 10, ticks * Double(timebase.numer) / Double(timebase.denom) / 1e6)
        #else
        // Another process's usage cannot be read on a real iPhone.
        return (-1, -1)
        #endif
    }

    /// A fingerprint of what the page shows: every element, class, inline style and text, inside the messages too,
    /// plus the page height. The same before and after a change means the page was built the same.
    static func domHash(_ model: AppModel) async -> String {
        let script = """
            (function () {
              var h = 2166136261, count = 0;
              function add(s) { for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } }
              function walk(n) {
                if (n.nodeType === 3) { add("#" + n.nodeValue); return; }
                if (n.nodeType !== 1) return;
                count++;
                add("<" + n.tagName + " " + (n.getAttribute("class") || "") + " " + (n.getAttribute("style") || "") + ">");
                // A collapsed message's inside is built in the background at no fixed moment, and is not on show.
                if (n.shadowRoot && n.parentNode.classList.contains("open")) { add("{"); n.shadowRoot.childNodes.forEach(walk); add("}"); }
                n.childNodes.forEach(walk);
                add("</>");
              }
              walk(document.getElementById("root"));
              return (h >>> 0).toString(16) + " nodes " + count + " height " + document.documentElement.scrollHeight + " scroll " + Math.round(window.scrollY);
            })()
            """
        return (try? await model.web.webView.evaluateJavaScript(script)) as? String ?? "?"
    }

    /// A picture of the conversation as drawn, saved as `shots/<name>.png` in the data folder.
    static func snapshot(_ model: AppModel, name: String) async {
        #if os(macOS)
        guard let image = try? await model.web.webView.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let folder = Bootstrap.directory.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent(name + ".png"))
        #else
        guard let image = try? await model.web.webView.takeSnapshot(configuration: nil), let png = image.pngData() else { return }
        let folder = Bootstrap.directory.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent(name + ".png"))
        #endif
    }
}
#endif
