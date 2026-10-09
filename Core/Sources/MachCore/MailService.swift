import Foundation
import UniformTypeIdentifiers

/// Builds the text of outgoing mail: replies, forwards and the final HTML.
public enum Composer {
    private static let bodyTag = try! NSRegularExpression(pattern: "<body[^>]*>(.*)</body>", options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static let attributionDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return formatter
    }()

    static func originalHTML(_ message: Message) -> String {
        if let html = message.bodyHTML, !html.isEmpty {
            let range = NSRange(html.startIndex..., in: html)
            if let match = bodyTag.firstMatch(in: html, range: range), let inner = Range(match.range(at: 1), in: html) {
                return String(html[inner])
            }
            return html
        }
        return HTMLText.fromPlain(message.bodyText ?? "")
    }

    private static func prefixed(_ subject: String, with prefix: String, others: [String]) -> String {
        let trimmed = subject.trimmed
        let lower = trimmed.lowercased()
        if lower.hasPrefix(prefix.lowercased()) { return trimmed }
        for other in others where lower.hasPrefix(other.lowercased()) && prefix == "Re: " { return trimmed }
        return prefix + trimmed
    }

    public static func reply(to message: Message, all: Bool, account: Account) -> Draft {
        let me = account.id.lowercased()
        let from = EmailAddress.parseList(message.sender)
        let replyTo = EmailAddress.parseList(message.replyTo)
        let originalTo = EmailAddress.parseList(message.toList)
        let originalCc = EmailAddress.parseList(message.ccList)
        let sentByMe = from.first?.email == me
        var to = sentByMe ? originalTo : (replyTo.isEmpty ? from : replyTo)
        var cc: [EmailAddress] = []
        if all {
            if !sentByMe {
                for address in originalTo where address.email != me && !to.contains(where: { $0.email == address.email }) { to.append(address) }
            }
            for address in originalCc where address.email != me && !to.contains(where: { $0.email == address.email }) { cc.append(address) }
        }
        let attribution = "On \(attributionDate.string(from: message.date)) \(HTMLText.escape(message.from.name.isEmpty ? "" : message.from.name + " "))&lt;\(HTMLText.escape(message.from.email))&gt; wrote:"
        let quoted = "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(attribution)<br></div><blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">\(originalHTML(message))</blockquote></div>"
        let references = [message.refs.trimmed, message.messageIdHeader.trimmed].filter { !$0.isEmpty }.joined(separator: " ")
        return Draft(accountId: account.id, threadId: message.threadId, sourceMessageId: message.id,
                     to: to.map(\.formatted).joined(separator: ", "), cc: cc.map(\.formatted).joined(separator: ", "),
                     subject: prefixed(message.subject, with: "Re: ", others: []), quotedHTML: quoted,
                     inReplyTo: message.messageIdHeader.trimmed, refs: references)
    }

    public static func forward(_ message: Message, account: Account) -> Draft {
        var header = "---------- Forwarded message ---------<br>From: \(HTMLText.escape(Message.readable(message.sender)))<br>Date: \(attributionDate.string(from: message.date))<br>Subject: \(HTMLText.escape(message.subject))<br>To: \(HTMLText.escape(Message.readable(message.toList)))<br>"
        if !message.ccList.isEmpty { header += "Cc: \(HTMLText.escape(Message.readable(message.ccList)))<br>" }
        let quoted = "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(header)</div><br>\(originalHTML(message))</div>"
        return Draft(accountId: account.id, threadId: nil, sourceMessageId: message.id,
                     subject: prefixed(message.subject, with: "Fwd: ", others: ["Fw: "]), quotedHTML: quoted)
    }

    static func html(for draft: Draft, signature: String) -> String {
        var html = "<div dir=\"ltr\">\(HTMLText.fromPlain(draft.body))</div>"
        if !signature.trimmed.isEmpty { html += "<br><div class=\"gmail_signature\">\(signature)</div>" }
        if !draft.quotedHTML.isEmpty { html += "<br>\(draft.quotedHTML)" }
        return html
    }

    static func text(for draft: Draft) -> String {
        guard !draft.quotedHTML.isEmpty else { return draft.body }
        let quoted = HTMLText.strip(draft.quotedHTML).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return draft.body + "\n\n" + quoted
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

private final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: TokenSet] = [:]

    func load(account: String) -> TokenSet? { lock.withLock { tokens[account] } }
    func save(_ tokens: TokenSet, account: String) { lock.withLock { self.tokens[account] = tokens } }
    func delete(account: String) { lock.withLock { tokens[account] = nil } }
}

