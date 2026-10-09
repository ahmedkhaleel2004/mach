import AppKit
import QuickLook
import ServiceManagement
import MachCore
import Sparkle
import SwiftUI

@main
struct MachApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Mach", id: "main") {
            RootView(delegate: delegate)
                .frame(minWidth: 760, minHeight: 480)
                .transaction { $0.animation = nil }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.checkForUpdates() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Accounts and Settings…") { delegate.model?.overlay = .accounts }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private(set) var hasClient = false
    private var monitor: Any?
    private var scrollMonitor: Any?
    private var swipeDistance: CGFloat = 0
    private var swipeIsSideways: Bool?
    private var swipeGlides = false
    private var notifier: Notifier?
    private var appearanceWatch: NSKeyValueObservation?
    private var live: LiveLink?
    /// Fetches new versions from GitHub and installs them when the app is next quit. Release builds only, so a
    /// build made while developing is never replaced under you.
    private var updater: SPUStandardUpdaterController?

    func checkForUpdates() {
        #if DEBUG || BENCH
        NSSound.beep()
        #else
        if updater == nil { updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) }
        updater?.checkForUpdates(nil)
        #endif
    }

    override init() {
        super.init()
        #if DEBUG || BENCH
        Bench.once("launch.delegate")
        #endif
        guard let (service, hasClient) = Bootstrap.service() else { return }
        self.hasClient = hasClient
        #if DEBUG || BENCH
        Bench.once("launch.service")
        #endif
        let model = AppModel(service: service, compact: false)
        #if DEBUG || BENCH
        Bench.once("launch.model")
        #endif
        model.openURL = { NSWorkspace.shared.open($0) }
        model.openSignIn = { NSWorkspace.shared.open($0) }
        model.signInFinished = { NSApp.activate(ignoringOtherApps: true) }
        model.dropFocus = { NSApp.keyWindow?.makeFirstResponder(nil) }
        model.backThreshold = 56
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        #if DEBUG || BENCH
        Bench.once("launch.didFinish")
        BenchRunner.shared.start(model: model)
        #endif
        NSWindow.allowsAutomaticWindowTabbing = false
        #if !DEBUG && !BENCH
        // Starts the hourly check for a newer version. Not in offline runs.
        if !Bootstrap.offline {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        #endif
        // The Dock icon follows light and dark mode while the app runs: dark blocks on white, or white on black.
        appearanceWatch = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            MainActor.assumeIsolated {
                let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                app.applicationIconImage = NSImage(named: dark ? "DockDark" : "DockLight")
            }
        }
        // The web view for conversations is made as soon as the first list of mail has been handed to the screen:
        // at the end of the first turn of the run loop that finds the window showing. If the app starts hidden
        // (at login), it is made after two seconds instead, so the first conversation never waits for it.
        var firstFrame: CFRunLoopObserver?
        firstFrame = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max - 3) { _, _ in
            MainActor.assumeIsolated {
                guard NSApp.windows.contains(where: { $0.isVisible && $0.frame.width > 700 }) else { return }
                if let firstFrame { CFRunLoopRemoveObserver(CFRunLoopGetMain(), firstFrame, .commonModes) }
                DispatchQueue.main.async { model.warmWeb() }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), firstFrame, .commonModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.warmWeb() }
        let notifier = Notifier(open: { [weak model] account, thread in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.frame.width > 700 }?.makeKeyAndOrderFront(nil)
            model?.open(account: account, threadId: thread)
        }, isFrontmost: { NSApp.isActive })
        notifier.askPermission()
        model.service.onNewMail = { notifier.announce($0) }
        self.notifier = notifier
        // Mail can only be announced while the app is running, so it starts with the Mac (once; it can be
        // switched off in the app's settings or in System Settings > General > Login Items and stays off).
        // Counted as done only once it has taken, so a first try that failed is made again on the next launch.
        if !UserDefaults.standard.bool(forKey: "loginItemSet"), Bundle.main.bundlePath.hasPrefix("/Applications/") {
            try? SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .enabled { UserDefaults.standard.set(true, forKey: "loginItemSet") }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            return self.handle(event, model: model) ? nil : event
        }
        // Two fingers swiped to the right on an open conversation go back, the way Safari does.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let model = self.model else { return event }
            return self.handleScroll(event, model: model) ? nil : event
        }
        Task {
            await Bootstrap.importSeed(into: model.service)
            model.service.startPolling(every: 15)
            // The relay tells this Mac the instant mail arrives; the 15 second check stays as a safety net.
            if let relay = PushRelay.current {
                let link = LiveLink(relay: relay, service: model.service)
                link.register()
                link.start()
                self.live = link
                model.accountsChanged = {
                    link.register()
                    link.start()
                }
                model.accountRemoved = { link.unregister($0) }
                model.splitChanged = { link.register() }
            }
        }
        #if DEBUG || BENCH
        // Lets a test script press keys in the app without taking the keyboard: `machkey j`, `machkey special:enter`.
        // A benchmark build listens on its own channel (`MACH_DEBUG_CHANNEL`) so its keys can never reach another copy.
        let channel = ProcessInfo.processInfo.environment["MACH_DEBUG_CHANNEL"] ?? "com.ahmedkhaleel.mach.debug"
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(channel), object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                if LeanBench.handle(command, model: model) { return }
                // Two benchmarks share the "bench:" prefix: the conversation one owns these scenario names, the window one the rest.
                let conversation: Set<Substring> = ["opens", "unread", "rapid", "memory", "paint", "verify", "offline", "all"]
                if command.hasPrefix("bench:"), !conversation.contains(command.dropFirst(6).prefix { $0 != ":" }) {
                    return BenchRunner.shared.enqueue([String(command.dropFirst(6))])
                }
                let specials: [String: AppModel.Key.Special] = ["enter": .enter, "escape": .escape, "up": .up, "down": .down, "tab": .tab, "space": .space, "delete": .delete]
                if command.hasPrefix("special:"), let special = specials[String(command.dropFirst(8))] {
                    _ = model.handle(AppModel.Key(characters: "", special: special))
                } else if command.hasPrefix("cmd:") {
                    _ = model.handle(AppModel.Key(characters: String(command.dropFirst(4)), command: true))
                } else if command.hasPrefix("search:") {
                    model.startSearch()
                    model.searchText = String(command.dropFirst(7))
                    model.searchChanged()
                } else if command == "lists" {
                    model.overlay = model.overlay == .lists ? nil : .lists
                } else if command == "front" {
                    // Shows the window without activating the app, so the keyboard stays where it was.
                    NSApp.windows.first { $0.frame.width > 700 }?.orderFrontRegardless()
                } else if command == "responder" {
                    // Which control would get the next key press: how a test checks that a field is ready to type in.
                    let window = NSApp.windows.first { $0.frame.width > 700 }
                    let name = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                    FileHandle.standardError.write(Data("responder: \(name) key: \(window?.isKeyWindow == true ? 1 : 0)\n".utf8))
                } else if command == "focusweb" {
                    // As if the conversation had been clicked: it holds the keyboard until something else asks for it.
                    NSApp.windows.first { $0.frame.width > 700 }?.makeFirstResponder(model.web.webView)
                } else if command == "back" {
                    NSApp.windows.first { $0.frame.width > 700 }?.orderBack(nil)
                } else if command.hasPrefix("js:") {
                    model.web.webView.evaluateJavaScript(String(command.dropFirst(3))) { value, error in
                        NSLog("js result: %@ %@", String(describing: value), String(describing: error))
                    }
                    NSLog("web frame: %@ messages: %d open: %@", NSStringFromRect(model.web.webView.frame), model.messages.count, model.openThread?.id ?? "none")
                } else if command.hasPrefix("bench:") {
                    ThreadBench.run(String(command.dropFirst(6)), model: model)
                } else if command.hasPrefix("to:") {
                    model.compose?.to = String(command.dropFirst(3))
                } else if command.hasPrefix("subject:") {
                    model.compose?.subject = String(command.dropFirst(8))
                } else if command.hasPrefix("attach:") {
                    model.compose?.attachmentPaths.append(String(command.dropFirst(7)))
                } else if command == "replydetails" {
                    model.replyDetailsRequest += 1
                } else if command == "discardcompose" {
                    model.closeCompose(discard: true)
                } else if command == "send" {
                    model.sendCompose()
                } else if command.hasPrefix("snooze:") {
                    model.snooze(until: Date().addingTimeInterval(Double(command.dropFirst(7)) ?? 60))
                } else if command == "seed" {
                    Task { await Bootstrap.importSeed(into: model.service) }
                } else if command.hasPrefix("account:") {
                    model.switchAccount(String(command.dropFirst(8)))
                } else if command.hasPrefix("type:") {
                    model.compose?.body += String(command.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\n")
                } else {
                    _ = model.handle(AppModel.Key(characters: command))
                }
            }
        }
        LeanBench.launched()
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.service.startPolling(every: 15)
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.service.startPolling(every: 90)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Returns true when the event was a sideways swipe that this consumed.
    private func handleScroll(_ event: NSEvent, model: AppModel) -> Bool {
        // The glide after the fingers lift belongs to the back swipe that was just handled, all of it: by then the
        // list is under the pointer, and any part of the glide let through would scroll it.
        if swipeGlides {
            if event.momentumPhase == [] {
                swipeGlides = false
            } else {
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled { swipeGlides = false }
                return true
            }
        }
        guard model.openThread != nil || swipeIsSideways == true, model.compose == nil || model.inlineReply, model.overlay == nil,
              event.hasPreciseScrollingDeltas else { return false }
        let width = event.window?.frame.width ?? 1200
        if event.phase == .began {
            swipeDistance = 0
            swipeIsSideways = nil
        }
        if event.phase == .changed || event.phase == .began {
            if swipeIsSideways == nil, abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 6 {
                swipeIsSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 3
            }
            guard swipeIsSideways == true else { return false }
            swipeDistance += event.scrollingDeltaX
            // The conversation leaves the moment the swipe has gone far enough or is plainly a flick, without
            // waiting for the fingers to lift: waiting is what made going back feel slow.
            let leaves = swipeDistance >= model.backThreshold || (swipeDistance >= 12 && event.scrollingDeltaX >= 14)
            model.dragBack(swipeDistance, endVelocity: leaves ? 1000 : nil, width: width)
            return true
        }
        if event.phase == .ended || event.phase == .cancelled {
            guard swipeIsSideways == true else { return false }
            swipeIsSideways = nil
            swipeGlides = true
            model.dragBack(event.phase == .cancelled ? 0 : swipeDistance, endVelocity: 0, width: width)
            return true
        }
        return false
    }

    private func handle(_ event: NSEvent, model: AppModel) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option) { return false }
        var key = AppModel.Key(characters: event.characters ?? "", command: flags.contains(.command), shift: flags.contains(.shift), control: flags.contains(.control))
        if flags.contains(.control) || flags.contains(.command) { key.characters = event.charactersIgnoringModifiers ?? "" }
        switch event.keyCode {
        case 126: key.special = .up
        case 125: key.special = .down
        case 36, 76: key.special = .enter
        case 53: key.special = .escape
        case 51, 117: key.special = .delete
        case 48: key.special = .tab
        case 49: key.special = .space
        case 116: key.special = .pageUp
        case 121: key.special = .pageDown
        case 115: key.special = .home
        case 119: key.special = .end
        default: break
        }
        // Only the mail window. A file picker or any other panel keeps its own keys.
        guard let window = event.window, !(window is NSPanel), window.sheetParent == nil, window.attachedSheet == nil, window.frame.width > 700 else { return false }
        let responder = window.firstResponder
        let typing = responder is NSTextView || responder is NSTextField
        if typing { return model.handleWhileTyping(key) }
        // Leave the system's own shortcuts alone (quit, close, copy, hide and so on).
        if key.command, ["q", "w", "c", "h", "m", "v", "x", "`"].contains(key.characters.lowercased()) { return false }
        return model.handle(key)
    }
}

