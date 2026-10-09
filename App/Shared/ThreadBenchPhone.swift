#if DEBUG || BENCH
import BlitzCore
import Foundation
import QuartzCore
import WebKit

/// The measurements of reading mail that matter most on a phone: the first frame of a wide newsletter, preparing
/// collapsed messages, scrolling, the back swipe, the page's memory, losing the page's process, going to the next
/// conversation and the app's own picture addresses. Compiled out of the app people use.
///
/// `bench/ios-thread/run.sh` starts them (`BLITZ_THREAD_BENCH=fit,prepare:5,...`); each writes lines to `bench.jsonl`.
extension ThreadBench {
    // MARK: Counting

    /// How many times each named thing happened (a view's body ran, a picture was asked for) since `takeCounts`.
    static var counts: [String: Int] = [:]

    static func count(_ name: String) { counts[name, default: 0] += 1 }

    static func takeCounts() -> [String: Any] {
        defer { counts = [:] }
        return Dictionary(uniqueKeysWithValues: counts.map { ("n_" + $0.key, $0.value as Any) })
    }

    /// Processor time the app's main thread has used, in milliseconds. Steadier than the wall clock in a simulator.
    static func mainCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    /// Calls back once a screen refresh, which is how the scenarios move things "per frame".
    private final class Frames: NSObject {
        static let shared = Frames()
        #if os(iOS)
        private var link: CADisplayLink?
        #endif
        private var waiting: [CheckedContinuation<Double, Never>] = []

        func next() async -> Double {
            #if os(iOS)
            return await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if link == nil {
                    link = CADisplayLink(target: self, selector: #selector(tick))
                    link?.add(to: .main, forMode: .common)
                }
            }
            #else
            try? await Task.sleep(nanoseconds: 16_000_000)
            return Bench.now()
            #endif
        }

        #if os(iOS)
        @objc private func tick(_ link: CADisplayLink) {
            let ready = waiting
            waiting = []
            if ready.isEmpty {
                link.invalidate()
                self.link = nil
            }
            for continuation in ready { continuation.resume(returning: link.timestamp * 1000) }
        }
        #endif
    }

    /// Waits for the next screen refresh and returns its time in milliseconds.
    @discardableResult static func frame() async -> Double { await Frames.shared.next() }

    static func frames(_ count: Int) async {
        for _ in 0..<count { await frame() }
    }

    private static func script(_ model: AppModel, _ source: String) async -> Any? {
        try? await model.web.webView.evaluateJavaScript(source)
    }

    /// Starts writing down, inside the page, the time between its animation frames: a long one is the page's main
    /// thread being busy.
    private static func startPageFrames(_ model: AppModel) async {
        _ = await script(model, """
            (function () {
              var log = window.__benchFrames = { on: true, gaps: [], last: 0 };
              function tick(now) {
                if (window.__benchFrames !== log || !log.on) return;
                if (log.last) log.gaps.push(now - log.last);
                log.last = now;
                requestAnimationFrame(tick);
              }
              requestAnimationFrame(tick);
              return 1;
            })()
            """)
    }

    /// Stops it and returns: frames seen, the longest gap, how many gaps were over 1.5 times the usual one, and the time
    /// lost in those beyond the usual gap.
    private static func stopPageFrames(_ model: AppModel) async -> [String: Any] {
        let text = await script(model, """
            (function () {
              var log = window.__benchFrames;
              if (!log) return "0 0 0 0 0";
              log.on = false;
              var gaps = log.gaps.slice().sort(function (a, b) { return a - b; });
              if (!gaps.length) return "0 0 0 0 0";
              var usual = gaps[gaps.length >> 1], long = 0, lost = 0;
              gaps.forEach(function (gap) { if (gap > usual * 1.5) { long++; lost += gap - usual; } });
              return [gaps.length, gaps[gaps.length - 1].toFixed(1), long, lost.toFixed(1), usual.toFixed(1)].join(" ");
            })()
            """) as? String ?? "0 0 0 0 0"
        let parts = text.split(separator: " ").map { Double($0) ?? 0 }
        return ["page_frames": parts[0], "page_worst_frame": parts[1], "page_long_frames": parts[2], "page_lost_ms": parts[3], "page_usual_frame": parts[4]]
    }

