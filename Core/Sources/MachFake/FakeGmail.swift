import Foundation

/// A pretend Gmail for benchmarks and tests. Nothing here touches the network: `FakeGmailProtocol` answers the
/// requests `GmailAPI` makes, from a made-up mailbox held in memory, after a fixed delay that stands in for the
/// round trip. Every request is logged so a benchmark can count round trips, units and bytes.
public final class FakeGmail: @unchecked Sendable {
    public struct Call: Sendable {
        public let start: Double
        public let end: Double
        public let method: String
        /// The kind of request: `history`, `messages.get`, `threads.get`, `messages.list`, `batchModify`, ...
        public let kind: String
        /// What the app charges its own allowance for this kind of request (see `QuotaBucket`).
        public let units: Int
        public let bytes: Int
    }

    struct Item {
        var id: String
        var threadId: String
        var labels: [String]
        var date: Int64
        var kind: Int
        var number: Int
        var replyTo: String?
    }

    public let email: String
    /// Seconds each request takes to answer.
    public var latency: Double
    /// When set, mail delivered from now on is dated from this moment (milliseconds since 1970) instead of the real time,
    /// so a test stores the same thing on every run.
    public var deliveryDate: Int64?
    /// The access token that routes requests to this server. Give it to the app's token store.
    public var token: String { "fake-" + email }

