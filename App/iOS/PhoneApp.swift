import AuthenticationServices
import BackgroundTasks
import MachCore
import QuickLook
import SwiftUI
import UIKit
import UserNotifications

@main
struct MachApp: App {
    @UIApplicationDelegateAdaptor(PhoneDelegate.self) private var delegate
    @State private var host = PhoneHost()
    @Environment(\.scenePhase) private var phase

    init() {
        #if DEBUG || BENCH
        Bench.once("launch.app")
        #endif
        // UIKit has not started yet. The database opens on another thread meanwhile; `PhoneHost` picks it up below.
        Bootstrap.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model = host.model {
                    PhoneRoot(model: model, host: host)
                } else {
                    Text("Mach could not open its database.")
                }
            }
            .transaction { $0.animation = nil }
            .tint(Theme.accent)
            // A palette that is always light or always dark takes the keyboard and the status bar with it.
            .preferredColorScheme(Palettes.shared.current.dark.map { $0 ? .dark : .light })
        }
        .onChange(of: phase) { _, value in
            guard let model = host.model else { return }
            #if DEBUG || BENCH
            LaunchBench.phase(value == .active ? "active" : value == .background ? "background" : "inactive") { phaseChanged(value, model) }
            #else
            phaseChanged(value, model)
            #endif
        }
        .backgroundTask(.appRefresh(PhoneHost.refreshTask)) {
            await host.model?.service.syncAll()
            await host.scheduleRefresh()
        }
    }

    private func phaseChanged(_ value: ScenePhase, _ model: AppModel) {
        if value == .active {
            model.service.startPolling(every: 20)
            PhoneDelegate.register()
            PhoneDelegate.live?.start()
        } else if value == .background {
            model.service.stopPolling()
            PhoneDelegate.live?.stop()
            host.scheduleRefresh()
        }
    }
}