struct RootView: View {
    let delegate: AppDelegate

    var body: some View {
        if let model = delegate.model {
            if model.accounts.isEmpty {
                ZStack {
                    WelcomeView(model: model, hasClient: delegate.hasClient)
                    toast(model)
                }
            } else {
                MainView(model: model)
            }
        } else {
            Text("Mach could not open its database.").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func toast(_ model: AppModel) -> some View {
        if let toast = model.toast {
            VStack {
                Spacer()
                ToastView(toast: toast, undoHint: "Undo").padding(.bottom, 24)
            }
        }
    }
}

/// Which inbox is on screen, and the way into accounts and settings. Meant to be found without being told.
struct AccountButton: View {
    let model: AppModel
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: model.isAll ? "person.2.fill" : "person.crop.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text(model.accountTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            if let count = model.accounts.count > 1 ? model.accounts.count : nil, model.isAll {
                Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(hovered ? Theme.selection : Theme.chip, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .pointerStyle(.link)
        .onTapGesture { model.overlay = .accounts }
        .help("Accounts and settings (⌘,)")
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("MainView")
        #endif
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ThreadList(model: model)
            }
            .background(Theme.background)
            .allowsHitTesting(model.openThread == nil)

            GeometryReader { geometry in
                ThreadSlide(model: model, width: geometry.size.width) {
                    VStack(spacing: 0) {
                        threadBar
                        // The web view is made just after the first frame (see `AppModel.web`); until then its place is empty.
                        if model.webWarm {
                            ThreadWebView(web: model.web)
                                .overlay { InlineReplyLayer(model: model) }
                        } else {
                            Color.clear
                        }
                    }
                    .background(Theme.background)
                }
            }

            ComposeLayer(model: model)
            if let toast = model.toast {
                VStack {
                    Spacer()
                    ToastView(toast: toast, undoHint: "Z to undo").padding(.bottom, 24)
                }
            }
            OverlayLayer(model: model)
        }
        .ignoresSafeArea(edges: .top)
        // Attachments open in Quick Look: instant, works for every kind of file, and never runs anything.
        .quickLookPreview($model.previewFile)
        .onChange(of: model.unread) { _, counts in
            let total = counts.values.reduce(0, +)
            NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            if model.searchActive {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                TextField("Search all mail", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onChange(of: model.searchText) { _, _ in model.searchChanged() }
            } else {
                ListTitle(model: model)
            }
            Spacer()
            if model.searchActive {
                // One click changes the order: newest, oldest, best match.
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
                    Text(model.searchSortTitle).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.dim)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.chip, in: Capsule())
                .contentShape(Capsule())
                .onTapGesture { model.cycleSearchSort() }
            }
            if !model.selected.isEmpty {
                Text("\(model.selected.count) selected").font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            if model.offline {
                Text("Offline").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            AccountButton(model: model)
            Text("⌘K")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { model.openPalette() }
        }
        .padding(.leading, 26)
        .padding(.trailing, 20)
        .padding(.top, 28)
        .frame(height: 76)
        .onChange(of: model.searchFocusRequest) { _, _ in DispatchQueue.main.async { searchFocused = true } }
    }

    private var threadBar: some View {
        HStack(spacing: 16) {
            Text("Esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { model.closeThread() }
            Spacer()
            ForEach(["E Archive", "B Snooze", "R Reply", "A Reply all", "F Forward"], id: \.self) { hint in
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .frame(height: 38)
        .padding(.top, 4)
    }
}

/// The list of conversations. A view of its own, so a change in the list redraws nothing around it, and each row
/// watches the cursor and the ticks for itself, so moving the cursor redraws the two rows it leaves and lands on.
struct ThreadList: View {
    let model: AppModel
    @State private var scroller = ListScroller()

    var body: some View {
        let rows = model.rows
        let showSnooze = model.list == .snoozed
        let today = model.today
        Group {
            if rows.isEmpty {
                EmptyListView(model: model)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { thread in
                            ThreadListRow(model: model, thread: thread, showSnooze: showSnooze, tag: model.tag(for: thread.accountId), today: today)
                                .id(thread.id)
                                .onTapGesture { model.show(thread) }
                        }
                    }
                    .padding(.bottom, 40)
                    .background(ListScroller.Finder(scroller: scroller, model: model))
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// Keeps the row under the cursor in view by moving the list's own scroll view.
///
/// Every row is the same height, so where a row sits is known without asking SwiftUI. A row that is already
/// wholly in view needs nothing, which is the usual case; asking SwiftUI to scroll to a row costs several times
/// more than moving the highlight, even when there is nowhere to scroll. It watches the cursor itself, so the
/// list is not looked at again on every move, and no move is missed when several land in one frame.
@MainActor
final class ListScroller {
    /// The height `WideRow` gives itself.
    static let rowHeight: CGFloat = 38
    private weak var probe: NSView?
    private var following = false
    private var shown: String?

    private func follow(_ model: AppModel) {
        withObservationTracking {
            _ = model.cursorId
        } onChange: { [weak self, weak model] in
            // Called just before the change. Look once it has been made, in the same frame.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let model else { return }
                    self.follow(model)
                    guard model.cursorId != self.shown else { return }
                    self.shown = model.cursorId
                    if let index = model.cursorIndex { self.reveal(row: index) }
                }
            }
        }
    }

    /// Scrolls just far enough to show the whole row, and not at all if it already shows.
    private func reveal(row index: Int) {
        guard let scroll = probe?.enclosingScrollView, let content = scroll.documentView else { return }
        let seen = scroll.documentVisibleRect
        let top = CGFloat(index) * Self.rowHeight
        let bottom = top + Self.rowHeight
        if top >= seen.minY, bottom <= seen.maxY { return }
        let wanted = top < seen.minY ? top : bottom - seen.height
        let furthest = max(0, content.frame.height - seen.height)
        scroll.contentView.scroll(to: NSPoint(x: seen.minX, y: min(max(wanted, 0), furthest)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// An empty view behind the rows, there only to find the scroll view they are in.
    struct Finder: NSViewRepresentable {
        let scroller: ListScroller
        let model: AppModel

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            scroller.probe = view
            if !scroller.following {
                scroller.following = true
                scroller.shown = model.cursorId
                scroller.follow(model)
            }
            return view
        }

        func updateNSView(_ view: NSView, context: Context) { scroller.probe = view }
    }
}

private struct ThreadListRow: View {
    let model: AppModel
    let thread: MailThread
    let showSnooze: Bool
    let tag: String
    let today: Int

    var body: some View {
        WideRow(thread: thread, isCursor: model.cursorId == thread.id, isSelected: model.selected.contains(thread.id), showSnooze: showSnooze, tag: tag, today: today, hasDraft: model.hasDraft(thread))
            .equatable()
    }
}
