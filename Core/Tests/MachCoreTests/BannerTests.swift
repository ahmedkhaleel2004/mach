import MachFake
import XCTest
@testable import MachCore

/// New-mail banners come down when their mail is read, archived or deleted, here or anywhere else, and never
/// before the device has heard of the mail.
final class BannerTests: XCTestCase {
    private struct Tokens: TokenStore {
        func load(account: String) -> TokenSet? { TokenSet(refreshToken: "none", accessToken: "fake-" + account, expiry: .distantFuture) }
        func save(_ tokens: TokenSet, account: String) {}
        func delete(account: String) {}
    }

    private let account = "banner-test@example.com"

    private func makeService() throws -> MailService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mach-banner-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let mail = try MailService(directory: directory, client: OAuthClient(clientId: "test", clientSecret: nil), tokens: Tokens(),
                                   transport: GmailTransport(protocolClasses: [FakeGmailProtocol.self], speedup: 5000))
        try mail.store.saveAccount(Account(id: account, name: "Test"))
        return mail
    }

    private func banner(_ server: FakeGmail, _ id: String) -> Banner {
        Banner(id: id, account: account, thread: server.threadId(of: id)!, delivered: Date())
    }

    private func stale(_ ledger: inout BannerLedger, _ banners: [Banner], _ mail: MailService) throws -> [String] {
        try ledger.stale(banners, waiting: mail.store.waitingThreads(), synced: mail.syncedFrom).sorted()
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 20_000_000) }

    /// A change made here is written a moment after it is asked for.
    private func written(_ mail: MailService, _ thread: String) async throws {
        while try mail.store.waitingThreads().contains(account + "/" + thread) { try await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testBannersComeDownWhenTheirMailIsDealtWith() async throws {
        let mail = try makeService()
        let server = FakeGmail(email: account, latency: 0.0005)
        defer { server.close() }
        server.seed(inbox: 20, archived: 5, seed: 3)
        await mail.sync(for: account).sync()
        var ledger = BannerLedger()

        // Pushes get here before the mail does: nothing is taken down for mail the device has not heard of.
        let fresh = server.deliver(5)
        var banners = fresh.map { banner(server, $0) }
        XCTAssertEqual(try stale(&ledger, banners, mail), [])
        await settle()
        await mail.sync(for: account).sync()
        XCTAssertEqual(try stale(&ledger, banners, mail), [])

        // Archived here: its banner goes at once, before Gmail has even been told.
        server.latency = 0.3
        mail.modify(account: account, threadIds: [banners[0].thread], add: [], remove: [SystemLabel.inbox])
        try await written(mail, banners[0].thread)
        XCTAssertEqual(try stale(&ledger, banners, mail), [fresh[0]])
        banners.removeFirst()
        // Read here: the same.
        mail.modify(account: account, threadIds: [banners[0].thread], add: [], remove: [SystemLabel.unread])
        try await written(mail, banners[0].thread)
        XCTAssertEqual(try stale(&ledger, banners, mail), [fresh[1]])
        banners.removeFirst()
        server.latency = 0.0005
        while try mail.store.pendingOpCount() > 0 { try await Task.sleep(nanoseconds: 10_000_000) }

        // Archived, read and deleted on another device: gone after the next look at Gmail, the rest stay.
        server.changeLabels(messageIds: [fresh[2]], add: [], remove: ["INBOX"])
        server.changeLabels(messageIds: [fresh[3]], add: [], remove: ["UNREAD"])
        XCTAssertEqual(try stale(&ledger, banners, mail), [])
        await settle()
        await mail.sync(for: account).sync()
        XCTAssertEqual(try stale(&ledger, banners, mail), [fresh[2], fresh[3]].sorted())
        banners.removeFirst(2)
        XCTAssertEqual(banners.map(\.id), [fresh[4]])
        XCTAssertEqual(try stale(&ledger, banners, mail), [])
    }

    /// The phone was not running: mail came and was archived on the Mac before the phone ever stored it. A fresh
    /// app (an empty ledger) takes the banner down once it has looked at Gmail, and not before.
    func testMailDealtWithBeforeTheDeviceEverSawIt() async throws {
        let mail = try makeService()
        let server = FakeGmail(email: account, latency: 0.0005)
        defer { server.close() }
        server.seed(inbox: 20, seed: 3)
        await mail.sync(for: account).sync()
        let gone = server.deliver(2)
        let kept = server.deliver(1)
        let banners = (gone + kept).map { banner(server, $0) }
        server.changeLabels(messageIds: [gone[0]], add: [], remove: ["INBOX"])
        server.delete(messageId: gone[1])
        var ledger = BannerLedger()
        XCTAssertEqual(try stale(&ledger, banners, mail), [])
        await settle()
        await mail.sync(for: account).sync()
        XCTAssertEqual(try stale(&ledger, banners, mail), gone.sorted())
    }

    /// With no connection the device knows nothing new, so every banner stays.
    func testAFailedLookAtGmailTakesNothingDown() async throws {
        let mail = try makeService()
        let server = FakeGmail(email: account, latency: 0.0005)
        server.seed(inbox: 5, seed: 3)
        await mail.sync(for: account).sync()
        let banners = server.deliver(2).map { banner(server, $0) }
        server.close()
        await settle()
        await mail.sync(for: account).sync()
        var ledger = BannerLedger()
        XCTAssertEqual(try stale(&ledger, banners, mail), [])
    }

    func testTheListOfWaitingMailIsToldWhenItChanges() async throws {
        let mail = try makeService()
        let server = FakeGmail(email: account, latency: 0.0005)
        defer { server.close() }
        let ids = server.seed(inbox: 6, seed: 3)
        await mail.sync(for: account).sync()
        let waiting = try mail.store.waitingThreads()
        let thread = try XCTUnwrap(ids.compactMap { server.threadId(of: $0) }.first { waiting.contains(account + "/" + $0) })
        var changes = mail.store.observeWaitingThreads().makeAsyncIterator()
        let first = await changes.next()
        XCTAssertEqual(first, waiting)
        mail.modify(account: account, threadIds: [thread], add: [], remove: [SystemLabel.inbox])
        let second = await changes.next()
        XCTAssertEqual(second, waiting.subtracting([account + "/" + thread]))
    }
}