    private let idPrefix: String
    private let lock = NSLock()
    private var items: [String: Item] = [:]
    /// Oldest first.
    private var order: [String] = []
    private var history: [(id: Int, json: String)] = []
    private var historyCounter = 1000
    private var counter = 0
    private var log: [Call] = []
    /// How many times each message's full content was sent out, and how big it was.
    private var served: [String: (times: Int, bytes: Int)] = [:]
    private var labels: [(id: String, name: String, type: String)] = [
        ("INBOX", "INBOX", "system"), ("UNREAD", "UNREAD", "system"), ("SENT", "SENT", "system"), ("STARRED", "STARRED", "system"),
        ("DRAFT", "DRAFT", "system"), ("TRASH", "TRASH", "system"), ("SPAM", "SPAM", "system"), ("Label_7", "Receipts", "user"),
    ]
    private let queue = DispatchQueue(label: "fake.gmail", attributes: .concurrent)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: FakeGmail] = [:]

    /// `idPrefix` starts every message id. Give each server its own when several fill the same database.
    public init(email: String, latency: Double = 0.12, idPrefix: String = "m") {
        self.email = email
        self.latency = latency
        self.idPrefix = idPrefix
        Self.registryLock.withLock { Self.registry[token] = self }
    }

    public func close() {
        Self.registryLock.withLock { Self.registry[token] = nil }
    }

    static func server(for request: URLRequest) -> FakeGmail? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else { return nil }
        return registryLock.withLock { registry[String(header.dropFirst(7))] }
    }

    // MARK: - Filling the mailbox

    /// The kinds of mail the fake hands out. The sizes are those of real mail: most of a message is its HTML.
    public enum Kind: Int, CaseIterable, Sendable {
        /// A short plain-text note.
        case plain = 0
        /// A reply in a conversation: text and 8 KB of HTML, with References.
        case reply = 1
        /// A 150 KB HTML newsletter with encoded-word headers.
        case newsletter = 2
        /// 20 KB of HTML, an inline picture and five attachments of about 1 MB each (metadata only, as Gmail sends it).
        case attachments = 3
        /// 40 KB of HTML in windows-1252 with Q-encoded headers.
        case latin = 4
        /// A 60 KB HTML notification.
        case medium = 5
    }

    /// Adds mail that was "always there": no change-log entries. Returns the ids, oldest first.
    /// Conversations alternate between mail from someone else (in the inbox) and replies sent from here.
    @discardableResult
    /// `conversations` is the share (in percent) of inbox items that are conversations rather than single messages;
    /// 9 gives about a quarter of all messages in conversations, as measured on a real mailbox.
    public func seed(inbox: Int, archived: Int = 0, seed: UInt64 = 7, conversations: Int = 9) -> [String] {
        var random = seed
        func next(_ bound: Int) -> Int {
            random &+= 0x9E37_79B9_7F4A_7C15
            var z = random
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(max(bound, 1)))
        }
        return lock.withLock {
            var made: [String] = []
            var date: Int64 = 1_750_000_000_000
            func add(kind: Kind, thread: String?, labels: [String], replyTo: String?) -> Item {
                counter += 1
                date += Int64(60_000 + next(600_000))
                let id = idPrefix + String(format: "%07x", counter)
                let item = Item(id: id, threadId: thread ?? id, labels: labels, date: date, kind: kind.rawValue, number: counter, replyTo: replyTo)
                items[id] = item
                order.append(id)
                made.append(id)
                return item
            }
            // Archived mail is the older part of the mailbox.
            var left = archived
            while left > 0 {
                let roll = next(100)
                let kind: Kind = roll < 30 ? .plain : roll < 55 ? .medium : roll < 80 ? .newsletter : roll < 90 ? .latin : .attachments
                _ = add(kind: kind, thread: nil, labels: ["CATEGORY_UPDATES"], replyTo: nil)
                left -= 1
            }
            left = inbox
            while left > 0 {
                let roll = next(100)
                if roll < conversations {
                    // A conversation of 2 to 6 messages; every other one was sent from here.
                    let length = 2 + [0, 0, 0, 1, 1, 2, 4][next(7)]
                    var first: Item?
                    var previous: Item?
                    for index in 0..<length {
                        let mine = index % 2 == 1
                        let item = add(kind: index == 0 ? .plain : .reply, thread: first?.id, labels: mine ? ["SENT"] : ["INBOX", "CATEGORY_PERSONAL"], replyTo: previous?.id)
                        if first == nil { first = item }
                        previous = item
                        if !mine { left -= 1 }
                    }
                } else {
                    let kind: Kind = roll < 40 ? .plain : roll < 62 ? .medium : roll < 85 ? .newsletter : roll < 93 ? .latin : .attachments
                    let category = kind == .plain ? "CATEGORY_PERSONAL" : (roll % 2 == 0 ? "CATEGORY_PROMOTIONS" : "CATEGORY_UPDATES")
                    _ = add(kind: kind, thread: nil, labels: ["INBOX", category] + (next(4) == 0 ? ["UNREAD"] : []), replyTo: nil)
                    left -= 1
                }
            }
            return made
        }
    }

    /// New mail arriving now: goes into the mailbox and the change log, the way a delivery does. Returns the ids.
    @discardableResult
    public func deliver(_ count: Int, kind: Kind = .medium, inThread thread: String? = nil) -> [String] {
        lock.withLock {
            var made: [String] = []
            for _ in 0..<count {
                counter += 1
                let id = idPrefix + String(format: "%07x", counter)
                let date = max((order.last.flatMap { items[$0]?.date } ?? 0) + 1, deliveryDate ?? Int64(Date().timeIntervalSince1970 * 1000))
                let item = Item(id: id, threadId: thread ?? id, labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], date: date, kind: kind.rawValue, number: counter,
                                replyTo: thread.flatMap { t in order.last { items[$0]?.threadId == t } })
                items[id] = item
                order.append(id)
                made.append(id)
                historyCounter += 1
                let ref = "{\"id\":\"\(id)\",\"threadId\":\"\(item.threadId)\",\"labelIds\":\(Self.array(item.labels))}"
                history.append((historyCounter, "{\"id\":\"\(historyCounter)\",\"messages\":[{\"id\":\"\(id)\",\"threadId\":\"\(item.threadId)\"}],\"messagesAdded\":[{\"message\":\(ref)}]}"))
            }
            return made
        }
    }

    /// A label change made somewhere else (another device, a filter): changes the mailbox and the change log.
    public func changeLabels(messageIds: [String], add: [String], remove: [String]) {
        lock.withLock { applyLabels(messageIds: messageIds, add: add, remove: remove) }
    }

    /// A message deleted for good somewhere else.
    public func delete(messageId: String) {
        lock.withLock {
            guard let item = items.removeValue(forKey: messageId) else { return }
            order.removeAll { $0 == messageId }
            historyCounter += 1
            history.append((historyCounter, "{\"id\":\"\(historyCounter)\",\"messagesDeleted\":[{\"message\":{\"id\":\"\(item.id)\",\"threadId\":\"\(item.threadId)\"}}]}"))
        }
    }

    private func applyLabels(messageIds: [String], add: [String], remove: [String]) {
        for id in messageIds {
            guard var item = items[id] else { continue }
            let before = item.labels
            item.labels.removeAll { remove.contains($0) }
            for label in add where !item.labels.contains(label) { item.labels.append(label) }
            items[id] = item
            let ref = "{\"id\":\"\(id)\",\"threadId\":\"\(item.threadId)\",\"labelIds\":\(Self.array(item.labels))}"
            let added = add.filter { !before.contains($0) }
            let removed = remove.filter { before.contains($0) }
            if !added.isEmpty {
                historyCounter += 1
                history.append((historyCounter, "{\"id\":\"\(historyCounter)\",\"labelsAdded\":[{\"message\":\(ref),\"labelIds\":\(Self.array(added))}]}"))
            }
            if !removed.isEmpty {
                historyCounter += 1
                history.append((historyCounter, "{\"id\":\"\(historyCounter)\",\"labelsRemoved\":[{\"message\":\(ref),\"labelIds\":\(Self.array(removed))}]}"))
            }
        }
    }

    public var historyId: String { lock.withLock { String(historyCounter) } }
    public func labels(of id: String) -> [String]? { lock.withLock { items[id]?.labels } }
    public func threadId(of id: String) -> String? { lock.withLock { items[id]?.threadId } }
    public var messageCount: Int { lock.withLock { order.count } }

    // MARK: - The request log

    public var calls: [Call] { lock.withLock { log } }
    public func resetLog() { lock.withLock { log = []; served = [:] } }

    /// Message contents sent out more than once: how many repeats, and their bytes. Pure waste.
    public var repeats: (messages: Int, bytes: Int) {
        lock.withLock {
            served.values.reduce(into: (0, 0)) { total, entry in
                total.0 += entry.times - 1
                total.1 += (entry.times - 1) * entry.bytes
            }
        }
    }

    /// How many different messages had their content sent out.
    public var distinctServed: Int { lock.withLock { served.count } }

    public struct Summary: Sendable {
        public var requests = 0
        public var units = 0
        public var bytes = 0
        /// How many requests had to wait for an earlier answer: groups of requests that started together.
        public var rounds = 0
        public var byKind: [String: Int] = [:]
    }

    /// Totals for the log. Requests that start within half a round trip of each other count as one round.
    public func summary() -> Summary {
        let calls = self.calls.sorted { $0.start < $1.start }
        var summary = Summary()
        var roundStart = -Double.infinity
        for call in calls {
            summary.requests += 1
            summary.units += call.units
            summary.bytes += call.bytes
            summary.byKind[call.kind, default: 0] += 1
            if call.start - roundStart > max(latency / 2, 0.0005) {
                summary.rounds += 1
                roundStart = call.start
            }
        }
        return summary
    }

    // MARK: - Answering

    fileprivate func handle(_ request: URLRequest, body: Data, reply: @escaping @Sendable (Int, Data) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        let (status, data, kind, units) = lock.withLock { answer(request, body: body) }
        let method = request.httpMethod ?? "GET"
        // A strict timer: the plain delayed dispatch is allowed to run several milliseconds late, which would count as our own slowness.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + latency, leeway: .nanoseconds(0))
        timer.setEventHandler {
            timer.cancel()
            self.lock.withLock { self.log.append(Call(start: start, end: ProcessInfo.processInfo.systemUptime, method: method, kind: kind, units: units, bytes: data.count)) }
            reply(status, data)
        }
        timer.resume()
    }

    private static let notFound = Data("{\"error\":{\"code\":404,\"message\":\"Requested entity was not found.\",\"errors\":[{\"message\":\"Requested entity was not found.\",\"domain\":\"global\",\"reason\":\"notFound\"}],\"status\":\"NOT_FOUND\"}}".utf8)

    private func answer(_ request: URLRequest, body: Data) -> (Int, Data, String, Int) {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (400, Data(), "bad", 0) }
        let path = components.path.replacingOccurrences(of: "/gmail/v1/users/me", with: "")
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let method = request.httpMethod ?? "GET"
        let parts = path.split(separator: "/").map(String.init)

        if method == "GET", path == "/profile" {
            return (200, Data("{\"emailAddress\":\"\(email)\",\"messagesTotal\":\(order.count),\"threadsTotal\":\(order.count),\"historyId\":\"\(historyCounter)\"}".utf8), "profile", 1)
        }
        if method == "GET", path == "/labels" {
            let list = labels.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"type\":\"\($0.type)\"}" }.joined(separator: ",")
            return (200, Data("{\"labels\":[\(list)]}".utf8), "labels", 1)
        }
        if method == "POST", path == "/labels" {
            let name = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["name"] as? String ?? "label"
            let id = "Label_\(100 + labels.count)"
            labels.append((id, name, "user"))
            return (200, Data("{\"id\":\"\(id)\",\"name\":\(Self.quoted(name)),\"type\":\"user\"}".utf8), "labels.create", 5)
        }
        if method == "GET", path == "/settings/sendAs" {
            return (200, Data("{\"sendAs\":[{\"sendAsEmail\":\"\(email)\",\"displayName\":\"Bench Person\",\"signature\":\"\",\"isPrimary\":true}]}".utf8), "sendAs", 1)
        }
        if method == "GET", path == "/history" {
            let since = Int(value("startHistoryId") ?? "") ?? 0
            let records = history.filter { $0.id > since }.map(\.json).joined(separator: ",")
            let list = records.isEmpty ? "" : "\"history\":[\(records)],"
            return (200, Data("{\(list)\"historyId\":\"\(historyCounter)\"}".utf8), "history", 2)
        }
        if method == "GET", path == "/messages" {
            let wanted = query.filter { $0.name == "labelIds" }.compactMap(\.value)
            let q = value("q") ?? ""
            let max = Int(value("maxResults") ?? "") ?? 100
            let offset = Int(value("pageToken") ?? "") ?? 0
            var matching: [Item] = []
            if q.isEmpty || q == "-in:spam -in:trash" {
                for id in order.reversed() {
                    guard let item = items[id], wanted.allSatisfy({ item.labels.contains($0) }) else { continue }
                    matching.append(item)
                }
            }
            let page = matching.dropFirst(offset).prefix(max)
            let refs = page.map { "{\"id\":\"\($0.id)\",\"threadId\":\"\($0.threadId)\"}" }.joined(separator: ",")
            let more = offset + page.count < matching.count ? ",\"nextPageToken\":\"\(offset + page.count)\"" : ""
            return (200, Data("{\"messages\":[\(refs)]\(more),\"resultSizeEstimate\":\(matching.count)}".utf8), "messages.list", 5)
        }
        if method == "GET", parts.count == 2, parts[0] == "messages" {
            guard let item = items[parts[1]] else { return (404, Self.notFound, "messages.get", 20) }
            return (200, messageJSON(item), "messages.get", 20)
        }
        if method == "GET", parts.count == 2, parts[0] == "threads" {
            let members = order.compactMap { items[$0] }.filter { $0.threadId == parts[1] }
            guard !members.isEmpty else { return (404, Self.notFound, "threads.get", 40) }
            var data = Data("{\"id\":\"\(parts[1])\",\"historyId\":\"\(historyCounter)\",\"messages\":[".utf8)
            for (index, item) in members.enumerated() {
                if index > 0 { data.append(UInt8(ascii: ",")) }
                data.append(messageJSON(item))
            }
            data.append(Data("]}".utf8))
            return (200, data, "threads.get", 40)
        }
        if method == "POST", parts.count == 3, parts[0] == "threads", parts[2] == "modify" {
            let object = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
            let ids = order.filter { items[$0]?.threadId == parts[1] }
            guard !ids.isEmpty else { return (404, Self.notFound, "threads.modify", 10) }
            applyLabels(messageIds: ids, add: object["addLabelIds"] as? [String] ?? [], remove: object["removeLabelIds"] as? [String] ?? [])
            return (200, Data("{\"id\":\"\(parts[1])\"}".utf8), "threads.modify", 10)
        }
        if method == "POST", path == "/messages/batchModify" {
            let object = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
            applyLabels(messageIds: object["ids"] as? [String] ?? [], add: object["addLabelIds"] as? [String] ?? [], remove: object["removeLabelIds"] as? [String] ?? [])
            return (204, Data(), "batchModify", 50)
        }
        return (404, Self.notFound, "unknown", 0)
    }

    // MARK: - Building answers

    private static func array(_ values: [String]) -> String { "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]" }

    private static func quoted(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [text]))?.dropFirst().dropLast() ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static let words = ["quarterly", "update", "invoice", "your", "order", "has", "shipped", "meeting", "notes", "from", "the", "team", "please", "review",
                                "attached", "thanks", "launch", "plan", "for", "next", "week", "reminder", "account", "summary", "new", "features", "available", "now"]

    private static func prose(_ bytes: Int, seed: Int) -> String {
        var out = ""
        var index = seed
        while out.utf8.count < bytes {
            out += words[index % words.count] + (index % 11 == 10 ? ".\n" : " ")
            index = index &* 31 &+ 7
            if index < 0 { index = -index }
        }
        return out
    }

    /// HTML the shape of a marketing mail: a style block, nested tables, long tracking links, entities.
    public static func html(_ bytes: Int, seed: Int = 1) -> String {
        var out = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Update</title><style type=\"text/css\">body{margin:0;padding:0;-webkit-text-size-adjust:100%}table{border-collapse:collapse}.btn{background:#1a73e8;color:#fff;padding:12px 24px;border-radius:4px}@media only screen and (max-width:600px){.col{width:100%!important;display:block!important}}</style></head><body style=\"margin:0;background:#f6f6f6\"><div style=\"display:none;max-height:0;overflow:hidden\">Preview text&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;</div><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tbody>"
        var index = seed
        while out.utf8.count < bytes {
            index += 1
            out += "<tr><td class=\"col\" style=\"padding:16px 24px;font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:22px;color:#202124\"><h2 style=\"margin:0 0 8px\">Section \(index) &mdash; what&rsquo;s new</h2><p style=\"margin:0 0 12px\">\(prose(220, seed: index).replacingOccurrences(of: "\n", with: "<br>"))&nbsp;&amp; more &#8217;til Friday.</p><a class=\"btn\" href=\"https://click.example.com/track/c/eJwUzk\(index)sKwjAQheGnSZYhM5k0ySILQXwNmUvaSi+SVnx96e7w8cN58M4T39oc21tfrRccEIo66R1jtQ2M0AIMwQbKmLLPkKM+WR/8k2MtNQKSOWRmEgoU6iDKGAvVVrfb/bqCqJjG8v6qj3L96oN95/9v0AAA__8nYSpu/\(index)?utm_source=newsletter&utm_medium=email&utm_campaign=q\(index % 4)\" target=\"_blank\">Read more</a><img src=\"https://images.example.com/hero/\(index).png\" width=\"552\" height=\"180\" alt=\"\" style=\"display:block;border:0\"></td></tr>"
        }
        return out + "</tbody></table><p style=\"font-size:11px;color:#888\">&copy; 2026 Example Inc. &bull; <a href=\"https://example.com/unsubscribe\">Unsubscribe</a></p></body></html>"
    }

    private static func header(_ name: String, _ value: String) -> String { "{\"name\":\"\(name)\",\"value\":\(quoted(value))}" }

    /// The headers every delivered message carries, whoever sent it. Real mail has about this much of them.
    private static let transportHeaders: String = [
        header("Delivered-To", "bench@example.com"),
        header("Received", "by 2002:a05:7300:a48f:b0:17c:5f5a:8f3d with SMTP id x15csp1234567dyb; Thu, 8 Oct 2026 06:12:44 -0700 (PDT)"),
        header("X-Google-Smtp-Source", "AGHT+IFq1xN0bXkq3p8yWm2Tt5cVd6rJ9uLhGz4sKe7aYo1iPw3nRf5mQb8cXv2lZj6tUk0hDg4sAy=="),
        header("X-Received", "by 2002:a17:90b:3a8c:b0:2e2:c6a1:7f3b with SMTP id om12-20020a17090b3a8c00b002e2c6a17f3bmr2345678pjb.12.1728393164123; Thu, 08 Oct 2026 06:12:44 -0700 (PDT)"),
        header("ARC-Seal", "i=1; a=rsa-sha256; t=1728393164; cv=none; d=google.com; s=arc-20240605; b=Qm9ndXNTaWduYXR1cmVCeXRlc0ZvckJlbmNobWFya2luZ09ubHlOb3RSZWFsQXRBbGxKdXN0UGFkZGluZ1RvTWFrZUl0TG9uZ0Vub3VnaFRvTG9va0xpa2VUaGVSZWFsVGhpbmdXaGljaElzQWJvdXRUaHJlZUh1bmRyZWRDaGFyYWN0ZXJz+abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ=="),
        header("ARC-Message-Signature", "i=1; a=rsa-sha256; c=relaxed/relaxed; d=google.com; s=arc-20240605; h=list-unsubscribe:mime-version:subject:message-id:to:reply-to:from:date:dkim-signature; bh=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=; fh=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQ=; b=Qm9ndXNTaWduYXR1cmVCeXRlc0ZvckJlbmNobWFya2luZ09ubHlOb3RSZWFsQXRBbGxKdXN0UGFkZGluZ1RvTWFrZUl0TG9uZ0Vub3VnaA=="),
        header("ARC-Authentication-Results", "i=1; mx.google.com; dkim=pass header.i=@example.org header.s=s1 header.b=AbCdEfGh; spf=pass (google.com: domain of bounce@mail.example.org designates 192.0.2.44 as permitted sender) smtp.mailfrom=bounce@mail.example.org; dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=example.org"),
        header("Return-Path", "<bounce+abc123=bench=example.com@mail.example.org>"),
        header("Received", "from mta-44.mail.example.org (mta-44.mail.example.org. [192.0.2.44]) by mx.google.com with ESMTPS id d9443c01a7336-20c1396a1e2si12345675ad.123.2026.10.08.06.12.43 for <bench@example.com> (version=TLS1_3 cipher=TLS_AES_256_GCM_SHA384 bits=256/256); Thu, 08 Oct 2026 06:12:44 -0700 (PDT)"),
        header("Received-SPF", "pass (google.com: domain of bounce@mail.example.org designates 192.0.2.44 as permitted sender) client-ip=192.0.2.44;"),
        header("Authentication-Results", "mx.google.com; dkim=pass header.i=@example.org header.s=s1 header.b=AbCdEfGh; spf=pass (google.com: domain of bounce@mail.example.org designates 192.0.2.44 as permitted sender) smtp.mailfrom=bounce@mail.example.org; dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=example.org"),
        header("DKIM-Signature", "v=1; a=rsa-sha256; c=relaxed/relaxed; d=example.org; s=s1; t=1728393163; h=from:reply-to:to:subject:mime-version:content-type:list-unsubscribe:message-id:date; bh=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=; b=Qm9ndXNTaWduYXR1cmVCeXRlc0ZvckJlbmNobWFya2luZ09ubHlOb3RSZWFsQXRBbGxKdXN0UGFkZGluZ1RvTWFrZUl0TG9uZ0Vub3VnaFRvTG9va0xpa2VUaGVSZWFsVGhpbmc="),
        header("Date", "Thu, 08 Oct 2026 13:12:43 +0000"),
        header("MIME-Version", "1.0"),
        header("List-Unsubscribe", "<https://example.org/unsubscribe/abc123def456>, <mailto:unsubscribe@example.org?subject=unsubscribe>"),
        header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click"),
        header("X-Feedback-ID", "1234567:example:campaign:q4"),
        header("To", "Bench Person <bench@example.com>"),
    ].joined(separator: ",")

    private static func textPart(_ mime: String, charset: String, _ data: Data) -> String {
        "{\"partId\":\"0\",\"mimeType\":\"\(mime)\",\"filename\":\"\",\"headers\":[\(header("Content-Type", "\(mime); charset=\"\(charset)\"")),\(header("Content-Transfer-Encoding", "quoted-printable"))],\"body\":{\"size\":\(data.count),\"data\":\"\(base64url(data))\"}}"
    }

    private static func alternative(text: Data, html: Data, charset: String = "UTF-8") -> String {
        "{\"partId\":\"\",\"mimeType\":\"multipart/alternative\",\"filename\":\"\",\"headers\":[\(header("Content-Type", "multipart/alternative; boundary=\"000000000000a1b2c3061f2e4d5a\""))],\"body\":{\"size\":0},\"parts\":[\(textPart("text/plain", charset: charset, text)),\(textPart("text/html", charset: charset, html))]}"
    }

    /// Everything after the headers of the top part, per kind. Built once: the body is the same for every message of a kind.
    private static let bodies: [Int: (mime: String, rest: String, snippet: String)] = {
        var out: [Int: (String, String, String)] = [:]
        let note = Data(prose(900, seed: 3).utf8)
        out[Kind.plain.rawValue] = ("text/plain", "\"body\":{\"size\":\(note.count),\"data\":\"\(base64url(note))\"}", "quarterly update invoice your order has shipped")
        func alt(_ htmlBytes: Int, seed: Int) -> String {
            let inner = alternative(text: Data(prose(max(600, htmlBytes / 30), seed: seed).utf8), html: Data(html(htmlBytes, seed: seed).utf8))
            // Gmail repeats the multipart's own parts under the top payload.
            return "\"body\":{\"size\":0},\"parts\":" + String(inner[inner.range(of: "\"parts\":")!.upperBound...].dropLast())
        }
        out[Kind.reply.rawValue] = ("multipart/alternative", alt(8_000, seed: 5), "thanks &amp; see you then")
        out[Kind.newsletter.rawValue] = ("multipart/alternative", alt(150_000, seed: 9), "Preview text &nbsp;&zwnj; what&#39;s new this week")
        out[Kind.medium.rawValue] = ("multipart/alternative", alt(60_000, seed: 13), "Your order has shipped &mdash; track it")
        let latinText = prose(2_000, seed: 17) + " caf\u{E9} na\u{EF}ve \u{2019}quoted\u{2019} \u{20AC}5"
        let latinHTML = html(40_000, seed: 17).replacingOccurrences(of: "utf-8", with: "windows-1252") + "<p>caf\u{E9} na\u{EF}ve \u{20AC}5</p>"
        let latin = alternative(text: latinText.data(using: .windowsCP1252)!, html: latinHTML.data(using: .windowsCP1252)!, charset: "windows-1252")
        out[Kind.latin.rawValue] = ("multipart/alternative", "\"body\":{\"size\":0},\"parts\":" + String(latin[latin.range(of: "\"parts\":")!.upperBound...].dropLast()), "caf\u{E9} na\u{EF}ve")
        var mixed = [alternative(text: Data(prose(1_200, seed: 21).utf8), html: Data(html(20_000, seed: 21).utf8))]
        let longId = String(repeating: "ANGjdJ8wQm9ndXNBdHRhY2htZW50SWRGb3JCZW5jaG1hcmtz", count: 8)
        mixed.append("{\"partId\":\"1\",\"mimeType\":\"image/png\",\"filename\":\"logo.png\",\"headers\":[\(header("Content-Type", "image/png; name=\"logo.png\"")),\(header("Content-Disposition", "inline; filename=\"logo.png\"")),\(header("Content-Transfer-Encoding", "base64")),\(header("Content-ID", "<logo@bench>")),\(header("X-Attachment-Id", "logo@bench"))],\"body\":{\"attachmentId\":\"\(longId)0\",\"size\":48211}}")
        for index in 1...5 {
            let name = index == 2 ? "=?UTF-8?B?UmFwcG9ydCBmaW5hbmNpZXIgw6l0w6kgMjAyNi5wZGY=?=" : "Quarterly report \(index).pdf"
            mixed.append("{\"partId\":\"\(index + 1)\",\"mimeType\":\"application/pdf\",\"filename\":\(quoted(name)),\"headers\":[\(header("Content-Type", "application/pdf; name=\"\(name)\"")),\(header("Content-Disposition", "attachment; filename=\"\(name)\"")),\(header("Content-Transfer-Encoding", "base64")),\(header("X-Attachment-Id", "f_m\(index)abc"))],\"body\":{\"attachmentId\":\"\(longId)\(index)\",\"size\":\(1_048_576 + index * 1000)}}")
        }
        out[Kind.attachments.rawValue] = ("multipart/mixed", "\"body\":{\"size\":0},\"parts\":[\(mixed.joined(separator: ","))]", "Reports attached")
        return out
    }()

    /// One `messages.get?format=full` answer.
    func messageJSON(_ item: Item) -> Data {
        let data = buildMessageJSON(item)
        served[item.id] = ((served[item.id]?.times ?? 0) + 1, data.count)
        return data
    }

    private func buildMessageJSON(_ item: Item) -> Data {
        let body = Self.bodies[item.kind]!
        let kind = Kind(rawValue: item.kind)!
        var from = "Sender \(item.number % 97) <sender\(item.number % 97)@example.org>"
        var subject = "Message number \(item.number) about the \(Self.words[item.number % Self.words.count])"
        if item.labels.contains("SENT") { from = "Bench Person <\(email)>" }
        if kind == .newsletter {
            from = "=?UTF-8?B?\(Data("Caf\u{E9} Soci\u{E9}t\u{E9} \(item.number % 13)".utf8).base64EncodedString())?= <news\(item.number % 13)@mail.example.org>"
            subject = "=?UTF-8?B?\(Data("\u{1F389} Votre r\u{E9}sum\u{E9} hebdomadaire".utf8).base64EncodedString())?= =?UTF-8?B?\(Data(" num\u{E9}ro \(item.number) \u{2014} nouveaut\u{E9}s".utf8).base64EncodedString())?="
        } else if kind == .latin {
            from = "=?iso-8859-1?Q?Jos=E9_Mu=F1oz?= <jose\(item.number % 7)@example.es>"
            subject = "=?iso-8859-1?Q?Informaci=F3n_de_su_pedido_n=FAmero_\(item.number)?="
        }
        var headers = Self.transportHeaders + "," + Self.header("From", from) + "," + Self.header("Subject", subject)
        headers += "," + Self.header("Message-ID", "<\(item.id)@mail.example.org>")
        headers += "," + Self.header("Content-Type", body.mime.hasPrefix("multipart") ? "\(body.mime); boundary=\"000000000000a1b2c3061f2e4d5a\"" : "text/plain; charset=\"UTF-8\"")
        if let replyTo = item.replyTo {
            headers += "," + Self.header("In-Reply-To", "<\(replyTo)@mail.example.org>") + "," + Self.header("References", "<\(item.threadId)@mail.example.org> <\(replyTo)@mail.example.org>")
        }
        let head = "{\"id\":\"\(item.id)\",\"threadId\":\"\(item.threadId)\",\"labelIds\":\(Self.array(item.labels)),\"snippet\":\(Self.quoted(body.snippet)),\"sizeEstimate\":\(body.rest.utf8.count),\"historyId\":\"\(historyCounter)\",\"internalDate\":\"\(item.date)\",\"payload\":{\"partId\":\"\",\"mimeType\":\"\(body.mime)\",\"filename\":\"\",\"headers\":[\(headers)],"
        var data = Data(head.utf8)
        data.append(Data(body.rest.utf8))
        data.append(Data("}}".utf8))
        return data
    }

    /// One `messages.get` answer of the given kind, for benchmarks of the decoding alone.
    public static func sampleMessage(_ kind: Kind, number: Int = 42) -> Data {
        let server = FakeGmail(email: "sample-\(UUID().uuidString)@example.com")
        defer { server.close() }
        return server.messageJSON(Item(id: "m\(number)", threadId: "t\(number)", labels: ["INBOX", "UNREAD"], date: 1_750_000_000_000, kind: kind.rawValue, number: number, replyTo: kind == .reply ? "m0" : nil))
    }
}

/// Answers `GmailAPI`'s requests from a `FakeGmail` instead of the network.
public final class FakeGmailProtocol: URLProtocol, @unchecked Sendable {
    public override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "gmail.googleapis.com" }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let server = FakeGmail.server(for: request), let url = request.url else {
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
        server.handle(request, body: body) { [weak self] status, data in
            guard let self, let client = self.client else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2", headerFields: ["Content-Type": "application/json; charset=UTF-8"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    public override func stopLoading() {}
}
