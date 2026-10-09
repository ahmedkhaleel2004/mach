import XCTest
@testable import BlitzCore

final class ParsingTests: XCTestCase {
    func testAddressList() {
        let list = EmailAddress.parseList("\"Doe, Jane\" <Jane@X.com>, bob@y.com; =?UTF-8?B?w4lyaWM=?= <eric@z.fr>, , junk")
        XCTAssertEqual(list.map(\.email), ["jane@x.com", "bob@y.com", "eric@z.fr"])
        XCTAssertEqual(list[0].name, "Doe, Jane")
        XCTAssertEqual(list[1].displayName, "bob")
        XCTAssertEqual(list[2].name, "Éric")
        XCTAssertEqual(list[0].formatted, "\"Doe, Jane\" <jane@x.com>")
    }

    func testEncodedWords() {
        XCTAssertEqual(MIMEWords.decode("=?UTF-8?Q?Caf=C3=A9_au_lait?="), "Café au lait")
        XCTAssertEqual(MIMEWords.decode("=?utf-8?B?SGVsbG8g?= =?utf-8?B?V29ybGQ=?="), "Hello World")
        XCTAssertEqual(MIMEWords.decode("plain"), "plain")
        XCTAssertEqual(MIMEWords.encode("plain"), "plain")
        let long = String(repeating: "héllo wörld ", count: 12)
        XCTAssertEqual(MIMEWords.decode(MIMEWords.encode(long).replacingOccurrences(of: "\r\n ", with: " ")), long)
    }

    func testHTMLHelpers() {
        XCTAssertEqual(HTMLText.strip("<style>p{}</style><p>Hi&nbsp;there &amp; <b>you</b></p><div>Next</div>"), "Hi there & you\nNext")
        XCTAssertEqual(HTMLText.tidy("Deal\u{200C} \u{200C} \u{00A0}  now \u{034F}"), "Deal now")
        XCTAssertEqual(HTMLText.fromPlain("a <b> & https://x.com/y?z=1.\nnext"), "a &lt;b&gt; &amp; <a href=\"https://x.com/y?z=1\">https://x.com/y?z=1</a>.<br>\nnext")
    }

    func testPayload() throws {
        func b64(_ s: String) -> String { Data(s.utf8).base64URLString() }
        let json = """
        {"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],"snippet":"Hi &amp; bye","internalDate":"1700000000000",
         "payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"=?UTF-8?B?w4lyaWM=?= <eric@z.fr>"},{"name":"To","value":"me@x.com"},
           {"name":"Subject","value":"Hello"},{"name":"Message-ID","value":"<abc@z.fr>"},{"name":"In-Reply-To","value":"<prev@x.com>"}],
          "parts":[{"mimeType":"multipart/alternative","parts":[
              {"mimeType":"text/plain","headers":[{"name":"Content-Type","value":"text/plain; charset=\\"iso-8859-1\\""}],"body":{"size":3,"data":"\(Data([0x63, 0x61, 0x66, 0xE9]).base64URLString())"}},
              {"mimeType":"text/html","headers":[{"name":"Content-Type","value":"text/html; charset=utf-8"}],"body":{"size":3,"data":"\(b64("<p>café</p>"))"}}]},
            {"mimeType":"image/png","filename":"logo.png","headers":[{"name":"Content-ID","value":"<logo@1>"},{"name":"Content-Disposition","value":"inline"}],"body":{"attachmentId":"A1","size":10}},
            {"mimeType":"application/pdf","filename":"doc.pdf","headers":[{"name":"Content-Disposition","value":"attachment; filename=doc.pdf"}],"body":{"attachmentId":"A2","size":20}}]}}
        """
        let message = try JSONDecoder().decode(GMessage.self, from: Data(json.utf8)).record(accountId: "me@x.com")
        XCTAssertEqual(message.from, EmailAddress(name: "Éric", email: "eric@z.fr"))
        XCTAssertEqual(message.bodyText, "café")
        XCTAssertEqual(message.bodyHTML, "<p>café</p>")
        XCTAssertEqual(message.snippet, "Hi & bye")
        XCTAssertEqual(message.refs, "<prev@x.com>")
        XCTAssertEqual(message.attachments.map(\.isInline), [true, false])
        XCTAssertEqual(message.attachments[0].contentId, "logo@1")
        XCTAssertTrue(message.isUnread)
    }

