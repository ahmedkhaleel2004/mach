import MachCore
import Observation
import SwiftUI

struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
}

enum Overlay: Equatable {
    case palette
    case snooze
    case help
    case accounts
    case more
    case lists
    case profile
}

/// What a swipe on a row does on iPhone. Each direction has its own setting.
enum SwipeAction: String, CaseIterable {
    case done, read, snooze, trash, star, none

    static let leftKey = "swipeLeft"
    static let rightKey = "swipeRight"
    static let defaultLeft = SwipeAction.done
    static let defaultRight = SwipeAction.read

    var title: String {
        switch self {
        case .done: return "Mark Done"
        case .read: return "Read / Unread"
        case .snooze: return "Snooze"
        case .trash: return "Trash"
        case .star: return "Star"
        case .none: return "Nothing"
        }
    }

    var icon: String {
        switch self {
        case .done: return "checkmark"
        case .read: return "envelope.badge"
        case .snooze: return "clock"
        case .trash: return "trash"
        case .star: return "star"
        case .none: return "nosign"
        }
    }

    var next: SwipeAction {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct Command: Identifiable {
    var title: String
    var keys: String = ""
    var action: () -> Void
    var id: String { title }
}

struct SnoozeOption: Identifiable {
    var title: String
    var date: Date
    var id: String { title }

    static func standard(now: Date = Date()) -> [SnoozeOption] {
        let calendar = Calendar.current
        func at(_ hour: Int, daysFromToday days: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        let weekday = calendar.component(.weekday, from: now)
        let toSaturday = (7 - weekday + 7) % 7 == 0 ? 7 : (7 - weekday + 7) % 7
        let toMonday = (2 - weekday + 7) % 7 == 0 ? 7 : (2 - weekday + 7) % 7
        var options = [SnoozeOption(title: "In 1 hour", date: now.addingTimeInterval(3600))]
        if calendar.component(.hour, from: now) < 15 { options.append(SnoozeOption(title: "This evening", date: at(18, daysFromToday: 0))) }
        options.append(SnoozeOption(title: "Tomorrow", date: at(8, daysFromToday: 1)))
        options.append(SnoozeOption(title: "This weekend", date: at(8, daysFromToday: toSaturday)))
        options.append(SnoozeOption(title: "Next week", date: at(8, daysFromToday: toMonday)))
        options.append(SnoozeOption(title: "In a month", date: at(8, daysFromToday: 30)))
        return options
    }
}

/// Runs searches of the mail on the device off the main thread, one at a time, the newest text winning.
final class LocalSearch: @unchecked Sendable {
    /// The person is waiting on this as they type, so it runs with the main thread's priority.
    private let queue = DispatchQueue(label: "mach.search", qos: .userInteractive)
    private let lock = NSLock()
    private var newest = 0
    private var waiting = 0
    /// Searches numbered up to this were cancelled: their rows are dropped.
    private var cancelled = 0
    /// The latest finished search's rows, until someone takes them.
    private var finished: (id: Int, rows: [MailThread])?

    /// Starts a search. Returns its rows if they were ready within `patience` seconds. Otherwise returns nil and
    /// hands the rows to `later` on the main thread when they are. A search that is overtaken before its turn
    /// comes is never run; one that is overtaken while running still hands over its rows, so results keep
    /// appearing while typing goes on.
    func run(patience: TimeInterval, search: @escaping @Sendable () -> [MailThread], later: @escaping @MainActor ([MailThread]) -> Void) -> [MailThread]? {
        let (id, busy): (Int, Bool) = lock.withLock {
            newest += 1
            waiting += 1
            return (newest, waiting > 1)
        }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            // Overtaken while it waited its turn: never run.
            let rows = self.lock.withLock({ self.newest == id }) ? search() : nil
            self.lock.withLock {
                self.waiting -= 1
                if let rows, id > self.cancelled { self.finished = (id, rows) }
            }
            done.signal()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let rows = self.take(id) { later(rows) }
                }
            }
        }
        // With an earlier search still running this one cannot be quick, so there is nothing to wait for.
        if !busy, done.wait(timeout: .now() + patience) == .success { return take(id) }
        return nil
    }

    private func take(_ id: Int) -> [MailThread]? {
        lock.withLock {
            guard let ready = finished, ready.id == id else { return nil }
            finished = nil
            return ready.rows
        }
    }

    /// Waits for the newest search to finish and returns its rows, if nobody has taken them yet.
    func wait() -> [MailThread]? {
        guard lock.withLock({ waiting > 0 || finished != nil }) else { return nil }
        queue.sync {}
        return lock.withLock {
            let rows = finished?.rows
            finished = nil
            return rows
        }
    }

    /// Forgets whatever is running: its rows will not be delivered.
    func cancel() {
        lock.withLock {
            newest += 1
            cancelled = newest
            finished = nil
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let service: MailService
    /// The warm web view for conversations. Made on first use: creating it takes about 50 ms of the main thread,
    /// so the Mac window draws its first list of mail before asking for it (`warmWeb`).
    @ObservationIgnored private(set) lazy var web: ThreadWeb = makeWeb()
    /// True once the web view exists, so the window can put it in place.
    private(set) var webWarm = false

    var accounts: [Account] = []
    /// The account on screen. Empty means every inbox together, which is the default.
    var accountId = ""
    var list = MailList.inbox
    /// Off by default: one inbox with everything in it. On: people in Inbox, the rest in Other.
    private(set) var splitInbox = UserDefaults.standard.bool(forKey: MailList.splitKey)
    /// The list the app starts on and Esc returns to.
    var home: MailList { splitInbox ? .main : .inbox }
    var inboxTabs: [MailList] { splitInbox ? [.main, .other] : [] }
    /// Called when the split changes, so the push relay can match which mail gets a banner.
    var splitChanged: () -> Void = {}

    func setSplit(_ on: Bool) {
        splitInbox = on
        UserDefaults.standard.set(on, forKey: MailList.splitKey)
        // With one inbox every new mail is announced; with the split, only mail from people.
        service.announceBulk = !on
        splitChanged()
        if list.isInbox {
            list = home
            reloadList()
        }
        show(Toast(text: on ? "Inbox split into Inbox and Other." : "One inbox for everything."))
    }

    /// Tab: the other half of a split inbox. Does nothing with a single inbox.
    func switchSplit() {
        guard splitInbox else { return }
        go(list == .main ? .other : .main)
    }
    var userLabels: [MailLabel] = []
    private(set) var threads: [MailThread] = []
    private(set) var localDrafts: [Draft] = []
    var cursorId: String?
    var selected = Set<String>()
    /// Which day it is. Rows show a time for today's mail and a date for older mail, so they are drawn again when this changes.
    private(set) var today = AppModel.dayStamp()

    private static func dayStamp() -> Int { Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) }

    private func refreshDay() {
        let now = Self.dayStamp()
        if now != today { today = now }
    }
    private(set) var openThread: MailThread?
    private(set) var messages: [Message] = []

    var searchActive = false
    var searchText = ""
    private(set) var searchResults: [MailThread] = []
    /// How search results are ordered. Best match first unless changed with the button beside the search field.
    private(set) var searchSort: Store.SearchOrder = .relevant
    /// Conversations Gmail found that this device did not already have, and where each account's next page starts.
    private var searchExtra: [MailThread] = []
    private var searchNext: [String: String] = [:]
    private var searchingMore = false

    var compose: Draft?
    var overlay: Overlay?
    /// Whose picture is being shown up close.
    var profile: EmailAddress?
    var paletteQuery = ""
    var paletteIndex = 0
    /// Bumped to ask the search field to take the keyboard.
    var searchFocusRequest = 0
    var toast: Toast?
    var unread: [String: Int] = [:]
    var offline = false
    var signingIn = false
    var loaded = false
    /// How far the open conversation has been dragged to the right by a back swipe.
    var backDrag: CGFloat = 0
    /// True for the instant the conversation slides away.
    var sliding = false
    /// How far a back swipe must have travelled when it is let go. Each platform sets its own.
    var backThreshold: CGFloat = 48

    /// Set by each platform: how to show a web page, a sign-in page and a downloaded file.
    var openURL: (URL) -> Void = { _ in }
    var openSignIn: (URL) -> Void = { _ in }
    var signInFinished: () -> Void = {}
    /// The attachment being looked at in Quick Look, if any.
    var previewFile: URL?
    /// Lets the platform tell the push relay about accounts coming and going.
    var accountsChanged: () -> Void = {}
    var accountRemoved: (String) -> Void = { _ in }
    /// Called when profile pictures are switched on or off, so the phone can tell the push relay.
    var avatarsChanged: () -> Void = {}
    /// Takes the keyboard away from whatever text field has it.
    var dropFocus: () -> Void = {}
    let compact: Bool

    private var limit = 300
    private var listTask: Task<Void, Never>?
    private var draftsTask: Task<Void, Never>?
    private var messagesTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Everything that writes a draft or puts a message in the outbox runs here, in the order it was asked for,
    /// so typing and ⌘Enter never wait for the database. Anything that reads drafts waits for it first.
    private let draftWrites = DispatchQueue(label: "mach.drafts", qos: .userInitiated)
    private var signInTask: Task<Void, Never>?
    private var loadingMore = false
    /// True between opening a list and the whole of it arriving (see `observeList`).
    private var listPartial = false
    /// True from asking for a longer list until it arrives.
    private var growing = false
    private var suppressed: [String: Date] = [:]
    private var lastCursorIndex = 0
    private var renderedSignature = ""
    /// The bodies (HTML, plain text) of the conversation the page was last sent, by message id.
    private var sentBodies: [String: [String?]] = [:]
    private var replyDraftsTask: Task<Void, Never>?
    /// Unsent messages written in this app. Each is also saved to Gmail, whose copy is not shown beside it.
    private(set) var replyDrafts: [Draft] = []

    /// Whether a conversation has a reply waiting to be finished, written here or on Gmail.
    func hasDraft(_ thread: MailThread) -> Bool {
        guard list != .drafts else { return false }
        return thread.labelIds.contains(SystemLabel.draft) || replyDrafts.contains { $0.accountId == thread.accountId && ($0.threadId == thread.id || $0.remoteThreadId == thread.id) }
    }

    /// The unsent reply to show at the end of the open conversation. Not while it is open for writing.
    private var openReplyDraft: Draft? {
        guard let thread = openThread else { return nil }
        return replyDrafts.first { $0.accountId == thread.accountId && ($0.threadId == thread.id || $0.remoteThreadId == thread.id) && $0.id != compose?.id }
    }
    private var undoStack: [() -> Void] = []
    private var pendingGo: Date?
    private let localSearch = LocalSearch()

    init(service: MailService, compact: Bool) {
        self.service = service
        self.compact = compact
        AvatarStore.googleLookup = { email in await service.googlePhotoURL(for: email) }
        // The phone makes it here and now, as it always has.
        if compact { _ = web }
        // Brand logos are drawn by the conversation's web view, which is made on first need.
        AvatarStore.drawLogo = { [weak self] svg in await self?.web.drawLogo(svg) }
        // Replies started here and not sent yet, kept in view so their conversations can show them.
        replyDrafts = (try? service.store.drafts(account: nil)) ?? []
        replyDraftsTask = Task { [weak self] in
            for await value in service.store.observeDrafts(account: nil) {
                guard let self else { return }
                self.replyDrafts = value
                if self.openThread != nil { self.render(keepScroll: true) }
            }
        }
        service.onReport = { [weak self] _, message in
            Task { @MainActor in self?.report(message) }
        }
        accounts = (try? service.store.accounts()) ?? []
        #if DEBUG || BENCH
        Bench.once("launch.model.accounts")
        #endif
        list = home
        service.announceBulk = !splitInbox
        accountId = UserDefaults.standard.string(forKey: "scope").flatMap { saved in accounts.first { $0.id == saved }?.id } ?? ""
        loaded = true
        #if DEBUG || BENCH
        Bench.once("launch.model.accounts")
        #endif
        reloadList()
        #if DEBUG || BENCH
        Bench.once("launch.model.list")
        #endif
        Task { [weak self] in
            for await value in service.store.observeAccounts() {
                guard let self else { return }
                let first = self.accounts.isEmpty && !value.isEmpty
                self.accounts = value
                if !self.isAll, !value.contains(where: { $0.id == self.accountId }) {
                    self.switchAccount("")
                } else if first {
                    self.reloadList()
                }
            }
        }
        Task { [weak self] in
            for await value in service.store.observeUnreadCounts() { self?.unread = value }
        }
        #if os(macOS)
        // Quitting waits for a draft or an outgoing message that is still on its way into the database.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [draftWrites] _ in
            draftWrites.sync {}
        }
        #endif
    }

