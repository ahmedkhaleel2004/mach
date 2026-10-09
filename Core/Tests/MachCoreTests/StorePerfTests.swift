import GRDB
import XCTest
@_spi(Bench) @testable import MachCore

/// Tests for the store's faster paths: each must give exactly what the plain way gives.
final class StorePerfTests: XCTestCase {
    func testStringListsReadTheSameAsTheDecoder() throws {
        let lists: [[String]] = [
            [], [""], ["INBOX"], ["INBOX", "UNREAD", "Label_12"], ["a/b", "Snoozed/2026-01-01T08:00Z"], ["quote\"inside", "back\\slash"],
            ["line\nbreak", "tab\there"], ["Zoë", "日本語", "😀 party"], ["me", "Doe, Jane", "[bracket]", "a,b", "\u{1}control"], [",", "]", "[", "\"\""],
        ]
        for list in lists {
            let stored = Store.json(list)
            XCTAssertEqual(try Store.decodeStrings(stored), list, stored)
            XCTAssertEqual(Store.strings(stored), list, stored)
        }
        // Spacing a decoder accepts, and things it rejects.
        XCTAssertEqual(try Store.decodeStrings("[ \"a\" , \"b\" ]"), ["a", "b"])
        XCTAssertEqual(try Store.decodeStrings("[\"\\u00e9\"]"), ["é"])
        for bad in ["", "[", "[\"a\"", "[1]", "{\"a\":1}", "[\"a\" \"b\"]", "nonsense"] {
            XCTAssertThrowsError(try Store.decodeStrings(bad), bad)
            XCTAssertEqual(Store.strings(bad), [], bad)
        }
    }