/// Owns the model and the pieces of UIKit the phone app needs.
@MainActor
@Observable
final class PhoneHost: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let refreshTask = "com.ahmedkhaleel.mach.refresh"
    let model: AppModel?
    var hasClient = false
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var answer: SignInAnswer?
    @ObservationIgnored private var notifier: Notifier?

    override init() {
        #if DEBUG || BENCH
        Bench.once("launch.host")
        #endif
        if let (service, hasClient) = Bootstrap.service() {
            #if DEBUG || BENCH
            Bench.once("launch.service")
            #endif
            model = AppModel(service: service, compact: true)
            self.hasClient = hasClient
        } else {
            model = nil
        }
        super.init()
        #if DEBUG || BENCH
        Bench.once("launch.model")
        defer { LaunchBench.start(model: model) }
        #endif
        guard let model else { return }
        model.openURL = { UIApplication.shared.open($0) }
        model.dropFocus = { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        model.presentSignIn = { [weak self] url, scheme in
            guard let self else { throw CancellationError() }
            return try await self.presentSignIn(url, scheme: scheme)
        }
        model.signInFinished = { [weak self] in self?.closeSignIn() }
        Task { await Bootstrap.importSeed(into: model.service) }
        let notifier = Notifier(open: { [weak model] account, thread in
            model?.open(account: account, threadId: thread)
        }, isFrontmost: { UIApplication.shared.applicationState == .active })
        // Screenshots and recordings are launched with "-noPrompts YES" so the system alert does not cover them.
        let prompts = !UserDefaults.standard.bool(forKey: "noPrompts")
        PhoneDelegate.service = model.service
        if let relay = PushRelay.current { PhoneDelegate.live = LiveLink(relay: relay, service: model.service) }
        model.avatarsChanged = { PhoneDelegate.register() }
        model.splitChanged = { PhoneDelegate.register() }
        model.accountsChanged = {
            // Asked when an account has just signed in, not on the sign-in screen: banners mean nothing before there is mail.
            if prompts { notifier.askPermission() }
            PhoneDelegate.register()
            PhoneDelegate.live?.start()
        }
        model.accountRemoved = { PhoneDelegate.live?.unregister($0) }
        #if !STORE
        if !Bootstrap.offline { UIApplication.shared.registerForRemoteNotifications() }
        #endif
        // The number on the icon is the unread conversations in every inbox. Whenever the app runs (open, or woken
        // by a push) it sets the number itself from what it holds; in between, the relay's pushes carry it.
        if !Bootstrap.offline {
            let store = model.service.store
            Task {
                for await counts in store.observeUnreadCounts() {
                    try? await UNUserNotificationCenter.current().setBadgeCount(counts.values.reduce(0, +))
                }
            }
        }
        // With a relay the banner comes from the push itself; without one the app announces what it finds.
        // The relay only watches Gmail, so Outlook's mail is always announced from here.
        let relayed = PushRelay.current != nil
        let service = model.service
        model.service.onNewMail = { messages in
            notifier.announce(relayed ? messages.filter { service.provider(of: $0.accountId) != .google } : messages)
        }
        notifier.follow(model.service)
        PhoneDelegate.tidy = { await notifier.tidy() }
        self.notifier = notifier
        // Short of memory: let go of what can be read again from disk. (The database lets go of its own caches
        // by itself, and the system empties the web view's.)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            AvatarImages.shared.releaseMemory()
            AvatarStore.shared.releaseMemory()
        }
        #if DEBUG || BENCH
        listenForTestKeys()
        ThreadBench.runFromEnvironment(model: model)
        RestBench.runFromEnvironment(model: model)
        ListBench.runFromEnvironment(model: model)
        #endif
    }

    #if DEBUG || BENCH
    /// Lets a test script drive the app in the simulator: `xcrun simctl spawn booted notifyutil -p com.ahmedkhaleel.mach.key.j`.
    private func listenForTestKeys() {
        // Any process on the device can post these, so they are only heard with the network off (`MACH_OFFLINE=1`).
        // A data folder of its own is not enough: it can hold a real signed-in account. A build that can reach
        // real mail listens to nothing.
        guard Bootstrap.offline else { return }
        let keys = ["j", "k", "e", "s", "u", "c", "r", "a", "f", "h", "z", "x", "o", "enter", "escape", "tab", "palette", "search", "send", "type",
                    "demoLeft", "demoRight", "style1", "style2", "style3", "lists", "face", "details", "scrollDown", "fling", "themeNext", "settings", "bigface", "discard", "drafts", "discardCompose", "replyDetails", "typeLong", "back", "licenses"]
        for key in keys {
            let name = "com.ahmedkhaleel.mach.key.\(key)" as CFString
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
                guard let raw = name?.rawValue as String?, let key = raw.split(separator: ".").last.map(String.init) else { return }
                DispatchQueue.main.async { PhoneHost.testKey?(key) }
            }, name, nil, .deliverImmediately)
        }
        PhoneHost.testKey = { [weak self] key in
            guard let model = self?.model else { return }
            switch key {
            case "enter": _ = model.handle(AppModel.Key(characters: "", special: .enter))
            case "escape": _ = model.handle(AppModel.Key(characters: "", special: .escape))
            case "tab": _ = model.handle(AppModel.Key(characters: "", special: .tab))
            case "palette": model.openPalette()
            case "search":
                model.startSearch()
                model.searchText = "github"
                model.searchChanged()
            case "type":
                model.compose?.to = "someone@example.com"
                model.compose?.subject = "Hello from Mach"
                model.compose?.body = "First line.\n\nSecond paragraph with a link https://example.com"
            case "typeLong": model.compose?.body = (1...14).map { "Line \($0) of a longer reply, to see it grow." }.joined(separator: "\n")
            case "replyDetails": model.replyDetailsRequest += 1
            case "back": model.closeThread()
            case "send": model.sendCompose()
            case "lists": model.overlay = model.overlay == .lists ? nil : .lists
            case "bigface":
                Task {
                    guard let email = model.profile?.email, let data = await AvatarStore.shared.sharp(for: email, side: 1600) else { return }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("test-picture.jpg")
                    try? data.write(to: file)
                    model.previewFile = file
                }
            case "discard": model.web.webView.evaluateJavaScript("document.querySelector('.draftbar button:nth-child(3)').click()", completionHandler: nil)
            case "drafts": model.go(.drafts)
            case "discardCompose": model.closeCompose(discard: true)
            case "scrollDown":
                let scroll = model.web.webView.scrollView
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
            case "fling":
                // Archive while the page is still gliding, the way a thumb does it.
                let scroll = model.web.webView.scrollView
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { model.markDone() }
            case "themeNext":
                let index = Palette.all.firstIndex { $0 == Palettes.shared.current } ?? 0
                model.setPalette(Palette.all[(index + 1) % Palette.all.count])
            case "settings": model.overlay = model.overlay == .accounts ? nil : .accounts
            case "licenses": model.overlay = model.overlay == .licenses ? nil : .licenses
            case "details": model.web.webView.evaluateJavaScript("document.querySelector('.msg.open .to').click()", completionHandler: nil)
            case "face": model.web.webView.evaluateJavaScript("document.querySelector('.face').click()", completionHandler: nil)
            case "style1", "style2", "style3": UserDefaults.standard.set(Int(String(key.last!)) ?? 1, forKey: "swipeStyle")
            case "demoLeft", "demoRight":
                // Plays a swipe on the second row the way a finger would, for recording the designs.
                let rows = model.rows
                guard rows.count > 2 else { return }
                let direction: CGFloat = key == "demoLeft" ? -1 : 1
                let swipe = RowSwipe.shared
                swipe.begin(rows[1].id)
                let start = CACurrentMediaTime()
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        let t = min(1, (CACurrentMediaTime() - start) / 0.42)
                        let eased = 1 - pow(1 - t, 2.2)
                        swipe.drag(to: direction * 128 * eased)
                        if t >= 1 {
                            timer.invalidate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                swipe.release(velocity: direction * 300, width: UIScreen.main.bounds.width, model: model)
                            }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            default: _ = model.handle(AppModel.Key(characters: key))
            }
        }
    }

    nonisolated(unsafe) static var testKey: ((String) -> Void)?
    #endif

    /// Google's page opens in the system sign-in sheet. Google answers on an address that only this app's key
    /// leads to, the sheet closes by itself and hands that address back. Nothing listens on the network.
    private func presentSignIn(_ url: URL, scheme: String) async throws -> URL {
        // Starting over closes the sheet of the attempt before.
        closeSignIn()
        let answer = SignInAnswer()
        self.answer = answer
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                answer.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { [weak self] callback, _ in
                    Task { @MainActor in
                        guard let self, self.answer === answer else { return }
                        self.session = nil
                        self.answer = nil
                        if let callback {
                            answer.give(.success(callback))
                        } else {
                            // The sheet only ends with nothing when the person closes it, which means they gave up.
                            answer.give(.failure(CancellationError()))
                            self.model?.cancelSignIn()
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() { answer.give(.failure(AuthError.failed("Could not open the sign-in page."))) }
            }
        } onCancel: {
            Task { @MainActor in answer.give(.failure(CancellationError())) }
        }
    }

    private func closeSignIn() {
        let open = session
        session = nil
        answer?.give(.failure(CancellationError()))
        answer = nil
        open?.cancel()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Which row is being swiped sideways and how far. Only that one row watches the distance.
@MainActor
@Observable
final class RowSwipe {
    static let shared = RowSwipe()

    var id: String?
    var offset: CGFloat = 0
    /// True while the row finishes after the finger lifts.
    var settling = false
    /// The row is closing up so the rows below rise into its place.
    var collapsing = false
    /// The row's content is dissolving (style 3).
    var fading = false
    /// The finger has gone far enough that letting go will act.
    private(set) var armed = false
    /// Where each visible row sits in the list, so a touch can be matched to its row. Not observed.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    /// The list's scroll view, once the gestures have found it.
    @ObservationIgnored weak var scroll: UIScrollView?
    /// The row at the top of the screen and where it sat, while rows are being added or removed above it.
    @ObservationIgnored private var anchor: (id: String, minY: CGFloat)?

    /// The list is about to be laid out with rows added or removed (new mail, mostly). Scrolled down, the rows
    /// on screen must stay where they are: remember the top one, so `moved` can put it back.
    func holdPlace() {
        guard let scroll, id == nil else { return }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        // At the very top the list stays at the top, and new mail comes into view.
        guard top > 1, let first = frames.filter({ $0.value.maxY > top }).min(by: { $0.value.minY < $1.value.minY }) else { return }
        anchor = (first.key, first.value.minY)
        // If that row is the one that went, there is nothing to hold on to.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if self?.anchor?.id == first.key { self?.anchor = nil }
        }
    }

    /// A row was laid out somewhere new. If it is the row being held in place, the list scrolls by the same
    /// distance in the same frame, so nothing is seen to move.
    func moved(_ row: String, to frame: CGRect) {
        frames[row] = frame
        guard let held = anchor, held.id == row else { return }
        anchor = nil
        let shift = frame.minY - held.minY
        // Moving the bounds, not `contentOffset`, leaves a scroll that is still coasting alone.
        if shift != 0, let scroll { scroll.bounds.origin.y += shift }
    }

    /// Which of the three swipe designs is in use. 1 Snap, 2 Stretch, 3 Dissolve.
    static var style: Int { UserDefaults.standard.object(forKey: "swipeStyle") as? Int ?? 1 }

    func row(at point: CGPoint) -> String? {
        frames.first { $0.value.minY <= point.y && point.y < $0.value.maxY }?.key
    }

    static func action(for offset: CGFloat) -> SwipeAction {
        let key = offset < 0 ? SwipeAction.leftKey : SwipeAction.rightKey
        let fallback = offset < 0 ? SwipeAction.defaultLeft : SwipeAction.defaultRight
        return UserDefaults.standard.string(forKey: key).flatMap(SwipeAction.init(rawValue:)) ?? fallback
    }

    /// How far the finger has to travel before letting go acts.
    static let trigger: CGFloat = 72

    /// How the row finishes once let go. All three are quicker than a blink but long enough to be seen.
    static var finish: (animation: Animation, seconds: Double) {
        switch style {
        case 2: return (.spring(response: 0.2, dampingFraction: 0.9), 0.17)
        case 3: return (.easeOut(duration: 0.13), 0.14)
        default: return (.easeOut(duration: 0.12), 0.13)
        }
    }

    func begin(_ row: String) {
        id = row
        offset = 0
        armed = false
        collapsing = false
        fading = false
        Haptics.prepare()
        FullRate.keep()
    }

    func drag(to distance: CGFloat) {
        FullRate.keep()
        offset = Self.action(for: distance) == .none ? 0 : distance
        let now = abs(offset) >= Self.trigger
        if now != armed {
            armed = now
            // A small tick the moment the swipe "takes", so you can let go without looking.
            Haptics.arm(now)
        }
    }

    func cancel() {
        id = nil
        offset = 0
        armed = false
    }

    /// The finger lifted. `velocity` is sideways speed in points a second; a clear flick counts even if short.
    func release(velocity: CGFloat, width: CGFloat, model: AppModel) {
        let distance = offset
        let action = Self.action(for: distance)
        let thread = id.flatMap { id in model.rows.first { $0.id == id } }
        let flicked = abs(distance) > 28 && abs(velocity) > 650 && (velocity < 0) == (distance < 0)
        let fires = (armed || flicked) && thread != nil && action != .none
        // A flick that acts without ever crossing the line still gets its tick.
        if fires, !armed { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9) }
        // Actions that take the row out of the list close the row up; the rest let it settle back.
        let leaves = fires && (action == .done || action == .trash)
        settling = true
        FullRate.keep(for: Self.finish.seconds + 0.1)
        if leaves {
            collapsing = true
            if Self.style == 3 { fading = true } else { offset = distance < 0 ? -width : width }
        } else {
            offset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finish.seconds) { [self] in
            if fires, let thread { model.swipe(action, on: thread) }
            settling = false
            collapsing = false
            fading = false
            armed = false
            id = nil
            offset = 0
        }
    }
}

