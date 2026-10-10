import Foundation

/// Keeps one account's local copy in step with its mail service (Gmail or Outlook), in both directions.
///
/// Gmail's allowance is small (about 300 message downloads a minute), so this works message by message,
/// newest first, and learns label changes from the change log instead of downloading anything twice.
/// Outlook is spoken to in the same terms through `GraphBackend`.
public actor AccountSync {
    public let accountId: String
    private let api: MailBackend
    private let store: Store
    private let report: @Sendable (String, String) -> Void
    private let arrived: @Sendable ([Message]) -> Void

    private var syncTask: Task<Void, Never>?
    private var syncAgain = false
    private var flushing = false
    private var savingDrafts = false
    private var saveDraftsAgain = false
    private var flushAgain = false
    private var backfilling = false
    private var stopped = false
    /// Set for benchmarks: nothing here ever talks to Gmail.
    private let offline: Bool
    /// Messages already announced, so the echo of our own change does not announce them again.
    private var announced: [String] = []
    /// Goes up every time mail from Gmail is written here: only then can there be something new to fill in.
    private var mailWrites = 0
    /// The value of `mailWrites` when a backfill last ran to its end with nothing left to do, and when that was.
    private var backfillSettled: (writes: Int, at: Date)?

    /// How many of the newest messages outside the inbox to keep on the device.
    private let backfillTarget = 1500
    private let inboxLimit = 5000

    /// Changes sent to the service a moment ago: (thread, what was added and removed, when it finished). A report
    /// that was already on its way when one of these landed describes the mailbox as it was before, so they are
    /// laid over it again. Only kept for a service that reports whole label lists.
    private var recentChanges: [(threadId: String, add: [String], remove: [String], at: Date)] = []
    /// Labels already recorded for a service that has no list of them.
    private var learnedLabels = Set<String>()

    init(accountId: String, api: MailBackend, store: Store, offline: Bool = false, report: @escaping @Sendable (String, String) -> Void,
         arrived: @escaping @Sendable ([Message]) -> Void) {
        self.offline = offline
        self.accountId = accountId
        self.api = api
        self.store = store
        self.report = report
        self.arrived = arrived
    }

    // MARK: - Pulling from Gmail

    /// One full pass: push local changes, then pull whatever changed on Gmail.
    /// If a pass is already running, this waits for it and makes it go round once more.
    public func sync() async {
        guard !offline else { return }
        if let running = syncTask {
            syncAgain = true
            await running.value
            return
        }
        let task = Task { await self.runSync() }
        syncTask = task
        await task.value
    }

    private func runSync() async {
        defer { syncTask = nil }
        guard !stopped else { return }
        repeat {
            syncAgain = false
            await flush()
            do {
                try await wakeSnoozed()
                if let historyId = try store.account(accountId)?.historyId {
                    try await incremental(from: historyId)
                } else {
                    try await initial()
                    // Outlook's first look at the change lists is what tells it how every message is filed.
                    if api.derivesLabels { syncAgain = true }
                }
            } catch is CancellationError {
                return
            } catch {
                report(accountId, describe(error))
                return
            }
        } while syncAgain
        dropSupersededDrafts()
        await saveDrafts()
        Task { await self.backfill() }
    }

    private func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed].contains(urlError.code) {
            return "offline"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func refreshProfile() async throws {
        async let labelsCall = api.labels()
        async let identityCall = api.identity()
        let labels = try await labelsCall
        try store.replaceLabels(labels.map { MailLabel(accountId: accountId, id: $0.id, name: $0.name, type: $0.type) }, account: accountId,
                                keepingLearned: api.derivesLabels)
        if let identity = try? await identityCall {
            try store.setProfile(name: identity.name, signature: identity.signature, account: accountId)
        }
    }

    private func initial() async throws {
        // Taken before listing, so nothing that changes while we download is missed. The labels and the sender's
        // name are asked for at the same moment: one round trip instead of two before the first list.
        async let cursorCall = api.cursor()
        try await refreshProfile()
        let cursor = try await cursorCall
        try await reconcile(label: SystemLabel.inbox, limit: inboxLimit)
        try store.setHistoryId(cursor, account: accountId)
    }

    /// Stores mail from the service. For a service with no list of labels, the ones these messages carry are recorded.
    private func keep(_ messages: [Message]) throws {
        try store.saveMessages(account: accountId, messages: messages)
        try learn(messages.flatMap(\.labelIds))
    }

    private func learn(_ labels: [String]) throws {
        guard api.derivesLabels else { return }
        let new = Set(labels.filter { $0.hasPrefix("Label_") && !learnedLabels.contains($0) })
        guard !new.isEmpty else { return }
        try store.learnLabels(account: accountId, ids: new)
        learnedLabels.formUnion(new)
    }

    /// Makes the local copy of one label match Gmail's: downloads what is missing and drops the label from what left.
    private func reconcile(label: String, limit: Int) async throws {
        var listed: [String] = []
        var pageToken: String?
        repeat {
            let page = try await api.list(label: label, query: nil, pageToken: pageToken, max: 500)
            let ids = page.refs.map(\.id)
            listed += ids
            try await download(ids)
            pageToken = page.next
        } while pageToken != nil && listed.count < limit
        let listedSet = Set(listed)
        let have = try store.messageIds(account: accountId, withLabel: label)
        let haveSet = Set(have.map(\.id))
        // Mail already here that gained the label elsewhere (moved back to the inbox, marked unread).
        let gained = listed.filter { !haveSet.contains($0) }
        _ = try store.applyLabelChanges(account: accountId, changes: gained.map { .init(messageId: $0, add: [label], remove: []) }, deleted: [])
        guard pageToken == nil else { return }
        let gone = have.filter { !listedSet.contains($0.id) }
        _ = try store.applyLabelChanges(account: accountId, changes: gone.map { .init(messageId: $0.id, add: [], remove: [label]) }, deleted: [])
    }

    private func incremental(from historyId: String) async throws {
        let asked = Date()
        var report: RemoteChanges
        do {
            report = try await api.changes(since: historyId)
        } catch let error as GmailError where error.isNotFound {
            // Gmail only keeps about a week of changes. Too old: compare the lists again instead.
            let cursor = try await api.cursor()
            try await refreshProfile()
            try await reconcile(label: SystemLabel.inbox, limit: inboxLimit)
            try await reconcile(label: SystemLabel.unread, limit: 2000)
            try await reconcile(label: SystemLabel.starred, limit: 1000)
            try store.setHistoryId(cursor, account: accountId)
            if api.derivesLabels { syncAgain = true }
            return
        }
        var changes = report.labels
        let deleted = report.deleted
        let added = report.added
        // A change sent from here while the report was on its way is not in it yet: lay it over what the report says.
        recentChanges.removeAll { Date().timeIntervalSince($0.at) > 120 }
        let overlaid = recentChanges.filter { $0.at >= asked }
        if !overlaid.isEmpty {
            for index in changes.indices {
                guard let replace = changes[index].replace, let threadId = changes[index].threadId else { continue }
                var labels = replace
                for change in overlaid where change.threadId == threadId { labels = Store.apply(add: change.add, remove: change.remove, to: labels) }
                changes[index].replace = labels
            }
            // The mailbox has moved on since this report was asked for; the next one says where it ended up.
            syncAgain = true
        }
        // A label this device has never heard of (a snooze made elsewhere, a new label): learn the names first.
        if api.derivesLabels {
            try learn(changes.flatMap { $0.replace ?? $0.add })
        } else {
            let mentioned = Set(changes.flatMap { $0.add + $0.remove }.filter { $0.hasPrefix("Label_") })
            if try !store.hasLabels(account: accountId, ids: mentioned) { try await refreshLabels() }
        }
        var returned = changes.filter { $0.add.contains(SystemLabel.inbox) }.map(\.messageId)
        let deletedSet = Set(deleted)
        // Changes to messages not on this device are skipped by the store, which hands their ids back for download.
        let noted = try store.applyLabelChangesNoting(account: accountId, changes: changes, deleted: deleted)
        returned += noted.returned
        let unknown = report.wanted.map { wanted in noted.unknown.filter { wanted.contains($0) } } ?? noted.unknown
        var wanted: [String] = []
        var seen = Set<String>()
        for id in added + unknown where !deletedSet.contains(id) && seen.insert(id).inserted { wanted.append(id) }
        try await download(wanted, urgent: true)
        if let latest = report.cursor, latest != historyId { try store.setHistoryId(latest, account: accountId) }
        // New mail, and mail that came back to the inbox unread (a snooze ending on another device).
        let new = added + returned + (report.unknownAreNew ? unknown : [])
        let fresh = try store.notable(account: accountId, ids: new.filter { !deletedSet.contains($0) })
        announce(fresh)
    }

    /// Downloads the messages that are not on the device yet.
    private func download(_ ids: [String], urgent: Bool = false) async throws {
        guard !ids.isEmpty else { return }
        let known = try store.knownMessageIds(account: accountId, among: ids)
        let missing = ids.filter { !known.contains($0) }
        let api = self.api
        let accountId = self.accountId
        var index = 0
        // Small waves so the first rows reach the screen at once.
        while index < missing.count {
            try Task.checkCancellation()
            let wave = Array(missing[index..<min(index + 20, missing.count)])
            index += wave.count
            // In the background each answer is stored as soon as it is here, together with any others that came in
            // while the last ones were being written: under the paced allowance answers trickle in one by one, and
            // holding rows back until all twenty are here kept mail off the screen for seconds. Urgent downloads are
            // not paced, their answers arrive together, and one write for all of them is the quickest.
            let arrivals = Arrivals()
            let store = self.store
            try await withThrowingTaskGroup(of: Void.self) { group in
                for id in wave {
                    group.addTask {
                        do {
                            arrivals.add(try await api.message(id, background: !urgent))
                        } catch let error as GmailError where error.isNotFound {}
                    }
                }
                for try await _ in group where !urgent {
                    try keep(arrivals.take())
                    mailWrites += 1
                }
            }
            try keep(arrivals.take())
            mailWrites += 1
        }
    }

    /// Downloaded messages waiting to be written.
    private final class Arrivals: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [Message] = []
        func add(_ message: Message) { lock.withLock { messages.append(message) } }
        func take() -> [Message] {
            lock.withLock {
                defer { messages = [] }
                return messages
            }
        }
    }

    /// Downloads a whole conversation, including the parts that were archived or sent from elsewhere.
    @discardableResult
    public func complete(threadId: String, urgent: Bool) async -> Bool {
        guard !threadId.hasPrefix("local-"), !stopped, !offline else { return true }
        do {
            let full = try await api.thread(threadId, background: !urgent)
            mailWrites += 1
            try store.saveThread(account: accountId, threadId: threadId, messages: full)
            try learn(full.flatMap(\.labelIds))
            return true
        } catch let error as GmailError where error.isNotFound {
            mailWrites += 1
            try? store.saveThread(account: accountId, threadId: threadId, messages: [])
            return true
        } catch {
            return false
        }
    }

    /// Called when the account is removed. Work already under way finishes harmlessly; nothing new starts.
    public func stop() {
        stopped = true
    }

    /// Fills in older mail in the background so Done, Sent and search work offline and instantly.
    private func backfill() async {
        guard !backfilling else { return }
        // Looking for conversations to complete reads through every message of the account. When nothing from Gmail
        // was written since a pass that found nothing left to do, there is nothing to find: skip it. (Looked at
        // again every ten minutes regardless, in case something outside this object wrote mail.)
        let writesAtStart = mailWrites
        if let settled = backfillSettled, settled.writes == writesAtStart, Date().timeIntervalSince(settled.at) < 600 { return }
        backfilling = true
        defer { backfilling = false }
        // Anything that fails is retried on a later sync, so a pass with a failure never counts as settled.
        var failed = false
        while !stopped, let threads = try? store.incompleteThreads(account: accountId, limit: 20), !threads.isEmpty {
            for threadId in threads {
                // Offline or refused: stop here and pick it up on a later sync instead of spinning.
                guard await complete(threadId: threadId, urgent: false) else { return }
            }
        }
        for label in [SystemLabel.starred, SystemLabel.draft, SystemLabel.sent] {
            if (try? store.loadedState(account: accountId, key: label)) == nil, (try? await loadMore(label: label, pageSize: 50)) == nil { failed = true }
        }
        // The running total lives in the database so this stops for good once the target is reached.
        let counterKey = "backfilled"
        var loaded = Int((try? store.loadedState(account: accountId, key: counterKey))?.pageToken ?? "") ?? 0
        while loaded < backfillTarget, !stopped {
            let more = try? await loadMore(label: SystemLabel.all, pageSize: 100)
            guard more == true else {
                if more == nil { failed = true }
                break
            }
            loaded += 100
            try? store.setLoadedState(account: accountId, key: counterKey, pageToken: String(loaded), done: false)
        }
        if !failed, !stopped { backfillSettled = (writesAtStart, Date()) }
    }

    /// Fetches the next page of a list from Gmail. Returns false when there is nothing more.
    @discardableResult
    public func loadMore(label: String, pageSize: Int = 100) async throws -> Bool {
        guard !offline else { return false }
        let state = try store.loadedState(account: accountId, key: label)
        if state?.done == true { return false }
        let page = try await api.list(label: label == SystemLabel.all ? nil : label, query: nil, pageToken: state?.pageToken, max: pageSize)
        try await download(page.refs.map(\.id))
        try store.setLoadedState(account: accountId, key: label, pageToken: page.next, done: page.next == nil)
        return page.next != nil
    }

    /// Asks Gmail to search, downloads what is missing, and returns the matching thread ids, best first.
    /// Asks Gmail itself, which knows mail older than what is kept on this device. One page at a time, newest
    /// first; `next` fetches the page after.
    public func serverSearch(_ query: String, pageToken: String? = nil) async throws -> (threads: [String], next: String?) {
        guard !offline else { return ([], nil) }
        let page = try await api.list(label: nil, query: query, pageToken: pageToken, max: 60)
        let refs = page.refs
        try await download(refs.map(\.id), urgent: true)
        var threadIds: [String] = []
        for ref in refs {
            if let threadId = ref.threadId, !threadIds.contains(threadId) { threadIds.append(threadId) }
        }
        return (threadIds, page.next)
    }

    public func attachment(messageId: String, attachmentId: String) async throws -> Data {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        return try await api.attachment(messageId: messageId, attachmentId: attachmentId)
    }

    private func wakeSnoozed() async throws {
        let due = try store.dueSnoozes(account: accountId)
        guard !due.isEmpty else { return }
        try store.modifyThreads(account: accountId, threadIds: due, add: [SystemLabel.inbox, SystemLabel.unread], remove: [], clearSnooze: true, bump: true)
        announce(try store.lastMessages(account: accountId, threadIds: due))
        await flush()
    }

    private func announce(_ messages: [Message]) {
        let new = messages.filter { !announced.contains($0.id) }
        guard !new.isEmpty else { return }
        announced = Array((announced + new.map(\.id)).suffix(200))
        arrived(new)
    }

    /// Turns the stand-ins in a queued change into real Gmail label ids, creating the snooze label if needed.
    private func resolve(_ labels: [String]) async throws -> [String] {
        var resolved: [String] = []
        for label in labels {
            if label.hasPrefix(SystemLabel.snoozeToken) {
                let name = SystemLabel.snoozeLabelName(until: Int64(label.dropFirst(SystemLabel.snoozeToken.count)) ?? 0)
                if let existing = try store.labelId(account: accountId, named: name) {
                    resolved.append(existing)
                    continue
                }
                do {
                    let created = try await api.createLabel(name: name)
                    try store.saveLabel(MailLabel(accountId: accountId, id: created.id, name: created.name, type: "user"))
                    learnedLabels.insert(created.id)
                    resolved.append(created.id)
                } catch let error as GmailError where error.status == 409 {
                    // Another device made the same label a moment ago.
                    try await refreshLabels()
                    if let existing = try store.labelId(account: accountId, named: name) { resolved.append(existing) }
                }
            } else if label == SystemLabel.unsnoozeToken {
                resolved += try store.snoozeLabelIds(account: accountId)
            } else {
                resolved.append(label)
            }
        }
        return resolved
    }

    private func refreshLabels() async throws {
        let labels = try await api.labels()
        try store.replaceLabels(labels.map { MailLabel(accountId: accountId, id: $0.id, name: $0.name, type: $0.type) }, account: accountId,
                                keepingLearned: api.derivesLabels)
        try store.recomputeSnoozed(account: accountId)
    }

    // MARK: - Pushing local changes

    public func flush() async {
        guard !offline else { return }
        if flushing {
            flushAgain = true
            return
        }
        flushing = true
        defer { flushing = false }
        repeat {
            flushAgain = false
            while true {
                guard let ops = try? store.readyOps(account: accountId, limit: 200), !ops.isEmpty else { break }
                // The same change on many threads (select all, mark done) goes up as one request.
                var grouped: [String: [PendingOp]] = [:]
                var singles: [PendingOp] = []
                for op in ops {
                    if op.kind == PendingOp.modify {
                        grouped[Store.json(op.addLabels) + "|" + Store.json(op.removeLabels), default: []].append(op)
                    } else {
                        singles.append(op)
                    }
                }
                var ok = true
                for group in grouped.values {
                    // One request by message id only covers a thread if all of its messages are on this device.
                    let whole = (try? store.wholeThreads(account: accountId, among: group.map(\.threadId))) ?? []
                    let batchable = api.batchesByMessage ? group.filter { whole.contains($0.threadId) } : []
                    singles += group.filter { !api.batchesByMessage || !whole.contains($0.threadId) }
                    if batchable.count >= 4 {
                        if await !runBatch(batchable) { ok = false }
                    } else {
                        singles += batchable
                    }
                }
                let chosen = Array(singles.prefix(8))
                let outcomes = await withTaskGroup(of: Bool.self) { tasks -> [Bool] in
                    for op in chosen { tasks.addTask { await self.run(op) } }
                    var all: [Bool] = []
                    for await outcome in tasks { all.append(outcome) }
                    return all
                }
                // A failure that may pass later (offline, rate limit) stops this round; the next sync retries.
                if !ok || outcomes.contains(false) { return }
            }
        } while flushAgain
    }

    private func runBatch(_ ops: [PendingOp]) async -> Bool {
        guard let first = ops.first else { return true }
        do {
            let add = try await resolve(first.addLabels)
            let remove = try await resolve(first.removeLabels)
            let ids = try store.serverMessageIds(account: accountId, threadIds: ops.map(\.threadId))
            guard !add.isEmpty || !remove.isEmpty else {
                try store.deleteOps(ops.compactMap(\.id))
                return true
            }
            for start in stride(from: 0, to: ids.count, by: 1000) {
                try await api.batchModify(messageIds: Array(ids[start..<min(start + 1000, ids.count)]), add: add, remove: remove)
            }
            try store.deleteOps(ops.compactMap(\.id))
            return true
        } catch let error as GmailError where error.isPermanent {
            // Something in the batch is off. Fall back to one request per thread so only that one fails.
            var ok = true
            for op in ops {
                if await !run(op) { ok = false }
            }
            return ok
        } catch {
            if describe(error) != "offline" { report(accountId, describe(error)) }
            return false
        }
    }

    /// Returns false when the change should be retried later.
    private func run(_ op: PendingOp) async -> Bool {
        guard let opId = op.id else { return true }
        do {
            if op.kind == PendingOp.send {
                try await runSend(op)
            } else if op.kind == PendingOp.sendGmailDraft || op.kind == PendingOp.deleteGmailDraft {
                if let messageId = op.draftId, let draftId = try await api.draftId(forMessage: messageId) {
                    if op.kind == PendingOp.sendGmailDraft {
                        // Marked first: from here Undo is refused, and a draft that is gone on retry was sent.
                        guard try store.beginSend(opId) else { return true }
                        do {
                            try await api.sendDraft(id: draftId)
                        } catch let error as GmailError where error.isNotFound {}
                    } else {
                        try await api.deleteDraft(id: draftId)
                    }
                }
                try store.deleteOp(opId)
                await complete(threadId: op.threadId, urgent: true)
            } else {
                let add = try await resolve(op.addLabels)
                let remove = try await resolve(op.removeLabels)
                if !add.isEmpty || !remove.isEmpty { try await api.modifyThread(op.threadId, add: add, remove: remove) }
                if api.derivesLabels { recentChanges.append((op.threadId, add, remove, Date())) }
                try store.deleteOp(opId)
            }
            return true
        } catch let error as GmailError where error.isNotFound && op.kind == PendingOp.modify {
            try? store.deleteOp(opId)
            mailWrites += 1
            try? store.saveThread(account: accountId, threadId: op.threadId, messages: [])
            return true
        } catch let error as GmailError where error.isPermanent {
            if op.kind == PendingOp.send {
                try? store.finishSend(op: op, sent: false)
                report(accountId, "Could not send: \(error.message) The message is back in your drafts.")
            } else {
                try? store.deleteOp(opId)
                await complete(threadId: op.threadId, urgent: true)
                report(accountId, op.kind == PendingOp.modify ? "A change could not be saved to \(api.provider.name): \(error.message)" : "Could not finish that draft: \(error.message)")
            }
            return true
        } catch let error as SendError {
            try? store.finishSend(op: op, sent: false)
            report(accountId, error.message)
            return true
        } catch {
            try? store.failOp(opId, error: describe(error))
            if describe(error) != "offline" { report(accountId, describe(error)) }
            return false
        }
    }

    private struct SendError: Error { let message: String }

    private func runSend(_ op: PendingOp) async throws {
        guard let draftId = op.draftId, let draft = try store.draft(draftId) else {
            if let id = op.id { try store.deleteOp(id) }
            return
        }
        let outgoing = try outgoing(draft, forSending: true)
        guard let opId = op.id else { return }
        var sentId: String?
        if op.attempts > 0 {
            // An earlier attempt may have reached Gmail with its answer lost. Look before sending again.
            // Not the saved draft, which carries the same id and has not gone anywhere.
            sentId = try await api.sentMessage(withMessageId: draft.outgoingMessageId)
        }
        if sentId == nil {
            // From here Undo is refused; if it was pressed a moment ago, the message must not go.
            guard try store.beginSend(opId) else { return }
            sentId = try await api.sendMessage(raw: outgoing.rfc822(), threadId: draft.threadId)
        }
        // The message is out. Nothing after this may make the queue send it again.
        if let sentId, let message = try? await api.message(sentId, background: false) {
            mailWrites += 1
            try? keep([message])
        }
        try store.finishSend(op: op, sent: true)
        // It has gone, so the copy that was kept as a draft on Gmail goes too.
        if let remote = draft.remoteDraftId {
            try? await api.deleteDraft(id: remote)
            if let copy = draft.remoteMessageId { try? store.removeMessage(account: accountId, id: copy) }
        }
    }

    /// The message a draft becomes. When only saving it, a missing attachment is left out rather than refused.
    private func outgoing(_ draft: Draft, forSending: Bool) throws -> OutgoingMessage {
        let account = try store.account(accountId)
        var attachments: [(filename: String, mimeType: String, data: Data)] = []
        for path in draft.attachmentPaths {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else {
                if !forSending { continue }
                throw SendError(message: "Could not send: the attachment \(url.lastPathComponent) is no longer there. The message is back in your drafts.")
            }
            attachments.append((url.lastPathComponent, Composer.mimeType(for: url), data))
        }
        return OutgoingMessage(
            from: EmailAddress(name: (try? store.senderName(account: accountId)) ?? "", email: accountId),
            to: EmailAddress.parseList(draft.to), cc: EmailAddress.parseList(draft.cc), bcc: EmailAddress.parseList(draft.bcc),
            subject: draft.subject, text: Composer.text(for: draft), html: Composer.html(for: draft, signature: account?.signature ?? ""),
            inReplyTo: draft.inReplyTo, references: draft.refs, messageId: draft.outgoingMessageId, attachments: attachments)
    }

    // MARK: - Drafts on Gmail

    /// Saves every draft written here to Gmail, so it is in Gmail and on your other devices too. Then drops the
    /// ones that were sent, thrown away or rewritten somewhere else: Gmail's version is the one that counts.
    public func saveDrafts() async {
        if savingDrafts {
            saveDraftsAgain = true
            return
        }
        savingDrafts = true
        defer { savingDrafts = false }
        repeat {
            saveDraftsAgain = false
            for draft in (try? store.draftsToUpload(account: accountId)) ?? [] where !draft.isEmpty {
                do {
                    try await save(draft)
                } catch {
                    // Offline, or Gmail said no for now. It stays here and goes up with the next sync.
                    return
                }
            }
        } while saveDraftsAgain && !stopped
    }

    private func save(_ draft: Draft) async throws {
        let raw = try outgoing(draft, forSending: false).rfc822()
        var remote = draft.remoteDraftId
        var replaced = draft.remoteMessageId
        if remote == nil, let source = draft.sourceMessageId, source.hasPrefix("draft:") {
            // It began as a draft that was already on Gmail: save over that one, do not make a second.
            replaced = String(source.dropFirst(6))
            remote = try await api.draftId(forMessage: String(source.dropFirst(6)))
        }
        var saved: RemoteDraft?
        if let remote {
            do {
                saved = try await api.saveDraft(id: remote, raw: raw, threadId: draft.threadId)
            } catch let error as GmailError where error.isNotFound {}
        }
        if saved == nil { saved = try await api.saveDraft(id: nil, raw: raw, threadId: draft.threadId) }
        guard let saved, let messageId = saved.messageId else { return }
        // Bring Gmail's copy here before recording it, so it is never mistaken for one that has gone.
        let message = try await api.message(messageId, background: false)
        try keep([message])
        guard try store.markUploaded(id: draft.id, version: draft.updatedAt, remoteDraftId: saved.id, remoteMessageId: messageId,
                                     remoteThreadId: saved.threadId ?? message.threadId) else {
            // Sent or thrown away while this was on its way up.
            try? await api.deleteDraft(id: saved.id)
            try? store.removeMessage(account: accountId, id: messageId)
            return
        }
        if let replaced, replaced != messageId { try? store.removeMessage(account: accountId, id: replaced) }
    }

    /// A draft whose copy on Gmail is no longer there was sent, discarded or rewritten on another device.
    private func dropSupersededDrafts() {
        for draft in (try? store.settledDrafts(account: accountId)) ?? [] {
            guard let copy = draft.remoteMessageId else { continue }
            // Only when the look-up itself worked and found nothing; a failed look-up proves nothing.
            do {
                if try store.message(account: accountId, id: copy) == nil { try store.deleteDraft(draft.id) }
            } catch {}
        }
    }
}