    private func makeWeb() -> ThreadWeb {
        let web = ThreadWeb(service: service)
        web.onEvent = { [weak self] event in self?.handle(event) }
        web.onReload = { [weak self] in
            // The system threw the page away (it does this to apps in the background). Draw the conversation again.
            self?.renderedSignature = ""
            self?.render(keepScroll: false)
        }
        // The size chosen in settings applies from the first conversation on.
        if !compact { web.setZoom(UserDefaults.standard.object(forKey: Theme.scaleKey) as? Double ?? Theme.defaultScale) }
        webWarm = true
        #if DEBUG || BENCH
        Bench.once("launch.web")
        #endif
        return web
    }

    /// Makes the web view now if nothing has needed it yet. Called right after the first frame.
    func warmWeb() {
        if !webWarm { _ = web }
    }

    // MARK: - What is on screen

    var isAll: Bool { accountId.isEmpty }
    /// nil when every inbox is shown.
    private var scope: String? { isAll ? nil : accountId }
    var account: Account? { accounts.first { $0.id == accountId } }
    var accountTitle: String { isAll ? (accounts.count > 1 ? "All Inboxes" : accounts.first?.id ?? "") : accountId }

    /// The account new mail is written from: the one on screen, else the one last written from.
    private var writingAccount: Account? {
        account ?? accounts.first { $0.id == UserDefaults.standard.string(forKey: "writeFrom") } ?? accounts.first
    }

    /// A short tag that tells accounts apart in the combined list, such as "gitdiagram" or "gmail".
    func tag(for account: String) -> String {
        guard isAll, accounts.count > 1 else { return "" }
        let domain = account.split(separator: "@").last.map(String.init) ?? account
        return domain.split(separator: ".").first.map(String.init) ?? domain
    }

    var rows: [MailThread] {
        if searchActive { return searchResults }
        if list == .drafts {
            // A draft kept here is also on Gmail; it is listed once, as the version written here.
            let mine = Set(localDrafts.flatMap { draft in [draft.threadId, draft.remoteThreadId].compactMap { $0 }.map { draft.accountId + "/" + $0 } })
            return draftRows + threads.filter { !mine.contains($0.accountId + "/" + $0.id) }
        }
        return threads
    }

    private var draftRows: [MailThread] {
        localDrafts.map { draft in
            let people = EmailAddress.parseList(draft.to).map(\.displayName)
            return MailThread(accountId: draft.accountId, id: "draft:" + draft.id, subject: draft.subject.isEmpty ? "(no subject)" : draft.subject,
                              snippet: draft.body.replacingOccurrences(of: "\n", with: " "), lastDate: draft.updatedAt,
                              participants: people.isEmpty ? ["Draft"] : people, messageCount: 1, unread: false, starred: false,
                              hasAttachments: !draft.attachmentPaths.isEmpty, labelIds: [SystemLabel.draft], snoozedUntil: nil)
        }
    }

    var cursorIndex: Int? { cursorId.flatMap { id in rows.firstIndex { $0.id == id } } }

    var allLists: [MailList] {
        [home] + (splitInbox ? [.other] : []) + MailList.standard + userLabels.filter { $0.type == "user" }.map { MailList(label: $0.id, title: $0.name) }
    }

    var title: String { searchActive ? "Search" : list.title }

    func switchAccount(_ id: String) {
        guard id != accountId else { return }
        accountId = id
        UserDefaults.standard.set(id.isEmpty ? "all" : id, forKey: "scope")
        closeThread()
        searchActive = false
        list = home
        reloadList()
    }

    /// 0 is every inbox together; 1, 2, 3 are the accounts in order.
    func switchAccount(index: Int) {
        if index == 0 {
            switchAccount("")
        } else if accounts.indices.contains(index - 1) {
            switchAccount(accounts[index - 1].id)
        }
    }

    func go(_ target: MailList) {
        overlay = nil
        closeThread()
        searchActive = false
        searchText = ""
        guard target != list else { return }
        list = target
        reloadList()
    }

    private func reloadList() {
        limit = 300
        selected = []
        cursorId = nil
        lastCursorIndex = 0
        suppressed = [:]
        userLabels = isAll ? [] : ((try? service.store.labels(account: accountId)) ?? [])
        observeList(quick: true)
    }

    /// More rows than a tall window shows. A list that has just been opened reads this many before it is drawn.
    private static let screenful = 80