/// One list row. Sideways swipes and long presses are not handled here but by `SwipeCatcher` on the scroll view:
/// gestures attached to every row fight the list's own scrolling and make it stick.
///
/// A row is drawn again only when what it shows changes: its conversation, a tick, its own swipe. The list being
/// rebuilt around it (new mail, another row ticked) leaves it alone.
struct SwipeRow: View, Equatable {
    let model: AppModel
    let thread: MailThread
    let swipe: RowSwipe
    /// The Snoozed list shows when a conversation comes back instead of when it arrived.
    var showSnooze = false
    var tag = ""
    /// Bumped when the day changes: a row showing "a time today" has to be drawn again then.
    var day = 0
    /// The two settings a row is drawn by (see `CompactRow`), read once by the list.
    var avatars = true
    var style = 1
    /// A reply to this conversation has been started and not sent.
    var hasDraft = false

    nonisolated static func == (a: SwipeRow, b: SwipeRow) -> Bool {
        a.thread == b.thread && a.showSnooze == b.showSnooze && a.tag == b.tag && a.day == b.day && a.avatars == b.avatars && a.style == b.style && a.hasDraft == b.hasDraft
    }

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("SwipeRow")
        let _ = ThreadBench.count("SwipeRow")
        #endif
        let isSelected = model.selected.contains(thread.id)
        let active = swipe.id == thread.id
        let offset = active ? swipe.offset : 0
        let action = RowSwipe.action(for: offset)
        let armed = active && swipe.armed
        let style = RowSwipe.style
        ZStack {
            if offset != 0, action != .none {
                backdrop(offset: offset, action: action, armed: armed, style: style)
            }
            CompactRow(thread: thread, isSelected: isSelected, showSnooze: showSnooze, tag: tag, day: day, avatars: avatars, hasDraft: hasDraft, style: style,
                       copyCode: { [weak model] in model?.copyCode(thread) })
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Theme.selection : Theme.background)
                .offset(x: offset)
                .opacity(active && swipe.fading ? 0 : 1)
                .scaleEffect(active && swipe.fading ? 0.96 : 1)
        }
        .frame(height: active && swipe.collapsing ? 0 : nil, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 14) }
        .contentShape(Rectangle())
        // The row follows the finger exactly, then finishes by itself once let go.
        .transaction { transaction in
            let animate = swipe.settling && active
            transaction.animation = animate ? RowSwipe.finish.animation : nil
            transaction.disablesAnimations = !animate
        }
        .onTapGesture {
            if model.selected.isEmpty { model.show(thread) } else { model.toggleSelect(thread.id) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("rows")) } action: { swipe.moved(thread.id, to: $0) }
        .onDisappear { swipe.frames[thread.id] = nil }
    }

    /// What shows behind the row as it is pulled aside.
    @ViewBuilder
    private func backdrop(offset: CGFloat, action: SwipeAction, armed: Bool, style: Int) -> some View {
        let leading = offset > 0
        let pull = abs(offset)
        let icon = Image(systemName: action.icon).font(.system(size: Theme.pt(19), weight: .bold))
        switch style {
        case 2:
            // Stretch: a pill grows out of the edge with the pull and turns solid when it will act.
            HStack {
                if !leading { Spacer(minLength: 0) }
                icon.foregroundStyle(armed ? Theme.background : Theme.dim)
                    .frame(width: max(pull - 12, 0))
                    .frame(maxHeight: .infinity)
                    .background(armed ? Theme.accent : Theme.chip, in: RoundedRectangle(cornerRadius: 22))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 6)
                    .opacity(pull > 24 ? 1 : pull / 24)
                if leading { Spacer(minLength: 0) }
            }
        case 3:
            // Dissolve: colour floods in behind the row as it is pulled; the icon waits at the edge.
            HStack {
                if !leading { Spacer(minLength: 0) }
                icon.foregroundStyle(.white).padding(.horizontal, 26).scaleEffect(armed ? 1.15 : 0.9).opacity(min(1, pull / 40))
                if leading { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.accent.opacity(armed ? 1 : min(0.55, pull / RowSwipe.trigger * 0.55)))
        default:
            // Snap: quiet until the swipe takes, then the whole strip turns solid at once.
            HStack {
                if !leading { Spacer(minLength: 0) }
                icon.foregroundStyle(armed ? Color.white : Theme.faint).padding(.horizontal, 24).scaleEffect(armed ? 1.2 : 1)
                if leading { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(armed ? Theme.accent : Theme.card)
        }
    }
}

/// Puts the row gestures on the list's own scroll view, the way UIKit lists do it.
///
/// A sideways pan is claimed only when the finger is clearly moving sideways; otherwise it fails at once and the
/// scroll view scrolls exactly as if no swipe gesture existed. This is what keeps scrolling smooth.
struct SwipeCatcher: UIViewRepresentable {
    let model: AppModel
    let swipe: RowSwipe

    func makeCoordinator() -> Coordinator { Coordinator(model: model, swipe: swipe) }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.coordinator = context.coordinator
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {}

    /// An invisible view inside the list whose only job is to find the scroll view it ended up in.
    final class Probe: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            if let scroll = view as? UIScrollView { coordinator?.attach(to: scroll) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let model: AppModel
        private let swipe: RowSwipe
        private weak var scroll: UIScrollView?
        private let pan = UIPanGestureRecognizer()
        private let hold = UILongPressGestureRecognizer()
        private var moving: NSKeyValueObservation?

        init(model: AppModel, swipe: RowSwipe) {
            self.model = model
            self.swipe = swipe
        }

        func attach(to scrollView: UIScrollView) {
            guard scroll !== scrollView else { return }
            scroll = scrollView
            swipe.scroll = scrollView
            moving = FullRate.follow(scrollView)
            pan.addTarget(self, action: #selector(panned))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            hold.addTarget(self, action: #selector(held))
            hold.minimumPressDuration = 0.4
            hold.delegate = self
            scrollView.addGestureRecognizer(pan)
            scrollView.addGestureRecognizer(hold)
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let scroll, model.openThread == nil, model.compose == nil, model.overlay == nil, !swipe.settling else { return false }
            guard recognizer === pan else { return true }
            let velocity = pan.velocity(in: scroll)
            // Clearly sideways, and on a real row. Anything else is a scroll and is left alone.
            guard abs(velocity.x) > abs(velocity.y) * 1.6, let id = swipe.row(at: pan.location(in: scroll)), !id.hasPrefix("draft:") else { return false }
            swipe.begin(id)
            return true
        }

        /// The list waits for this to say "not sideways" (which it does within the first few points of movement)
        /// before it scrolls, so a swipe never also scrolls and a scroll never also swipes.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            recognizer === pan && other === scroll?.panGestureRecognizer
        }

        @objc private func panned() {
            guard let scroll else { return }
            switch pan.state {
            case .changed:
                swipe.drag(to: pan.translation(in: scroll).x)
            case .ended:
                swipe.release(velocity: pan.velocity(in: scroll).x, width: scroll.bounds.width, model: model)
            case .cancelled, .failed:
                swipe.cancel()
            default:
                break
            }
        }

        @objc private func held() {
            guard hold.state == .began, let scroll, let id = swipe.row(at: hold.location(in: scroll)) else { return }
            Haptics.select()
            model.toggleSelect(id)
        }
    }
}

/// The toast near the bottom of the screen, when there is one.
struct PhoneToast: View {
    let model: AppModel

    var body: some View {
        if let toast = model.toast {
            VStack {
                Spacer()
                // Over an open conversation it clears the Done button and the reply buttons under it.
                ToastView(toast: toast, undoHint: "Undo").padding(.bottom, model.openThread != nil && !model.inlineReply ? Theme.pt(92) + 30 : 70)
            }
        }
    }
}

/// What a sign-in sheet came back with. It is waited for once and answered once, whichever of the sheet, the
/// person and a second attempt gets there first.
@MainActor
private final class SignInAnswer {
    var continuation: CheckedContinuation<URL, Error>?

    func give(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

struct PhoneRoot: View {
    @Bindable var model: AppModel
    @Bindable var host: PhoneHost
    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("PhoneRoot")
        let _ = ThreadBench.count("PhoneRoot")
        #endif
        ZStack {
            Theme.background.ignoresSafeArea()
            if model.accounts.isEmpty {
                WelcomeView(model: model, hasClient: host.hasClient)
            } else {
                PhoneList(model: model)
                    .background(Theme.background)
                    .allowsHitTesting(model.openThread == nil)
                SlideHost(model: model, open: model.openThread != nil, content: threadScreen)
                    .ignoresSafeArea()
                    .allowsHitTesting(model.openThread != nil)
                // Views of their own, so a letter typed in a message, or a toast coming and going, rebuilds only them
                // and not the list and everything else on this screen.
                ComposeLayer(model: model, top: 0)
            }
            PhoneToast(model: model)
            OverlayLayer(model: model)
        }
        .quickLookPreview($model.previewFile)
    }

    // MARK: Thread

    private var threadScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                barButton("chevron.left") { model.closeThread() }
                Spacer()
                barButton("clock") { model.askSnooze() }
                barButton(model.openThread?.starred == true ? "star.fill" : "star") { model.toggleStar() }
                barButton("trash") { model.trash() }
                // Our own instant list, not the system menu, whose glass animation takes its time.
                Button(action: { model.overlay = .more }) {
                    Image(systemName: "ellipsis").font(.system(size: Theme.pt(18))).foregroundStyle(Theme.text).frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: Theme.pt(50))
            ZStack {
                ThreadWebView(web: model.web)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) { ThreadButtons(model: model) }
                    // The room the Done button may be dragged around in.
                    .overlay {
                        Color.clear.allowsHitTesting(false)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DoneSpot.space)) } action: { DoneSpot.shared.room = $0 }
                    }
                // Not over the web view itself, which runs on under the keyboard: this stops where the keyboard starts.
                InlineReplyLayer(model: model)
            }
            .coordinateSpace(.named(DoneSpot.space))
        }
        .background(Theme.background)
    }
}