/// The one object the apps talk to.
public final class MailService: @unchecked Sendable {
    public let store: Store
    public let client: OAuthClient
    private let tokens: TokenStore
    private let lock = NSLock()
    private var syncs: [String: AccountSync] = [:]
    private var authenticators: [String: Authenticator] = [:]
    private var people: [String: PeopleDirectory] = [:]
    private let directory: URL
    /// Benchmarks run with this set: the local database is all there is, and nothing reaches the network.
    public let offline: Bool
    /// Benchmarks and tests only: a stand-in for Gmail.
    private let transport: GmailTransport?
    private var pollTask: Task<Void, Never>?
    private let writes = DispatchQueue(label: "mach.writes", qos: .userInitiated)

    /// Called with (account, message) when something the person should know about happens. "offline" means no connection.
    public var onReport: (@Sendable (String, String) -> Void)?
    /// Called when new mail that deserves a notification has arrived.
    public var onNewMail: (@Sendable ([Message]) -> Void)?
    /// See `Store.announceBulk`.
    public var announceBulk: Bool {
        get { store.announceBulk }
        set { store.announceBulk = newValue }
    }

    public init(directory: URL, client: OAuthClient, tokens: TokenStore, offline: Bool = false, transport: GmailTransport? = nil) throws {
        self.offline = offline
        self.transport = transport
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try Store(path: directory.appendingPathComponent("mail.sqlite").path)
        self.directory = directory
        self.client = client
        self.tokens = tokens
    }

    public func sync(for account: String) -> AccountSync {
        lock.withLock {
            if let existing = syncs[account] { return existing }
            let auth = authenticators[account] ?? Authenticator(account: account, client: client, store: tokens)
            authenticators[account] = auth
            let api = GmailAPI(auth: auth, transport: transport)
            let created = AccountSync(accountId: account, api: api, store: store, offline: offline, report: { [weak self] account, message in
                self?.onReport?(account, message)
            }, arrived: { [weak self] messages in
                self?.onNewMail?(messages)
            })
            syncs[account] = created
            return created
        }
    }

    /// A person's Google profile picture, looked for in every signed-in account's contacts. Your own accounts first.
    public func googlePhotoURL(for email: String) async -> URL? {
        guard !offline else { return nil }
        let accounts = ((try? store.accounts()) ?? []).map(\.id)
        let ordered = accounts.filter { $0 == email.lowercased() } + accounts.filter { $0 != email.lowercased() }
        for account in ordered {
            let directory: PeopleDirectory = lock.withLock {
                if let existing = people[account] { return existing }
                let auth = authenticators[account] ?? Authenticator(account: account, client: client, store: tokens)
                authenticators[account] = auth
                let created = PeopleDirectory(account: account, auth: auth, directory: self.directory)
                people[account] = created
                return created
            }
            if let url = await directory.photoURL(for: email) { return url }
        }
        return nil
    }

    // MARK: Accounts

    /// Finishes a sign-in: learns which address the tokens belong to and starts syncing it.
    @discardableResult
    public func addAccount(tokens newTokens: TokenSet) async throws -> Account {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        let scratch = MemoryTokenStore()
        scratch.save(newTokens, account: "pending")
        let api = GmailAPI(auth: Authenticator(account: "pending", client: client, store: scratch))
        let email = try await api.profile().emailAddress.lowercased()
        tokens.save(scratch.load(account: "pending") ?? newTokens, account: email)
        lock.withLock {
            syncs[email] = nil
            authenticators[email] = nil
            people[email] = nil
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("people-\(email).json"))
        let existing = try store.account(email)
        let nextOrder = (try store.accounts().map(\.sortOrder).max() ?? -1) + 1
        let account = existing ?? Account(id: email, name: "", sortOrder: nextOrder)
        try store.saveAccount(account)
        Task { await self.sync(for: email).sync() }
        return account
    }

    public func signIn(loginHint: String? = nil, open: @escaping @Sendable (URL) -> Void) async throws -> Account {
        guard !offline else { throw URLError(.notConnectedToInternet) }
        return try await addAccount(tokens: try await OAuth.signIn(client: client, loginHint: loginHint, open: open))
    }

    public func removeAccount(_ id: String) throws {
        tokens.delete(account: id)
        let running = lock.withLock {
            authenticators[id] = nil
            people[id] = nil
            return syncs.removeValue(forKey: id)
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("people-\(id).json"))
        if let running { Task { await running.stop() } }
        try store.deleteAccount(id)
    }