    /// `quick`: the list is being opened at its top, so only a screenful is read here and now; the rest arrives a
    /// moment later from the database's own thread. Reading and decoding all of it first is most of what opening
    /// a list costs.
    private func observeList(quick: Bool = false) {
        listTask?.cancel()
        draftsTask?.cancel()
        localDrafts = []
        guard !accounts.isEmpty else {
            threads = []
            return
        }
        let account = scope
        let label = list.label
        let count = limit
        // Read once right here so the list is on screen in the same frame.
        let first = quick ? min(count, Self.screenful) : count
        let read = (try? service.store.threads(account: account, label: label, limit: first)) ?? []
        // Fewer rows than were asked for means that is all there is.
        listPartial = first < count && read.count == first
        applyThreads(read)
        let service = self.service
        watchThreads()
        if list == .drafts {
            localDrafts = (try? service.store.drafts(account: account)) ?? []
            draftsTask = Task { [weak self] in
                for await value in service.store.observeDrafts(account: account) {
                    guard let self, !Task.isCancelled else { return }
                    self.localDrafts = value
                    self.fixCursor()
                }
            }
        }
        if threads.count < 30, let serverLabel = list.serverLabel, !list.isInbox {
            for id in scopeAccounts {
                Task { _ = await service.loadMore(account: id, label: serverLabel) }
            }
        }
    }

    /// If only the first screenful has been read so far, reads the rest now. Called before anything that goes by
    /// the whole list (a key press), so nothing ever acts on a list that is still short.
    private func completeList() {
        guard listPartial else { return }
        listPartial = false
        applyThreads((try? service.store.threads(account: scope, label: list.label, limit: limit)) ?? [])
    }

    /// Follows the list in the database, up to `limit` rows. Reads happen off the main thread.
    private func watchThreads() {
        listTask?.cancel()
        let account = scope
        let label = list.label
        let count = limit
        let service = self.service
        listTask = Task { [weak self] in
            for await value in service.store.observeThreads(account: account, label: label, limit: count) {
                guard let self, !Task.isCancelled else { return }
                self.growing = false
                self.listPartial = false
                self.applyThreads(value)
            }
        }
    }

    private func applyThreads(_ value: [MailThread]) {
        #if DEBUG || BENCH
        ApplyCount.applies += 1
        #endif
        refreshDay()
        let now = Date()
        suppressed = suppressed.filter { $0.value > now }
        // The database hands the whole list over again after every write, its own first answer included. Setting
        // the same rows again would have every view that shows them looked at again, so only a real change is set.
        let next = suppressed.isEmpty ? value : value.filter { suppressed[$0.id] == nil }
        if next != threads {
            threads = next
        } else {
            #if DEBUG || BENCH
            ApplyCount.skipped += 1
            #endif
        }
        if let open = openThread, let fresh = value.first(where: { $0.id == open.id }), fresh != open { openThread = fresh }
        userLabelsIfNeeded()
        fixCursor()
    }

    private var scopeAccounts: [String] { isAll ? accounts.map(\.id) : [accountId] }

    private func userLabelsIfNeeded() {
        if userLabels.isEmpty, !isAll { userLabels = (try? service.store.labels(account: accountId)) ?? [] }
    }

    private func fixCursor() {
        let current = rows
        if !selected.isEmpty {
            let present = Set(current.map(\.id))
            let kept = selected.filter { present.contains($0) }
            if kept.count != selected.count { selected = kept }
        }
        if let index = cursorIndex {
            lastCursorIndex = index
        } else if current.isEmpty {
            cursorId = nil
        } else {
            cursorId = current[min(lastCursorIndex, current.count - 1)].id
        }
    }

    func moveCursor(by delta: Int) {
        let current = rows
        guard !current.isEmpty else { return }
        let index = min(max((cursorIndex ?? 0) + delta, 0), current.count - 1)
        cursorId = current[index].id
        lastCursorIndex = index
        if openThread != nil { show(current[index]) }
        if index > current.count - 25 { loadOlder() }
    }

    func moveCursor(toEnd: Bool) {
        let current = rows
        guard !current.isEmpty else { return }
        moveCursor(by: toEnd ? current.count : -current.count)
    }

    func setCursor(_ id: String) {
        cursorId = id
        lastCursorIndex = cursorIndex ?? 0
    }

    func loadOlder() {
        if searchActive {
            searchMore()
            return
        }
        guard !loadingMore, !growing else { return }
        completeList()
        if threads.count >= limit {
            // The list is on screen and probably moving: the longer one is read off the main thread and swapped in
            // when it is ready, a few milliseconds later, instead of making this frame wait for it.
            growing = true
            limit += 300
            watchThreads()
            return
        }
        guard let serverLabel = list.serverLabel else { return }
        loadingMore = true
        let ids = scopeAccounts
        Task {
            for id in ids { _ = await service.loadMore(account: id, label: serverLabel) }
            loadingMore = false
        }
    }

    // MARK: - Opening a thread

    /// Opens a conversation from outside the lists, for example from a notification.
    func open(account: String, threadId: String) {
        overlay = nil
        if compose != nil { closeCompose() }
        if !isAll, account != accountId { switchAccount(account) }
        if let thread = try? service.store.thread(account: account, id: threadId) {
            show(thread)
        } else {
            // The banner can arrive before this device has the message. Fetch, then open.
            Task {
                await service.sync(for: account).sync()
                if let thread = try? service.store.thread(account: account, id: threadId) { show(thread) }
            }
        }
    }

    func openCursor() {
        guard let index = cursorIndex else { return }
        show(rows[index])
    }

    func show(_ thread: MailThread) {
        if thread.id.hasPrefix("draft:") {
            finishDraftWrites()
            if let draft = try? service.store.draft(String(thread.id.dropFirst(6))) { compose = draft }
            return
        }
        setCursor(thread.id)
        openThread = thread
        renderedSignature = ""
        let account = thread.accountId
        let threadId = thread.id
        // Straight from the local database, which takes well under a millisecond.
        messages = (try? service.store.messages(account: account, threadId: threadId)) ?? []
        #if DEBUG || BENCH
        ThreadBench.lap("db")
        #endif
        render(keepScroll: false)
        messagesTask?.cancel()
        let service = self.service
        messagesTask = Task { [weak self] in
            for await value in service.store.observeMessages(account: account, threadId: threadId) {
                guard let self, !Task.isCancelled, self.openThread?.id == threadId else { return }
                self.messages = value
                // The thread itself too, so star and read state are right even when it is not in the list behind.
                if let fresh = try? service.store.thread(account: account, id: threadId) { self.openThread = fresh }
                self.render(keepScroll: true)
            }
        }
        if thread.unread {
            service.modify(account: account, threadIds: [threadId], remove: [SystemLabel.unread])
        }
        service.completeThreadIfNeeded(account: account, threadId: threadId)
    }

