import MachFake
import XCTest
@testable import MachCore

/// Whole syncs against a pretend Outlook: what a check costs, and that mail is found, moved and dropped correctly.
final class OutlookSyncTests: XCTestCase {
    private struct Tokens: TokenStore {
        func load(account: String) -> TokenSet? { TokenSet(refreshToken: "none", accessToken: "fake-" + account, expiry: .distantFuture, provider: .microsoft) }
        func save(_ tokens: TokenSet, account: String) {}
        func delete(account: String) {}
    }

    private final class Announced: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ new: [String]) { lock.withLock { ids += new } }
        var all: [String] { lock.withLock { ids } }
    }

    private let account = "outlook-test@example.com"
    private var directory: URL!
    private var server: FakeGraph!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mach-outlook-\(UUID().uuidString)")
        server = FakeGraph(email: account, latency: 0.002)
        GraphBackend.confirmWait = 45
    }

    override func tearDown() {
        server.close()
        try? FileManager.default.removeItem(at: directory)
        GraphBackend.confirmWait = 45
    }

    private func makeService() throws -> MailService {
        let mail = try MailService(directory: directory, client: OAuthClient(clientId: "test", clientSecret: nil),
                                   microsoftClient: OAuthClient(clientId: "test", clientSecret: nil), tokens: Tokens(),
                                   transport: GmailTransport(protocolClasses: [FakeGraphProtocol.self], speedup: 5000))
        if try mail.store.account(account) == nil { try mail.store.saveAccount(Account(id: account, name: "Test", provider: .microsoft)) }
        return mail
    }

    /// Waits until the server has heard nothing for a moment: the background filling-in has ended.
    private func quiet() async {
        var last = server.calls.count
        var since = Date()
        while Date().timeIntervalSince(since) < 0.3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if server.calls.count != last {
                last = server.calls.count
                since = Date()
            }
        }
    }

    /// A mailbox the app has finished taking in, with nothing left to fetch.
    private func settled(inbox: Int = 12, archived: Int = 6) async throws -> MailService {
        server.seed(archived, folder: "archive")
        server.seed(inbox)
        let mail = try makeService()
        for _ in 0..<6 {
            await mail.sync(for: account).sync()
            await quiet()
        }
        server.resetLog()
        return mail
    }

    private func labels(_ mail: MailService, _ id: String) throws -> [String]? {
        try mail.store.message(account: account, id: id)?.labelIds
    }

    func testFirstSyncFillsTheInbox() async throws {
        let mail = try await settled()
        XCTAssertEqual(try mail.store.threads(account: account, label: SystemLabel.inbox, limit: 100).count, 12)
        XCTAssertEqual(try mail.store.threads(account: account, label: SystemLabel.all, limit: 100).count, 18)
    }

    func testAnIdleCheckIsOneRoundTrip() async throws {
        let mail = try await settled()
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(server.calls.map(\.kind), ["batch"])
        // The top of the inbox, the list of folders, and the six folders that hold mail.
        XCTAssertEqual(server.calls.first?.reads, 8)
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(server.calls.count, 2)
    }

    func testFoldersAreRememberedAcrossALaunch() async throws {
        _ = try await settled()
        // A new launch: nothing in memory, everything from the database.
        let relaunched = try makeService()
        await relaunched.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(server.calls.first?.kind, "batch")
        XCTAssertFalse(server.calls.contains { $0.kind == "folders.delta" || $0.kind == "folder.get" })
    }

    func testNewMailArrives() async throws {
        let mail = try await settled()
        let announced = Announced()
        mail.onNewMail = { announced.add($0.map(\.id)) }
        let id = server.deliver().first!
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(try labels(mail, id), ["INBOX", "UNREAD"])
        XCTAssertEqual(announced.all, [id])
        // The change list and one download.
        XCTAssertEqual(server.calls.map(\.kind), ["batch", "messages.get"])
    }

    func testASignalLooksAtTheInboxFirst() async throws {
        let mail = try await settled()
        let announced = Announced()
        mail.onNewMail = { announced.add($0.map(\.id)) }
        // The change list is far behind: only the inbox itself has the mail.
        server.changeLag = 60
        let id = server.deliver().first!
        await mail.sync(for: account).sync(newMail: true)
        await quiet()
        XCTAssertEqual(try labels(mail, id), ["INBOX", "UNREAD"])
        XCTAssertEqual(Array(server.calls.map(\.kind).prefix(3)), ["messages.list", "messages.get", "batch"])
        // The change list catching up later neither stores nor announces it a second time.
        server.changeLag = 0
        await mail.sync(for: account).sync(newMail: true)
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(announced.all, [id])
        XCTAssertEqual(server.calls.filter { $0.kind == "messages.get" }.count, 1)
    }

    func testAPlainCheckFindsMailTheChangeListDoesNotHaveYet() async throws {
        let mail = try await settled()
        server.changeLag = 60
        let id = server.deliver().first!
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(try labels(mail, id), ["INBOX", "UNREAD"])
        // Nothing is said twice while it waits for the change list.
        server.resetLog()
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(server.calls.map(\.kind), ["batch"])
    }

    func testMailThatCameAndWentIsDropped() async throws {
        let mail = try await settled()
        server.changeLag = 60
        let id = server.deliver().first!
        await mail.sync(for: account).sync(newMail: true)
        XCTAssertNotNil(try labels(mail, id))
        // Deleted for good before any change list spoke of it: nothing will ever say so.
        server.delete(id, silently: true)
        GraphBackend.confirmWait = 0.05
        try await Task.sleep(nanoseconds: 100_000_000)
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertNil(try labels(mail, id))
    }

    func testChangesMadeElsewhereAreFollowed() async throws {
        let mail = try await settled()
        let ids = server.deliver(3)
        await mail.sync(for: account).sync()
        server.move(ids[0], to: "archive")
        server.mark(ids[1], read: true)
        server.delete(ids[2])
        await mail.sync(for: account).sync()
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(try labels(mail, ids[0]), ["UNREAD"])
        XCTAssertEqual(try labels(mail, ids[1]), ["INBOX"])
        XCTAssertNil(try labels(mail, ids[2]))
    }

    func testANewFolderIsNoticed() async throws {
        let mail = try await settled()
        let folder = server.addFolder("Receipts")
        let id = server.deliver().first!
        await mail.sync(for: account).sync()
        server.move(id, to: String(folder.dropFirst(2)))
        await mail.sync(for: account).sync()
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(try labels(mail, id), ["Folder_" + folder, "UNREAD"])
        // Once learned, the folder list is not asked for again.
        server.resetLog()
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(server.calls.map(\.kind), ["batch"])
    }

    func testAChangeMadeHereReachesOutlook() async throws {
        let mail = try await settled()
        let id = server.deliver().first!
        await mail.sync(for: account).sync()
        let thread = try XCTUnwrap(try mail.store.message(account: account, id: id)?.threadId)
        mail.modify(account: account, threadIds: [thread], remove: [SystemLabel.inbox, SystemLabel.unread])
        try await Task.sleep(nanoseconds: 150_000_000)
        await mail.sync(for: account).flush()
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(server.folder(of: id), "archive")
        XCTAssertEqual(server.isRead(id), true)
        XCTAssertEqual(try labels(mail, id), [])
    }

    // MARK: Contacts and pictures

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var accounts: [String] = []
        func add(_ account: String) { lock.withLock { accounts.append(account) } }
        var all: [String] { lock.withLock { accounts } }
    }

    func testContactsAndPeopleCanBeAddressed() async throws {
        server.contacts = [FakeGraph.Person(name: "Dana Saved", emails: ["Dana@Example.com"], photo: Data([1, 2, 3])),
                           FakeGraph.Person(name: "No Mail", emails: [])]
        server.people = [FakeGraph.Person(name: "Omar Written", emails: ["omar@example.com"]), FakeGraph.Person(name: "Dana Other", emails: ["dana@example.com"])]
        server.ownPhoto = Data([9, 9])
        let mail = try await settled()
        XCTAssertEqual(try mail.store.contacts(account: account, matching: "dana").map(\.name), ["Dana Saved"])
        XCTAssertEqual(try mail.store.contacts(account: account, matching: "omar").map(\.email), ["omar@example.com"])
        XCTAssertTrue(mail.accountsWithoutContacts.isEmpty)
        // Pictures: a saved contact's own, the account's own, and nobody else's.
        let dana = await mail.outlookPhoto(for: "dana@example.com")
        let me = await mail.outlookPhoto(for: account)
        let omar = await mail.outlookPhoto(for: "omar@example.com")
        XCTAssertEqual(dana, Data([1, 2, 3]))
        XCTAssertEqual(me, Data([9, 9]))
        XCTAssertNil(omar)
        // The lists are read once a day, not at every check.
        await quiet()
        server.resetLog()
        await mail.sync(for: account).sync()
        await quiet()
        XCTAssertEqual(server.calls.map(\.kind), ["batch"])
    }

    func testAnOlderSignInWorksWithoutContacts() async throws {
        server.allowsContacts = false
        server.seed(4)
        let mail = try makeService()
        let denied = Flag()
        mail.onContactsDenied = { denied.add($0) }
        for _ in 0..<4 {
            await mail.sync(for: account).sync()
            await quiet()
        }
        // Mail is all there; the person is told once, not at every check.
        XCTAssertEqual(try mail.store.threads(account: account, label: SystemLabel.inbox, limit: 100).count, 4)
        XCTAssertEqual(denied.all, [account])
        XCTAssertEqual(mail.accountsWithoutContacts, [account])
        XCTAssertEqual(server.calls.filter { $0.kind == "contacts" }.count, 1)
        let nobody = await mail.outlookPhoto(for: "dana@example.com")
        XCTAssertNil(nobody)
    }

    // MARK: Signature

    func testTheSignatureWrittenInMachGoesUnderOutgoingMail() throws {
        let mail = try makeService()
        var saved = try XCTUnwrap(try mail.store.account(account))
        XCTAssertEqual(saved.signatureHTML, "")
        try mail.store.setOwnSignature("Ahmed\nmach.ahmedkhaleel.com <hi>", account: account)
        saved = try XCTUnwrap(try mail.store.account(account))
        XCTAssertEqual(saved.ownSignature, "Ahmed\nmach.ahmedkhaleel.com <hi>")
        XCTAssertTrue(saved.signatureHTML.hasPrefix("Ahmed<br>"))
        XCTAssertTrue(saved.signatureHTML.contains("&lt;hi&gt;"))
        let html = Composer.html(for: Draft(accountId: account, to: "x@example.com", subject: "s", body: "Hello"), signature: saved.signatureHTML)
        XCTAssertTrue(html.contains("Hello") && html.contains("class=\"gmail_signature\">Ahmed<br>"))
        // One written here wins over the mail service's; cleared, the service's is back.
        try mail.store.pool.write { try $0.execute(sql: "UPDATE account SET signature = '<b>From Gmail</b>'") }
        XCTAssertTrue(try XCTUnwrap(try mail.store.account(account)).signatureHTML.hasPrefix("Ahmed"))
        try mail.store.setOwnSignature("  ", account: account)
        XCTAssertEqual(try XCTUnwrap(try mail.store.account(account)).signatureHTML, "<b>From Gmail</b>")
    }
}
