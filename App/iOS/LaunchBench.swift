#if DEBUG || BENCH
import MachCore
import SwiftUI
import UIKit
import UserNotifications
import WebKit

/// Times every way the phone app starts: a cold launch, a launch that goes straight to a conversation (the
/// notification path), coming back from the background, and the conversation page being thrown away and loaded again.
/// Compiled out of the app people use. Driven by `bench/ios-launch/`; every number goes to `bench.jsonl`.
///
/// Launch marks are milliseconds since the process started, each with the main thread's processor time so far:
///   launch.host        first line of our own code (`PhoneHost.init`)
///   launch.service     the database is open and migrated
///   launch.model.web / .accounts / .list     inside `AppModel.init`: web view made, accounts read, first list read
///   launch.model       `AppModel.init` returned
///   launch.hostReady   `PhoneHost.init` returned
///   launch.firstFrame  first screen refresh at which the list's rows have been laid out (or the welcome screen is up)
///   launch.idle        the main thread first has nothing to do after that: a tap would be handled from here
///   thread_web_ready   the conversation page can take a conversation
///   launch.openShown   (MACH_LAUNCH_OPEN=1) the conversation asked for at launch has been painted
@MainActor
enum LaunchBench {
    private static weak var model: AppModel?
    private static var link: CADisplayLink?
    private static var ticks = 0
    /// Screen refreshes with a window up but no row laid out yet, while rows were expected: an empty-list flash.
    private static var emptyTicks = 0
    private static var firstFrame = false
    private static var idle = false
    private static var webReady = false
    private static var finished = false
    private static var opening = false
    private static var openShown = false
    /// How many times the list of conversations was replaced since launch.
    private static var listApplies = 0

    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
    static func cpuAll() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e6 }

    /// Memory charged to the app, in megabytes.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private final class Ticker: NSObject {
        @objc func tick(_ link: CADisplayLink) { MainActor.assumeIsolated { LaunchBench.tick() } }
    }
    private static let ticker = Ticker()

    /// Called at the end of `PhoneHost.init`.
    static func start(model: AppModel?) {
        Bench.once("launch.hostReady")
        guard let model else { return }
        self.model = model
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated { LaunchBench.wentIdle() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        watchList()
        watchForeground()
        // Nothing outside can drive a build that is looking at real mail.
        if Bootstrap.offline { listenForCommands() }
        if ProcessInfo.processInfo.environment["MACH_LAUNCH_OPEN"] == "1" {
            opening = true
            // A tapped notification is handed to `Notifier` once launch has finished; this is the earliest that can be.
            DispatchQueue.main.async {
                guard let thread = model.rows.first else { return }
                Bench.once("launch.openCalled")
                model.open(account: thread.accountId, threadId: thread.id)
            }
        }
    }

    private static func watchList() {
        guard let model else { return }
        withObservationTracking { _ = model.rows } onChange: {
            DispatchQueue.main.async {
                listApplies += 1
                watchList()
            }
        }
    }

    private static var windowUp: Bool {
        UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.windows.contains { $0.rootViewController?.viewIfLoaded?.window != nil } ?? false }
    }

    private static func tick() {
        guard let model else { return }
        ticks += 1
        if !firstFrame {
            guard windowUp else { return }
            let expected = !model.rows.isEmpty
            let laid = RowSwipe.shared.frames.count
            if laid > 0 || !expected {
                firstFrame = true
                Bench.once("launch.firstFrame", ["rows": laid, "tick": ticks, "emptyTicks": emptyTicks, "cpuAll": cpuAll(), "listApplies": listApplies])
            } else {
                emptyTicks += 1
            }
            return
        }
        if !webReady, model.web.caughtUp {
            webReady = true
            if opening { shown("launch.openShown") { openShown = true } }
        }
        if idle, webReady, !opening || openShown, !finished {
            finished = true
            link?.isPaused = true
            Bench.record("done", ms: 0, ["cmd": "launch", "listApplies": listApplies, "emptyTicks": emptyTicks, "cpu": cpu(), "cpuAll": cpuAll(), "footprint": footprint()])
        }
    }

    private static func wentIdle() {
        if firstFrame, !idle {
            idle = true
            Bench.once("launch.idle", ["cpuAll": cpuAll(), "listApplies": listApplies])
        }
        if let began = resumeBegan, resumeActive {
            resumeBegan = nil
            Bench.record("resume.idle", ms: Bench.now() - began.at, ["cpu": cpu() - began.cpu, "handler": resumeHandler, "handlerCpu": resumeHandlerCPU])
        }
    }

    /// Records `metric` once the page has painted what it was last given: two of its own screen refreshes later.
    private static func shown(_ metric: String, since: Double? = nil, then: @escaping () -> Void = {}) {
        guard let model else { return }
        let script = "return await new Promise(function (done) { requestAnimationFrame(function () { requestAnimationFrame(function () { done(document.body.innerText.length); }); }); });"
        model.web.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            let length = (try? result.get()) as? Int ?? -1
            if let since {
                Bench.record(metric, ms: Bench.now() - since, ["chars": length])
            } else {
                Bench.once(metric, ["chars": length])
            }
            then()
        }
    }

    // MARK: Coming back from the background

    private static var resumeBegan: (at: Double, cpu: Double)?
    private static var resumeActive = false
    private static var resumeHandler = 0.0
    private static var resumeHandlerCPU = 0.0

    private static func watchForeground() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                resumeBegan = (Bench.now(), cpu())
                resumeActive = false
                resumeHandler = 0
                resumeHandlerCPU = 0
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { resumeActive = true }
        }
    }

    /// Wraps what the app itself does when the scene becomes active or goes to the background.
    static func phase(_ name: String, _ work: () -> Void) {
        let start = (Bench.now(), cpu())
        work()
        let took = (Bench.now() - start.0, cpu() - start.1)
        if name == "active" {
            resumeHandler = took.0
            resumeHandlerCPU = took.1
        }
        Bench.record("phase." + name, ms: took.0, ["cpu": took.1])
    }

    // MARK: Commands from the benchmark script

    private static func listenForCommands() {
        for command in ["webkill", "open", "relay"] {
            let name = "com.ahmedkhaleel.machbench.launch.\(command)" as CFString
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
                guard let raw = name?.rawValue as String?, let command = raw.split(separator: ".").last.map(String.init) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { LaunchBench.run(command) } }
            }, name, nil, .deliverImmediately)
        }
    }

    private static var busy = false

    private static func run(_ command: String) {
        guard let model, !busy else { return }
        busy = true
        Task { @MainActor in
            switch command {
            case "open":
                if let thread = model.rows.first { model.open(account: thread.accountId, threadId: thread.id) }
                await painted()
            case "webkill":
                await webKill(model, rounds: 8)
            case "relay":
                relay(model)
            default:
                break
            }
            busy = false
            Bench.record("done", ms: 0, ["cmd": command])
        }
    }

    /// What the app does on the main thread for the push relay every time it comes to the front, with a relay that
    /// is not there (127.0.0.1, nothing listening): the cost on this side only. Offline the real code path does nothing,
    /// so this uses a second service that is not offline, is given made-up sign-ins, and is never asked to sync.
    private static func relay(_ model: AppModel) {
        let tokens = FileTokenStore(directory: Bootstrap.directory)
        for account in model.accounts { tokens.save(TokenSet(refreshToken: "made-up"), account: account.id) }
        guard let service = try? MailService(directory: Bootstrap.directory, client: OAuthClient(clientId: "bench.invalid", clientSecret: nil), tokens: tokens, offline: false) else { return }
        let link = LiveLink(relay: PushRelay(url: "http://127.0.0.1:1", secret: "x", sandbox: nil), service: service)
        let token = String(repeating: "a", count: 64)
        func time(_ metric: String, _ work: () -> Void) {
            let start = (Bench.now(), cpu())
            work()
            Bench.record(metric, ms: Bench.now() - start.0, ["cpu": cpu() - start.1])
        }
        for _ in 0 ..< 20 {
            time("relay.register") { link.register(deviceToken: token, avatars: AvatarStore.enabled) }
        }
        // `LiveLink.start` without its retry (which would sync): read the accounts, open a web socket.
        let session = URLSession(configuration: .default)
        for _ in 0 ..< 20 {
            time("relay.liveStart") {
                let emails = ((try? service.store.accounts()) ?? []).map(\.id)
                var components = URLComponents(string: "ws://127.0.0.1:1/live")!
                components.queryItems = [URLQueryItem(name: "emails", value: emails.joined(separator: ","))]
                let socket = session.webSocketTask(with: URLRequest(url: components.url!))
                socket.resume()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
        for _ in 0 ..< 20 {
            time("relay.badge") { UNUserNotificationCenter.current().setBadgeCount(0) }
        }
    }

    private static func painted() async {
        await withCheckedContinuation { continuation in shown("open.shown", since: Bench.now()) { continuation.resume() } }
    }

    private static func sleep(_ milliseconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(milliseconds * 1e6))
    }

    /// With a conversation open, has the system throw the page's process away (what it does to apps in the background)
    /// and times how long until the conversation is on screen again.
    private static func webKill(_ model: AppModel, rounds: Int) async {
        guard let thread = model.rows.first else { return }
        model.open(account: thread.accountId, threadId: thread.id)
        await painted()
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        guard model.web.webView.responds(to: kill) else {
            Bench.record("webkill.error", ms: 0, ["what": "this WebKit cannot end the page's process on request"])
            return
        }
        for _ in 0 ..< rounds {
            await sleep(400)
            let start = Bench.now()
            let startCPU = cpu()
            model.web.webView.perform(kill)
            // The page is gone once the web view has been told; it is back when it has taken the conversation again.
            var noticed = 0.0
            while model.web.caughtUp, Bench.now() - start < 5000 { await sleep(1) }
            noticed = Bench.now() - start
            while !model.web.caughtUp, Bench.now() - start < 10000 { await sleep(1) }
            let ready = Bench.now() - start
            await withCheckedContinuation { continuation in
                shown("webkill.redrawn", since: start) { continuation.resume() }
            }
            Bench.record("webkill.ready", ms: ready, ["noticed": noticed, "cpu": cpu() - startCPU])
        }
        model.closeThread()
    }
}
#endif