    func testOutgoingMessage() {
        let message = OutgoingMessage(
            from: EmailAddress(name: "Ahmed K", email: "a@x.com"), to: [EmailAddress(name: "Zoë", email: "z@y.com")],
            subject: "Héllo", text: "body", html: "<p>body</p>", inReplyTo: "<1@x>", references: "<0@x> <1@x>",
            attachments: [("a b.txt", "text/plain", Data("file".utf8))])
        let raw = String(decoding: message.rfc822(), as: UTF8.self)
        XCTAssertTrue(raw.contains("From: \"Ahmed K\" <a@x.com>\r\n"))
        XCTAssertTrue(raw.contains("To: =?UTF-8?B?Wm/Dqw==?= <z@y.com>\r\n"))
        XCTAssertTrue(raw.contains("Subject: =?UTF-8?B?SMOpbGxv?=\r\n"))
        XCTAssertTrue(raw.contains("In-Reply-To: <1@x>\r\nReferences: <0@x> <1@x>\r\n"))
        XCTAssertTrue(raw.contains("Content-Type: multipart/mixed; boundary="))
        XCTAssertTrue(raw.contains(Data("<p>body</p>".utf8).base64EncodedString()))
        XCTAssertTrue(raw.contains("Content-Disposition: attachment; filename=\"a b.txt\""))
        XCTAssertFalse(raw.contains("\n\n"), "every line must end in CRLF")
        let headerEnd = raw.range(of: "\r\n\r\n")!
        XCTAssertFalse(raw[..<headerEnd.lowerBound].contains("Bcc"))
    }

    func testHostileHeaders() throws {
        // An encoded display name must not be able to pose as a second, trusted address.
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        let spoof = "=?UTF-8?B?\(b64("Bank <support@bank.com>, x"))?= <attacker@evil.com>"
        let parsed = EmailAddress.parseList(spoof)
        XCTAssertEqual(parsed.map(\.email), ["attacker@evil.com"])
        XCTAssertEqual(EmailAddress.parseList("=?UTF-8?Q?M=C3=BCller=2C_Hans?= <h@x.com>").first?.name, "Müller, Hans")
        // A name that decodes to line breaks must not add headers to our reply.
        let evil = EmailAddress.parseList("=?UTF-8?B?\(b64("a\r\nBcc: evil@x.com\r\nX-J: "))?= <bob@y.com>")
        let raw = String(decoding: OutgoingMessage(from: EmailAddress(name: "Me", email: "me@x.com"), to: evil, subject: "Hi\r\nBcc: z@z.com", text: "t", html: "h").rfc822(), as: UTF8.self)
        let headers = raw.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        XCTAssertFalse(headers.contains { $0.lowercased().hasPrefix("bcc:") || $0.lowercased().hasPrefix("x-j:") })
        // A character split across two encoded words still decodes.
        XCTAssertEqual(MIMEWords.decode("=?UTF-8?Q?caf=C3?= =?UTF-8?Q?=A9?="), "café")
    }

    func testLongHeadersAreFolded() {
        let many = (0..<60).map { EmailAddress(name: "Person Number \($0)", email: "person\($0)@example.com") }
        let references = (0..<40).map { "<message-\($0)-abcdefghijklmnop@mail.example.com>" }.joined(separator: " ")
        let message = OutgoingMessage(from: EmailAddress(name: "Me", email: "me@x.com"), to: many, subject: String(repeating: "word ", count: 300),
                                      text: "t", html: "h", references: references, messageId: "<abc@mail.blitzmail.app>")
        let raw = String(decoding: message.rfc822(), as: UTF8.self)
        let head = raw.components(separatedBy: "\r\n\r\n")[0]
        XCTAssertLessThan(head.components(separatedBy: "\r\n").map(\.count).max() ?? 0, 200)
        XCTAssertTrue(head.contains("Message-ID: <abc@mail.blitzmail.app>"))
        // Unfolding gives back every recipient.
        let unfolded = head.replacingOccurrences(of: "\r\n ", with: " ")
        let toLine = unfolded.components(separatedBy: "\r\n").first { $0.hasPrefix("To: ") } ?? ""
        XCTAssertEqual(EmailAddress.parseList(String(toLine.dropFirst(4))).count, 60)
    }

