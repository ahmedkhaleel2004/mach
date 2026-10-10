import XCTest
@testable import MachCore

final class OutlookTests: XCTestCase {
    private let me = "me@outlook.com"
    private var folders: GraphFolders {
        GraphFolders(wellKnown: ["inbox": "F-in", "drafts": "F-dr", "sentitems": "F-se", "deleteditems": "F-tr", "junkemail": "F-jk", "archive": "F-ar", "outbox": "F-ob"],
                     names: ["F-in": "Inbox", "F-dr": "Drafts", "F-se": "Sent Items", "F-tr": "Deleted Items", "F-jk": "Junk Email", "F-ar": "Archive", "F-ob": "Outbox", "F-x": "Receipts"])
    }

    private func message(_ json: String) throws -> MSMessage {
        try JSONDecoder().decode(MSMessage.self, from: Data(json.utf8))
    }

    private func light(_ id: String, folder: String, read: Bool = true, flagged: Bool = false, draft: Bool = false, categories: [String] = [],
                       from: String = "them@x.com", received: String = "2026-10-01T10:00:00Z") throws -> MSMessage {
        try message("""
            {"id":"\(id)","conversationId":"c1","parentFolderId":"\(folder)","receivedDateTime":"\(received)","isRead":\(read),"isDraft":\(draft),
             "flag":{"flagStatus":"\(flagged ? "flagged" : "notFlagged")"},"categories":\(Store.json(categories)),"from":{"emailAddress":{"name":"X","address":"\(from)"}}}
            """)
    }