    /// What a push relay needs to watch each account on Gmail's side. Leaves the device only if a relay is configured.
    public func relayAccounts() -> [[String: String]] {
        guard !offline else { return [] }
        return ((try? store.accounts()) ?? []).compactMap { account -> [String: String]? in
            guard let saved = tokens.load(account: account.id) else { return nil }
            let used = saved.client ?? client
            var entry = ["email": account.id, "refreshToken": saved.refreshToken, "clientId": used.clientId]
            if let secret = used.clientSecret { entry["clientSecret"] = secret }
            return entry
        }
    }

    // MARK: Syncing

    public func syncAll() async {
        guard !offline, let accounts = try? store.accounts() else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await self.sync(for: account.id).sync() }
            }
        }
    }

    /// Syncs now and then again every `interval` seconds until called again or stopped.
    public func startPolling(every interval: TimeInterval) {
        pollTask?.cancel()
        guard !offline else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAll()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Actions (applied locally at once, sent to Gmail in the background)

    public func modify(account: String, threadIds: [String], add: [String] = [], remove: [String] = [],
                       snoozeUntil: Date? = nil, clearSnooze: Bool = false, bump: Bool = false) {
        guard !threadIds.isEmpty else { return }
        writes.async {
            do {
                try self.store.modifyThreads(account: account, threadIds: threadIds, add: add, remove: remove,
                                             snoozeUntil: snoozeUntil.map { Int64($0.timeIntervalSince1970 * 1000) },
                                             clearSnooze: clearSnooze, bump: bump)
            } catch {
                self.onReport?(account, error.localizedDescription)
            }
            Task { await self.sync(for: account).flush() }
        }
    }

    /// Keeps a draft: here at once, and on Gmail a moment later so it is on every device.
    public func saveDraft(_ draft: Draft) {
        try? store.saveDraft(draft)
        saveDraftsToGmail(account: draft.accountId)
    }

    public func saveDraftsToGmail(account: String) {
        Task { await self.sync(for: account).saveDrafts() }
    }

    /// Throws a draft away, here and on Gmail.
    public func discardDraft(id: String) {
        guard let draft = try? store.draft(id) else { return }
        try? store.deleteDraft(id)
        if let copy = draft.remoteMessageId {
            try? finishGmailDraft(account: draft.accountId, threadId: draft.remoteThreadId ?? draft.threadId ?? "", messageId: copy, send: false)
        }
    }

    /// Queues the draft. It leaves after `undoWindow` seconds unless `cancelSend` is called first.
    public func send(_ draft: Draft, undoWindow: TimeInterval = 5) throws {
        let account = try store.account(draft.accountId)
        let from = EmailAddress(name: (try? store.senderName(account: draft.accountId)) ?? "", email: draft.accountId)
        try store.queueSend(draft: draft, from: from, html: Composer.html(for: draft, signature: account?.signature ?? ""), delay: undoWindow)
        if let threadId = draft.threadId {
            // Replying means you have dealt with it.
            modify(account: draft.accountId, threadIds: [threadId], remove: [SystemLabel.unread])
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64((undoWindow + 0.05) * 1e9))
            await self.sync(for: draft.accountId).flush()
        }
    }

    /// Sends (or deletes) a draft that already exists on Gmail, for example one an assistant prepared.
    public func finishGmailDraft(account: String, threadId: String, messageId: String, send: Bool, undoWindow: TimeInterval = 5) throws {
        try store.queueGmailDraft(account: account, threadId: threadId, messageId: messageId, send: send, delay: send ? undoWindow : 0)
        Task {
            if send { try? await Task.sleep(nanoseconds: UInt64((undoWindow + 0.05) * 1e9)) }
            await self.sync(for: account).flush()
        }
    }

    public func cancelGmailDraftSend(account: String, messageId: String) -> Bool {
        (try? store.cancelGmailDraftSend(account: account, messageId: messageId)) ?? false
    }

    /// Downloads the rest of a conversation if only part of it is on the device.
    public func completeThreadIfNeeded(account: String, threadId: String) {
        guard (try? store.threadNeedsCompleting(account: account, threadId: threadId)) == true else { return }
        Task { await self.sync(for: account).complete(threadId: threadId, urgent: true) }
    }

    public func loadMore(account: String, label: String) async -> Bool {
        (try? await sync(for: account).loadMore(label: label)) ?? false
    }

    public func serverSearch(account: String, query: String, pageToken: String? = nil) async -> (threads: [String], next: String?) {
        (try? await sync(for: account).serverSearch(query, pageToken: pageToken)) ?? ([], nil)
    }

    public func cancelSend(draftId: String) -> Draft? {
        try? store.cancelSend(draftId: draftId)
    }

    public func attachmentData(account: String, messageId: String, attachment: Attachment) async throws -> Data {
        try await sync(for: account).attachment(messageId: messageId, attachmentId: attachment.attachmentId)
    }
}
