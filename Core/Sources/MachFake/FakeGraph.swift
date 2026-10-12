import Foundation

/// A pretend Outlook for benchmarks and tests, the way `FakeGmail` is a pretend Gmail. `FakeGraphProtocol` answers
/// the requests `GraphAPI` makes from a made-up mailbox held in memory, after a fixed delay per round trip, and logs
/// every one. It knows the parts of Microsoft Graph that reading mail and keeping in step use: folders, each
/// folder's change list (which, like the real one, can run behind the mailbox: `changeLag`), lists, single
/// messages, moves, marks, several reads in one round trip, contacts and their pictures.
public final class FakeGraph: @unchecked Sendable {
    public struct Call: Sendable {
        public let start: Double
        public let end: Double
        public let method: String
        /// The kind of request: `batch`, `folders.delta`, `folder.get`, `messages.delta`, `messages.list`, `messages.get`, ...
        public let kind: String
        /// How many reads the round trip carried: 1, or the size of a batch.
        public let reads: Int
        public let bytes: Int
    }

    struct Item {
        var id: String
        var conversation: String
        var folder: String
        var received: Int64
        var read: Bool
        var flagged = false
        var draft = false
        var categories: [String] = []
        var from: String
        var number: Int
    }

    public struct Person: Sendable {
        public var name: String
        public var emails: [String]
        /// The bytes of the picture saved on the contact, if it has one.
        public var photo: Data?

        public init(name: String, emails: [String], photo: Data? = nil) {
            self.name = name
            self.emails = emails
            self.photo = photo
        }
    }

    public let email: String
    /// Seconds each round trip takes to answer.
    public var latency: Double
    /// Seconds a change takes to show up in a folder's change list. The lists and single messages have it at once.
    public var changeLag: Double = 0
    /// The access token that routes requests to this server. Give it to the app's token store.
    public var token: String { "fake-" + email }
    /// False for a sign-in from before contacts were asked for: the contact and people lists are refused.
    public var allowsContacts = true
    /// Saved contacts, and the people mail goes back and forth with.
    public var contacts: [Person] = []
    public var people: [Person] = []
    /// The account's own picture.
    public var ownPhoto: Data?

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var folders: [(id: String, name: String)] = FakeGraph.fixed.map { ("F-" + $0.key, $0.name) }
    private var folderVersion = 1
    /// Every change, oldest first: which folder's list it belongs in, the message, whether it left, and when.
    private var journal: [(seq: Int, folder: String, id: String, removed: Bool, at: Double)] = []
    private var sequence = 100
    private var counter = 0
    private var log: [Call] = []
    private let queue = DispatchQueue(label: "fake.graph", attributes: .concurrent)

