import BlitzFake
import CryptoKit
import GRDB
import XCTest
@testable import BlitzCore

/// Whole syncs against a pretend Gmail. The point of these is that speed work on the sync must not change what ends
/// up in the database: each scenario's stored result is compared with a fingerprint taken before any of that work.
final class SyncTests: XCTestCase {
    private struct Tokens: TokenStore {
        func load(account: String) -> TokenSet? { TokenSet(refreshToken: "none", accessToken: "fake-" + account, expiry: .distantFuture) }
        func save(_ tokens: TokenSet, account: String) {}
        func delete(account: String) {}
    }

    private final class Announced: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ new: [String]) { lock.withLock { ids += new } }
        var all: [String] { lock.withLock { ids } }
    }

    private let account = "sync-test@example.com"

    private func makeService() throws -> MailService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-sync-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let mail = try MailService(directory: directory, client: OAuthClient(clientId: "test", clientSecret: nil), tokens: Tokens(),
                                   transport: GmailTransport(protocolClasses: [FakeGmailProtocol.self], speedup: 5000))
        try mail.store.saveAccount(Account(id: account, name: "Test"))
        return mail
    }

    private func quiet(_ server: FakeGmail) async {
        var last = server.calls.count
        var since = Date()
        while Date().timeIntervalSince(since) < 0.4 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if server.calls.count != last {
                last = server.calls.count
                since = Date()
            }
        }
    }

    /// Syncs the way the app's regular check does, until a pass finds nothing left to fetch.
    private func settle(_ mail: MailService, _ server: FakeGmail) async {
        for _ in 0..<40 {
            await quiet(server)
            let before = server.calls.count
            await mail.sync(for: account).sync()
            await quiet(server)
            if server.calls.count - before <= 1 { return }
        }
        XCTFail("the sync never settled")
    }

    /// A fingerprint of every table, in an order that does not depend on when rows were written.
    private func fingerprint(_ store: Store) throws -> [String: String] {
        let queries: [String: String] = [
            "account": "SELECT id, name, historyId, signature FROM account ORDER BY id",
            "label": "SELECT * FROM label ORDER BY accountId, id",
            "thread": "SELECT * FROM thread ORDER BY accountId, id",
            "thread_label": "SELECT * FROM thread_label ORDER BY accountId, labelId, threadId",
            "message": "SELECT * FROM message ORDER BY accountId, id",
            "search": "SELECT m.id, f.subject, f.people, f.body FROM message m JOIN message_fts f ON f.rowid = m.rowid ORDER BY m.accountId, m.id",
            "search_count": "SELECT count(*) FROM message_fts",
            "snooze": "SELECT * FROM snooze ORDER BY accountId, threadId",
            "op": "SELECT accountId, kind, threadId, addLabels, removeLabels, draftId FROM op ORDER BY id",
            "contact": "SELECT * FROM contact ORDER BY accountId, email",
            "full_thread": "SELECT * FROM full_thread ORDER BY accountId, threadId",
            "loaded": "SELECT * FROM loaded ORDER BY accountId, key",
        ]
        return try store.pool.read { db in
            var out: [String: String] = [:]
            for (name, sql) in queries {
                var hash = SHA256()
                var rows = 0
                for row in try Row.fetchAll(db, sql: sql) {
                    rows += 1
                    for (column, value) in row { hash.update(data: Data("\(column)=\(value)\u{1F}".utf8)) }
                    hash.update(data: Data("\n".utf8))
                }
                out[name] = "\(rows):" + hash.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
            }
            return out
        }
    }

    private func check(_ actual: [String: String], _ expected: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        if expected.isEmpty {
            // Printed so a fingerprint can be recorded; a test with no expectation fails.
            print("FINGERPRINT [" + actual.keys.sorted().map { "\"\($0)\": \"\(actual[$0]!)\"" }.joined(separator: ", ") + "]")
            XCTFail("no fingerprint recorded", file: file, line: line)
            return
        }
        for name in expected.keys.sorted() {
            XCTAssertEqual(actual[name], expected[name], "table \(name) differs from the recorded result", file: file, line: line)
        }
    }

    func testFirstSyncAndBackfillStoreTheSameMailbox() async throws {
        let mail = try makeService()
        let server = FakeGmail(email: account, latency: 0.0005)
        defer { server.close() }
        server.seed(inbox: 260, archived: 150, seed: 11, conversations: 14)
        await settle(mail, server)
        let stored = try await mail.store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message") ?? 0 }
        XCTAssertGreaterThan(stored, 300)
        check(try fingerprint(mail.store), Self.firstSync)
    }

    func testChangesFromGmailStoreTheSameMailbox() async throws {
        let mail = try makeService()
        let announced = Announced()
        mail.onNewMail = { announced.add($0.map(\.id)) }
        let server = FakeGmail(email: account, latency: 0.0005)
        defer { server.close() }
        server.deliveryDate = 1_760_000_000_000
        let ids = server.seed(inbox: 60, archived: 150, seed: 5, conversations: 14)
        await settle(mail, server)
        // Old mail this device has never seen: it appears on Gmail's side without a word in the change log.
        let old = server.seed(inbox: 0, archived: 3, seed: 99)[0]
        let inbox = ids.filter { server.labels(of: $0)?.contains("INBOX") == true }
        // New mail, one of them a reply in a conversation already here.
        let fresh = server.deliver(3) + server.deliver(1, kind: .reply, inThread: server.threadId(of: inbox[10]))
        // Changes made on another device: archived, starred, marked unread, deleted for good.
        server.changeLabels(messageIds: [inbox[0], inbox[1]], add: [], remove: ["INBOX"])
        server.changeLabels(messageIds: [inbox[2]], add: ["STARRED", "UNREAD"], remove: [])
        server.delete(messageId: inbox[3])
        // A change to old mail this device never downloaded brings that mail in.
        server.changeLabels(messageIds: [old], add: ["INBOX", "UNREAD"], remove: [])
        // A change made here that Gmail has not heard of yet stays on top of what Gmail reports.
        server.latency = 0.3
        mail.modify(account: account, threadIds: [server.threadId(of: inbox[5])!], add: [SystemLabel.starred], remove: [SystemLabel.inbox])
        try await Task.sleep(nanoseconds: 50_000_000)
        server.changeLabels(messageIds: [inbox[5]], add: ["UNREAD"], remove: [])
        await mail.sync(for: account).sync()
        let during = try mail.store.message(account: account, id: inbox[5])
        XCTAssertEqual(during?.labelIds.contains(SystemLabel.inbox), false)
        XCTAssertEqual(during?.labelIds.contains(SystemLabel.starred), true)
        server.latency = 0.0005
        while try mail.store.pendingOpCount() > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        await settle(mail, server)
        XCTAssertEqual(server.labels(of: inbox[5])?.contains("INBOX"), false)
        XCTAssertNil(try mail.store.message(account: account, id: inbox[3]))
        XCTAssertNotNil(try mail.store.message(account: account, id: old))
        // New unread inbox mail is announced once each; the echo of our own change announces nothing.
        XCTAssertEqual(announced.all.sorted(), (fresh + [old]).sorted())
        check(try fingerprint(mail.store), Self.changes)
    }

    /// Every kind of message the fake hands out must turn into exactly the record it did before the speed work.
    func testRecordsAreUnchanged() throws {
        var hash = SHA256()
        for kind in FakeGmail.Kind.allCases {
            let message = try WireMessage.record(from: FakeGmail.sampleMessage(kind), accountId: account)
            let text = message.bodyText.map { String($0.prefix(40_000)) } ?? message.bodyHTML.map { HTMLText.strip($0) } ?? ""
            let fields = [message.id, message.threadId, String(message.internalDate), message.sender, message.toList, message.ccList, message.bccList, message.replyTo,
                          message.subject, message.snippet, message.labelIds.joined(separator: ","), message.messageIdHeader, message.refs, message.bodyHTML ?? "<nil>",
                          message.bodyText ?? "<nil>", text] + message.attachments.map { "\($0.filename)|\($0.mimeType)|\($0.size)|\($0.attachmentId)|\($0.contentId ?? "")|\($0.isInline)" }
            hash.update(data: Data(fields.joined(separator: "\u{1F}").utf8))
        }
        let digest = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        if Self.records.isEmpty { print("FINGERPRINT records \(digest)") }
        XCTAssertEqual(digest, Self.records)
    }

    // MARK: The fast paths must agree with the plain ones

    /// `HTMLText.strip` as it was before the byte-level tag remover, kept here to compare against.
    private enum Reference {
        static let blocks = try! NSRegularExpression(pattern: "<(style|script|head|title)\\b[^>]*>.*?</\\1>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        static let breaks = try! NSRegularExpression(pattern: "<(br|/p|/div|/tr|/li|/h[1-6])\\b[^>]*>", options: [.caseInsensitive])
        static let tags = try! NSRegularExpression(pattern: "<[^>]+>")

        static func withoutTags(_ html: String, limit: Int) -> String {
            var s = html.count > limit ? String(html.prefix(limit)) : html
            for (re, with) in [(blocks, " "), (breaks, "\n"), (tags, " ")] {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
            }
            return s
        }

        static let spaces = try! NSRegularExpression(pattern: "[ \\t\\u00a0\\u200b\\u200c\\ufeff]+")
        static let lines = try! NSRegularExpression(pattern: "\\s*\\n\\s*")
        static let entity = try! NSRegularExpression(pattern: "&(#x?[0-9a-fA-F]+|[a-zA-Z]+);")
        static let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "zwnj": "", "zwj": "",
            "rsquo": "\u{2019}", "lsquo": "\u{2018}", "rdquo": "\u{201D}", "ldquo": "\u{201C}", "mdash": "\u{2014}",
            "ndash": "\u{2013}", "hellip": "\u{2026}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "bull": "\u{2022}",
        ]

        static func squeezed(_ text: String) -> String {
            var s = text
            for (re, with) in [(spaces, " "), (lines, "\n")] {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
            }
            return s
        }

        static func decodeEntities(_ text: String) -> String {
            guard text.contains("&") else { return text }
            let ns = text as NSString
            var out = ""
            var cursor = 0
            for match in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let body = ns.substring(with: match.range(at: 1))
                var replacement: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    if let v = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(u) }
                } else if body.hasPrefix("#") {
                    if let v = UInt32(body.dropFirst()), let u = Unicode.Scalar(v) { replacement = String(u) }
                } else {
                    replacement = named[body.lowercased()]
                }
                out += replacement ?? ns.substring(with: match.range)
                cursor = match.range.location + match.range.length
            }
            out += ns.substring(from: cursor)
            return out
        }

        static func base64URL(_ string: String) -> Data? {
            var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let remainder = s.count % 4
            if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
        }
    }

    private struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(bound))
        }
    }

    func testFastTagRemovalAgreesWithThePatterns() {
        let pieces = ["<", ">", "</", "<br", "<BR/>", "<br >", "<bro>", "<br-x>", "</p>", "</P >", "</pre>", "</div>", "</DIV\n>", "</tr>", "</li>", "</h1>", "</H6 x>", "</h7>", "</h12>",
                      "<style>", "<STYLE type=\"a>b\">", "</style>", "</Style>", "</style >", "<styles>", "<script>", "</script>", "<head>", "<header>", "</head>", "<title>", "</title>",
                      "<>", "< >", "<a href=\"x\">", "</a>", "<p>", "<div class='c'>", "text", " ", "\n", "\r\n", "\t", "&amp;", "&nbsp;", "é", "<é>", "<\u{17F}tyle>", "</\u{17F}tyle>",
                      "<br\u{301}>", "<style\u{E9}>", "\u{1F389}", "\u{200B}", "a<b", "1 > 0", "<!-- c -->", "<![CDATA[", "]]>", "p{color:red}", "<h1>", "<tr><td>", "_", "<br_>", "<br1>"]
        var random = Random(state: 42)
        var inputs = FakeGmail.Kind.allCases.compactMap { try? WireMessage.record(from: FakeGmail.sampleMessage($0), accountId: account).bodyHTML }
        inputs += ["", "<", "<style>never closed <p>one</p><style>two</style>", "<title>a</title><TITLE>b</title>c", "<head><style>x</head>y</style>z", String(repeating: "<style>", count: 500)]
        for _ in 0..<6000 {
            inputs.append((0..<(1 + random.next(14))).map { _ in pieces[random.next(pieces.count)] }.joined())
        }
        var fast = 0
        for html in inputs {
            for limit in [240_000, 7] {
                guard let quick = HTMLText.withoutTags(html, limit: limit) else { continue }
                fast += 1
                XCTAssertEqual(quick, Reference.withoutTags(html, limit: limit), "differs for \(html.debugDescription) at limit \(limit)")
            }
        }
        // The fast path must be the usual one, not the exception.
        XCTAssertGreaterThan(fast, inputs.count)
        XCTAssertNil(HTMLText.withoutTags("x <\u{17F}tyle>a</style> y", limit: 100))
        XCTAssertEqual(HTMLText.strip("x <\u{17F}tyle>a</style> y"), "x y")
    }

    func testFastTextCleanupAgreesWithThePatterns() {
        let pieces = ["&", "&amp;", "&AMP;", "&nbsp;", "&zwnj;", "&rsquo;", "&bogus;", "&#8217;", "&#x1F389;", "&#X41;", "&#x;", "&#;", "&#1f;", "&#xD800;", "&#99999999999;", "&#x110000;",
                      "&#0;", "&#65", "&amp", "&a1;", ";", "#", "x", "a", "Z", "1", "f", " ", "  ", "\t", "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{A0}", "\u{1680}", "\u{180E}",
                      "\u{2000}", "\u{2003}", "\u{200A}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{2060}", "\u{3000}", "\u{FEFF}",
                      "\u{E9}", "\u{1F389}", "word", "\u{E2}", "\u{C2}", "\u{300}"]
        var random = Random(state: 99)
        var inputs = ["", "&", "&amp;&lt;&gt;", "a \u{A0}\u{200B} b", " \n ", "a\u{2028}\nb", "a\u{2003}b"]
        for _ in 0..<8000 {
            inputs.append((0..<(1 + random.next(12))).map { _ in pieces[random.next(pieces.count)] }.joined())
        }
        for text in inputs {
            XCTAssertEqual(HTMLText.decodeEntities(text), Reference.decodeEntities(text), "entities differ for \(text.debugDescription)")
            XCTAssertEqual(HTMLText.squeezed(text), Reference.squeezed(text), "white space differs for \(text.debugDescription)")
        }
    }

    func testFastBase64AgreesWithThePlainOne() {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_-_+/=\n\r \u{E9}.")
        var random = Random(state: 7)
        var inputs = ["", "-", "_w", "SGVsbG8", "SGVsbG8=", "SG\r\nVsbG8", "SG\nVsbG8", "a\u{E9}b", "====", "-_-_"]
        for _ in 0..<4000 {
            // Mostly clean input, the way Gmail sends it; sometimes with stray characters.
            let dirty = random.next(4) == 0
            inputs.append(String((0..<random.next(40)).map { _ in alphabet[random.next(dirty ? alphabet.count : 64)] }))
        }
        let big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        inputs.append(big.base64URLString())
        for input in inputs {
            XCTAssertEqual(Data(base64URL: input), Reference.base64URL(input), "differs for \(input.debugDescription)")
        }
        XCTAssertEqual(Data(base64URL: big.base64URLString()), big)
    }

    // Recorded on the code as it was before the sync speed work (commit 2751da4).
    private static let firstSync: [String: String] = [
        "account": "1:92c14a8fc057", "contact": "117:d74eb9a5da86", "full_thread": "34:11c45dfbc13c", "label": "8:849140faa422", "loaded": "5:a856af38d43c",
        "message": "463:baa76af060d5", "op": "0:e3b0c44298fc", "search": "463:9a72adfa9b6d", "search_count": "1:0ef8f4969733", "snooze": "0:e3b0c44298fc",
        "thread": "379:3482fe817eb4", "thread_label": "1448:3dfd8f7d8757"]
    private static let changes: [String: String] = [
        "account": "1:bc60817a32b5", "contact": "108:88e5cbea9284", "full_thread": "8:6845f68cb4ac", "label": "8:849140faa422", "loaded": "5:536237ff1569",
        "message": "221:bd7cd86d3be8", "op": "0:e3b0c44298fc", "search": "221:bf8ef400b4b6", "search_count": "1:9b5285554d61", "snooze": "0:e3b0c44298fc",
        "thread": "212:56d68cdbcb64", "thread_label": "727:635b77066fae"]
    private static let records = "c77f48717484e321"
}