    private static func prepared(_ model: AppModel) async -> (built: Int, total: Int) {
        let text = await script(model, """
            (function () {
              var boxes = document.querySelectorAll("#root > .msg"), built = 0;
              for (var i = 0; i < boxes.length; i++) if (boxes[i].querySelector(":scope > .body").shadowRoot) built++;
              return built + " " + boxes.length;
            })()
            """) as? String ?? "0 0"
        let parts = text.split(separator: " ").map { Int($0) ?? 0 }
        return (parts[0], parts[1])
    }

    private static func merge(_ fields: inout [String: Any], _ more: [String: Any]) {
        for (key, value) in more { fields[key] = value }
    }

    // MARK: Running

    static func phone(_ scenario: String, count: Int?, model: AppModel, chosen: [Chosen]) async {
        let shapes = chosen.filter { $0.shape != "memory" }
        seedPictures(model)
        switch scenario {
        case "fit": await fit(model, shapes)
        case "prepare": await prepare(model, shapes, reps: count ?? 5)
        case "scroll": await scroll(model, shapes, reps: count ?? 3)
        case "back": await back(model, shapes, reps: count ?? 10)
        case "reclaim": await reclaim(model, shapes, reps: count ?? 5)
        case "next": await next(model, reps: count ?? 12)
        case "pictures": await pictures(model, shapes, reps: count ?? 5)
        case "heavy": await heavy(model, chosen.filter { $0.shape == "memory" }, rounds: count ?? 1)
        case "hold": await hold(model, chosen.filter { $0.shape == "memory" }, rounds: count ?? 1)
        default: break
        }
    }

