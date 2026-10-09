import XCTest
@testable import MachCore

final class EmptyListTests: XCTestCase {
    /// All Inboxes, opened while every inbox is empty, must still show mail that arrives afterwards.
    func testAllInboxesFillsFromEmpty() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mach-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        try store.saveAccount(Account(id: "me@x.com", name: "Me"))
        try store.saveAccount(Account(id: "other@x.com", name: "Other"))
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [[String]] = []
            func add(_ value: [String]) { lock.lock(); values.append(value); lock.unlock() }
            var last: [String]? { lock.lock(); defer { lock.unlock() }; return values.last }
        }
        let lists = Seen()
        let task = Task { for await value in store.observeThreads(account: nil, label: SystemLabel.inbox, limit: 50) { lists.add(value.map(\.id)) } }
        defer { task.cancel() }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(lists.last, [])
        try store.saveMessages(account: "me@x.com", messages: [message("m1", thread: "t1", labels: ["INBOX", "UNREAD"])])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(lists.last, ["t1"])
    }
}
