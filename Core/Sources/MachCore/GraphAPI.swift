import Foundation

// Outlook, through Microsoft Graph. Works for personal accounts (outlook.com, hotmail.com, live.com) and for work
// or school accounts alike.
//
// Outlook keeps mail in folders where Gmail uses labels, so `GraphBackend` translates: the folder a message is in
// becomes a label (Inbox -> INBOX, Sent Items -> SENT, Archive -> no label at all, which is what "done" means here),
// read and flagged become UNREAD and STARRED, and Outlook's categories become `Label_<name>` labels. A snooze is a
// category whose name carries the wake time, exactly like the hidden Gmail label, so every device sees it.

// MARK: - Wire types

struct MSAddress: Decodable {
    struct Inner: Decodable { let name: String?; let address: String? }
    let emailAddress: Inner?

    var formatted: String? {
        guard let address = emailAddress?.address, !address.isEmpty else { return nil }
        let name = emailAddress?.name ?? ""
        return EmailAddress(name: name.lowercased() == address.lowercased() ? "" : name, email: address.lowercased()).formatted
    }
}

struct MSBody: Decodable { let contentType: String?; let content: String? }
struct MSFlag: Decodable { let flagStatus: String? }
struct MSAttachment: Decodable {
    let id: String
    let name: String?
    let contentType: String?
    let size: Int?
    let isInline: Bool?
    let contentId: String?
}
struct MSProperty: Decodable { let id: String; let value: String? }
struct MSRemoved: Decodable { let reason: String? }

struct MSMessage: Decodable {
    let id: String
    let conversationId: String?
    let parentFolderId: String?
    let receivedDateTime: String?
    let sentDateTime: String?
    let createdDateTime: String?
    let subject: String?
    let bodyPreview: String?
    let body: MSBody?
    let from: MSAddress?
    let toRecipients: [MSAddress]?
    let ccRecipients: [MSAddress]?
    let bccRecipients: [MSAddress]?
    let replyTo: [MSAddress]?
    let internetMessageId: String?
    let isRead: Bool?
    let isDraft: Bool?
    let flag: MSFlag?
    let categories: [String]?
    let inferenceClassification: String?
    let attachments: [MSAttachment]?
    let singleValueExtendedProperties: [MSProperty]?
    let removed: MSRemoved?

    enum CodingKeys: String, CodingKey {
        case id, conversationId, parentFolderId, receivedDateTime, sentDateTime, createdDateTime, subject, bodyPreview, body, from
        case toRecipients, ccRecipients, bccRecipients, replyTo, internetMessageId, isRead, isDraft, flag, categories
        case inferenceClassification, attachments, singleValueExtendedProperties
        case removed = "@removed"
    }
}

struct MSPage<Item: Decodable>: Decodable {
    let value: [Item]
    let nextLink: String?
    let deltaLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }
}

struct MSFolder: Decodable {
    let id: String
    let displayName: String?
    let removed: MSRemoved?

    enum CodingKeys: String, CodingKey {
        case id, displayName
        case removed = "@removed"
    }
}

struct MSUser: Decodable {
    let mail: String?
    let userPrincipalName: String?
    let displayName: String?
}

private struct MSErrorBody: Decodable {
    struct Inner: Decodable { let code: String?; let message: String? }
    let error: Inner?
}

// MARK: - Pacing

/// Outlook allows one app four requests at a time per mailbox and refuses the fifth. Background downloads keep to
/// three, so a tap (archive, send, search) always finds a free slot.
actor GraphGate {
    private var running = 0
    private var waiters: [(background: Bool, resume: CheckedContinuation<Void, Never>)] = []
    private let limit = 4

    func enter(background: Bool) async {
        if running < (background ? limit - 1 : limit) {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append((background, $0)) }
    }

    func leave() {
        running -= 1
        // Whoever is waiting for a tap goes first.
        if let index = waiters.firstIndex(where: { !$0.background }) ?? (running < limit - 1 ? waiters.indices.first : nil) {
            let next = waiters.remove(at: index)
            running += 1
            next.resume.resume()
        }
    }
}

// MARK: - Client

public final class GraphAPI: @unchecked Sendable {
    static let base = "https://graph.microsoft.com/v1.0"
    private let session: URLSession
    private let auth: Authenticator
    private let gate = GraphGate()
    private let decoder = JSONDecoder()
    private static let debug = ProcessInfo.processInfo.environment["MACH_DEBUG"] != nil

