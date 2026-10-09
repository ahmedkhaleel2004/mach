import Foundation
import GRDB

// Doors for the headless benchmarks (`blitzbench`) into parts of the store that only sync calls.
// Marked as a private interface, so the app cannot reach them by accident.

extension Store {
    @_spi(Bench) public func benchSaveMessages(account: String, messages: [Message]) throws {
        try saveMessages(account: account, messages: messages)
    }

    @_spi(Bench) public func benchSaveThreads(account: String, threads: [(id: String, messages: [Message])]) throws {
        try saveThreads(account: account, threads: threads)
    }

    @_spi(Bench) public func benchApplyLabelChanges(account: String, changes: [(messageId: String, add: [String], remove: [String])], deleted: [String]) throws -> [String] {
        try applyLabelChanges(account: account, changes: changes.map { LabelChange(messageId: $0.messageId, add: $0.add, remove: $0.remove) }, deleted: deleted)
    }

    @_spi(Bench) public func benchRecompute(account: String, threadIds: [String]) throws {
        try pool.write { db in
            for id in threadIds { try self.recompute(db, account: account, threadId: id) }
        }
    }

    @_spi(Bench) public func benchRecomputeSnoozed(account: String) throws { try recomputeSnoozed(account: account) }
    @_spi(Bench) public func benchIncompleteThreads(account: String, limit: Int) throws -> [String] { try incompleteThreads(account: account, limit: limit) }
    @_spi(Bench) public func benchReadyOps(account: String, limit: Int) throws -> [PendingOp] { try readyOps(account: account, limit: limit) }
    @_spi(Bench) public func benchNextOpDelay(account: String) throws -> Int64? { try nextOpDelay(account: account) }
    @_spi(Bench) public func benchDueSnoozes(account: String) throws -> [String] { try dueSnoozes(account: account) }
    @_spi(Bench) public func benchNextSnooze() throws -> Int64? { try nextSnooze() }
    @_spi(Bench) public func benchMessageIds(account: String, withLabel label: String) throws -> [String] {
        try messageIds(account: account, withLabel: label).map { $0.id + "/" + $0.threadId }
    }
    @_spi(Bench) public func benchWholeThreads(account: String, among ids: [String]) throws -> Set<String> { try wholeThreads(account: account, among: ids) }
    @_spi(Bench) public func benchServerMessageIds(account: String, threadIds: [String]) throws -> [String] { try serverMessageIds(account: account, threadIds: threadIds) }
    @_spi(Bench) public func benchLastMessages(account: String, threadIds: [String]) throws -> [Message] { try lastMessages(account: account, threadIds: threadIds) }
    @_spi(Bench) public func benchNotable(account: String, ids: [String]) throws -> [Message] { try notable(account: account, ids: ids) }
    @_spi(Bench) public func benchKnownMessageIds(account: String, among ids: [String]) throws -> Set<String> { try knownMessageIds(account: account, among: ids) }
    @_spi(Bench) public func benchSnoozeLabelIds(account: String) throws -> [String] { try snoozeLabelIds(account: account) }
}

extension Message {
    @_spi(Bench) public static func bench(accountId: String, id: String, threadId: String, internalDate: Int64, sender: String, toList: String,
                                          subject: String, snippet: String, labelIds: [String], refs: String, bodyHTML: String?, bodyText: String? = nil) -> Message {
        Message(accountId: accountId, id: id, threadId: threadId, internalDate: internalDate, sender: sender, toList: toList, ccList: "", bccList: "",
                replyTo: "", subject: subject, snippet: snippet, labelIds: labelIds, messageIdHeader: "<\(id)@bench.invalid>", refs: refs,
                bodyHTML: bodyHTML, bodyText: bodyText, attachments: [])
    }
}