    func testEmptyDrafts() {
        XCTAssertTrue(Draft(accountId: "me@x.com").isEmpty)
        XCTAssertTrue(Draft(accountId: "me@x.com", threadId: "T", to: "bob@y.com", subject: "Re: Hi", quotedHTML: "<p>q</p>").isEmpty)
        XCTAssertFalse(Draft(accountId: "me@x.com", threadId: "T", to: "bob@y.com", body: "ok").isEmpty)
        XCTAssertTrue(Draft(accountId: "me@x.com", subject: "Fwd: Hi", quotedHTML: "<p>q</p>", attachmentPaths: ["/tmp/a"]).isEmpty)
        XCTAssertFalse(Draft(accountId: "me@x.com", to: "bob@y.com").isEmpty)
    }

    func testReplyRecipients() {
        let account = Account(id: "me@x.com", name: "Me")
        var incoming = message("m1", thread: "t1", labels: ["INBOX"], from: "Bob <bob@y.com>")
        incoming.toList = "me@x.com, Carol <carol@y.com>"
        incoming.ccList = "dave@y.com"
        incoming.messageIdHeader = "<m1@y.com>"
        incoming.subject = "Plan"
        let single = Composer.reply(to: incoming, all: false, account: account)
        XCTAssertEqual(single.to, "Bob <bob@y.com>")
        XCTAssertEqual(single.cc, "")
        XCTAssertEqual(single.subject, "Re: Plan")
        XCTAssertEqual(single.inReplyTo, "<m1@y.com>")
        let everyone = Composer.reply(to: incoming, all: true, account: account)
        XCTAssertEqual(everyone.to, "Bob <bob@y.com>, Carol <carol@y.com>")
        XCTAssertEqual(everyone.cc, "dave@y.com")
        var mine = incoming
        mine.sender = "Me <me@x.com>"
        mine.toList = "bob@y.com"
        mine.subject = "RE: Plan"
        let followUp = Composer.reply(to: mine, all: false, account: account)
        XCTAssertEqual(followUp.to, "bob@y.com")
        XCTAssertEqual(followUp.subject, "RE: Plan")
        XCTAssertEqual(Composer.forward(incoming, account: account).subject, "Fwd: Plan")
    }
}

func message(_ id: String, thread: String, labels: [String], from: String = "Bob <bob@y.com>", date: Int64 = 1000, body: String = "hello world", refs: String = "") -> Message {
    Message(accountId: "me@x.com", id: id, threadId: thread, internalDate: date, sender: from, toList: "me@x.com", ccList: "", bccList: "",
            replyTo: "", subject: "Subject \(thread)", snippet: body, labelIds: labels, messageIdHeader: "<\(id)@y.com>", refs: refs,
            bodyHTML: nil, bodyText: body, attachments: [])
}

final class StoreTests: XCTestCase {
    var store: Store!
    let me = "me@x.com"