    /// Copies the made-up attachments `blitzbench pictures` wrote (`bench-pictures/<message id>/<file>`) to where the
    /// app keeps downloaded attachments, because nothing can be downloaded in a benchmark.
    private static func seedPictures(_ model: AppModel) {
        guard !seeded else { return }
        seeded = true
        let folder = Bootstrap.directory.appendingPathComponent("bench-pictures", isDirectory: true)
        for messageId in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            for account in (try? model.service.store.accounts()) ?? [] {
                guard let message = try? model.service.store.message(account: account.id, id: messageId) else { continue }
                for attachment in message.attachments {
                    guard let data = try? Data(contentsOf: folder.appendingPathComponent(messageId).appendingPathComponent(attachment.filename)) else { continue }
                    AttachmentCache.seed(messageId: messageId, attachment: attachment, data: data)
                }
            }
        }
    }

    private static var seeded = false

    // MARK: The first frame of a wide message

    /// Opens each shape once and writes down what its first laid-out frame looked like: how far the open message
    /// stuck out of its box sideways, the shrink it had been given, and the same again a second later. Saves a picture
    /// of the web view at both moments (made-up mail only; the script throws them away for real mail).
    private static func fit(_ model: AppModel, _ shapes: [Chosen]) async {
        for chosen in shapes {
            guard let fields = await open(model, chosen, unread: false, settle: 0, paintWait: 150) else { continue }
            await snapshot(model, name: "first-" + chosen.shape)
            await sleep(1000)
            let later = await script(model, """
                (function () {
                  var over = 0, zoom = "";
                  document.querySelectorAll("#root > .msg.open > .body").forEach(function (host) {
                    over = Math.max(over, host.scrollWidth - host.clientWidth);
                    var wrapper = host.shadowRoot && host.shadowRoot.querySelector(".w");
                    if (wrapper && wrapper.style.zoom) zoom = wrapper.style.zoom;
                  });
                  return over + " " + zoom;
                })()
                """) as? String ?? ""
            await snapshot(model, name: "settled-" + chosen.shape)
            let parts = later.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            Bench.record("thread_fit", ms: fields["page_layout"] as? Double ?? -1, [
                "shape": chosen.shape, "over_first": fields["over"] ?? -1, "zoom_first": fields["zoom"] ?? "",
                "over_later": Double(parts.first ?? "") ?? -1, "zoom_later": parts.count > 1 ? parts[1] : "", "dom": await domHash(model),
            ])
        }
    }

    // MARK: Preparing collapsed messages

    /// Opens a long conversation and watches the page build its collapsed messages in the background until it stops: how many it built and by when, the processor time its process used, what that did to the page's
    /// frames and its memory, and then how long expanding a message takes (the nearest collapsed one, and the first).
    private static func prepare(_ model: AppModel, _ shapes: [Chosen], reps: Int) async {
        for rep in 0..<reps + 1 {
            for chosen in shapes where ["thread60", "thread200", "pics-thread"].contains(chosen.shape) {
                model.closeThread()
                await drained(model)
                await sleep(400)
                guard let thread = try? model.service.store.thread(account: chosen.account, id: chosen.thread) else { continue }
                let before = usage(model)
                await startPageFrames(model)
                begin()
                model.show(thread)
                guard let first = renders.first, await waitLayout(first.id, timeout: 10_000), let layout = layouts[first.id] else { continue }
                // Until every message is built, or nothing more has been built for a second and a half (20 s at most).
                var built = 0, total = 0, lastChange = 0.0, half = 0.0
                while Bench.now() - start < 20_000 {
                    let now = await prepared(model)
                    if now.total > 0 {
                        if now.built != built { lastChange = Bench.now() - start }
                        (built, total) = now
                    }
                    if half == 0, Bench.now() - start >= 500 { half = usage(model).cpu - before.cpu }
                    if total > 0, built == total || Bench.now() - start - lastChange > 1500 { break }
                    await sleep(25)
                }
                _ = await waitPaint(first.id, timeout: 10)
                var fields = await stopPageFrames(model)
                active = false
                let after = usage(model)
                fields["shape"] = chosen.shape
                fields["messages"] = total
                fields["built"] = built
                fields["built_at_paint"] = notes[first.id]?["prepared_at_paint"] ?? -1
                fields["built_by_ms"] = round3(lastChange)
                fields["page_layout"] = layout.layout
                fields["page_painted"] = paints[first.id].map { round3($0.clock - startClock) } ?? -1
                fields["web_cpu_500ms"] = round3(half)
                                fields["web_mb_before"] = before.megabytes
                fields["web_mb_after"] = after.megabytes
                // Expanding: the collapsed message nearest the open one, then the very first, each timed inside the page
                // from the tap to laid out.
                let expand = await script(model, """
                    (function () {
                      var closed = document.querySelectorAll("#root > .msg:not(.open)");
                      if (!closed.length) return "-1 -1";
                      function time(box) {
                        var started = performance.now();
                        box.querySelector(".head").click();
                        void document.getElementById("root").offsetHeight;
                        return (performance.now() - started).toFixed(2);
                      }
                      var near = time(closed[closed.length - 1]);
                      return near + " " + (closed.length > 1 ? time(closed[0]) : "-1");
                    })()
                    """) as? String ?? "-1 -1"
                let times = expand.split(separator: " ").map { Double($0) ?? -1 }
                fields["expand_near_ms"] = times[0]
                fields["expand_far_ms"] = times.count > 1 ? times[1] : -1
                if rep > 0 { Bench.record("thread_prepare", ms: after.cpu - before.cpu, fields) }
            }
        }
    }

    // MARK: Scrolling

    /// Scrolls an open message from top to bottom a fixed distance every frame, the way a quick flick does, twice:
    /// the first pass meets every picture for the first time, the second finds them decoded. Writes down the page's
    /// frames, the processor time of the page's process and of the app's main thread per frame, and the memory after.
    private static func scroll(_ model: AppModel, _ shapes: [Chosen], reps: Int) async {
        for rep in 0..<reps {
            for chosen in shapes where ["news150", "pics-data", "pics-cid", "thread200"].contains(chosen.shape) {
                guard await open(model, chosen, unread: false, settle: 700, paintWait: 150) != nil else { continue }
                if chosen.shape == "thread200" {
                    model.web.expandAll()
                    await sleep(1500)
                }
                for pass in ["first", "again"] {
                    await jump(model, to: 0)
                    await frames(6)
                    let height = (await script(model, "document.documentElement.scrollHeight - window.innerHeight") as? Double) ?? 0
                    let before = usage(model)
                    let cpu = mainCPU()
                    await startPageFrames(model)
                    var offset = 0.0, steps = 0
                    while offset < height, steps < 240 {
                        offset = min(height, offset + 48)
                        await jump(model, to: offset)
                        await frame()
                        steps += 1
                    }
                    await frames(4)
                    var fields = await stopPageFrames(model)
                    let after = usage(model)
                    fields["shape"] = chosen.shape
                    fields["pass"] = pass
                    fields["steps"] = steps
                    fields["page_height"] = height
                    fields["web_cpu_per_frame"] = round3((after.cpu - before.cpu) / Double(max(1, steps)))
                    fields["main_cpu_per_frame"] = round3((mainCPU() - cpu) / Double(max(1, steps)))
                    fields["web_mb"] = after.megabytes
                    if rep > 0 || reps == 1 { Bench.record("thread_scroll", ms: after.cpu - before.cpu, fields) }
                }
            }
        }
    }

    /// Moves the conversation to `offset` points from its top, the way a finger moves it.
    private static func jump(_ model: AppModel, to offset: Double) async {
        #if os(iOS)
        let view = model.web.webView.scrollView
        view.setContentOffset(CGPoint(x: 0, y: offset - view.adjustedContentInset.top), animated: false)
        #else
        _ = await script(model, "window.scrollTo(0, \(offset))")
        #endif
    }

    // MARK: The back swipe

    /// Opens a conversation and drags it back with a finger: thirty frames of travel, then a lift past the threshold
    /// and the slide away. Counts which views drew themselves again, the app's main-thread time per frame and the
    /// processor time the page's process spent while its view was only being moved. Once more with the drag starting
    /// the instant a 200-message conversation is asked for, while the page is still drawing it.
    private static func back(_ model: AppModel, _ shapes: [Chosen], reps: Int) async {
        await frames(10)
        let idle = mainCPU()
        await frames(60)
        Bench.record("thread_back_idle_frame", ms: (mainCPU() - idle) / 60)
        for (label, shape, settle) in [("settled", "news150", 600.0), ("while drawing", "thread200", 0.0)] {
            guard let chosen = shapes.first(where: { $0.shape == shape }), let thread = try? model.service.store.thread(account: chosen.account, id: chosen.thread) else { continue }
            for rep in 0..<reps + 1 {
                model.closeThread()
                await drained(model)
                await sleep(300)
                model.show(thread)
                if settle > 0 {
                    await sleep(settle)
                    await drained(model)
                }
                _ = takeCounts()
                let before = usage(model)
                let cpu = mainCPU()
                var last = await frame()
                var gaps: [Double] = []
                let steps = 30
                for step in 1...steps {
                    dragBack(model, Double(step) * 8, nil)
                    let now = await frame()
                    gaps.append(now - last)
                    last = now
                }
                var fields = takeCounts()
                fields["case"] = label
                fields["main_cpu_per_frame"] = round3((mainCPU() - cpu) / Double(steps))
                fields["web_cpu_per_frame"] = round3((usage(model).cpu - before.cpu) / Double(steps))
                fields["worst_frame"] = round3(gaps.max() ?? 0)
                if rep > 0 { Bench.record("thread_back_drag", ms: fields["main_cpu_per_frame"] as? Double ?? -1, fields) }
                let liftCPU = mainCPU(), lifted = Bench.now()
                dragBack(model, Double(steps) * 8, 600)
                gaps = []
                last = await frame()
                while model.openThread != nil, Bench.now() - lifted < 2000 {
                    let now = await frame()
                    gaps.append(now - last)
                    last = now
                }
                await frame()
                fields = takeCounts()
                fields["case"] = label
                fields["main_cpu"] = round3(mainCPU() - liftCPU)
                fields["frames"] = gaps.count
                fields["worst_frame"] = round3(gaps.max() ?? 0)
                if rep > 0 { Bench.record("thread_back_slide", ms: Bench.now() - lifted, fields) }
                await frames(6)
            }
        }
    }

    private static func dragBack(_ model: AppModel, _ distance: Double, _ velocity: Double?) {
        #if os(iOS)
        model.web.onBackDrag?(CGFloat(distance), velocity.map { CGFloat($0) })
        #endif
    }

    // MARK: Losing the page's process

    /// Opens a conversation, scrolls it, then kills the page's process the way the system does to a phone app in the
    /// background. Times the way back: the app being told, the page loaded again, the conversation laid out. Writes
    /// down what was kept: the place scrolled to and how many messages were open.
    private static func reclaim(_ model: AppModel, _ shapes: [Chosen], reps: Int) async {
        for _ in 0..<reps {
            for chosen in shapes where ["news150", "thread60"].contains(chosen.shape) {
                guard await open(model, chosen, unread: false, settle: 300, paintWait: 150) != nil else { continue }
                if chosen.shape == "thread60" {
                    model.web.expandAll()
                    await sleep(400)
                }
                await jump(model, to: 600)
                await frames(10)
                let state = "window.scrollY + ' ' + document.querySelectorAll('#root > .msg.open').length"
                let stateBefore = await script(model, state) as? String ?? "?"
                guard let pid = model.web.webView.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0 else { continue }
                begin()
                // Only ever this app's own page process, by its id.
                kill(pid, SIGKILL)
                var told = 0.0
                while Bench.now() - start < 60_000, renders.isEmpty {
                    if told == 0, (model.web.webView.value(forKey: "_webProcessIdentifier") as? Int32 ?? 0) != pid { told = Bench.now() - start }
                    await sleep(1)
                }
                guard let first = renders.first, await waitLayout(first.id, timeout: 10_000), let layout = layouts[first.id] else {
                    Bench.record("thread_reclaim", ms: -1, ["shape": chosen.shape, "error": "not drawn again"])
                    active = false
                    continue
                }
                let painted = await waitPaint(first.id, timeout: 300)
                active = false
                await sleep(300)
                let stateAfter = await script(model, state) as? String ?? "?"
                Bench.record("thread_reclaim", ms: round3(layout.at - start), [
                    "shape": chosen.shape, "noticed": round3(told), "page_ready": round3(first.at - start), "page_layout": layout.layout,
                    "painted": painted ? round3((paints[first.id]?.at ?? 0) - start) : -1, "state_before": stateBefore, "state_after": stateAfter,
                    "web_mb": usage(model).megabytes,
                ])
            }
        }
    }

    // MARK: The next conversation

    /// With a conversation open from the inbox, archives it: the next one is shown in its place. Counts which views
    /// drew themselves again and times the app's main thread and the page.
    private static func next(_ model: AppModel, reps: Int) async {
        model.closeThread()
        model.go(model.home)
        await sleep(500)
        guard let top = model.rows.first(where: { !$0.id.hasPrefix("draft:") }) else { return }
        model.show(top)
        await sleep(600)
        for rep in 0..<reps + 2 {
            await drained(model)
            await frames(4)
            guard model.openThread != nil else { return }
            _ = takeCounts()
            let cpu = mainCPU()
            begin()
            model.markDone()
            let call = Bench.now() - start
            guard let first = renders.first, await waitLayout(first.id, timeout: 10_000), let layout = layouts[first.id] else { continue }
            await frame()
            var fields = takeCounts()
            fields["main_cpu"] = round3(mainCPU() - cpu)
            fields["call"] = round3(call)
            fields["page_layout"] = layout.layout
            fields["bytes"] = first.bytes
            fields["messages"] = model.messages.count
            active = false
            if rep >= 2 { Bench.record("thread_next", ms: round3(layout.at - start), fields) }
            model.toast = nil
            await sleep(250)
        }
    }

    // MARK: The app's own picture addresses

    /// Sender pictures and inline pictures come from the app (`blitz-avatar:`, `blitz-cid:`). Counts how often the
    /// page asks for them on a first open and on opening the same conversation again, and times each answer from
    /// inside the page.
    private static func pictures(_ model: AppModel, _ shapes: [Chosen], reps: Int) async {
        for chosen in shapes where ["pics-cid", "pics-thread", "thread60"].contains(chosen.shape) {
            guard let thread = try? model.service.store.thread(account: chosen.account, id: chosen.thread) else { continue }
            for rep in 0..<reps {
                model.closeThread()
                await drained(model)
                await sleep(300)
                _ = takeCounts()
                let cpu = mainCPU()
                model.show(thread)
                await sleep(1500)
                var fields = takeCounts()
                fields["shape"] = chosen.shape
                fields["open"] = rep == 0 ? "first" : "again"
                fields["main_cpu"] = round3(mainCPU() - cpu)
                // Each picture on the page asked for once more under a new address, one at a time, timed in the page.
                let timed = (try? await model.web.webView.callAsyncJavaScript("""
                    var seen = {}, urls = [];
                    function collect(scope) {
                      scope.querySelectorAll("img").forEach(function (img) {
                        var src = img.getAttribute("src") || "";
                        if ((src.indexOf("blitz-cid:") === 0 || src.indexOf("blitz-avatar:") === 0) && !seen[src]) { seen[src] = 1; urls.push(src); }
                      });
                      scope.querySelectorAll("*").forEach(function (node) { if (node.shadowRoot) collect(node.shadowRoot); });
                    }
                    collect(document);
                    var out = { cid: [], avatar: [] };
                    for (var i = 0; i < urls.length && i < 24; i++) {
                      var started = performance.now();
                      await new Promise(function (done) {
                        var img = new Image();
                        img.onload = img.onerror = done;
                        img.src = urls[i];
                      });
                      out[urls[i].indexOf("blitz-cid:") === 0 ? "cid" : "avatar"].push(performance.now() - started);
                    }
                    function median(list) { list.sort(function (a, b) { return a - b; }); return list.length ? list[list.length >> 1] : -1; }
                    return [urls.length, median(out.cid), median(out.avatar)].join(" ");
                    """, arguments: [:], in: nil, contentWorld: .page)) as? String ?? ""
                let parts = timed.split(separator: " ").map { Double($0) ?? -1 }
                if parts.count == 3 {
                    fields["addresses"] = parts[0]
                    fields["cid_ms"] = round3(parts[1])
                    fields["avatar_ms"] = round3(parts[2])
                }
                merge(&fields, takeCounts().reduce(into: [:]) { $0["again_" + $1.key] = $1.value })
                if rep < 2 { Bench.record("thread_pictures", ms: fields["main_cpu"] as? Double ?? -1, fields) }
            }
        }
    }

    // MARK: Looking inside the page's process

    /// For finding what the page's process keeps: stops three times for 25 seconds, each time writing the process's id
    /// to the log so the script can look inside it (`INSPECT=` in run.sh): before anything, after one round of the 50
    /// largest newsletters opened and closed, and after `rounds` more. What grows between the last two is kept for good.
    private static func hold(_ model: AppModel, _ heavy: [Chosen], rounds: Int) async {
        func pause(_ label: String) async {
            model.closeThread()
            await sleep(3000)
            let pid = model.web.webView.value(forKey: "_webProcessIdentifier") as? Int32 ?? 0
            Bench.record("thread_hold", ms: Double(pid), ["at": label, "web_mb": usage(model).megabytes])
            await sleep(25_000)
        }
        func round() async {
            for chosen in heavy {
                guard let thread = try? model.service.store.thread(account: chosen.account, id: chosen.thread) else { continue }
                begin()
                model.show(thread)
                if let id = renders.first?.id { _ = await waitLayout(id, timeout: 10_000) }
                active = false
                await frames(3)
            }
        }
        await pause("start")
        await round()
        await pause("after 50")
        for _ in 0..<max(1, rounds) { await round() }
        await pause("after \(50 * (1 + max(1, rounds)))")
    }

    // MARK: Memory after many heavy opens

    /// Opens the 50 largest newsletters one after another, `rounds` times over, then closes: the memory of the page's
    /// process when idle, after the opens, after closing, and 5 seconds later.
    private static func heavy(_ model: AppModel, _ heavy: [Chosen], rounds: Int) async {
        model.closeThread()
        await sleep(1500)
        let idle = usage(model).megabytes
        for round in 1...max(1, rounds) {
            for chosen in heavy {
                guard let thread = try? model.service.store.thread(account: chosen.account, id: chosen.thread) else { continue }
                begin()
                model.show(thread)
                if let id = renders.first?.id { _ = await waitLayout(id, timeout: 10_000) }
                active = false
                await frames(3)
            }
            await sleep(500)
            let open = usage(model).megabytes
            model.closeThread()
            await sleep(1500)
            let closed = usage(model).megabytes
            await sleep(5000)
            Bench.record("thread_heavy", ms: 0, ["round": round, "opens": heavy.count * round, "idle_mb": idle, "after_opens_mb": open, "after_close_mb": closed, "later_mb": usage(model).megabytes])
        }
    }
}
#endif