    /// A back swipe on the open conversation. The conversation follows the fingers exactly; letting go past the
    /// threshold (or with a flick) finishes the slide, anything less drops it back. `endVelocity` is nil while
    /// the swipe is still going.
    func dragBack(_ distance: CGFloat, endVelocity: CGFloat?, width: CGFloat) {
        guard openThread != nil, !sliding, compose == nil, overlay == nil else { return }
        guard let endVelocity else {
            backDrag = max(0, distance)
            return
        }
        sliding = true
        if distance >= backThreshold || (distance >= 10 && endVelocity > 200) {
            backDrag = width
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slide + 0.01) { [weak self] in
                self?.closeThread()
                self?.sliding = false
                self?.backDrag = 0
            }
        } else {
            backDrag = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slide + 0.01) { [weak self] in self?.sliding = false }
        }
    }

    /// How long the conversation takes to slide away once let go. Short, but long enough to be drawn smoothly.
    static let slide = 0.075

    func closeThread() {
        guard openThread != nil else { return }
        messagesTask?.cancel()
        openThread = nil
        messages = []
        renderedSignature = ""
        // The copy of the bodies kept to tell what changed is only of use while the conversation is open.
        sentBodies = [:]
        web.clear()
    }

    private static let cidPattern = try! NSRegularExpression(pattern: "(src\\s*=\\s*[\"'])cid:([^\"']+)([\"'])", options: [.caseInsensitive])
    /// Mail that brings its own page design (a style sheet, or a background that is not plain white) keeps its
    /// own colours on a light card. Everything else, which is nearly all mail written by people, is shown in the
    /// app's colours, so it follows light and dark mode like the rest of the window.
    private static let richPattern = try! NSRegularExpression(
        pattern: "<style|bgcolor\\s*=\\s*[\"']?(?!#?fff\\b|#?ffffff|white|transparent)[#a-z0-9]|background(-color)?\\s*:\\s*(?!#fff\\b|#ffffff|white|transparent|none|inherit|initial|rgba?\\(\\s*255\\s*,\\s*255\\s*,\\s*255|rgba\\([^)]*,\\s*0\\s*\\))[#a-z]",
        options: [.caseInsensitive])

    /// What one walk over a message's bytes found, in any letter case.
    struct Hints {
        var style = false, background = false, cid = false
        /// A `<table` and an `<img`: together, a newsletter's layout.
        var table = false, image = false
        /// A picture address with no scheme (`src="//host/picture.png"`).
        var bareAddress = false
    }

    /// Which of the things the two patterns above look for could be in `html` at all: a `<style`, a `bgcolor` or
    /// `background`, a `cid:`, in any letter case; and whether it has a table, a picture, or an address with no scheme.
    /// One walk over the bytes, so the patterns (which take about a tenth of a second on a megabyte) and whole-text
    /// searches only run on the few messages that need them.
    static func hints(in html: String) -> Hints {
        var html = html
        return html.withUTF8 { bytes in
            /// Whether the bytes from `start` spell `word` (lower-case ASCII), ignoring the case of letters.
            func follows(_ start: Int, _ word: StaticString) -> Bool {
                guard start + word.utf8CodeUnitCount <= bytes.count else { return false }
                return word.withUTF8Buffer { word in
                    for (offset, wanted) in word.enumerated() {
                        let byte = bytes[start + offset]
                        guard byte == wanted || (wanted >= 0x61 && wanted <= 0x7A && byte == wanted - 0x20) else { return false }
                    }
                    return true
                }
            }
            var found = Hints()
            for (index, byte) in bytes.enumerated() {
                switch byte {
                case 0x3C:
                    if !found.style { found.style = follows(index + 1, "style") }
                    if !found.table { found.table = follows(index + 1, "table") }
                    if !found.image { found.image = follows(index + 1, "img") }
                case 0x62, 0x42: if !found.background { found.background = follows(index + 1, "gcolor") || follows(index + 1, "ackground") }
                case 0x63, 0x43: if !found.cid { found.cid = follows(index + 1, "id:") }
                case 0x3D: if !found.bareAddress { found.bareAddress = follows(index + 1, "\"//") || follows(index + 1, "'//") }
                default: break
                }
            }
            return found
        }
    }

    /// Whether the message brings its own page design (see `richPattern`).
    static func isRich(_ html: String, _ hints: Hints) -> Bool {
        // A style sheet is the pattern's first case; without one it can only match where one of the two words is.
        hints.style || (hints.background && richPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) != nil)
    }

    /// Whether two messages' bodies (HTML and plain text) are byte for byte the same.
    private static func sameBytes(_ old: [String?]?, _ new: [String?]?) -> Bool {
        guard let old, let new, old.count == new.count else { return false }
        return zip(old, new).allSatisfy { old, new in
            guard let old, let new else { return old == nil && new == nil }
            return old.utf8.count == new.utf8.count && old.utf8.elementsEqual(new.utf8)
        }
    }

    private func render(keepScroll: Bool) {
        #if DEBUG || BENCH
        if keepScroll { ThreadBench.lap("wait") }
        #endif
        guard let thread = openThread else { return }
        let avatars = AvatarStore.enabled
        let waiting = openReplyDraft
        // Gmail's copies of drafts kept here are left out: the draft is shown once, as written here.
        let mirrored = (try? service.store.mirroredDraftMessages(account: thread.accountId)) ?? [:]
        let messages = self.messages.filter { mirrored[$0.id] == nil }
        let signature = thread.id + (avatars ? "+" : "-") + messages.map { "\($0.id):\($0.labelIds.joined(separator: ","))" }.joined(separator: "|")
            + (waiting.map { "|draft:\($0.id):\($0.updatedAt)" } ?? "")
        guard signature != renderedSignature else { return }
        let sameThread = renderedSignature.hasPrefix(thread.id)
        renderedSignature = signature
        let lastId = messages.last?.id
        let me = thread.accountId
        #if DEBUG || BENCH
        ThreadBench.lap("signature")
        #endif
        // When the same conversation is drawn again (it was marked read, a label changed, a message arrived) the page
        // still holds the bodies it was sent, so only new or changed ones go out; it keeps the rest as they are.
        // (If the page has not been handed this conversation yet, because it is still loading or busy with the one
        // before, this is its first drawing: everything goes, and the place scrolled to is not kept.)
        let again = keepScroll && sameThread && web.caughtUp
        var bodies: [String: [String: String]] = [:]
        var sent: [String: [String?]] = [:]
        var payloadMessages: [[String: Any]] = messages.map { message in
            sent[message.id] = [message.bodyHTML, message.bodyText]
            if !again || !Self.sameBytes(sentBodies[message.id], sent[message.id]) {
                var html = message.bodyHTML ?? ""
                var kind = "plain"
                if html.isEmpty {
                    html = message.bodyText ?? ""
                } else {
                    let hints = Self.hints(in: html)
                    // Its own page design, or a table layout with pictures (a newsletter): keep the sender's colours.
                    let designed = Self.isRich(html, hints) || (hints.table && hints.image)
                    kind = designed ? "rich" : "simple"
                    // Addresses with no scheme ("//host/picture.png") have nothing to be relative to here.
                    if hints.bareAddress {
                        html = html.replacingOccurrences(of: "src=\"//", with: "src=\"https://").replacingOccurrences(of: "src='//", with: "src='https://")
                    }
                    if hints.cid {
                        let ns = html as NSString
                        var out = ""
                        var position = 0
                        for match in Self.cidPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                            out += ns.substring(with: NSRange(location: position, length: match.range.location - position))
                            out += ns.substring(with: match.range(at: 1)) + InlineImageHandler.url(messageId: message.id, contentId: ns.substring(with: match.range(at: 2))) + ns.substring(with: match.range(at: 3))
                            position = match.range.location + match.range.length
                        }
                        html = out + ns.substring(from: position)
                    }
                }
                bodies[message.id] = ["html": html, "kind": kind]
            }
            #if DEBUG || BENCH
            ThreadBench.lap("regex")
            #endif
            let from = message.from
            let recipients = (EmailAddress.parseList(message.toList) + EmailAddress.parseList(message.ccList)).map { $0.email == me ? "me" : $0.displayName }
            #if DEBUG || BENCH
            ThreadBench.lap("people")
            #endif
            let files = message.attachments.filter { !$0.isInline }.enumerated().map { index, file in
                ["name": file.filename, "size": file.size, "preview": "mach-att://m\(message.id)/\(index)"] as [String: Any]
            }
            // The full header lines, shown when the "to" line is clicked, the way Gmail's little arrow does.
            var details: [[String]] = [["from", message.sender]]
            if !message.replyTo.isEmpty, message.replyTo != message.sender { details.append(["reply-to", message.replyTo]) }
            if !message.toList.isEmpty { details.append(["to", message.toList]) }
            if !message.ccList.isEmpty { details.append(["cc", message.ccList]) }
            if !message.bccList.isEmpty { details.append(["bcc", message.bccList]) }
            #if DEBUG || BENCH
            ThreadBench.lap("rest")
            #endif
            details.append(["date", Dates.full(message.date)])
            let shownDate = Dates.detailed(message.date)
            #if DEBUG || BENCH
            ThreadBench.lap("dates")
            #endif
            details.append(["subject", message.subject])
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._")
            let entry: [String: Any] = [
                "id": message.id,
                "avatar": avatars ? "mach-avatar://a/" + (from.email.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") : "",
                "initials": AvatarStore.initials(from.name.isEmpty ? from.email : from.name),
                "color": String(format: "#%06x", AvatarStore.colorHex(for: from.email)),
                "from": from.email == me ? "Me" : from.displayName,
                "to": recipients.isEmpty ? "" : "to " + recipients.joined(separator: ", "),
                "details": details,
                "date": shownDate,
                "snippet": message.snippet,
                "open": message.id == lastId || message.isUnread || message.isDraft,
                "unread": message.isUnread,
                "draft": message.isDraft && !message.isLocal,
                "sending": message.isLocal,
                "files": files,
            ]
            #if DEBUG || BENCH
            ThreadBench.lap("rest")
            #endif
            return entry
        }
        if let waiting {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._")
            let people = (EmailAddress.parseList(waiting.to) + EmailAddress.parseList(waiting.cc)).map(\.displayName)
            let name = accounts.first { $0.id == me }?.name ?? ""
            // Its text goes with every drawing: it changes as it is written.
            bodies["local:" + waiting.id] = ["html": waiting.body, "kind": "plain"]
            payloadMessages.append([
                "id": "local:" + waiting.id,
                "avatar": avatars ? "mach-avatar://a/" + (me.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") : "",
                "initials": AvatarStore.initials(name.isEmpty ? me : name),
                "color": String(format: "#%06x", AvatarStore.colorHex(for: me)),
                "from": "Me",
                "to": people.isEmpty ? "" : "to " + people.joined(separator: ", "),
                "details": [[String]](),
                "date": Dates.detailed(Date(timeIntervalSince1970: Double(waiting.updatedAt) / 1000)),
                "snippet": waiting.body.replacingOccurrences(of: "\n", with: " "),
                "html": waiting.body,
                "kind": "plain",
                "open": true,
                "unread": false,
                "draft": true,
                "sending": false,
                "files": [[String: Any]](),
            ])
        }
        let labelNames = Dictionary(userLabels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let tags = thread.labelIds.compactMap { labelNames[$0] }.filter { !$0.hasPrefix("CATEGORY_") && $0.uppercased() != $0 }
        #if DEBUG || BENCH
        ThreadBench.lap("rest")
        #endif
        sentBodies = sent
        web.render(["subject": thread.subject, "tags": tags, "messages": payloadMessages, "bodies": bodies, "again": again, "compact": compact, "textScale": compact ? TextSize.shared.value : 1, "keepScroll": again])
    }

    private func handle(_ event: ThreadWeb.Event) {
        guard let thread = openThread else { return }
        switch event {
        case .link(let url):
            openURL(url)
        case .face(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { return }
            profile = message.from
            overlay = .profile
        case .file(let messageId, let index):
            guard let message = messages.first(where: { $0.id == messageId }) else { return }
            let files = message.attachments.filter { !$0.isInline }
            guard files.indices.contains(index) else { return }
            let attachment = files[index]
            show(Toast(text: "Opening \(attachment.filename)…"))
            Task {
                do {
                    let url = try await AttachmentCache.file(service: service, account: thread.accountId, messageId: messageId, attachment: attachment)
                    toast = nil
                    previewFile = url
                } catch {
                    show(Toast(text: "Could not download \(attachment.filename)."))
                }
            }
        case .sendDraft(let messageId) where messageId.hasPrefix("local:"):
            // A reply written here: sent the same way as from the writing screen, with the same chance to undo.
            guard let draft = try? service.store.draft(String(messageId.dropFirst(6))) else { return }
            compose = draft
            sendCompose()
        case .editDraft(let messageId) where messageId.hasPrefix("local:"):
            if let draft = try? service.store.draft(String(messageId.dropFirst(6))) { compose = draft }
        case .discardDraft(let messageId) where messageId.hasPrefix("local:"):
            service.discardDraft(id: String(messageId.dropFirst(6)))
            show(Toast(text: "Draft discarded."))
        case .sendDraft(let messageId):
            do {
                try service.finishGmailDraft(account: thread.accountId, threadId: thread.id, messageId: messageId, send: true)
                let account = thread.accountId
                offerUndo("Sent.") { [weak self] in
                    guard let self else { return }
                    self.show(Toast(text: self.service.cancelGmailDraftSend(account: account, messageId: messageId) ? "Sending undone." : "Too late, it already went out."))
                }
            } catch {
                show(Toast(text: error.localizedDescription))
            }
        case .editDraft(let messageId):
            if let message = messages.first(where: { $0.id == messageId }) { editGmailDraft(message) }
        case .discardDraft(let messageId):
            try? service.finishGmailDraft(account: thread.accountId, threadId: thread.id, messageId: messageId, send: false)
            show(Toast(text: "Draft discarded."))
            if messages.count <= 1 { closeThread() }
        }
    }

    // MARK: - Acting on threads

    /// What an action applies to: the open thread, else the ticked rows, else the row under the cursor.
    private var targets: [MailThread] {
        if let open = openThread { return [open] }
        let current = rows
        if !selected.isEmpty { return current.filter { selected.contains($0.id) } }
        return cursorIndex.map { [current[$0]] } ?? []
    }

    /// Shows a message with an Undo, and makes the same undo what Z does next.
    private func offerUndo(_ text: String, _ action: @escaping () -> Void) {
        undoStack.append(action)
        if undoStack.count > 30 { undoStack.removeFirst() }
        show(Toast(text: text, undo: { [weak self] in self?.undo() }))
    }

    /// The same thread as it will look once a label change has been applied, for showing at once.
    private func changed(_ thread: MailThread, add: [String], remove: [String]) -> MailThread {
        var copy = thread
        copy.labelIds = copy.labelIds.filter { !remove.contains($0) } + add.filter { !thread.labelIds.contains($0) }
        if remove.contains(SystemLabel.unread) { copy.unread = false }
        if add.contains(SystemLabel.unread) { copy.unread = true }
        if remove.contains(SystemLabel.starred) { copy.starred = false }
        if add.contains(SystemLabel.starred) { copy.starred = true }
        return copy
    }

    /// Applies a change to the targets, here at once and on Gmail in the background.
    /// `leavesList`: the rows disappear from the list on screen. `closes`: an open conversation is finished with.
    private func act(_ name: String, add: [String] = [], remove: [String] = [], snoozeUntil: Date? = nil, clearSnooze: Bool = false,
                     leavesList: Bool, closes: Bool = false) {
        let items = targets.filter { !$0.id.hasPrefix("draft:") }
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        let byAccount = Dictionary(grouping: items, by: \.accountId).mapValues { $0.map(\.id) }
        let wasOpen = openThread != nil
        selected = []
        if leavesList {
            let expiry = Date().addingTimeInterval(3)
            for id in ids { suppressed[id] = expiry }
            let position = rows.firstIndex { ids.contains($0.id) }
            threads.removeAll { ids.contains($0.id) }
            searchResults.removeAll { ids.contains($0.id) }
            let after = rows
            if let position, !after.isEmpty {
                let next = after[min(position, after.count - 1)]
                cursorId = next.id
                lastCursorIndex = min(position, after.count - 1)
                if wasOpen { show(next) }
            } else {
                // The conversation was not from this list (opened from a notification, say): just go back.
                if after.isEmpty { cursorId = nil }
                closeThread()
            }
        } else {
            // Still on screen, so show the new state straight away instead of waiting for the database.
            threads = threads.map { ids.contains($0.id) ? changed($0, add: add, remove: remove) : $0 }
            searchResults = searchResults.map { ids.contains($0.id) ? changed($0, add: add, remove: remove) : $0 }
            if let open = openThread, ids.contains(open.id) { openThread = changed(open, add: add, remove: remove) }
            if closes, wasOpen { closeThread() }
        }
        for (account, threadIds) in byAccount {
            service.modify(account: account, threadIds: threadIds, add: add, remove: remove, snoozeUntil: snoozeUntil, clearSnooze: clearSnooze)
        }
        // Undo puts each conversation back exactly as it was: only labels that really changed are reversed.
        let before = items
        let subject = ids.count == 1 ? name : "\(ids.count) conversations: \(name.prefix(1).lowercased() + name.dropFirst())"
        offerUndo(subject) { [weak self] in
            guard let self else { return }
            // Conversations that need the same change go back in one write, so the list is handed over once, not once each.
            var writes: [(account: String, restore: [String], takeBack: [String], wasSnoozed: Date?, ids: [String])] = []
            for item in before {
                self.suppressed[item.id] = nil
                let restore = remove.filter { item.labelIds.contains($0) }
                let takeBack = add.filter { !item.labelIds.contains($0) }
                let wasSnoozed = clearSnooze ? item.snoozedUntil.map { Date(timeIntervalSince1970: Double($0) / 1000) } : nil
                if let index = writes.firstIndex(where: { $0.account == item.accountId && $0.restore == restore && $0.takeBack == takeBack && $0.wasSnoozed == wasSnoozed }) {
                    writes[index].ids.append(item.id)
                } else {
                    writes.append((item.accountId, restore, takeBack, wasSnoozed, [item.id]))
                }
            }
            for write in writes {
                self.service.modify(account: write.account, threadIds: write.ids, add: write.restore, remove: write.takeBack,
                                    snoozeUntil: write.wasSnoozed, clearSnooze: snoozeUntil != nil)
            }
            self.show(Toast(text: "Undone."))
        }
    }

    /// The list on screen, unless a search is showing results from everywhere.
    private var shownList: MailList? { searchActive ? nil : list }

    func markDone() {
        if shownList == .snoozed {
            act("Marked Done.", clearSnooze: true, leavesList: true)
            return
        }
        guard targets.contains(where: { $0.labelIds.contains(SystemLabel.inbox) || $0.snoozedUntil != nil }) else {
            if openThread != nil { closeThread() }
            return
        }
        act("Marked Done.", remove: [SystemLabel.inbox], clearSnooze: targets.contains { $0.snoozedUntil != nil },
            leavesList: shownList?.isInbox == true, closes: true)
    }

    func moveToInbox() {
        act("Moved to Inbox.", add: [SystemLabel.inbox], remove: [SystemLabel.trash, SystemLabel.spam], clearSnooze: true,
            leavesList: shownList.map { [MailList.done, .trash, .spam, .snoozed].contains($0) } ?? false)
    }

    func trash() {
        guard shownList != .trash else { return }
        act("Moved to Trash.", add: [SystemLabel.trash], remove: [SystemLabel.inbox], leavesList: !searchActive, closes: true)
    }

    func markSpam() {
        guard shownList != .spam else { return }
        act("Marked as Spam.", add: [SystemLabel.spam], remove: [SystemLabel.inbox], leavesList: !searchActive, closes: true)
    }

    func toggleStar() {
        if targets.allSatisfy(\.starred) {
            act("Star removed.", remove: [SystemLabel.starred], leavesList: shownList == .starred)
        } else {
            act("Starred.", add: [SystemLabel.starred], leavesList: false)
        }
    }

    func toggleRead() {
        let items = targets
        guard !items.isEmpty else { return }
        if items.allSatisfy({ !$0.unread }) { markUnread() } else { markRead() }
    }

    func markRead() {
        guard targets.contains(where: \.unread) else { return }
        act("Marked Read.", remove: [SystemLabel.unread], leavesList: false)
    }

    func markUnread() {
        guard !targets.isEmpty else { return }
        act("Marked Unread.", add: [SystemLabel.unread], leavesList: false, closes: true)
    }

    func snooze(until date: Date) {
        overlay = nil
        act("Snoozed until \(Dates.snooze(date)).", remove: [SystemLabel.inbox], snoozeUntil: date,
            leavesList: shownList?.isInbox == true, closes: true)
    }

    func askSnooze() {
        guard !targets.isEmpty else { return }
        overlay = .snooze
    }

    func undo() {
        guard let last = undoStack.popLast() else {
            show(Toast(text: "Nothing to undo."))
            return
        }
        last()
    }

    func toggleSelect(_ id: String? = nil) {
        guard let id = id ?? cursorId else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func selectAll() {
        // Only in a list. With a conversation open, the same keys select its text instead.
        guard openThread == nil else { return }
        completeList()
        selected = selected.count == rows.count ? [] : Set(rows.map(\.id))
    }

    /// Runs a swipe's action on one row, whatever else is ticked.
    func swipe(_ action: SwipeAction, on thread: MailThread) {
        guard action != .none, !thread.id.hasPrefix("draft:") else { return }
        selected = []
        setCursor(thread.id)
        switch action {
        case .done:
            if thread.labelIds.contains(SystemLabel.inbox) || list == .snoozed { markDone() }
        case .read: toggleRead()
        case .snooze: askSnooze()
        case .trash: trash()
        case .star: toggleStar()
        case .none: break
        }
    }

    /// The size slider moved: the open email follows the list.
    func scaleChanged() {
        applyScale()
    }

    func applyScale() {
        // The iPhone sizes the email inside the page instead, so wide messages still fit the screen.
        guard !compact else { return }
        let scale = UserDefaults.standard.object(forKey: Theme.scaleKey) as? Double ?? Theme.defaultScale
        web.setZoom(scale)
    }

    func setAvatars(_ on: Bool) {
        AvatarStore.enabled = on
        renderedSignature = ""
        render(keepScroll: true)
        avatarsChanged()
        show(Toast(text: on ? "Profile pictures on." : "Profile pictures off."))
    }

    func refresh() {
        Task { await service.syncAll() }
    }

    // MARK: - Search

    func startSearch() {
        closeThread()
        overlay = nil
        searchActive = true
        searchFocusRequest += 1
        searchChanged()
    }

    func endSearch() {
        searchTask?.cancel()
        localSearch.cancel()
        searchActive = false
        searchText = ""
        searchResults = []
        searchSort = .relevant
        searchExtra = []
        searchNext = [:]
        cursorId = nil
        lastCursorIndex = 0
        fixCursor()
    }

    /// The words on the sort button.
    var searchSortTitle: String {
        switch searchSort {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .relevant: return "Best match"
        }
    }

    func cycleSearchSort() {
        let all: [Store.SearchOrder] = [.relevant, .newest, .oldest]
        searchSort = all[((all.firstIndex(of: searchSort) ?? 0) + 1) % all.count]
        localSearch.cancel()
        showSearch((try? service.store.search(account: scope, text: searchText, order: searchSort)) ?? [])
    }

    /// What is on this device (`local`), plus what Gmail found beyond it, in the chosen order.
    private func showSearch(_ local: [MailThread], keepCursor: Bool = false) {
        let known = Set(local.map { $0.accountId + "/" + $0.id })
        let extra = searchExtra.filter { !known.contains($0.accountId + "/" + $0.id) }
        switch searchSort {
        case .newest: searchResults = extra.isEmpty ? local : (local + extra).sorted { $0.lastDate > $1.lastDate }
        case .oldest: searchResults = extra.isEmpty ? local : (local + extra).sorted { $0.lastDate < $1.lastDate }
        case .relevant: searchResults = local + extra.sorted { $0.lastDate > $1.lastDate }
        }
        guard !keepCursor else { return }
        cursorId = searchResults.first?.id
        lastCursorIndex = 0
    }

    /// Before a key acts on the results: if the search for what has been typed is still running, wait for it,
    /// so the key never lands on the results of an earlier, shorter text.
    private func settleSearch() {
        guard searchActive, let rows = localSearch.wait() else { return }
        showSearch(rows)
    }

    func searchChanged() {
        let text = searchText
        let ids = scopeAccounts
        searchTask?.cancel()
        searchExtra = []
        searchNext = [:]
        searchingMore = false
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            localSearch.cancel()
            searchResults = []
            cursorId = nil
            return
        }
        // Local results on every keystroke, then Gmail's own search folded in when typing pauses.
        // The search runs off the main thread. A quick one is waited for and shown in this same frame; a slow one
        // (a short prefix over a big mailbox takes a tenth of a second) shows when it is done, and typing carries on.
        let store = service.store
        let account = scope
        let order = searchSort
        let ready = localSearch.run(patience: 0.008, search: { (try? store.search(account: account, text: text, order: order)) ?? [] }, later: { [weak self] rows in
            // These may be the results for a few letters ago while the search for the latest text is still running:
            // they are shown meanwhile, as each keystroke's results always were.
            guard let self, self.searchActive else { return }
            self.showSearch(rows)
        })
        if let ready { showSearch(ready) }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.searchServer(text: text, accounts: ids, tokens: [:])
        }
    }

    /// Scrolled to the end of the results: fetch the next, older, page from Gmail.
    private func searchMore() {
        guard !searchingMore, !searchNext.isEmpty else { return }
        let text = searchText
        let tokens = searchNext
        searchingMore = true
        Task { [weak self] in
            await self?.searchServer(text: text, accounts: Array(tokens.keys), tokens: tokens)
            self?.searchingMore = false
        }
    }

    private func searchServer(text: String, accounts: [String], tokens: [String: String]) async {
        var found: [(String, [String], String?)] = []
        for id in accounts {
            let page = await service.serverSearch(account: id, query: text, pageToken: tokens[id])
            found.append((id, page.threads, page.next))
        }
        guard !Task.isCancelled, searchActive, searchText == text else { return }
        for (id, threadIds, next) in found {
            searchNext[id] = next
            let have = Set(searchExtra.filter { $0.accountId == id }.map(\.id))
            searchExtra += (try? service.store.threads(account: id, ids: threadIds.filter { !have.contains($0) })) ?? []
        }
        let store = service.store
        let account = scope
        let order = searchSort
        let local = await Task.detached { (try? store.search(account: account, text: text, order: order)) ?? [] }.value
        guard !Task.isCancelled, searchActive, searchText == text, searchSort == order else { return }
        showSearch(local, keepCursor: true)
        fixCursor()
    }

    // MARK: - Writing mail

    private func sourceMessage() -> Message? {
        let candidates: [Message]
        if openThread != nil {
            candidates = messages
        } else if let index = cursorIndex, !rows[index].id.hasPrefix("draft:") {
            candidates = (try? service.store.messages(account: rows[index].accountId, threadId: rows[index].id)) ?? []
        } else {
            return nil
        }
        return candidates.last { !$0.isDraft && !$0.isLocal } ?? candidates.last { !$0.isLocal }
    }

    func startCompose() {
        guard let account = writingAccount else { return }
        overlay = nil
        compose = Draft(accountId: account.id)
    }

    /// Switches a new message to the next account. Replies stay with the account that received the mail.
    func cycleComposeAccount() {
        guard var draft = compose, draft.threadId == nil, accounts.count > 1,
              let index = accounts.firstIndex(where: { $0.id == draft.accountId }) else { return }
        draft.accountId = accounts[(index + 1) % accounts.count].id
        UserDefaults.standard.set(draft.accountId, forKey: "writeFrom")
        compose = draft
        composeChanged()
    }

    func startReply(all: Bool) {
        guard let message = sourceMessage(), let account = accounts.first(where: { $0.id == message.accountId }) else { return }
        overlay = nil
        // A reply already started on this conversation is picked up again, unless the conversation has moved on
        // since, or it was to one person and you now want everyone.
        finishDraftWrites()
        if let existing = try? service.store.draftForThread(account: account.id, threadId: message.threadId) {
            let fresh = Composer.reply(to: message, all: all, account: account)
            if existing.sourceMessageId == message.id, !all || existing.to == fresh.to {
                compose = existing
                return
            }
            // The same draft, re-addressed: it keeps its place on Gmail instead of leaving a second one there.
            var carried = fresh
            carried.id = existing.id
            carried.body = existing.body
            carried.attachmentPaths = existing.attachmentPaths
            compose = carried
            return
        }
        compose = Composer.reply(to: message, all: all, account: account)
    }

    func startForward() {
        guard let message = sourceMessage(), let account = accounts.first(where: { $0.id == message.accountId }) else { return }
        overlay = nil
        let draft = Composer.forward(message, account: account)
        compose = draft
        // The original's files come along. They are fetched in the background and added as they arrive.
        let files = message.attachments.filter { !$0.isInline }
        guard !files.isEmpty else { return }
        show(Toast(text: files.count == 1 ? "Attaching \(files[0].filename)…" : "Attaching \(files.count) files…"))
        Task {
            var failed = 0
            for attachment in files {
                guard let cached = try? await AttachmentCache.file(service: service, account: message.accountId, messageId: message.id, attachment: attachment),
                      let copy = Self.outgoingCopy(of: cached) else {
                    failed += 1
                    continue
                }
                guard compose?.id == draft.id else { return }
                compose?.attachmentPaths.append(copy)
                composeChanged()
            }
            if compose?.id == draft.id {
                show(Toast(text: failed == 0 ? "Attached." : "\(failed) of the original's files could not be attached."))
            }
        }
    }

    /// Copies a file into the app's own folder, so it is still there when the message goes out.
    static func outgoingCopy(of url: URL) -> String? {
        let folder = Bootstrap.directory.appendingPathComponent("outgoing/\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
            return target.path
        } catch {
            return nil
        }
    }

    /// Opens a draft that lives on Gmail (written in Gmail, or by an assistant) for editing here.
    /// Sending the edited version removes the Gmail one.
    func editGmailDraft(_ message: Message) {
        guard let thread = openThread else { return }
        let inThread = messages.contains { !$0.isDraft }
        let references = message.refs.trimmingCharacters(in: .whitespaces)
        // A draft written in this app on another device: what you wrote comes back as text to edit, and the
        // quoted original below it stays exactly as it was.
        var body = message.bodyText ?? HTMLText.strip(message.bodyHTML ?? "")
        var quoted = ""
        if let html = message.bodyHTML, html.hasPrefix("<div dir=\"ltr\">") {
            var own = html
            if let quote = html.range(of: "<br><div class=\"gmail_quote\">") {
                quoted = String(html[html.index(quote.lowerBound, offsetBy: 4)...])
                own = String(html[..<quote.lowerBound])
            }
            if let signature = own.range(of: "<br><div class=\"gmail_signature\">") { own = String(own[..<signature.lowerBound]) }
            body = HTMLText.strip(own)
        }
        compose = Draft(accountId: message.accountId, threadId: inThread ? thread.id : nil, sourceMessageId: "draft:" + message.id,
                        to: message.toList, cc: message.ccList, bcc: message.bccList, subject: message.subject,
                        body: body, quotedHTML: quoted,
                        inReplyTo: references.split(separator: " ").last.map(String.init) ?? "", refs: references)
    }

    /// Called on every edit. Saves a moment after typing stops.
    func composeChanged() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, let draft = self.compose, !draft.isEmpty else { return }
            self.persist(draft)
            // Kept on this device at once; sent up to Gmail when typing has stopped for a few seconds.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self.service.saveDraftsToGmail(account: draft.accountId)
        }
    }

    /// Writes the message being written to the database, off the main thread: a sync that is busy writing mail
    /// must not hold up typing.
    private func persist(_ draft: Draft) {
        let store = service.store
        draftWrites.async { try? store.saveDraft(draft) }
    }

    /// Waits until every draft write asked for so far is in the database. Instant when nothing is waiting.
    private func finishDraftWrites() {
        draftWrites.sync {}
    }

    #if DEBUG || BENCH
    /// For benchmarks: the save that follows a pause in typing, without the pause.
    func saveComposeNowForBench() {
        if let draft = compose { persist(draft) }
    }
    #endif

    func closeCompose(discard: Bool = false) {
        saveTask?.cancel()
        guard let draft = compose else { return }
        compose = nil
        if discard || draft.isEmpty {
            // After any save still on its way, or that save would bring the draft back.
            draftWrites.sync {}
            service.discardDraft(id: draft.id)
            if discard { show(Toast(text: "Draft discarded.")) }
        } else {
            draftWrites.sync {}
            service.saveDraft(draft)
            show(Toast(text: "Draft saved."))
        }
    }

    func sendCompose() {
        guard let draft = compose else { return }
        let recipients = EmailAddress.parseList(draft.to) + EmailAddress.parseList(draft.cc) + EmailAddress.parseList(draft.bcc)
        guard !recipients.isEmpty else {
            show(Toast(text: "Add at least one recipient."))
            return
        }
        if let bad = recipients.first(where: { !$0.email.contains("@") || !$0.email.contains(".") }) {
            show(Toast(text: "\(bad.email) is not a valid address."))
            return
        }
        saveTask?.cancel()
        // The compose view goes away at once. Putting the message in the outbox (which indexes the whole quoted
        // original for search) happens off the main thread, after any save still on its way.
        compose = nil
        let service = self.service
        draftWrites.async { [weak self] in
            let failure: Error?
            do {
                try service.send(draft)
                if let source = draft.sourceMessageId, source.hasPrefix("draft:") {
                    // The edited copy replaces the draft that was on Gmail.
                    let gmailId = String(source.dropFirst(6))
                    if let original = try? service.store.message(account: draft.accountId, id: gmailId) {
                        try? service.finishGmailDraft(account: draft.accountId, threadId: original.threadId, messageId: gmailId, send: false)
                    }
                }
                failure = nil
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let failure {
                        // It could not be queued: the message comes back, exactly as it was.
                        if self.compose != nil { self.closeCompose() }
                        self.compose = draft
                        self.show(Toast(text: failure.localizedDescription))
                        return
                    }
                    self.offerUndo("Sent.") { [weak self] in
                        guard let self else { return }
                        guard let restored = self.service.cancelSend(draftId: draft.id) else {
                            self.show(Toast(text: "Too late, it already went out."))
                            return
                        }
                        // Whatever is being written right now is kept as a draft before the unsent one comes back.
                        if self.compose != nil { self.closeCompose() }
                        self.compose = restored
                        self.show(Toast(text: "Sending undone."))
                    }
                }
            }
        }
    }

    func contacts(matching text: String) -> [Contact] {
        #if DEBUG || BENCH
        BodyCount.bump("contactsLookup")
        #endif
        return (try? service.store.contacts(account: compose?.accountId ?? writingAccount?.id ?? "", matching: text)) ?? []
    }

    // MARK: - Accounts

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signingIn = false
    }

    func signIn() {
        // Pressing again starts over, so an abandoned browser tab never leaves the button dead.
        signInTask?.cancel()
        signingIn = true
        signInTask = Task {
            do {
                let opener = openSignIn
                let account = try await service.signIn { url in
                    Task { @MainActor in opener(url) }
                }
                guard !Task.isCancelled else { return }
                signInFinished()
                signingIn = false
                overlay = nil
                AvatarStore.shared.forgetMisses()
                accountsChanged()
                switchAccount(account.id)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                signInFinished()
                signingIn = false
                show(Toast(text: error.localizedDescription))
            }
        }
    }

    func signOut(_ id: String) {
        try? service.removeAccount(id)
        accountRemoved(id)
    }

    // MARK: - Messages to the person

    func show(_ value: Toast) {
        toast = value
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.toast?.id == value.id else { return }
            self.toast = nil
        }
    }

    private func report(_ message: String) {
        if message == "offline" {
            offline = true
            return
        }
        show(Toast(text: message))
    }

    func syncSucceeded() { offline = false }

    // MARK: - Commands

    var commands: [Command] {
        var items: [Command] = [
            Command(title: "Compose", keys: "C") { [weak self] in self?.startCompose() },
            Command(title: "Reply", keys: "R") { [weak self] in self?.startReply(all: false) },
            Command(title: "Reply All", keys: "A") { [weak self] in self?.startReply(all: true) },
            Command(title: "Forward", keys: "F") { [weak self] in self?.startForward() },
            Command(title: "Mark Done", keys: "E") { [weak self] in self?.markDone() },
            Command(title: "Snooze", keys: "B") { [weak self] in self?.askSnooze() },
            Command(title: "Star", keys: "S") { [weak self] in self?.toggleStar() },
            Command(title: "Mark Read", keys: "⇧I") { [weak self] in self?.markRead() },
            Command(title: "Mark Unread", keys: "⇧U") { [weak self] in self?.markUnread() },
            Command(title: "Back to List", keys: "U") { [weak self] in self?.closeThread() },
            Command(title: "Move to Trash", keys: "#") { [weak self] in self?.trash() },
            Command(title: "Mark as Spam", keys: "!") { [weak self] in self?.markSpam() },
            Command(title: "Move to Inbox") { [weak self] in self?.moveToInbox() },
            Command(title: "Undo", keys: "Z") { [weak self] in self?.undo() },
            Command(title: "Search", keys: "/") { [weak self] in self?.startSearch() },
            Command(title: "Select All", keys: "⌘A") { [weak self] in self?.selectAll() },
            Command(title: "Check for New Mail", keys: "⌘R") { [weak self] in self?.refresh() },
            Command(title: "Keyboard Shortcuts", keys: "?") { [weak self] in self?.overlay = .help },
            Command(title: "Accounts", keys: "⌘,") { [weak self] in self?.overlay = .accounts },
            Command(title: AvatarStore.enabled ? "Hide Profile Pictures" : "Show Profile Pictures") { [weak self] in self?.setAvatars(!AvatarStore.enabled) },
        ]
        let goKeys: [String: String] = [home.label: "G I", MailList.other.label: "G O", MailList.starred.label: "G S", MailList.drafts.label: "G D",
                                        MailList.sent.label: "G T", MailList.done.label: "G E", MailList.snoozed.label: "G B", MailList.all.label: "G A",
                                        MailList.trash.label: "G #", MailList.spam.label: "G !"]
        for target in allLists {
            items.append(Command(title: "Go to \(target.title)", keys: goKeys[target.label] ?? "") { [weak self] in self?.go(target) })
        }
        if accounts.count > 1, !isAll {
            items.append(Command(title: "Switch to All Inboxes", keys: "⌃0") { [weak self] in self?.switchAccount("") })
        }
        for (index, account) in accounts.enumerated() where account.id != accountId {
            items.append(Command(title: "Switch to \(account.id)", keys: "⌃\(index + 1)") { [weak self] in self?.switchAccount(account.id) })
        }
        return items
    }

    func run(_ command: Command) {
        overlay = nil
        command.action()
    }

    func openPalette() {
        paletteQuery = ""
        paletteIndex = 0
        overlay = .palette
    }

    /// Commands whose title contains every typed word, or whose letters appear in order.
    var paletteCommands: [Command] {
        let query = paletteQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return commands }
        let words = query.split(separator: " ")
        var exact: [Command] = []
        var loose: [Command] = []
        for command in commands {
            let title = command.title.lowercased()
            if words.allSatisfy({ title.contains($0) }) {
                exact.append(command)
                continue
            }
            var position = title.startIndex
            var matched = true
            for character in query where character != " " {
                guard let found = title[position...].firstIndex(of: character) else {
                    matched = false
                    break
                }
                position = title.index(after: found)
            }
            if matched { loose.append(command) }
        }
        return exact + loose
    }

    func runPaletteSelection() {
        let available = paletteCommands
        guard available.indices.contains(paletteIndex) else { return }
        run(available[paletteIndex])
    }

    /// Keys that still mean something while a text field has the keyboard. Returns true if handled.
    func handleWhileTyping(_ key: Key) -> Bool {
        completeList()
        if overlay == .palette {
            switch key.special {
            case .escape: overlay = nil
            case .down: paletteIndex = min(paletteIndex + 1, max(paletteCommands.count - 1, 0))
            case .up: paletteIndex = max(paletteIndex - 1, 0)
            case .enter: runPaletteSelection()
            default: return false
            }
            return true
        }
        if overlay != nil {
            if key.special == .escape {
                overlay = nil
                return true
            }
            return false
        }
        if compose != nil {
            if key.special == .escape {
                closeCompose()
                return true
            }
            if key.command, key.special == .enter {
                sendCompose()
                return true
            }
            return false
        }
        if key.command, key.characters.lowercased() == "k" {
            openPalette()
            return true
        }
        if searchActive {
            switch key.special {
            case .escape:
                dropFocus()
                endSearch()
            case .down:
                settleSearch()
                moveCursor(by: 1)
            case .up:
                settleSearch()
                moveCursor(by: -1)
            case .enter:
                settleSearch()
                dropFocus()
                openCursor()
            default: return false
            }
            return true
        }
        return false
    }

    // MARK: - Keyboard

    struct Key {
        var characters: String
        var command = false
        var shift = false
        var control = false
        var special: Special?

        enum Special { case up, down, enter, escape, delete, tab, space, pageUp, pageDown, home, end }
    }

    /// Handles a key press when no text field has focus. Returns true if it did something.
    func handle(_ key: Key) -> Bool {
        refreshDay()
        completeList()
        settleSearch()
        if let current = overlay {
            if key.special == .escape {
                overlay = nil
            } else if current == .snooze, let digit = Int(key.characters) {
                let options = SnoozeOption.standard()
                if options.indices.contains(digit - 1) { snooze(until: options[digit - 1].date) }
            } else if current == .palette {
                return handleWhileTyping(key)
            }
            return true
        }
        if compose != nil { return handleWhileTyping(key) }
        if key.control, let digit = Int(key.characters) {
            switchAccount(index: digit)
            return true
        }
        if key.command {
            switch key.characters.lowercased() {
            case "k": openPalette()
            case "a":
                if openThread != nil { return false }
                selectAll()
            case "r": refresh()
            case "n": startCompose()
            case ",": overlay = .accounts
            case "z": undo()
            default:
                if key.special == .delete { trash(); return true }
                if key.special == .up { moveCursor(toEnd: false); return true }
                if key.special == .down { moveCursor(toEnd: true); return true }
                return false
            }
            return true
        }
        if let started = pendingGo {
            pendingGo = nil
            if Date().timeIntervalSince(started) < 1.5 {
                let map: [String: MailList] = ["i": home, "o": splitInbox ? .other : home, "s": .starred, "d": .drafts, "t": .sent, "e": .done, "b": .snoozed, "h": .snoozed, "a": .all, "#": .trash, "!": .spam]
                if let target = map[key.characters.lowercased()] {
                    go(target)
                    return true
                }
            }
        }
        if let special = key.special {
            switch special {
            case .down: moveCursor(by: 1)
            case .up: moveCursor(by: -1)
            case .enter:
                if openThread == nil { openCursor() } else { web.expandAll() }
            case .escape:
                if openThread != nil { closeThread() } else if searchActive { endSearch() } else if !selected.isEmpty { selected = [] } else if list != home { go(home) }
            case .delete: trash()
            case .tab: switchSplit()
            case .space:
                if openThread != nil { web.scroll(pages: key.shift ? -1 : 1) } else { openCursor() }
            case .pageDown: if openThread != nil { web.scroll(pages: 1) } else { moveCursor(by: 20) }
            case .pageUp: if openThread != nil { web.scroll(pages: -1) } else { moveCursor(by: -20) }
            case .home: moveCursor(toEnd: false)
            case .end: moveCursor(toEnd: true)
            }
            return true
        }
        // Gmail's own shortcuts, so nothing has to be relearned.
        switch key.characters {
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            // The lists in the order they are shown along the top.
            let lists = allLists
            guard let number = Int(key.characters), lists.indices.contains(number - 1) else { return false }
            go(lists[number - 1])
        case "j": moveCursor(by: 1)
        case "k": moveCursor(by: -1)
        case "o": if openThread == nil { openCursor() } else { web.expandAll() }
        case "u": if openThread != nil { closeThread() } else { refresh() }
        case "e", "y", "[", "]": markDone()
        case "#": trash()
        case "!": markSpam()
        case "s": toggleStar()
        case "I": markRead()
        case "U": markUnread()
        case "r": startReply(all: false)
        case "a": startReply(all: true)
        case "f": startForward()
        case "c": startCompose()
        case "b", "h": askSnooze()
        case "z": undo()
        case "x": if openThread == nil { toggleSelect() }
        case "n": if openThread != nil { web.scroll(pages: 0.5) }
        case "p": if openThread != nil { web.scroll(pages: -0.5) }
        case "`", "~": switchSplit()
        case "/": startSearch()
        case "?": overlay = .help
        case "g": pendingGo = Date()
        case "G": moveCursor(toEnd: true)
        default: return false
        }
        return true
    }
}

#if DEBUG || BENCH
/// Counts for benchmarks: how often the list on screen was replaced, and how often a re-delivery was skipped.
enum ApplyCount {
    nonisolated(unsafe) static var applies = 0
    nonisolated(unsafe) static var skipped = 0
}

extension AppModel {
    /// Loads exactly this many rows into the list on screen, to time long lists.
    func benchSetLimit(_ count: Int) {
        limit = count
        observeList()
    }
}
#endif