    static let fixed: [(key: String, name: String)] = [("inbox", "Inbox"), ("drafts", "Drafts"), ("sentitems", "Sent Items"), ("deleteditems", "Deleted Items"),
                                                        ("junkemail", "Junk Email"), ("archive", "Archive"), ("outbox", "Outbox")]
    static let base = "https://graph.microsoft.com/v1.0"

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: FakeGraph] = [:]

    public init(email: String, latency: Double = 0.12) {
        self.email = email
        self.latency = latency
        Self.registryLock.withLock { Self.registry[token] = self }
    }

    public func close() {
        Self.registryLock.withLock { Self.registry[token] = nil }
    }

    static func server(for request: URLRequest) -> FakeGraph? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else { return nil }
        return registryLock.withLock { registry[String(header.dropFirst(7))] }
    }

    // MARK: - Changing the mailbox, as Outlook or another device would

    private func record(_ folder: String, _ id: String, removed: Bool) {
        sequence += 1
        journal.append((sequence, folder, id, removed, ProcessInfo.processInfo.systemUptime))
    }

    /// Mail that was "always there": in the folder, and in no change list.
    @discardableResult
    public func seed(_ count: Int, folder: String = "inbox", read: Bool = true) -> [String] {
        lock.withLock {
            (0..<count).map { _ in
                counter += 1
                let id = "AAkALg-\(String(format: "%06d", counter))="
                items[id] = Item(id: id, conversation: "conv-\(counter)", folder: "F-" + folder, received: 1_750_000_000_000 + Int64(counter) * 60_000,
                                 read: read, from: "sender\(counter % 40)@example.com", number: counter)
                return id
            }
        }
    }

    /// New mail arriving now. Returns the ids.
    @discardableResult
    public func deliver(_ count: Int = 1, from: String? = nil, conversation: String? = nil) -> [String] {
        lock.withLock {
            (0..<count).map { _ in
                counter += 1
                let id = "AAkALg-\(String(format: "%06d", counter))="
                items[id] = Item(id: id, conversation: conversation ?? "conv-\(counter)", folder: "F-inbox", received: Int64(Date().timeIntervalSince1970 * 1000) + Int64(counter),
                                 read: false, from: from ?? "sender\(counter % 40)@example.com", number: counter)
                record("F-inbox", id, removed: false)
                return id
            }
        }
    }

    public func move(_ id: String, to folder: String) {
        lock.withLock { moveLocked(id, to: "F-" + folder) }
    }

    private func moveLocked(_ id: String, to folder: String) {
        guard var item = items[id], item.folder != folder else { return }
        record(item.folder, id, removed: true)
        item.folder = folder
        items[id] = item
        record(folder, id, removed: false)
    }

    public func mark(_ id: String, read: Bool) {
        lock.withLock {
            guard var item = items[id] else { return }
            item.read = read
            items[id] = item
            record(item.folder, id, removed: false)
        }
    }

    /// Gone for good. `silently` leaves it out of the change list, as Outlook does for mail that came and went
    /// between two looks.
    public func delete(_ id: String, silently: Bool = false) {
        lock.withLock {
            guard let item = items.removeValue(forKey: id) else { return }
            if silently {
                journal.removeAll { $0.id == id }
            } else {
                record(item.folder, id, removed: true)
            }
        }
    }

    @discardableResult
    public func addFolder(_ name: String) -> String {
        lock.withLock {
            let id = "F-user\(folders.count)"
            folders.append((id, name))
            folderVersion += 1
            return id
        }
    }

    public func folder(of id: String) -> String? { lock.withLock { items[id].map { String($0.folder.dropFirst(2)) } } }
    public func isRead(_ id: String) -> Bool? { lock.withLock { items[id]?.read } }
    public func categories(of id: String) -> [String]? { lock.withLock { items[id]?.categories } }

    // MARK: - The request log

    public var calls: [Call] { lock.withLock { log } }
    public func resetLog() { lock.withLock { log = [] } }

    // MARK: - Answering

    fileprivate func handle(_ request: URLRequest, body: Data, reply: @escaping @Sendable (Int, Data, String) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        let (status, data, kind, reads, type) = lock.withLock { () -> (Int, Data, String, Int, String) in
            guard let url = request.url else { return (400, Data(), "bad", 1, "application/json") }
            if request.httpMethod == "POST", url.path.hasSuffix("/$batch") { return batch(body) }
            let (status, object, kind) = answer(request.httpMethod ?? "GET", url, body: body)
            if let raw = object as? Data { return (status, raw, kind, 1, "image/jpeg") }
            return (status, Self.data(object), kind, 1, "application/json")
        }
        let method = request.httpMethod ?? "GET"
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + latency, leeway: .nanoseconds(0))
        timer.setEventHandler {
            timer.cancel()
            self.lock.withLock { self.log.append(Call(start: start, end: ProcessInfo.processInfo.systemUptime, method: method, kind: kind, reads: reads, bytes: data.count)) }
            reply(status, data, type)
        }
        timer.resume()
    }

    private static func data(_ object: Any?) -> Data {
        guard let object, JSONSerialization.isValidJSONObject(object) else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func batch(_ body: Data) -> (Int, Data, String, Int, String) {
        let asked = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["requests"] as? [[String: Any]] ?? []
        guard asked.count <= 20 else { return (400, Self.data(Self.failure("BadRequest", "too many requests")), "batch", asked.count, "application/json") }
        var answers: [[String: Any]] = []
        for one in asked {
            guard let id = one["id"] as? String, let path = one["url"] as? String, let url = URL(string: Self.base + path) else { continue }
            let (status, object, _) = answer(one["method"] as? String ?? "GET", url, body: Data())
            answers.append(["id": id, "status": status, "body": object as? [String: Any] ?? [:]])
        }
        return (200, Self.data(["responses": answers]), "batch", asked.count, "application/json")
    }

    private static func failure(_ code: String, _ message: String) -> [String: Any] { ["error": ["code": code, "message": message]] }
    private static let missing: [String: Any] = failure("ErrorItemNotFound", "The specified object was not found in the store.")
    private static let denied: [String: Any] = failure("ErrorAccessDenied", "Access is denied. Check credentials and try again.")

    private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func json(_ item: Item, full: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "id": item.id, "conversationId": item.conversation, "parentFolderId": item.folder,
            "receivedDateTime": Self.dates.string(from: Date(timeIntervalSince1970: Double(item.received) / 1000)),
            "isRead": item.read, "isDraft": item.draft, "flag": ["flagStatus": item.flagged ? "flagged" : "notFlagged"],
            "categories": item.categories, "inferenceClassification": "focused",
            "from": ["emailAddress": ["name": "Sender \(item.number % 40)", "address": item.from]],
        ]
        if full {
            object["subject"] = "Message \(item.number)"
            object["bodyPreview"] = "Preview of message \(item.number)"
            object["body"] = ["contentType": "html", "content": "<html><body><p>Body of message \(item.number)</p></body></html>"]
            object["toRecipients"] = [["emailAddress": ["name": "", "address": email]]]
            object["internetMessageId"] = "<m\(item.number)@example.com>"
            object["attachments"] = [[String: Any]]()
        }
        return object
    }

    private func folderId(_ segment: String) -> String? {
        if folders.contains(where: { $0.id == segment }) { return segment }
        return Self.fixed.contains { $0.key == segment } ? "F-" + segment : nil
    }

    /// Returns the status, the answer (a JSON object, or the bytes of a picture) and the kind of request.
    private func answer(_ method: String, _ url: URL, body: Data) -> (Int, Any?, String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (400, nil, "bad") }
        let parts = components.path.replacingOccurrences(of: "/v1.0", with: "").split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let full = value("$select").map { $0.contains("body") } ?? true
        let top = Int(value("$top") ?? "") ?? 100
        let now = ProcessInfo.processInfo.systemUptime
        guard parts.first == "me" else { return (404, Self.missing, "other") }

        if method == "GET", parts.count == 1 {
            return (200, ["mail": email, "userPrincipalName": email, "displayName": "Bench Person"], "me")
        }
        if method == "GET", parts == ["me", "photo", "$value"] {
            return ownPhoto.map { (200, $0 as Any?, "photo") } ?? (404, Self.missing, "photo")
        }
        if method == "GET", parts.count >= 2, parts[1] == "contacts" {
            guard allowsContacts else { return (403, Self.denied, "contacts") }
            if parts.count == 2 {
                let list = contacts.enumerated().map { index, person -> [String: Any] in
                    ["id": "C-\(index)", "displayName": person.name, "emailAddresses": person.emails.map { ["address": $0, "name": person.name] }]
                }
                return (200, ["value": list], "contacts")
            }
            if parts.count == 5, parts[3] == "photo", parts[4] == "$value", let index = Int(parts[2].dropFirst(2)), contacts.indices.contains(index),
               let photo = contacts[index].photo {
                return (200, photo, "contact.photo")
            }
            return (404, Self.missing, "contact.photo")
        }
        if method == "GET", parts == ["me", "people"] {
            guard allowsContacts else { return (403, Self.denied, "people") }
            let list = people.map { person -> [String: Any] in
                ["displayName": person.name, "scoredEmailAddresses": person.emails.map { ["address": $0] }]
            }
            return (200, ["value": list], "people")
        }
        if parts.count >= 2, parts[1] == "mailFolders" {
            if method == "GET", parts.count == 3, parts[2] == "delta" {
                let token = value("$deltatoken").flatMap(Int.init)
                let listed = token == folderVersion ? [] : folders.map { ["id": $0.id, "displayName": $0.name] as [String: Any] }
                return (200, ["value": listed, "@odata.deltaLink": Self.base + "/me/mailFolders/delta?$deltatoken=\(folderVersion)"], "folders.delta")
            }
            guard parts.count >= 3, let folder = folderId(parts[2]) else { return (404, Self.missing, "folder.get") }
            if method == "GET", parts.count == 3 { return (200, ["id": folder], "folder.get") }
            if method == "GET", parts.count == 5, parts[3] == "messages", parts[4] == "delta" {
                // What the change list has caught up to: everything older than the lag.
                let visible = journal.last { now - $0.at >= changeLag }?.seq ?? 100
                var listed: [[String: Any]] = []
                if let token = value("$deltatoken").flatMap(Int.init) {
                    var seen = Set<String>()
                    for entry in journal.reversed() where entry.folder == folder && entry.seq > token && entry.seq <= visible && seen.insert(entry.id).inserted {
                        if let item = items[entry.id], item.folder == folder, !entry.removed {
                            listed.append(json(item, full: false))
                        } else {
                            listed.append(["id": entry.id, "@removed": ["reason": "deleted"]])
                        }
                    }
                } else {
                    // A first read: what is in the folder as far as the change list has caught up.
                    let late = Set(journal.filter { $0.seq > visible && !$0.removed }.map(\.id))
                    listed = items.values.filter { $0.folder == folder && !late.contains($0.id) }.sorted { $0.received > $1.received }.map { json($0, full: false) }
                }
                return (200, ["value": listed, "@odata.deltaLink": Self.base + "/me/mailFolders/\(folder)/messages/delta?$deltatoken=\(visible)"], "messages.delta")
            }
            if method == "GET", parts.count == 4, parts[3] == "messages" {
                let listed = items.values.filter { $0.folder == folder }.sorted { $0.received > $1.received }.prefix(top)
                return (200, ["value": listed.map { json($0, full: full) }], "messages.list")
            }
            return (404, Self.missing, "other")
        }
        if parts.count >= 2, parts[1] == "messages" {
            if method == "GET", parts.count == 2 {
                var listed = Array(items.values)
                if value("$search") != nil { listed = [] }
                if let filter = value("$filter") {
                    if filter.hasPrefix("conversationId eq '") {
                        let wanted = String(filter.dropFirst("conversationId eq '".count).dropLast())
                        listed = listed.filter { $0.conversation == wanted }
                    } else if filter.contains("flagStatus eq 'flagged'") {
                        listed = listed.filter(\.flagged)
                    } else if filter.contains("isRead eq false") {
                        listed = listed.filter { !$0.read }
                    } else {
                        listed = []
                    }
                }
                return (200, ["value": listed.sorted { $0.received > $1.received }.prefix(top).map { json($0, full: full) }], "messages.list")
            }
            guard parts.count >= 3, var item = items[parts[2]] else { return (404, Self.missing, "messages.get") }
            if method == "GET", parts.count == 3 { return (200, json(item, full: full), "messages.get") }
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if method == "POST", parts.count == 4, parts[3] == "move", let destination = (sent["destinationId"] as? String).flatMap(folderId) {
                moveLocked(item.id, to: destination)
                return (201, items[item.id].map { json($0, full: false) }, "messages.move")
            }
            if method == "PATCH", parts.count == 3 {
                if let read = sent["isRead"] as? Bool { item.read = read }
                if let flag = (sent["flag"] as? [String: Any])?["flagStatus"] as? String { item.flagged = flag == "flagged" }
                if let categories = sent["categories"] as? [String] { item.categories = categories }
                items[item.id] = item
                record(item.folder, item.id, removed: false)
                return (200, json(item, full: false), "messages.patch")
            }
        }
        return (404, Self.missing, "other")
    }
}

public final class FakeGraphProtocol: URLProtocol, @unchecked Sendable {
    public override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "graph.microsoft.com" }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let server = FakeGraph.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        server.handle(request, body: body) { [weak self] status, data, type in
            guard let self, let client = self.client else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: ["Content-Type": type])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    public override func stopLoading() {}
}