/// Where the Done button has been dragged to, and the room it has to stay inside.
@MainActor @Observable
final class DoneSpot {
    static let shared = DoneSpot()
    nonisolated static let space = "thread"
    static let xKey = "doneX", yKey = "doneY"

    /// The conversation's page above the home bar, in the `space` coordinates.
    var room = CGRect.zero
    /// Where the button sits when it has never been moved.
    var home = CGRect.zero
    /// How far from `home` it has been left.
    var offset = CGSize(width: UserDefaults.standard.double(forKey: xKey), height: UserDefaults.standard.double(forKey: yKey))

    /// The nearest place to `wanted` that keeps the whole button on the page.
    func kept(_ wanted: CGSize) -> CGSize {
        guard room.width > 0, home.width > 0 else { return wanted }
        let edge: CGFloat = 8
        let x = min(max(wanted.width, room.minX + edge - home.minX), max(0, room.maxX - edge - home.maxX))
        let y = min(max(wanted.height, room.minY + edge - home.minY), max(0, room.maxY - 6 - home.maxY))
        return CGSize(width: x, height: y)
    }

    func leave(at wanted: CGSize) {
        var spot = kept(wanted)
        // Let go close to where it started, it goes back there exactly.
        if hypot(spot.width, spot.height) < 28 { spot = .zero }
        offset = spot
        UserDefaults.standard.set(spot.width, forKey: Self.xKey)
        UserDefaults.standard.set(spot.height, forKey: Self.yKey)
    }
}