    func testFoldersBecomeLabels() throws {
        XCTAssertEqual(GraphBackend.labels(for: try light("a", folder: "F-in", read: false), folders: folders), ["INBOX", "UNREAD"])
        XCTAssertEqual(GraphBackend.labels(for: try light("a", folder: "F-ar", flagged: true), folders: folders), ["STARRED"])
        XCTAssertEqual(GraphBackend.labels(for: try light("a", folder: "F-se"), folders: folders), ["SENT"])
        XCTAssertEqual(GraphBackend.labels(for: try light("a", folder: "F-dr", read: false, draft: true), folders: folders), ["DRAFT"])
        XCTAssertEqual(GraphBackend.labels(for: try light("a", folder: "F-x", categories: ["Snoozed/2026-10-11T02:04:00Z"]), folders: folders),
                       ["Folder_F-x", "Label_Snoozed/2026-10-11T02:04:00Z"])
        let other = try message(#"{"id":"a","parentFolderId":"F-in","isRead":true,"inferenceClassification":"other"}"#)
        XCTAssertEqual(GraphBackend.labels(for: other, folders: folders), ["INBOX", "CATEGORY_UPDATES"])
        // Deleted mail that Outlook keeps out of sight is in no folder of the mailbox.
        XCTAssertFalse(folders.holds(try light("a", folder: "F-hidden")))
        XCTAssertFalse(folders.tracked.contains("F-ob"))
    }

    func testAFullMessageBecomesARecord() throws {
        let wire = try message("""
            {"id":"m1","conversationId":"c9","parentFolderId":"F-in","receivedDateTime":"2026-10-10T01:53:06Z","subject":"Hello",
             "bodyPreview":"Hi there\\r\\nsecond line","body":{"contentType":"html","content":"<html><body><img src=\\"cid:pic1\\">Hi</body></html>"},
             "from":{"emailAddress":{"name":"Doe, Jane","address":"Jane@X.com"}},
             "toRecipients":[{"emailAddress":{"name":"me@outlook.com","address":"me@outlook.com"}},{"emailAddress":{"name":"Bob","address":"bob@y.com"}}],
             "internetMessageId":"<abc@x.com>","isRead":false,"isDraft":false,"flag":{"flagStatus":"notFlagged"},"categories":[],
             "singleValueExtendedProperties":[{"id":"String 0x1042","value":"<first@x.com>"}],
             "attachments":[{"id":"a1","name":"pic.png","contentType":"image/png","size":10,"isInline":true,"contentId":"<pic1>"},
                            {"id":"a2","name":"doc.pdf","contentType":"application/pdf","size":99,"isInline":false}]}
            """)
        let record = GraphBackend.record(wire, accountId: me, folders: folders)
        XCTAssertEqual(record.threadId, "c9")
        XCTAssertEqual(record.internalDate, 1_791_597_186_000)
        XCTAssertEqual(record.from, EmailAddress(name: "Doe, Jane", email: "jane@x.com"))
        XCTAssertEqual(EmailAddress.parseList(record.toList).map(\.email), ["me@outlook.com", "bob@y.com"])
        XCTAssertEqual(EmailAddress.parseList(record.toList).first?.name, "")
        XCTAssertEqual(record.labelIds, ["INBOX", "UNREAD"])
        XCTAssertEqual(record.refs, "<first@x.com>")
        XCTAssertEqual(record.messageIdHeader, "<abc@x.com>")
        XCTAssertNotNil(record.bodyHTML)
        XCTAssertNil(record.bodyText)
        XCTAssertEqual(record.attachments.map(\.isInline), [true, false])
        XCTAssertEqual(record.attachments.first?.contentId, "pic1")
    }

    private func plan(_ messages: [MSMessage], add: [String] = [], remove: [String] = []) -> [GraphBackend.Step] {
        GraphBackend.plan(messages, add: add, remove: remove, folders: folders, accountId: me)
    }

    func testLabelChangesBecomeMovesAndMarks() throws {
        let received = try light("r1", folder: "F-in", read: false)
        let sent = try light("s1", folder: "F-se", from: me)
        let later = try light("r2", folder: "F-in", read: false, received: "2026-10-02T10:00:00Z")
        let thread = [received, sent, later]

        // Archiving moves what is in the inbox and leaves what you sent where it is.
        XCTAssertEqual(plan(thread, remove: ["INBOX"]), [.init(id: "r1", destination: "F-ar"), .init(id: "r2", destination: "F-ar")])
        // Reading marks every unread message; unread again marks only the newest received one.
        XCTAssertEqual(plan(thread, remove: ["UNREAD"]), [.init(id: "r1", patch: ["isRead": "true"]), .init(id: "r2", patch: ["isRead": "true"])])
        let read = [try light("r1", folder: "F-in"), sent, try light("r2", folder: "F-in", received: "2026-10-02T10:00:00Z")]
        XCTAssertEqual(plan(read, add: ["UNREAD"]), [.init(id: "r2", patch: ["isRead": "false"])])
        XCTAssertEqual(plan(read, add: ["STARRED"]), [.init(id: "r2", patch: ["flag": "flagged"])])
        // Trash takes everything, and coming back puts what you sent back in Sent.
        XCTAssertEqual(plan(read, add: ["TRASH"], remove: ["INBOX"]).map(\.destination), ["F-tr", "F-tr", "F-tr"])
        let trashed = [try light("r1", folder: "F-tr"), try light("s1", folder: "F-tr", from: me)]
        XCTAssertEqual(plan(trashed, add: ["INBOX"], remove: ["TRASH", "SPAM"]), [.init(id: "r1", destination: "F-in"), .init(id: "s1", destination: "F-se")])
        // A snooze is a category on the newest received message plus the move out of the inbox; waking undoes both.
        let snooze = plan(read, add: ["Label_Snoozed/T"], remove: ["INBOX"])
        XCTAssertEqual(snooze, [.init(id: "r1", destination: "F-ar"), .init(id: "r2", categories: ["Snoozed/T"], destination: "F-ar")])
        let snoozed = [try light("r1", folder: "F-ar"), sent, try light("r2", folder: "F-ar", categories: ["Snoozed/T", "Keep"])]
        XCTAssertEqual(plan(snoozed, add: ["INBOX", "UNREAD"], remove: ["Label_Snoozed/T"]),
                       [.init(id: "r1", destination: "F-in"), .init(id: "r2", patch: ["isRead": "false"], categories: ["Keep"], destination: "F-in")])
        // Nothing to do is nothing sent.
        XCTAssertEqual(plan(read, remove: ["UNREAD", "STARRED"]), [])
    }

    func testAReportOfWholeLabelListsReplacesWhatIsStored() throws {
        let store = try Store(path: NSTemporaryDirectory() + "outlook-\(UUID().uuidString).sqlite")
        try store.saveAccount(Account(id: me, name: "Me", provider: .microsoft))
        XCTAssertEqual(try store.account(me)?.service, .microsoft)
        let stored = Message(accountId: me, id: "m1", threadId: "c1", internalDate: 1000, sender: "A <a@x.com>", toList: me, ccList: "", bccList: "", replyTo: "",
                             subject: "Hi", snippet: "", labelIds: ["UNREAD"], messageIdHeader: "", refs: "", bodyHTML: nil, bodyText: "Hi", attachments: [])
        try store.saveMessages(account: me, messages: [stored])
        let noted = try store.applyLabelChangesNoting(account: me, changes: [
            .init(messageId: "m1", replace: ["INBOX", "Label_Snoozed/2026-10-11T02:04:00Z"], threadId: "c1"),
            .init(messageId: "m2", replace: ["INBOX"], threadId: "c2"),
        ], deleted: [])
        XCTAssertEqual(noted.unknown, ["m2"])
        XCTAssertEqual(noted.returned, ["m1"])
        XCTAssertEqual(try store.message(account: me, id: "m1")?.labelIds, ["INBOX", "Label_Snoozed/2026-10-11T02:04:00Z"])
        // Labels learned from messages survive the folder list being read again.
        try store.learnLabels(account: me, ids: ["Label_Snoozed/2026-10-11T02:04:00Z"])
        try store.replaceLabels([MailLabel(accountId: me, id: "INBOX", name: "INBOX", type: "system")], account: me, keepingLearned: true)
        XCTAssertEqual(try store.labels(account: me).map(\.id).sorted(), ["INBOX", "Label_Snoozed/2026-10-11T02:04:00Z"])
        XCTAssertEqual(try store.snoozeLabelIds(account: me), ["Label_Snoozed/2026-10-11T02:04:00Z"])
    }

    func testMicrosoftSignInAddresses() throws {
        let client = OAuthClient(clientId: "abc-123", clientSecret: nil)
        let url = OAuth.authorizationURL(client: client, redirect: "http://localhost:5000", challenge: "CH", state: "ST", loginHint: "a@outlook.com",
                                         scope: OAuth.microsoftScope, provider: .microsoft)
        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertEqual(url.path, "/common/oauth2/v2.0/authorize")
        let query = OAuth.callbackParameters(url)
        XCTAssertEqual(query["client_id"], "abc-123")
        XCTAssertEqual(query["scope"], "offline_access User.Read Mail.ReadWrite Mail.Send")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:5000")
        XCTAssertEqual(OAuth.tokenAddress(.microsoft), "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        XCTAssertNil(OAuth.refreshForm(client: client, refreshToken: "r")["client_secret"])
        // A sign-in saved before Outlook existed here has no service written on it, and is Google's.
        let old = try JSONDecoder().decode(TokenSet.self, from: Data(#"{"refreshToken":"r","accessToken":"","expiry":0}"#.utf8))
        XCTAssertEqual(old.service, .google)
        XCTAssertEqual(GraphBackend.messageId(inRaw: Data("From: a\r\nMessage-ID: <x@y>\r\n\r\nMessage-ID: <no@no>".utf8)), "<x@y>")
    }
}

final class OneTimeCodeTests: XCTestCase {
    func testFindsCodes() {
        let found: [(String, String, String)] = [
            ("Your verification code", "Your verification code is 482913. It expires in 10 minutes.", "482913"),
            ("123456 is your Facebook confirmation code", "", "123456"),
            ("Microsoft account security code", "Please use the following security code for the Microsoft account ah*****@outlook.com.\n\nSecurity code: 5501234\n\nIf you didn't request this", "5501234"),
            ("Your Google verification code", "G-719204 is your Google verification code.", "719204"),
            ("Sign in to Slack", "Your confirmation code is below — enter it in your open browser window\n\nXK2-9QP\n\nIf you didn't request", "XK2-9QP"),
            ("Verify your email", "Enter this code to verify your email address:\n\n  934 112  \n\nThis code expires in 2026.", "934112"),
            ("Your one-time passcode", "Use 8842 to finish signing in.\n\n8842\n", "8842"),
            ("Login code", "Here is your login code: 123-456", "123456"),
            ("GitHub", "Your GitHub launch code\n\nContinue signing in by entering the code below:\n\n74829316\n", "74829316"),
        ]
        for (subject, text, code) in found {
            XCTAssertEqual(OneTimeCode.find(subject: subject, text: text), code, subject)
        }
    }

    func testLeavesOtherNumbersAlone() {
        let none: [(String, String)] = [
            ("Your order #48291 has shipped", "Order 48291 will arrive on Oct 12, 2026.\n\n48291\n"),
            ("Receipt from Acme", "Total: $1,234.00\nInvoice 20261009"),
            ("Save 20% this week", "Use promo code 202620 at checkout. Zip code 90210."),
            ("Happy new year", "Your code of conduct for 2026:\n\n2026\n"),
            ("Meeting notes", "Call me at 555 1234 about the 2025 plan."),
            ("Your verification code", "We sent a code to your phone."),
        ]
        for (subject, text) in none {
            XCTAssertNil(OneTimeCode.find(subject: subject, text: text), subject)
        }
    }
}