    public init(auth: Authenticator, transport: GmailTransport? = nil) {
        self.auth = auth
        let config = URLSessionConfiguration.default
        if let transport { config.protocolClasses = transport.protocolClasses }
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    static func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var components = URLComponents(string: path.hasPrefix("https://") ? path : base + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" alone, but the server reads it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    /// An id as one piece of a path. Ids are mostly letters and digits but may carry "=", "+" or "/".
    static func segment(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~=")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    /// `once` is for requests that must not be repeated when the outcome is unknown (sending mail).
    func send(_ method: String, _ url: URL, body: Data? = nil, contentType: String = "application/json",
              prefer: [String] = [], background: Bool = false, once: Bool = false) async throws -> Data {
        var attempt = 0
        var refreshed = false
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            // Ids that stay the same when a message moves to another folder. Without this, archiving changes the id.
            request.setValue((["IdType=\"ImmutableId\""] + prefer).joined(separator: ", "), forHTTPHeaderField: "Prefer")
            if let body {
                request.httpBody = body
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            await gate.enter(background: background)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
                await gate.leave()
            } catch {
                await gate.leave()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                attempt += 1
                if attempt > 4 || once { throw error }
                try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 0.6 * 1e9))
                continue
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            let parsed = try? decoder.decode(MSErrorBody.self, from: data)
            let failure = GmailError(status: status, reason: parsed?.error?.code ?? "",
                                     message: parsed?.error?.message ?? String(decoding: data.prefix(300), as: UTF8.self), service: "Outlook")
            if Self.debug {
                FileHandle.standardError.write(Data("\(Date().timeIntervalSince1970) \(status) \(failure.reason) \(method) \(url.path.prefix(60))\n".utf8))
            }
            if status == 401, !refreshed {
                refreshed = true
                _ = try await auth.accessToken(forceRefresh: true)
                continue
            }
            if status == 429 || status == 503 || status == 504 {
                attempt += 1
                if attempt > 8 || (once && status != 429) { throw failure }
                // Outlook says how long to stay away.
                let asked = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                try await Task.sleep(nanoseconds: UInt64(min(60, max(asked, pow(2, Double(attempt - 1)) * 0.5)) * 1e9))
                continue
            }
            if status == 409 || status == 412, !once {
                // Two changes to one message crossed. The second goes through a moment later.
                attempt += 1
                if attempt > 3 { throw failure }
                try await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            if status >= 500 {
                attempt += 1
                if attempt > 5 || once { throw failure }
                try await Task.sleep(nanoseconds: UInt64((min(16, pow(2, Double(attempt - 1))) * 0.5 + Double.random(in: 0...0.4)) * 1e9))
                continue
            }
            throw failure
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ url: URL, prefer: [String] = [], background: Bool = false) async throws -> T {
        try decoder.decode(T.self, from: try await send("GET", url, prefer: prefer, background: background))
    }

    func json<T: Decodable>(_ type: T.Type, _ method: String, _ url: URL, _ object: Any, once: Bool = false) async throws -> T {
        try decoder.decode(T.self, from: try await send(method, url, body: try JSONSerialization.data(withJSONObject: object), once: once))
    }

    /// The address and name of the signed-in account.
    func me() async throws -> MSUser {
        try await get(MSUser.self, Self.url("/me", [("$select", "mail,userPrincipalName,displayName")]))
    }
}

// MARK: - Folders

/// The mailbox's folders and which label each one stands for.
struct GraphFolders: Sendable {
    /// Outlook's fixed folders, by the name Graph knows them under (`inbox`, `sentitems`, ...), to their ids.
    var wellKnown: [String: String] = [:]
    var names: [String: String] = [:]

    static let fixed = ["inbox", "drafts", "sentitems", "deleteditems", "junkemail", "archive", "outbox"]
    static let fixedLabels = ["inbox": SystemLabel.inbox, "drafts": SystemLabel.draft, "sentitems": SystemLabel.sent,
                              "deleteditems": SystemLabel.trash, "junkemail": SystemLabel.spam]
    static let folderPrefix = "Folder_"

    func id(_ name: String) -> String? { wellKnown[name] }

    /// The label a folder stands for. Archive stands for none; a folder of your own is a label of its own.
    func label(forFolder id: String) -> String? {
        for (name, known) in wellKnown where known == id {
            return Self.fixedLabels[name]
        }
        return Self.folderPrefix + id
    }

    /// The folder a label lives in, for the labels that are folders.
    func folder(forLabel label: String) -> String? {
        if label.hasPrefix(Self.folderPrefix) { return String(label.dropFirst(Self.folderPrefix.count)) }
        for (name, known) in Self.fixedLabels where known == label { return wellKnown[name] }
        return nil
    }

    /// False for a message in a folder that is not listed: deleted mail that Outlook keeps for a while out of sight.
    func holds(_ message: MSMessage) -> Bool {
        guard let folder = message.parentFolderId else { return true }
        return names[folder] != nil
    }

    /// Folders whose changes are followed. The outbox holds mail on its way out, which is not mail yet.
    var tracked: [String] { names.keys.filter { $0 != wellKnown["outbox"] }.sorted() }
}

// MARK: - Backend

final class GraphBackend: MailBackend, @unchecked Sendable {
    let api: GraphAPI
    let accountId: String

    var provider: MailProvider { .microsoft }
    var batchesByMessage: Bool { false }
    var derivesLabels: Bool { true }

    private let lock = NSLock()
    private var folders: GraphFolders?
    private var loadingFolders: Task<GraphFolders, Error>?
    /// Messages that came with a list, kept until they are asked for one by one.
    private var cache: [String: (message: Message, at: Date)] = [:]
    /// How long a message that came with a list may stand in for asking again. Long enough for the download that
    /// follows the list; anything older could describe a message that has since changed or gone.
    private static let cacheLife: TimeInterval = 20

    static let labelPrefix = "Label_"
    /// Everything a message needs to be shown.
    static let fullSelect = "id,conversationId,parentFolderId,receivedDateTime,sentDateTime,createdDateTime,subject,bodyPreview,body,from,toRecipients,ccRecipients,bccRecipients,replyTo,internetMessageId,isRead,isDraft,flag,categories,inferenceClassification"
    /// The References and In-Reply-To headers (MAPI 0x1039 and 0x1042), and what is attached, without the files themselves.
    static let fullExpand = "singleValueExtendedProperties($filter=id eq 'String 0x1039' or id eq 'String 0x1042'),attachments($select=id,name,contentType,size,isInline,microsoft.graph.fileAttachment/contentId)"
    /// Only what decides a message's labels.
    static let lightSelect = "conversationId,parentFolderId,receivedDateTime,isRead,isDraft,flag,categories,inferenceClassification,from"

    init(api: GraphAPI, accountId: String) {
        self.api = api
        self.accountId = accountId
    }

    // MARK: Folders

    private func knownFolders(refresh: Bool = false) async throws -> GraphFolders {
        let task: Task<GraphFolders, Error> = lock.withLock {
            if !refresh, let folders { return Task { folders } }
            if let loadingFolders { return loadingFolders }
            let created = Task { try await self.loadFolders() }
            loadingFolders = created
            return created
        }
        defer { lock.withLock { if loadingFolders == task { loadingFolders = nil } } }
        let loaded = try await task.value
        lock.withLock { folders = loaded }
        return loaded
    }

    private func loadFolders() async throws -> GraphFolders {
        var result = GraphFolders()
        // The change list of folders is the one call that returns every folder, nested ones included.
        var next: URL? = GraphAPI.url("/me/mailFolders/delta", [("$select", "displayName")])
        while let url = next {
            let page = try await api.get(MSPage<MSFolder>.self, url)
            for folder in page.value where folder.removed == nil { result.names[folder.id] = folder.displayName ?? "" }
            next = page.nextLink.flatMap(URL.init(string:))
        }
        let api = self.api
        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            for name in GraphFolders.fixed {
                group.addTask {
                    do {
                        return (name, try await api.get(MSFolder.self, GraphAPI.url("/me/mailFolders/\(name)", [("$select", "id")])).id)
                    } catch let error as GmailError where error.isNotFound {
                        return (name, nil)
                    }
                }
            }
            for try await (name, id) in group { result.wellKnown[name] = id }
        }
        return result
    }

    // MARK: Converting

    private static let dateFormat: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let fractionalDateFormat: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func milliseconds(_ text: String?) -> Int64 {
        guard let text, let date = dateFormat.date(from: text) ?? fractionalDateFormat.date(from: text) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// The labels a message carries, worked out from where Outlook keeps it and how it is marked.
    static func labels(for message: MSMessage, folders: GraphFolders) -> [String] {
        var labels: [String] = []
        // Mail in the outbox is on its way out: it counts as sent, as it will be a moment later.
        let leaving = message.parentFolderId != nil && message.parentFolderId == folders.id("outbox")
        let folderLabel = leaving ? SystemLabel.sent : message.parentFolderId.flatMap { folders.label(forFolder: $0) }
        if let folderLabel { labels.append(folderLabel) }
        // Outlook can go on calling a message a draft for a moment after it has gone. In Sent it is not one.
        let isDraft = message.isDraft == true && folderLabel != SystemLabel.sent
        if isDraft, !labels.contains(SystemLabel.draft) { labels.append(SystemLabel.draft) }
        if message.isRead == false, !isDraft { labels.append(SystemLabel.unread) }
        if message.flag?.flagStatus == "flagged" { labels.append(SystemLabel.starred) }
        for category in message.categories ?? [] { labels.append(labelPrefix + category) }
        // Outlook's "Other" tab is what the split inbox calls the rest of the inbox.
        if folderLabel == SystemLabel.inbox, message.inferenceClassification == "other" { labels.append("CATEGORY_UPDATES") }
        return labels
    }

    static func record(_ message: MSMessage, accountId: String, folders: GraphFolders) -> Message {
        func list(_ addresses: [MSAddress]?) -> String { (addresses ?? []).compactMap(\.formatted).joined(separator: ", ") }
        let isHTML = message.body?.contentType?.lowercased() == "html"
        let content = message.body?.content
        var snippet = HTMLText.tidy(message.bodyPreview ?? "")
        if snippet.count > 200 { snippet = String(snippet.prefix(200)) }
        var properties: [String: String] = [:]
        for property in message.singleValueExtendedProperties ?? [] { properties[property.id.lowercased()] = property.value ?? "" }
        let references = properties["string 0x1039"] ?? ""
        let inReplyTo = properties["string 0x1042"] ?? ""
        let attachments = (message.attachments ?? []).map { item -> Attachment in
            let contentId = item.contentId.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }.flatMap { $0.isEmpty ? nil : $0 }
            return Attachment(filename: (item.name ?? "").isEmpty ? "attachment" : item.name!, mimeType: (item.contentType ?? "application/octet-stream").lowercased(),
                              size: item.size ?? 0, attachmentId: item.id, contentId: contentId, isInline: item.isInline == true && contentId != nil)
        }
        return Message(
            accountId: accountId, id: message.id, threadId: message.conversationId ?? message.id,
            internalDate: milliseconds(message.receivedDateTime ?? message.sentDateTime ?? message.createdDateTime),
            sender: message.from?.formatted ?? "", toList: list(message.toRecipients), ccList: list(message.ccRecipients),
            bccList: list(message.bccRecipients), replyTo: list(message.replyTo), subject: message.subject ?? "", snippet: snippet,
            labelIds: labels(for: message, folders: folders), messageIdHeader: message.internetMessageId ?? "",
            refs: references.isEmpty ? inReplyTo : references,
            bodyHTML: isHTML ? content : nil, bodyText: isHTML ? nil : content, attachments: attachments)
    }

    private func remember(_ messages: [Message]) {
        lock.withLock {
            let now = Date()
            if cache.count > 600 { cache = cache.filter { now.timeIntervalSince($0.value.at) < Self.cacheLife } }
            for message in messages { cache[message.id] = (message, now) }
        }
    }

    /// Converts a page of full messages. A folder Outlook made since the list was read is learned first.
    private func records(_ messages: [MSMessage]) async throws -> [Message] {
        var folders = try await knownFolders()
        if messages.contains(where: { $0.parentFolderId.map { folders.names[$0] == nil } ?? false }) {
            folders = try await knownFolders(refresh: true)
        }
        // What is left names a folder that is not one of the mailbox's own: Outlook's hidden store of deleted mail,
        // which a search or a conversation still turns up. Deleted is deleted.
        return messages.filter { folders.holds($0) }.map { Self.record($0, accountId: accountId, folders: folders) }
    }

    private func fullQuery(_ extra: [(String, String)]) -> [(String, String)] {
        extra + [("$select", Self.fullSelect), ("$expand", Self.fullExpand)]
    }

    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    // MARK: Reads

    func cursor() async throws -> String { "{}" }

    func labels() async throws -> [RemoteLabel] {
        let folders = try await knownFolders(refresh: true)
        var labels = [SystemLabel.inbox, SystemLabel.sent, SystemLabel.draft, SystemLabel.trash, SystemLabel.spam, SystemLabel.unread, SystemLabel.starred]
            .map { RemoteLabel(id: $0, name: $0, type: "system") }
        for (id, name) in folders.names where !folders.wellKnown.values.contains(id) {
            labels.append(RemoteLabel(id: GraphFolders.folderPrefix + id, name: name, type: "user"))
        }
        return labels
    }

    func identity() async throws -> (name: String, signature: String)? {
        // Outlook does not hand its signatures to other apps.
        (try await api.me().displayName ?? "", "")
    }

    func list(label: String?, query: String?, pageToken: String?, max: Int) async throws -> RemotePage {
        let url: URL
        if let pageToken, let next = URL(string: pageToken) {
            url = next
        } else {
            // Whole messages come with the list, so pages stay small enough to arrive quickly.
            let top = ("$top", String(min(max, 50)))
            let newestFirst = ("$orderby", "receivedDateTime desc")
            if let query, !query.trimmed.isEmpty {
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                url = GraphAPI.url("/me/messages", fullQuery([("$search", "\"\(escaped)\""), top]))
            } else if label == nil {
                url = GraphAPI.url("/me/messages", fullQuery([newestFirst, top]))
            } else if label == SystemLabel.starred {
                url = GraphAPI.url("/me/messages", fullQuery([("$filter", "flag/flagStatus eq 'flagged'"), top]))
            } else if label == SystemLabel.unread {
                url = GraphAPI.url("/me/messages", fullQuery([("$filter", "isRead eq false"), top]))
            } else if let label, let folder = try await knownFolders().folder(forLabel: label) {
                url = GraphAPI.url("/me/mailFolders/\(GraphAPI.segment(folder))/messages", fullQuery([newestFirst, top]))
            } else {
                return RemotePage(refs: [], next: nil)
            }
        }
        let page = try await api.get(MSPage<MSMessage>.self, url)
        let messages = try await records(page.value)
        remember(messages)
        return RemotePage(refs: messages.map { RemoteRef(id: $0.id, threadId: $0.threadId) }, next: page.nextLink)
    }

    func message(_ id: String, background: Bool) async throws -> Message {
        if let cached = lock.withLock({ cache.removeValue(forKey: id) }), Date().timeIntervalSince(cached.at) < Self.cacheLife { return cached.message }
        let found = try await api.get(MSMessage.self, GraphAPI.url("/me/messages/\(GraphAPI.segment(id))", fullQuery([])), background: background)
        guard let record = try await records([found]).first else {
            throw GmailError(status: 404, reason: "deleted", message: "The message was deleted.", service: "Outlook")
        }
        return record
    }

    func thread(_ id: String, background: Bool) async throws -> [Message] {
        var found: [MSMessage] = []
        var next: URL? = GraphAPI.url("/me/messages", fullQuery([("$filter", "conversationId eq \(Self.quoted(id))"), ("$top", "50")]))
        while let url = next {
            let page = try await api.get(MSPage<MSMessage>.self, url, background: background)
            found += page.value
            next = page.nextLink.flatMap(URL.init(string:))
        }
        return try await records(found)
    }

    func attachment(messageId: String, attachmentId: String) async throws -> Data {
        try await api.send("GET", GraphAPI.url("/me/messages/\(GraphAPI.segment(messageId))/attachments/\(GraphAPI.segment(attachmentId))/$value"))
    }

    // MARK: Changes

    /// Where each folder's change list was last read up to.
    struct Cursor: Codable {
        var folders: [String: String] = [:]
    }

    func changes(since cursor: String) async throws -> RemoteChanges {
        var state = (try? JSONDecoder().decode(Cursor.self, from: Data(cursor.utf8))) ?? Cursor()
        let folders = try await knownFolders(refresh: true)
        let api = self.api
        struct FolderResult: Sendable {
            var folder: String
            var link: String?
            var present: [MSMessage] = []
            var removed: [String] = []
            var first: Bool
        }
        let previous = state.folders
        var results: [FolderResult] = []
        try await withThrowingTaskGroup(of: FolderResult.self) { group in
            for folder in folders.tracked {
                group.addTask {
                    var result = FolderResult(folder: folder, first: previous[folder] == nil)
                    var next: URL? = previous[folder].flatMap(URL.init(string:))
                        ?? GraphAPI.url("/me/mailFolders/\(GraphAPI.segment(folder))/messages/delta", [("$select", Self.lightSelect)])
                    while let url = next {
                        let page = try await api.get(MSPage<MSMessage>.self, url, prefer: ["odata.maxpagesize=500"], background: true)
                        for item in page.value {
                            if item.removed != nil { result.removed.append(item.id) } else { result.present.append(item) }
                        }
                        next = page.nextLink.flatMap(URL.init(string:))
                        if let link = page.deltaLink { result.link = link }
                    }
                    return result
                }
            }
            do {
                for try await result in group { results.append(result) }
            } catch let error as GmailError where error.status == 410 || error.reason.lowercased().contains("syncstate") {
                // Outlook forgot where this device had read up to. Reported as "too old", which makes sync compare the lists again.
                throw GmailError(status: 404, reason: "cursorExpired", message: error.message, service: "Outlook")
            }
        }
        var changes = RemoteChanges(wanted: [], unknownAreNew: true)
        var present = Set<String>()
        // A first read of a folder lists everything in it. Only what arrived in the last minutes is worth fetching
        // for that reason alone; the rest is fetched when its list is opened, like on Gmail.
        let recent = Int64(Date().timeIntervalSince1970 * 1000) - 15 * 60 * 1000
        for result in results {
            if let link = result.link { state.folders[result.folder] = link }
            for item in result.present {
                present.insert(item.id)
                changes.labels.append(.init(messageId: item.id, replace: Self.labels(for: item, folders: folders), threadId: item.conversationId))
                if !result.first || Self.milliseconds(item.receivedDateTime) > recent { changes.wanted?.insert(item.id) }
            }
        }
        for folder in state.folders.keys where folders.names[folder] == nil { state.folders[folder] = nil }
        // A message that left one folder was usually moved, and the folder it went to may not have said so yet.
        // Each one is looked at before it is called deleted.
        var seen = Set<String>()
        let gone = results.flatMap(\.removed).filter { !present.contains($0) && seen.insert($0).inserted }
        try await withThrowingTaskGroup(of: (String, MSMessage?).self) { group in
            for id in gone {
                group.addTask {
                    do {
                        return (id, try await api.get(MSMessage.self, GraphAPI.url("/me/messages/\(GraphAPI.segment(id))", [("$select", Self.lightSelect)]), background: true))
                    } catch let error as GmailError where error.isNotFound {
                        return (id, nil)
                    }
                }
            }
            for try await (id, found) in group {
                if let found, folders.holds(found) {
                    changes.labels.append(.init(messageId: id, replace: Self.labels(for: found, folders: folders), threadId: found.conversationId))
                    changes.wanted?.insert(id)
                } else {
                    changes.deleted.append(id)
                }
            }
        }
        changes.cursor = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        return changes
    }

    // MARK: Writes

    /// What has to happen to one message of a thread for a label change to be true on Outlook.
    struct Step: Equatable {
        var id: String
        var patch: [String: String] = [:]
        var categories: [String]?
        /// The folder to move it to.
        var destination: String?
    }

    /// Turns "add these labels, remove those" on a thread into Outlook's terms, message by message.
    /// `messages` is the thread as Outlook has it now, oldest first.
    static func plan(_ messages: [MSMessage], add: [String], remove: [String], folders: GraphFolders, accountId: String) -> [Step] {
        let inbox = folders.id("inbox"), archive = folders.id("archive"), trash = folders.id("deleteditems")
        let junk = folders.id("junkemail"), sent = folders.id("sentitems"), drafts = folders.id("drafts")
        func mine(_ message: MSMessage) -> Bool { message.from?.emailAddress?.address?.lowercased() == accountId }
        // Marks that Gmail puts on a whole thread go on one message here: the newest one that was received.
        let received = messages.filter { $0.isDraft != true && $0.parentFolderId != sent && !mine($0) }
        let newest = (received.last ?? messages.last { $0.isDraft != true })?.id
        let addCategories = add.filter { $0.hasPrefix(labelPrefix) }.map { String($0.dropFirst(labelPrefix.count)) }
        let removeCategories = Set(remove.filter { $0.hasPrefix(labelPrefix) }.map { String($0.dropFirst(labelPrefix.count)) })
        let addFolder = add.first { $0.hasPrefix(GraphFolders.folderPrefix) }.flatMap { folders.folder(forLabel: $0) }
        var steps: [Step] = []
        for message in messages {
            var step = Step(id: message.id)
            let folder = message.parentFolderId
            let isDraft = message.isDraft == true
            if remove.contains(SystemLabel.unread), message.isRead == false { step.patch["isRead"] = "true" }
            if add.contains(SystemLabel.unread), message.id == newest, message.isRead != false { step.patch["isRead"] = "false" }
            if remove.contains(SystemLabel.starred), message.flag?.flagStatus == "flagged" { step.patch["flag"] = "notFlagged" }
            if add.contains(SystemLabel.starred), message.id == newest, message.flag?.flagStatus != "flagged" { step.patch["flag"] = "flagged" }
            var categories = message.categories ?? []
            categories.removeAll { removeCategories.contains($0) }
            if message.id == newest { for category in addCategories where !categories.contains(category) { categories.append(category) } }
            if categories != (message.categories ?? []) { step.categories = categories }

            // Where mail that leaves the trash or the junk folder belongs: what you sent goes back to Sent.
            let home = mine(message) ? sent : inbox
            if add.contains(SystemLabel.trash) {
                if folder != trash { step.destination = trash }
            } else if add.contains(SystemLabel.spam) {
                if folder != junk, folder != sent, !isDraft { step.destination = junk }
            } else if add.contains(SystemLabel.inbox) {
                if folder == archive { step.destination = inbox }
                if folder == trash, remove.contains(SystemLabel.trash) { step.destination = isDraft ? drafts : home }
                if folder == junk, remove.contains(SystemLabel.spam) { step.destination = home }
            } else if let addFolder {
                if folder != addFolder, folder != sent, !isDraft { step.destination = addFolder }
            } else if remove.contains(SystemLabel.inbox) {
                if folder == inbox { step.destination = archive }
            } else if remove.contains(SystemLabel.trash), folder == trash {
                step.destination = isDraft ? drafts : (mine(message) ? sent : archive)
            } else if remove.contains(SystemLabel.spam), folder == junk {
                step.destination = home
            }
            if step.destination == folder { step.destination = nil }
            if !step.patch.isEmpty || step.categories != nil || step.destination != nil { steps.append(step) }
        }
        return steps
    }

    @discardableResult
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws -> [String]? {
        var found: [MSMessage] = []
        var next: URL? = GraphAPI.url("/me/messages", [("$filter", "conversationId eq \(Self.quoted(id))"), ("$select", Self.lightSelect), ("$top", "100")])
        while let url = next {
            let page = try await api.get(MSPage<MSMessage>.self, url)
            found += page.value
            next = page.nextLink.flatMap(URL.init(string:))
        }
        let folders = try await knownFolders()
        found.removeAll { !folders.holds($0) }
        guard !found.isEmpty else { throw GmailError(status: 404, reason: "threadGone", message: "The conversation is no longer there.", service: "Outlook") }
        found.sort { Self.milliseconds($0.receivedDateTime) < Self.milliseconds($1.receivedDateTime) }
        let steps = Self.plan(found, add: add, remove: remove, folders: folders, accountId: accountId)
        let api = self.api
        try await withThrowingTaskGroup(of: Void.self) { group in
            for step in steps {
                group.addTask {
                    let address = "/me/messages/\(GraphAPI.segment(step.id))"
                    do {
                        var patch: [String: Any] = [:]
                        if let read = step.patch["isRead"] { patch["isRead"] = read == "true" }
                        if let flag = step.patch["flag"] { patch["flag"] = ["flagStatus": flag] }
                        if let categories = step.categories { patch["categories"] = categories }
                        // Moved first, marked after: a mark made a moment before a move can be lost with the old copy.
                        if let destination = step.destination {
                            _ = try await api.send("POST", GraphAPI.url(address + "/move"), body: try JSONSerialization.data(withJSONObject: ["destinationId": destination]))
                        }
                        if !patch.isEmpty {
                            _ = try await api.send("PATCH", GraphAPI.url(address), body: try JSONSerialization.data(withJSONObject: patch))
                        }
                    } catch let error as GmailError where error.isNotFound {
                        // Deleted elsewhere a moment ago: nothing left to change.
                    }
                }
            }
            try await group.waitForAll()
        }
        return steps.map(\.id)
    }

    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws {
        throw GmailError(status: 400, reason: "unsupported", message: "Outlook changes mail one conversation at a time.", service: "Outlook")
    }

    func createLabel(name: String) async throws -> RemoteLabel {
        // A category exists the moment a message carries it.
        RemoteLabel(id: Self.labelPrefix + name, name: name, type: "user")
    }

    // MARK: Drafts and sending

    func draftMessageIds() async throws -> Set<String>? {
        guard let drafts = try await knownFolders().id("drafts") else { return nil }
        var ids = Set<String>()
        var next: URL? = GraphAPI.url("/me/mailFolders/\(GraphAPI.segment(drafts))/messages", [("$select", "id"), ("$top", "500")])
        while let url = next {
            let page = try await api.get(MSPage<MSMessage>.self, url, background: true)
            for message in page.value { ids.insert(message.id) }
            next = page.nextLink.flatMap(URL.init(string:))
        }
        return ids
    }

    func draftId(forMessage messageId: String) async throws -> String? {
        do {
            let found = try await api.get(MSMessage.self, GraphAPI.url("/me/messages/\(GraphAPI.segment(messageId))", [("$select", "isDraft")]))
            return found.isDraft == true ? found.id : nil
        } catch let error as GmailError where error.isNotFound {
            return nil
        }
    }

    func sendDraft(id: String) async throws {
        _ = try await api.send("POST", GraphAPI.url("/me/messages/\(GraphAPI.segment(id))/send"), once: true)
    }

    func deleteDraft(id: String) async throws {
        do {
            _ = try await api.send("DELETE", GraphAPI.url("/me/messages/\(GraphAPI.segment(id))"))
        } catch let error as GmailError where error.isNotFound || error.reason == "ErrorCannotDeleteObject" {
            // Already deleted: Outlook keeps deleted mail out of sight for a while and will not delete it twice.
        }
    }

    /// Outlook takes a whole message as text only when making a new draft, so saving over a draft makes the new
    /// one and then removes the old.
    private func createDraft(raw: Data, once: Bool = false) async throws -> MSMessage {
        let data = try await api.send("POST", GraphAPI.url("/me/messages"), body: raw.base64EncodedData(), contentType: "text/plain", once: once)
        return try JSONDecoder().decode(MSMessage.self, from: data)
    }

    func saveDraft(id: String?, raw: Data, threadId: String?) async throws -> RemoteDraft {
        let created = try await createDraft(raw: raw)
        if let id, id != created.id { try? await deleteDraft(id: id) }
        return RemoteDraft(id: created.id, messageId: created.id, threadId: created.conversationId)
    }

    func sendMessage(raw: Data, threadId: String?) async throws -> String? {
        // Made as a draft first and then sent, so the message has an id before it leaves: it keeps that id in Sent.
        let draft = try await createDraft(raw: raw)
        do {
            try await sendDraft(id: draft.id)
        } catch let error as GmailError where error.isPermanent {
            // Refused for good. Nothing went out, so the draft made for it goes too.
            try? await deleteDraft(id: draft.id)
            throw error
        }
        // Drafts left behind by an attempt whose answer was lost carry the same Message-ID. They go now.
        if let header = Self.messageId(inRaw: raw),
           let page = try? await api.get(MSPage<MSMessage>.self, GraphAPI.url("/me/mailFolders/drafts/messages", [("$filter", "internetMessageId eq \(Self.quoted(header))"), ("$select", "isDraft")])) {
            for leftover in page.value where leftover.id != draft.id && leftover.isDraft == true { try? await deleteDraft(id: leftover.id) }
        }
        return draft.id
    }

    /// The Message-ID header of a message in its sending form.
    static func messageId(inRaw raw: Data) -> String? {
        let head = String(decoding: raw.prefix(4000), as: UTF8.self)
        for line in head.components(separatedBy: "\r\n") {
            if line.isEmpty { break }
            if line.lowercased().hasPrefix("message-id:") { return String(line.dropFirst("message-id:".count)).trimmed }
        }
        return nil
    }

    func sentMessage(withMessageId header: String) async throws -> String? {
        let page = try await api.get(MSPage<MSMessage>.self, GraphAPI.url("/me/messages", [("$filter", "internetMessageId eq \(Self.quoted(header))"), ("$select", "isDraft,parentFolderId")]))
        let folders = try await knownFolders()
        return page.value.first { $0.isDraft != true && folders.holds($0) }?.id
    }
}