/// The Done button. A tap archives; held for a moment it lifts off the page and follows the finger, and stays where
/// it is let go. The touches are read by the system's own tap and long-press recognizers (`DoneTouch`): a SwiftUI
/// drag timed by hand worked in the simulator and missed half the holds of a real thumb.
private struct DoneButton: View {
    let model: AppModel
    private let spot = DoneSpot.shared
    @State private var pressed = false
    @State private var lifted = false
    @State private var finger = CGSize.zero

    private var place: CGSize {
        guard lifted else { return spot.kept(spot.offset) }
        return spot.kept(CGSize(width: spot.offset.width + finger.width, height: spot.offset.height + finger.height))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: Theme.pt(17), weight: .bold))
            Text("Done").font(.system(size: Theme.pt(18), weight: .semibold))
        }
        .foregroundStyle(Theme.background)
        .padding(.horizontal, 24)
        .frame(height: Theme.pt(50))
        .background(Theme.accent, in: Capsule())
        .shadow(color: .black.opacity(lifted ? 0.35 : 0.25), radius: lifted ? 16 : 8, y: lifted ? 8 : 3)
        .opacity(pressed && !lifted ? 0.6 : 1)
        .scaleEffect(lifted ? 1.08 : 1)
        .overlay {
            DoneTouch(
                press: { pressed = $0 },
                tap: { model.markDone() },
                lift: {
                    finger = .zero
                    withAnimation(.spring(duration: 0.25, bounce: 0.3)) { lifted = true }
                    Haptics.select()
                },
                move: { finger = $0 },
                drop: {
                    let wanted = place
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                        spot.leave(at: wanted)
                        lifted = false
                    }
                    finger = .zero
                })
        }
        .offset(place)
        // Read outside the offset, so it is where the button would sit unmoved, wherever it is now.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DoneSpot.space)) } action: { spot.home = $0 }
        .accessibilityElement()
        .accessibilityLabel("Done")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.markDone() }
    }
}