    override func setUpWithError() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("blitz-\(UUID().uuidString).sqlite").path
        store = try Store(path: path)
        try store.saveAccount(Account(id: me, name: "Me"))
    }

    func ids(_ label: String) throws -> [String] { try store.threads(account: me, label: label, limit: 100).map(\.id) }

    func testThreadsAndSplits() throws {
        try store.saveMessages(account: me, messages: [
            message("a1", thread: "A", labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], date: 10),
            message("b1", thread: "B", labels: ["INBOX", "CATEGORY_PROMOTIONS"], from: "Shop <deals@shop.com>", date: 20),
            message("c1", thread: "C", labels: ["SENT"], from: "Me <me@x.com>", date: 30),
            message("a2", thread: "A", labels: ["SENT"], from: "Me <me@x.com>", date: 40),
        ])
        XCTAssertEqual(try ids(SystemLabel.inboxMain), ["A"])
        XCTAssertEqual(try ids(SystemLabel.inboxOther), ["B"])
        XCTAssertEqual(try ids(SystemLabel.done), ["C"])
        XCTAssertEqual(try ids(SystemLabel.all), ["A", "C", "B"])
        let thread = try XCTUnwrap(store.thread(account: me, id: "A"))
        XCTAssertEqual(thread.participants, ["Bob", "me"])
        XCTAssertEqual(thread.messageCount, 2)
        XCTAssertTrue(thread.unread)
        XCTAssertEqual(try store.unreadCount(account: me), 1)
        XCTAssertEqual(try store.contacts(account: me, matching: "bo").map(\.email), ["bob@y.com"])
    }

    func testLocalChangeSurvivesStaleServerData() throws {
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX", "UNREAD"])])
        try store.modifyThreads(account: me, threadIds: ["A"], add: [], remove: ["INBOX", "UNREAD"])
        XCTAssertEqual(try ids(SystemLabel.inbox), [])
        XCTAssertEqual(try ids(SystemLabel.done), ["A"])
        XCTAssertEqual(try store.pendingOpCount(), 1)
        // Gmail has not heard about it yet and still says the thread is in the inbox.
        try store.saveThread(account: me, threadId: "A", messages: [message("a1", thread: "A", labels: ["INBOX", "UNREAD"]), message("a2", thread: "A", labels: ["INBOX", "UNREAD"], date: 2000)])
        XCTAssertEqual(try ids(SystemLabel.inbox), [])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.messageCount, 2)
        let op = try XCTUnwrap(store.readyOps(account: me, limit: 10).first)
        try store.deleteOp(try XCTUnwrap(op.id))
        // Once the change has gone up, a genuinely new message brings the thread back.
        try store.saveMessages(account: me, messages: [message("a3", thread: "A", labels: ["INBOX", "UNREAD"], date: 3000)])
        XCTAssertEqual(try ids(SystemLabel.inbox), ["A"])
    }

    func testLabelChangesFromGmail() throws {
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX", "UNREAD"]), message("b1", thread: "B", labels: ["INBOX"])])
        let unknown = try store.applyLabelChanges(account: me, changes: [
            .init(messageId: "a1", add: ["STARRED"], remove: ["UNREAD"]),
            .init(messageId: "zzz", add: ["INBOX"], remove: []),
        ], deleted: ["b1"])
        XCTAssertEqual(unknown, ["zzz"])
        let thread = try XCTUnwrap(store.thread(account: me, id: "A"))
        XCTAssertTrue(thread.starred)
        XCTAssertFalse(thread.unread)
        XCTAssertNil(try store.thread(account: me, id: "B"))
        XCTAssertEqual(try store.search(account: me, text: "hello").map(\.id), ["A"])
    }

    func testSearch() throws {
        try store.saveMessages(account: me, messages: [
            message("a1", thread: "A", labels: ["INBOX"], date: 10, body: "The quarterly invoice is attached"),
            message("b1", thread: "B", labels: ["INBOX"], date: 20, body: "Lunch on Friday?"),
        ])
        XCTAssertEqual(try store.search(account: me, text: "invo").map(\.id), ["A"])
        XCTAssertEqual(try store.search(account: me, text: "bob").map(\.id), ["B", "A"])
        XCTAssertEqual(try store.search(account: me, text: "bob", order: .oldest).map(\.id), ["A", "B"])
        XCTAssertEqual(Set(try store.search(account: me, text: "bob", order: .relevant).map(\.id)), ["A", "B"])
        XCTAssertEqual(try store.search(account: me, text: "friday lunch").map(\.id), ["B"])
        XCTAssertEqual(try store.search(account: me, text: "\"*(").count, 0)
    }

    func testSnooze() throws {
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX"])])
        try store.modifyThreads(account: me, threadIds: ["A"], add: [], remove: ["INBOX"], snoozeUntil: Store.now() - 5)
        XCTAssertEqual(try ids(SystemLabel.snoozed), ["A"])
        XCTAssertEqual(try ids(SystemLabel.done), [])
        XCTAssertEqual(try store.dueSnoozes(account: me), ["A"])
        try store.modifyThreads(account: me, threadIds: ["A"], add: ["INBOX", "UNREAD"], remove: [], clearSnooze: true, bump: true)
        XCTAssertEqual(try ids(SystemLabel.snoozed), [])
        XCTAssertEqual(try ids(SystemLabel.inbox), ["A"])
        XCTAssertNil(try store.thread(account: me, id: "A")?.snoozedUntil)
    }

    func testSnoozeSharedThroughLabel() throws {
        let later = Store.now() + 3_600_000
        let name = SystemLabel.snoozeLabelName(until: later)
        XCTAssertEqual(SystemLabel.snoozeTime(fromLabelName: name), (later / 60000) * 60000)
        XCTAssertNil(SystemLabel.snoozeTime(fromLabelName: "Receipts"))
        // Another device snoozed thread A: here it only shows up as a label on the message.
        try store.saveLabel(MailLabel(accountId: me, id: "Label_9", name: name, type: "user"))
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["Label_9"])])
        XCTAssertEqual(try ids(SystemLabel.snoozed), ["A"])
        XCTAssertEqual(try ids(SystemLabel.done), [])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.snoozedUntil, (later / 60000) * 60000)
        XCTAssertEqual(try store.dueSnoozes(account: me), [])
        // Bringing it back removes the label here at once and queues the same for Gmail.
        try store.modifyThreads(account: me, threadIds: ["A"], add: ["INBOX"], remove: [], clearSnooze: true)
        XCTAssertEqual(try ids(SystemLabel.snoozed), [])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.labelIds, ["INBOX"])
        let op = try XCTUnwrap(store.readyOps(account: me, limit: 10).first)
        XCTAssertEqual(op.removeLabels, ["^unsnooze"])
        try store.deleteOp(try XCTUnwrap(op.id))
        // Snoozing from here queues a stand-in that becomes the real label when sent, and never leaks into stored labels.
        try store.modifyThreads(account: me, threadIds: ["A"], add: [], remove: ["INBOX"], snoozeUntil: later)
        XCTAssertEqual(try store.readyOps(account: me, limit: 10).first?.addLabels, ["^snooze:\(later)"])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.labelIds, [])
        XCTAssertEqual(try ids(SystemLabel.snoozed), ["A"])
        // Stale server data arriving meanwhile must not un-snooze it or store the stand-in.
        try store.saveThread(account: me, threadId: "A", messages: [message("a1", thread: "A", labels: ["INBOX"])])
        XCTAssertEqual(try ids(SystemLabel.snoozed), ["A"])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.labelIds, [])
    }

    func testSendQueueAndUndo() throws {
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX"])])
        let draft = Draft(accountId: me, threadId: "A", to: "bob@y.com", subject: "Re: Subject A", body: "On it")
        try store.queueSend(draft: draft, from: EmailAddress(name: "Me", email: me), html: "<div>On it</div>", delay: 60)
        XCTAssertEqual(try store.thread(account: me, id: "A")?.messageCount, 2)
        XCTAssertEqual(try store.drafts(account: me).count, 0)
        XCTAssertTrue(try store.readyOps(account: me, limit: 10).isEmpty, "not due until the undo window has passed")
        // Fresh data from Gmail must not wipe the message that is waiting to go out.
        try store.saveThread(account: me, threadId: "A", messages: [message("a1", thread: "A", labels: ["INBOX"])])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.messageCount, 2)
        let restored = try XCTUnwrap(store.cancelSend(draftId: draft.id))
        XCTAssertEqual(restored.body, "On it")
        XCTAssertEqual(try store.thread(account: me, id: "A")?.messageCount, 1)
        XCTAssertEqual(try store.drafts(account: me).count, 1)
        XCTAssertNil(try store.cancelSend(draftId: draft.id))
    }

    func testServerLabelChangeDoesNotUndoPendingSnooze() throws {
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX"])])
        let later = Store.now() + 3_600_000
        try store.modifyThreads(account: me, threadIds: ["A"], add: [], remove: ["INBOX"], snoozeUntil: later)
        // A change log entry from just before the snooze says INBOX was added.
        _ = try store.applyLabelChanges(account: me, changes: [.init(messageId: "a1", add: ["INBOX", "STARRED"], remove: [])], deleted: [])
        XCTAssertEqual(try ids(SystemLabel.snoozed), ["A"])
        XCTAssertEqual(try ids(SystemLabel.inbox), [])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.starred, true)
    }

    func testSendInFlightCannotBeUndone() throws {
        let draft = Draft(accountId: me, to: "bob@y.com", subject: "Hello", body: "Hi")
        try store.queueSend(draft: draft, from: EmailAddress(name: "Me", email: me), html: "<div>Hi</div>", delay: 0)
        let op = try XCTUnwrap(store.readyOps(account: me, limit: 10).first)
        XCTAssertTrue(try store.beginSend(try XCTUnwrap(op.id)))
        XCTAssertNil(try store.cancelSend(draftId: draft.id), "a message already on its way cannot be taken back")
        XCTAssertEqual(try store.readyOps(account: me, limit: 10).first?.attempts, 1)
        // A failed attempt releases it again.
        try store.failOp(try XCTUnwrap(op.id), error: "offline")
        XCTAssertNotNil(try store.cancelSend(draftId: draft.id))
        XCTAssertFalse(try store.beginSend(try XCTUnwrap(op.id)), "a cancelled send must not go")
    }

    func testStaleThreadAnswerKeepsNewerMessage() throws {
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX"], date: 10), message("a2", thread: "A", labels: ["INBOX"], date: 30)])
        // An answer fetched before a2 existed arrives late.
        try store.saveThread(account: me, threadId: "A", messages: [message("a1", thread: "A", labels: ["INBOX"], date: 10)])
        XCTAssertEqual(try store.thread(account: me, id: "A")?.messageCount, 2)
    }

    func testRemovedAccountStaysRemoved() throws {
        try store.deleteAccount(me)
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX"])])
        try store.saveThread(account: me, threadId: "B", messages: [message("b1", thread: "B", labels: ["INBOX"])])
        XCTAssertEqual(try store.search(account: nil, text: "hello").count, 0)
    }

    func testNewConversationSend() throws {
        let draft = Draft(accountId: me, to: "bob@y.com", subject: "Hello", body: "Hi")
        try store.queueSend(draft: draft, from: EmailAddress(name: "Me", email: me), html: "<div>Hi</div>", delay: 0)
        XCTAssertEqual(try ids(SystemLabel.sent), ["local-\(draft.id)"])
        let op = try XCTUnwrap(store.readyOps(account: me, limit: 10).first)
        try store.finishSend(op: op, sent: true)
        XCTAssertEqual(try ids(SystemLabel.sent), [])
        XCTAssertNil(try store.draft(draft.id))
        XCTAssertEqual(try store.pendingOpCount(), 0)
    }

    func testIncompleteThreads() throws {
        try store.saveMessages(account: me, messages: [message("a2", thread: "A", labels: ["INBOX"], refs: "<a1@y.com>"), message("b1", thread: "B", labels: ["INBOX"])])
        XCTAssertEqual(try store.incompleteThreads(account: me, limit: 10), ["A"])
        XCTAssertTrue(try store.threadNeedsCompleting(account: me, threadId: "A"))
        XCTAssertFalse(try store.threadNeedsCompleting(account: me, threadId: "B"))
        try store.saveThread(account: me, threadId: "A", messages: [message("a1", thread: "A", labels: []), message("a2", thread: "A", labels: ["INBOX"], refs: "<a1@y.com>")])
        XCTAssertEqual(try store.incompleteThreads(account: me, limit: 10), [])
    }

    func testDeleteAccount() throws {
        try store.saveMessages(account: me, messages: [message("a1", thread: "A", labels: ["INBOX"])])
        try store.deleteAccount(me)
        XCTAssertEqual(try store.accounts().count, 0)
        XCTAssertEqual(try store.search(account: me, text: "hello").count, 0)
    }
}