    private func tables(_ store: Store) throws -> [String] {
        try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM thread ORDER BY accountId, id").map { "\($0)" }
                + Row.fetchAll(db, sql: "SELECT * FROM thread_label ORDER BY accountId, labelId, threadId").map { "\($0)" }
        }
    }

    /// Rebuilding a thread writes only what changed. The outcome must be what a rebuild from nothing gives.
    func testRebuildByDifferenceMatchesRebuildFromNothing() throws {
        let store = try Store(path: NSTemporaryDirectory() + "mach-perf-\(UUID().uuidString).sqlite")
        let me = "me@x.com"
        try store.saveAccount(Account(id: me, name: "Me"))
        try store.replaceLabels([MailLabel(accountId: me, id: "Label_1", name: "Work", type: "user"),
                                 MailLabel(accountId: me, id: "Label_2", name: SystemLabel.snoozeLabelName(until: 4_000_000_000_000), type: "user")], account: me)
        var messages: [Message] = []
        for index in 0..<40 {
            let labels = [["INBOX", "UNREAD"], ["INBOX", "CATEGORY_PROMOTIONS"], ["SENT"], ["Label_1"], ["INBOX", "STARRED", "Label_1"], ["TRASH"], ["DRAFT"], ["Label_2"]][index % 8]
            messages.append(message("m\(index)", thread: "t\(index % 25)", labels: labels, date: Int64(1000 + index)))
        }
        try store.saveMessages(account: me, messages: messages)
        let threads = (0..<25).map { "t\($0)" }
        try store.modifyThreads(account: me, threadIds: Array(threads[0..<6]), add: [], remove: ["INBOX"])
        try store.modifyThreads(account: me, threadIds: Array(threads[3..<9]), add: ["STARRED", "Label_1"], remove: ["UNREAD"])
        try store.modifyThreads(account: me, threadIds: Array(threads[8..<12]), add: [], remove: ["INBOX"], snoozeUntil: 4_100_000_000_000)
        try store.modifyThreads(account: me, threadIds: [threads[9]], add: ["INBOX"], remove: [], clearSnooze: true)
        try store.modifyThreads(account: me, threadIds: [threads[12]], add: ["INBOX"], remove: [], bump: true)
        try store.modifyThreads(account: me, threadIds: [threads[13]], add: ["TRASH"], remove: ["INBOX"])
        _ = try store.applyLabelChanges(account: me, changes: [.init(messageId: "m14", add: ["UNREAD"], remove: ["INBOX"]), .init(messageId: "m15", add: [], remove: ["Label_2"])], deleted: ["m16", "m20"])
        try store.saveThread(account: me, threadId: "t17", messages: [])
        // Nothing to do, done twice: still the same.
        try store.modifyThreads(account: me, threadIds: threads, add: [], remove: [])
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM thread_label; DELETE FROM thread")
            for id in threads { try store.recompute(db, account: me, threadId: id) }
        }
        // Due snoozes come from the snoozed list now; the thread table must agree, at any moment asked about.
        try store.modifyThreads(account: me, threadIds: Array(threads[18..<22]), add: [], remove: ["INBOX"], snoozeUntil: 5000)
        try store.modifyThreads(account: me, threadIds: [threads[22]], add: [], remove: ["INBOX"], snoozeUntil: 1)
        XCTAssertEqual(try store.dueSnoozes(account: me), try store.pool.read {
            try String.fetchAll($0, sql: "SELECT id FROM thread WHERE accountId = ? AND snoozedUntil IS NOT NULL AND snoozedUntil <= ?", arguments: [me, Store.now()])
        })
        XCTAssertGreaterThanOrEqual(try store.dueSnoozes(account: me).count, 3)
        XCTAssertEqual(try store.dueSnoozes(account: "nobody@x.com"), [])
        let incremental = try tables(store)
        XCTAssertEqual(try tables(store), incremental)
        XCTAssertFalse(incremental.isEmpty)
        // The lookup of a thread's lists must use the index made for it, not walk the account's rows.
        let plan = try store.pool.read { try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN SELECT labelId, sortDate FROM thread_label WHERE accountId = ? AND threadId = ?", arguments: [me, "t1"]).map { $0["detail"] as String } }
        XCTAssertTrue(plan.joined().contains("thread_label_thread"), plan.joined())
    }

    /// The hand-written whitespace steps of `HTMLText.strip` against the patterns they replaced.
    func testStripMatchesThePatternVersion() {
        let pieces = ["<p>", "</p>", "<br>", "<BR/>", "<div class=\"a\">", "</div>", "<style>p{color:red}</style>", "<STYLE type=x>\n.a{}\n</style>", "<script>if(a<b){}</script>",
                      "<head><title>T</title></head>", "<header>", "</tr>", "</li>", "</h3>", "<a href=\"x>y\">", "<", ">", "<>", "< b>", "<style>never closed", "</style>",
                      " ", "  ", "\t", "\n", "\r\n", "\n\n\n", "\u{00A0}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2028}", "\u{2029}", "\u{3000}", "\u{2003}", "\u{000B}", "\u{000C}", "\u{0085}", "\u{1680}", "\u{202F}", "\u{205F}",
                      "&nbsp;", "&amp;", "&lt;b&gt;", "&#10;", "&#x20;", "&#32;", "&#xA0;", "&#9;", "&#13;", "&bogus;", "&", "&#x110000;", "&zwnj;", "&#8203;",
                      "word", "Zoë", "日本語", "😀", "e\u{301}", "\u{1F1E8}\u{1F1E6}", "a", "b c"]
        var state: UInt64 = 42
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        var checked = 0
        for round in 0..<4000 {
            var html = ""
            for _ in 0..<(1 + next(round % 7 == 0 ? 400 : 30)) { html += pieces[next(pieces.count)] }
            for limit in [40_000, 7, 1] {
                XCTAssertEqual(HTMLText.strip(html, limit: limit).debugDescription, HTMLText.stripReference(html, limit: limit).debugDescription, html.debugDescription)
                checked += 1
            }
        }
        for whole in ["", " ", "\n", "<br>", "plain", String(repeating: "é ", count: 50_000), String(repeating: "<p>x &amp; y</p>\n ", count: 30_000), String(repeating: "😀", count: 300_000)] {
            XCTAssertEqual(HTMLText.strip(whole), HTMLText.stripReference(whole))
            XCTAssertEqual(HTMLText.strip(whole, limit: 100), HTMLText.stripReference(whole, limit: 100))
        }
        let whitespace = try! NSRegularExpression(pattern: "\\s")
        // Every UTF-16 unit by itself between two words and next to a line break: settles which ones count as whitespace.
        for unit in UInt16(0)...UInt16(0xFFFF) where !(0xD800...0xDFFF).contains(unit) {
            let character = String(decoding: [unit], as: UTF16.self)
            for html in ["a" + character + "b", "a" + character + "\n" + character + "b", character + "a" + character] {
                XCTAssertEqual(HTMLText.strip(html), HTMLText.stripReference(html), "U+" + String(unit, radix: 16))
            }
            XCTAssertEqual(HTMLText.isSpace(unit), whitespace.firstMatch(in: character, range: NSRange(location: 0, length: 1)) != nil, "U+" + String(unit, radix: 16))
        }
        XCTAssertGreaterThan(checked, 10_000)
    }

    /// Search has two ways to find the newest matching threads. They must agree, ties and all.
    func testSearchWalkMatchesPlainQuery() throws {
        let store = try Store(path: NSTemporaryDirectory() + "mach-perf-\(UUID().uuidString).sqlite")
        let accounts = ["me@x.com", "other@x.com"]
        var state: UInt64 = 7
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let words = ["apple", "apricot", "banana", "blueberry", "cherry", "cranberry", "date", "elderberry"]
        for (order, account) in accounts.enumerated() {
            try store.saveAccount(Account(id: account, name: "A", sortOrder: order))
            var messages: [Message] = []
            for index in 0..<600 {
                var one = message("m\(order)-\(index)", thread: "t\(order)-\(next(260))", labels: [["INBOX"], ["SENT"], ["TRASH"], ["DRAFT"]][next(4)],
                                  // Only twelve different dates, so most threads tie with many others.
                                  date: Int64(1000 + next(12)), body: (0..<(1 + next(3))).map { _ in words[next(words.count)] }.joined(separator: " "))
                one.accountId = account
                messages.append(one)
            }
            // In several batches and out of order, so row order is not date order.
            for start in stride(from: 0, to: messages.count, by: 97) { try store.saveMessages(account: account, messages: Array(messages[start..<min(start + 97, messages.count)])) }
        }
        _ = try store.applyLabelChanges(account: accounts[0], changes: [], deleted: (0..<40).map { "m0-\($0 * 7)" })
        let walkAbove = Store.searchNewestFirstAbove, budget = Store.searchWalkBudget
        defer { Store.searchNewestFirstAbove = walkAbove; Store.searchWalkBudget = budget }
        var compared = 0
        for text in ["a", "ap", "apple", "b", "c", "cherry", "date", "e", "apple banana", "a b", "hello", "bob", "nothing"] {
            for account in [nil, accounts[0], accounts[1]] as [String?] {
                for limit in [1, 2, 5, 37, 200, 10_000] {
                    Store.searchNewestFirstAbove = .max
                    let plain = try store.search(account: account, text: text, limit: limit)
                    Store.searchNewestFirstAbove = 1
                    XCTAssertEqual(try store.search(account: account, text: text, limit: limit).map { $0.accountId + $0.id }, plain.map { $0.accountId + $0.id }, "\(text) \(account ?? "all") \(limit)")
                    XCTAssertEqual(try store.search(account: account, text: text, limit: limit), plain)
                    // Giving up half-way must fall back to the plain query, not return half an answer.
                    Store.searchWalkBudget = 50
                    XCTAssertEqual(try store.search(account: account, text: text, limit: limit), plain)
                    Store.searchWalkBudget = budget
                    compared += plain.count
                }
            }
        }
        XCTAssertGreaterThan(compared, 5000)
    }

    /// What the app relies on: the list comes round after every change the user makes, even one that alters nothing,
    /// while the open conversation and the counts stay quiet when a write does not concern them.
    func testObservationsRefreshWhenTheyShould() async throws {
        let store = try Store(path: NSTemporaryDirectory() + "mach-perf-\(UUID().uuidString).sqlite")
        let me = "me@x.com"
        try store.saveAccount(Account(id: me, name: "Me"))
        try store.saveMessages(account: me, messages: [message("m1", thread: "t1", labels: ["INBOX", "UNREAD"]), message("m2", thread: "t2", labels: ["INBOX"])])
        final class Seen<T: Sendable>: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [T] = []
            func add(_ value: T) { lock.lock(); values.append(value); lock.unlock() }
            var all: [T] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let lists = Seen<[MailThread]>(), conversations = Seen<[Message]>(), counts = Seen<[String: Int]>()
        let tasks = [
            Task { for await value in store.observeThreads(account: nil, label: SystemLabel.inbox, limit: 50) { lists.add(value) } },
            Task { for await value in store.observeMessages(account: me, threadId: "t1") { conversations.add(value) } },
            Task { for await value in store.observeUnreadCounts() { counts.add(value) } },
        ]
        defer { tasks.forEach { $0.cancel() } }
        func settle() async throws { try await Task.sleep(nanoseconds: 250_000_000) }
        try await settle()
        XCTAssertEqual(lists.all.count, 1)
        XCTAssertEqual(conversations.all.count, 1)
        XCTAssertEqual(counts.all, [[me: 1]])
        // A change that alters nothing (the thread is already in the inbox) still sends the list round.
        try store.modifyThreads(account: me, threadIds: ["t2"], add: ["INBOX"], remove: [])
        try await settle()
        XCTAssertEqual(lists.all.count, 2)
        XCTAssertEqual(lists.all.last, lists.all.first)
        // Mail for another thread: the list changes, the open conversation and the unread count do not.
        try store.saveMessages(account: me, messages: [message("m3", thread: "t3", labels: ["INBOX"], date: 2000)])
        try await settle()
        XCTAssertEqual(lists.all.last?.map(\.id), ["t3", "t1", "t2"])
        XCTAssertEqual(conversations.all.count, 1)
        XCTAssertEqual(counts.all.count, 1)
        // A change to the open conversation reaches all three.
        try store.modifyThreads(account: me, threadIds: ["t1"], add: [], remove: ["UNREAD"])
        try await settle()
        XCTAssertEqual(conversations.all.count, 2)
        XCTAssertEqual(conversations.all.last?.first?.isUnread, false)
        XCTAssertEqual(counts.all.last, [:])
        XCTAssertEqual(lists.all.last?.first { $0.id == "t1" }?.unread, false)
    }
}