/// The touch surface over the Done button: a tap, or a hold that turns into a drag.
private struct DoneTouch: UIViewRepresentable {
    let press: (Bool) -> Void
    let tap: () -> Void
    let lift: () -> Void
    let move: (CGSize) -> Void
    let drop: () -> Void

    final class Pad: UIView {
        var touch: DoneTouch?
        private var from = CGPoint.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.22
            // A thumb settling onto the glass moves more than the usual ten points allow.
            hold.allowableMovement = 24
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            addGestureRecognizer(hold)
            addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            Haptics.prepare()
            touch?.press(true)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touch?.press(false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touch?.press(false) }

        @objc private func tapped() { touch?.tap() }

        /// Measured on the window, since this view moves along with the button it sits on.
        @objc private func held(_ hold: UILongPressGestureRecognizer) {
            let at = hold.location(in: nil)
            switch hold.state {
            case .began:
                from = at
                touch?.lift()
            case .changed:
                touch?.move(CGSize(width: at.x - from.x, height: at.y - from.y))
            case .ended, .cancelled, .failed:
                touch?.press(false)
                touch?.drop()
            default:
                break
            }
        }
    }

    func makeUIView(context: Context) -> Pad { Pad() }
    func updateUIView(_ pad: Pad, context: Context) { pad.touch = self }
}

/// Done (archive) above Reply, Reply All and Forward, floating over the foot of an open conversation. A view of its own, and
/// gone while a reply is being written there: its Send takes their place.
private struct ThreadButtons: View {
    let model: AppModel

    var body: some View {
        if !model.inlineReply {
            VStack(alignment: .trailing, spacing: 10) {
                // The one thing you do to most mail, so it is the biggest thing here and sits under the thumb.
                // Above the reply buttons, wherever it has been dragged to.
                DoneButton(model: model).zIndex(1)
                HStack(spacing: 10) {
                    replyButton("Reply", icon: "arrowshape.turn.up.left") { model.startReply(all: false) }
                    replyButton("Reply All", icon: "arrowshape.turn.up.left.2") { model.startReply(all: true) }
                    replyButton("Forward", icon: "arrowshape.turn.up.right") { model.startForward() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    private func replyButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: Theme.pt(13)))
                Text(title).font(.system(size: Theme.pt(14), weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.pt(42))
            .background(Theme.overlay, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
    }
}

private func barButton(_ icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon).font(.system(size: Theme.pt(18))).foregroundStyle(Theme.text).frame(width: 48, height: 44)
    }
}

// MARK: List

/// Counts the things that change how a date reads in a row: a new day, a new time zone, a 12- or 24-hour clock.
@MainActor
@Observable
final class Today {
    static let shared = Today()
    private(set) var stamp = 0

    private init() {
        let names: [Notification.Name] = [.NSCalendarDayChanged, UIApplication.significantTimeChangeNotification, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Today.shared.stamp += 1 }
            }
        }
    }
}

/// The list screen. Each part is a view of its own that reads only what it shows, so a change redraws that part
/// alone: ticking a row does not rebuild the list, typing in search does not rebuild the bar under it.
struct PhoneList: View {
    let model: AppModel

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("PhoneList")
        #endif
        VStack(spacing: 0) {
            ListHeader(model: model)
            if model.offline {
                Text("Offline. Changes will sync when you are back.").font(.system(size: Theme.pt(12))).foregroundStyle(Theme.faint).padding(.bottom, 4)
            }
            ZStack(alignment: .bottomTrailing) {
                ListRows(model: model)
                ComposeButton(model: model)
            }
            SelectionBar(model: model)
        }
    }
}

/// The bar above the list: the account, the list's name and the magnifying glass, or the search field.
private struct ListHeader: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("ListHeader")
        #endif
        if model.searchActive {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search all mail", text: $model.searchText)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onChange(of: model.searchText) { _, _ in model.searchChanged() }
                // One tap changes the order: newest, oldest, best match.
                Button(action: { model.cycleSearchSort() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: Theme.pt(11), weight: .semibold))
                        Text(model.searchSortTitle).font(.system(size: Theme.pt(13), weight: .medium))
                    }
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 9)
                    .frame(height: Theme.pt(28))
                    .background(Theme.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                Button("Cancel") {
                    searchFocused = false
                    model.endSearch()
                }
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.pt(48))
        } else {
            HStack(spacing: 4) {
                Button(action: { model.overlay = UserDefaults.standard.integer(forKey: "switcherStyle") == 2 ? .lists : .accounts }) {
                    // One inbox shows its initial; all of them together show a stack of trays.
                    Group {
                        if model.isAll {
                            Image(systemName: "person.2.fill").font(.system(size: Theme.pt(11), weight: .semibold))
                        } else {
                            Text(String(model.accountId.prefix(1)).uppercased()).font(.system(size: Theme.pt(14), weight: .bold))
                        }
                    }
                    .foregroundStyle(Theme.background)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                    .frame(width: 44, height: 44)
                }
                ListTitle(model: model)
                Spacer()
                Button(action: {
                    model.startSearch()
                    searchFocused = true
                }) {
                    Image(systemName: "magnifyingglass").font(.system(size: Theme.pt(17))).foregroundStyle(Theme.dim).frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Theme.pt(48))
        }
    }
}

/// The rows themselves. Rebuilt when the list of conversations changes, and then each row decides for itself
/// whether it has anything new to draw.
private struct ListRows: View {
    let model: AppModel
    private let swipe = RowSwipe.shared
    @AppStorage(AvatarStore.settingKey) private var avatars = true
    @AppStorage("rowStyle") private var style = 1

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("ListRows")
        #endif
        let rows = model.rows
        let showSnooze = model.list == .snoozed
        let day = Today.shared.stamp
        if rows.isEmpty {
            EmptyListView(model: model)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { thread in
                        SwipeRow(model: model, thread: thread, swipe: swipe, showSnooze: showSnooze, tag: model.tag(for: thread.accountId), day: day, avatars: avatars, style: style, hasDraft: model.hasDraft(thread))
                            .equatable()
                            .onAppear {
                                if thread.id == rows.last?.id { model.loadOlder() }
                            }
                    }
                }
                .coordinateSpace(.named("rows"))
                .background(SwipeCatcher(model: model, swipe: swipe))
                .padding(.bottom, 90)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await model.service.syncAll() }
            // New mail while scrolled down: the rows on screen stay put.
            .onChange(of: rows.first?.id) { _, _ in swipe.holdPlace() }
            .onChange(of: rows.count) { _, _ in swipe.holdPlace() }
        }
    }
}

/// The round button that starts a new message. Hidden while rows are ticked or a search is open.
private struct ComposeButton: View {
    let model: AppModel

    var body: some View {
        if model.selected.isEmpty && !model.searchActive {
            Button(action: { model.startCompose() }) {
                // This symbol's pencil sticks out up and to the right, so its box is not its visual centre.
                Image(systemName: "square.and.pencil")
                    .font(.system(size: Theme.pt(20), weight: .semibold))
                    .offset(x: 1, y: -2)
                    .foregroundStyle(Theme.background)
                    .frame(width: 54, height: 54)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .padding(18)
        }
    }
}

/// What can be done to the ticked rows, under the list.
private struct SelectionBar: View {
    let model: AppModel

    var body: some View {
        if !model.selected.isEmpty {
            HStack {
                Text("\(model.selected.count)").font(.system(size: Theme.pt(15), weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 44)
                Spacer()
                barButton("checkmark") { model.markDone() }
                barButton("clock") { model.askSnooze() }
                barButton("envelope.badge") { model.toggleRead() }
                barButton("star") { model.toggleStar() }
                barButton("trash") { model.trash() }
                barButton("xmark") { model.selected = [] }
            }
            .padding(.horizontal, 8)
            .frame(height: Theme.pt(50))
            .background(Theme.card)
        }
    }
}

// MARK: - Back swipe

/// Holds the open conversation in a layer of its own and moves that layer directly.
///
/// The finger moves the layer without the rest of the screen being worked out again, and the finish after letting
/// go is drawn by the system's compositor rather than by the app, so it runs at the display's full rate even
/// while the app is busy putting the list back.
struct SlideHost<Content: View>: UIViewControllerRepresentable {
    let model: AppModel
    let open: Bool
    let content: Content

    func makeUIViewController(context: Context) -> SlideController<Content> { SlideController(content: content, model: model) }

    func updateUIViewController(_ controller: SlideController<Content>, context: Context) {
        controller.hosting.rootView = content
        controller.setOpen(open)
    }
}

final class SlideController<Content: View>: UIViewController {
    /// Lets touches through to the list wherever the conversation is not.
    private final class Clear: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }

    let hosting: UIHostingController<Content>
    private let model: AppModel
    private var open = false
    private var finishing = false
    private var armed = false
    private var laidOut: CGFloat = 0
    private let tick = UIImpactFeedbackGenerator(style: .rigid)
    private var slid: UIView { hosting.view }
    private var away: CGFloat { view.bounds.width + 20 }

    init(content: Content, model: AppModel) {
        hosting = UIHostingController(rootView: content)
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = Clear() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hosting)
        hosting.view.backgroundColor = Theme.platformBackground
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        model.web.onBackDrag = { [weak self] distance, velocity in self?.drag(distance, velocity) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Only when the screen's width changes: a slide in progress must not be cut short by an ordinary layout.
        guard view.bounds.width != laidOut else { return }
        laidOut = view.bounds.width
        if !open, !finishing { place(away) }
    }

    private func place(_ x: CGFloat) {
        slid.layer.removeAllAnimations()
        slid.transform = x == 0 ? .identity : CGAffineTransform(translationX: x, y: 0)
    }

    /// Closed, the conversation is parked off the right edge. It is never hidden, because a web view that is
    /// hidden stops painting.
    func setOpen(_ now: Bool) {
        guard now != open else { return }
        open = now
        guard !finishing else { return }
        // Opening slides in, as quick as the swipe back. Closing with the arrow is instant.
        if now, view.window != nil {
            glide(from: away, to: 0, speed: 0, longest: 0.14, then: nil)
        } else {
            place(now ? 0 : away)
        }
    }

    /// A stiff spring with no bounce that carries on at the finger's own speed, so there is no jolt on letting go.
    /// Drawn by the system's compositor, not the app.
    private func glide(from: CGFloat, to target: CGFloat, speed: CGFloat, longest: Double, then: (() -> Void)?) {
        slid.layer.removeAllAnimations()
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.fromValue = from
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = 3200
        spring.damping = 2 * sqrt(3200)
        spring.initialVelocity = max(0, speed / (target - from))
        spring.duration = min(spring.settlingDuration, longest)
        spring.preferredFrameRateRange = FullRate.range
        CATransaction.begin()
        if let then { CATransaction.setCompletionBlock(then) }
        slid.transform = target == 0 ? .identity : CGAffineTransform(translationX: target, y: 0)
        slid.layer.add(spring, forKey: "slide")
        CATransaction.commit()
    }

    private func drag(_ distance: CGFloat, _ endVelocity: CGFloat?) {
        guard open, !finishing, model.compose == nil || model.inlineReply, model.overlay == nil else { return }
        FullRate.keep()
        guard let endVelocity else {
            slid.transform = CGAffineTransform(translationX: max(0, distance), y: 0)
            // The same tick as the row swipe, the moment letting go will take you back.
            let now = distance >= model.backThreshold
            if now != armed {
                armed = now
                tick.impactOccurred(intensity: now ? 0.9 : 0.5)
                tick.prepare()
            }
            return
        }
        let leaves = distance >= model.backThreshold || (distance >= 10 && endVelocity > 200)
        let target = leaves ? away : 0
        let remaining = target - distance
        // A quick flick never crosses the line while the finger is down, so it gets its tick here: going back
        // always ticks, exactly once.
        if leaves, !armed { tick.impactOccurred(intensity: 0.9) }
        armed = false
        guard abs(remaining) > 0.5 else {
            place(target)
            if leaves { model.closeThread() }
            return
        }
        finishing = true
        glide(from: distance, to: target, speed: endVelocity, longest: 0.12) { [weak self] in
            guard let self else { return }
            self.finishing = false
            if leaves { self.model.closeThread() }
            self.place(self.open ? 0 : self.away)
        }
    }
}
