import Foundation
import GRDB

/// The local copy of the mailbox. Every screen reads from here, never from the network.
public final class Store: @unchecked Sendable {
    public let pool: DatabasePool
    /// Whether promotions, updates and the like are announced too, or only mail from people.
    public var announceBulk = true

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
        }
        pool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE account(
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, historyId TEXT,
                    sortOrder INTEGER NOT NULL DEFAULT 0, signature TEXT NOT NULL DEFAULT '');
                CREATE TABLE label(
                    accountId TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL,
                    PRIMARY KEY(accountId, id));
                CREATE TABLE thread(
                    accountId TEXT NOT NULL, id TEXT NOT NULL, subject TEXT NOT NULL, snippet TEXT NOT NULL,
                    lastDate INTEGER NOT NULL, participants TEXT NOT NULL, messageCount INTEGER NOT NULL,
                    unread INTEGER NOT NULL, starred INTEGER NOT NULL, hasAttachments INTEGER NOT NULL,
                    labelIds TEXT NOT NULL, snoozedUntil INTEGER,
                    PRIMARY KEY(accountId, id));
                CREATE TABLE thread_label(
                    accountId TEXT NOT NULL, labelId TEXT NOT NULL, threadId TEXT NOT NULL, sortDate INTEGER NOT NULL,
                    PRIMARY KEY(accountId, labelId, threadId)) WITHOUT ROWID;
                CREATE INDEX thread_label_order ON thread_label(accountId, labelId, sortDate DESC);
                CREATE TABLE message(
                    accountId TEXT NOT NULL, id TEXT NOT NULL, threadId TEXT NOT NULL, internalDate INTEGER NOT NULL,
                    sender TEXT NOT NULL, toList TEXT NOT NULL, ccList TEXT NOT NULL, bccList TEXT NOT NULL,
                    replyTo TEXT NOT NULL, subject TEXT NOT NULL, snippet TEXT NOT NULL, labelIds TEXT NOT NULL,
                    messageIdHeader TEXT NOT NULL, refs TEXT NOT NULL, bodyHTML TEXT, bodyText TEXT,
                    attachments TEXT NOT NULL,
                    PRIMARY KEY(accountId, id));
                CREATE INDEX message_thread ON message(accountId, threadId, internalDate);
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    subject, people, body, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE snooze(
                    accountId TEXT NOT NULL, threadId TEXT NOT NULL, until INTEGER NOT NULL,
                    PRIMARY KEY(accountId, threadId));
                CREATE TABLE bump(
                    accountId TEXT NOT NULL, threadId TEXT NOT NULL, date INTEGER NOT NULL,
                    PRIMARY KEY(accountId, threadId));
                CREATE TABLE draft(
                    id TEXT PRIMARY KEY NOT NULL, accountId TEXT NOT NULL, threadId TEXT, sourceMessageId TEXT,
                    "to" TEXT NOT NULL, cc TEXT NOT NULL, bcc TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL,
                    quotedHTML TEXT NOT NULL, inReplyTo TEXT NOT NULL, refs TEXT NOT NULL,
                    attachmentPaths TEXT NOT NULL, updatedAt INTEGER NOT NULL, queued INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE op(
                    id INTEGER PRIMARY KEY AUTOINCREMENT, accountId TEXT NOT NULL, kind TEXT NOT NULL,
                    threadId TEXT NOT NULL, addLabels TEXT NOT NULL, removeLabels TEXT NOT NULL, draftId TEXT,
                    notBefore INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, lastError TEXT);
                CREATE TABLE contact(
                    accountId TEXT NOT NULL, email TEXT NOT NULL, name TEXT NOT NULL, uses INTEGER NOT NULL,
                    lastUsed INTEGER NOT NULL,
                    PRIMARY KEY(accountId, email));
                CREATE TABLE full_thread(
                    accountId TEXT NOT NULL, threadId TEXT NOT NULL,
                    PRIMARY KEY(accountId, threadId)) WITHOUT ROWID;
                CREATE TABLE loaded(
                    accountId TEXT NOT NULL, key TEXT NOT NULL, pageToken TEXT, done INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(accountId, key));
                """)
        }
        migrator.registerMigration("v2-avatars") { db in
            try db.execute(sql: """
                ALTER TABLE thread ADD COLUMN avatarEmail TEXT NOT NULL DEFAULT '';
                ALTER TABLE thread ADD COLUMN avatarName TEXT NOT NULL DEFAULT '';
                """)
            // Fill the new columns for mail that is already here.
            for row in try Row.fetchAll(db, sql: """
                SELECT m.accountId AS account, m.threadId AS thread, m.sender AS sender, m.toList AS toList FROM message m
                WHERE m.internalDate = (SELECT max(internalDate) FROM message x WHERE x.accountId = m.accountId AND x.threadId = m.threadId AND x.sender NOT LIKE '%' || x.accountId || '%')
                   OR NOT EXISTS (SELECT 1 FROM message x WHERE x.accountId = m.accountId AND x.threadId = m.threadId AND x.sender NOT LIKE '%' || x.accountId || '%')
                GROUP BY m.accountId, m.threadId
                """) {
                let account: String = row["account"]
                let from = EmailAddress.parseList(row["sender"]).first
                let face = from?.email == account ? EmailAddress.parseList(row["toList"]).first : from
                guard let face else { continue }
                try db.execute(sql: "UPDATE thread SET avatarEmail = ?, avatarName = ? WHERE accountId = ? AND id = ?",
                               arguments: [face.email, face.displayName, account, row["thread"] as String])
            }
        }
        migrator.registerMigration("v3-draft-sync") { db in
            try db.execute(sql: """
                ALTER TABLE draft ADD COLUMN remoteDraftId TEXT;
                ALTER TABLE draft ADD COLUMN remoteMessageId TEXT;
                ALTER TABLE draft ADD COLUMN remoteThreadId TEXT;
                ALTER TABLE draft ADD COLUMN uploadedAt INTEGER NOT NULL DEFAULT 0;
                """)
        }
        migrator.registerMigration("perf-thread-label-by-thread") { db in
            // Rebuilding a thread looks up the lists it is in. Without this that walked every list row of the account.
            // (The date rides along so the index answers the lookup by itself; SQLite's planner passes over it otherwise.)
            try db.execute(sql: "CREATE INDEX thread_label_thread ON thread_label(accountId, threadId, sortDate)")
        }
        migrator.registerMigration("perf-thread-by-date") { db in
            // Lets search walk threads newest first without reading the thread rows themselves (see `search`).
            try db.execute(sql: "CREATE INDEX thread_recent ON thread(lastDate DESC, accountId, id)")
        }
        return migrator
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func json(_ values: [String]) -> String {
        (try? String(data: JSONEncoder().encode(values), encoding: .utf8)) ?? "[]"
    }

    static func strings(_ json: String) -> [String] {
        (try? decodeStrings(json)) ?? []
    }

    /// Reads a stored list of strings (`["INBOX","UNREAD"]`). Nearly every list is plain enough to be cut apart by
    /// hand, which is many times faster than a JSON decoder; anything with an escape or a surprise goes to the decoder.
    static func decodeStrings(_ json: String) throws -> [String] {
        var json = json
        let plain: [String]? = json.withUTF8 { bytes in
            let count = bytes.count
            guard count >= 2, bytes[0] == UInt8(ascii: "["), bytes[count - 1] == UInt8(ascii: "]") else { return nil }
            if count == 2 { return [] }
            var result: [String] = []
            var index = 1
            while true {
                guard index < count - 1, bytes[index] == UInt8(ascii: "\"") else { return nil }
                index += 1
                let start = index
                while index < count - 1, bytes[index] != UInt8(ascii: "\"") {
                    // Escapes and control characters are the decoder's business.
                    if bytes[index] == UInt8(ascii: "\\") || bytes[index] < 0x20 { return nil }
                    index += 1
                }
                guard index < count - 1 else { return nil }
                guard let text = String(validating: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self) else { return nil }
                result.append(text)
                index += 1
                if index == count - 1 { return result }
                guard bytes[index] == UInt8(ascii: ",") else { return nil }
                index += 1
            }
        }
        if let plain { return plain }
        return try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    /// The thread table's columns in a fixed order, so rows can be read by position (see `thread(_:)`).
    static let threadColumns = """
        thread.accountId, thread.id, thread.subject, thread.snippet, thread.lastDate, thread.participants, thread.messageCount, \
        thread.unread, thread.starred, thread.hasAttachments, thread.labelIds, thread.snoozedUntil, thread.avatarEmail, thread.avatarName
        """

    /// A thread from a row selected with `threadColumns`. Reading by position skips the per-row name lookups and the
    /// JSON decoder that the generic record decoding goes through, which were most of the cost of reading a list.
    static func thread(_ row: Row) throws -> MailThread {
        MailThread(accountId: row[0], id: row[1], subject: row[2], snippet: row[3], lastDate: row[4], participants: try decodeStrings(row[5]),
                   messageCount: row[6], unread: row[7], starred: row[8], hasAttachments: row[9], labelIds: try decodeStrings(row[10]),
                   snoozedUntil: row[11], avatarEmail: row[12], avatarName: row[13])
    }

    private static func fetchThreads(_ db: Database, sql: String, arguments: StatementArguments) throws -> [MailThread] {
        var threads: [MailThread] = []
        let rows = try Row.fetchCursor(db.cachedStatement(sql: sql), arguments: arguments)
        while let row = try rows.next() { threads.append(try thread(row)) }
        return threads
    }

    // MARK: - Accounts and labels

    public func accounts() throws -> [Account] {
        try pool.read { try Account.order(Column("sortOrder"), Column("id")).fetchAll($0) }
    }

    public func account(_ id: String) throws -> Account? {
        try pool.read { try Account.fetchOne($0, key: id) }
    }

    /// The name to send mail under: the one set in Gmail, else the name other people most often write to this address with.
    /// (Gmail does not add a name by itself, and its API does not expose the Google account's name.)
    public func senderName(account id: String) throws -> String {
        try pool.read { db in
            if let name = try String.fetchOne(db, sql: "SELECT name FROM account WHERE id = ?", arguments: [id]), !name.isEmpty { return name }
            var counts: [String: Int] = [:]
            let received = try Row.fetchAll(db, sql: """
                SELECT toList, ccList FROM message WHERE accountId = ? AND labelIds NOT LIKE '%"SENT"%' AND toList LIKE ?
                ORDER BY internalDate DESC LIMIT 400
                """, arguments: [id, "%<\(id)>%"])
            for row in received {
                for address in EmailAddress.parseList(row["toList"]) + EmailAddress.parseList(row["ccList"]) where address.email == id && !address.name.isEmpty && !address.name.contains("@") {
                    counts[address.name, default: 0] += 1
                }
            }
            if counts.isEmpty {
                for sender in try String.fetchAll(db, sql: "SELECT sender FROM message WHERE accountId = ? AND labelIds LIKE '%\"SENT\"%' ORDER BY internalDate DESC LIMIT 200", arguments: [id]) {
                    if let address = EmailAddress.parseList(sender).first, address.email == id, !address.name.isEmpty { counts[address.name, default: 0] += 1 }
                }
            }
            // "Ahmed" and "Ahmed Khaleel" are both common; among the common ones the fuller name is the right one.
            let top = counts.values.max() ?? 0
            return counts.filter { $0.value * 3 >= top }.max { a, b in
                let wa = a.key.split(separator: " ").count, wb = b.key.split(separator: " ").count
                return wa != wb ? wa < wb : a.value < b.value
            }?.key ?? ""
        }
    }

    public func saveAccount(_ account: Account) throws {
        try pool.write { try account.save($0) }
    }

    func setHistoryId(_ historyId: String?, account: String) throws {
        try pool.write { try $0.execute(sql: "UPDATE account SET historyId = ? WHERE id = ?", arguments: [historyId, account]) }
    }

    func setProfile(name: String, signature: String, account: String) throws {
        try pool.write { try $0.execute(sql: "UPDATE account SET name = ?, signature = ? WHERE id = ?", arguments: [name, signature, account]) }
    }

    /// Removes an account and everything stored for it.
    public func deleteAccount(_ id: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid IN (SELECT rowid FROM message WHERE accountId = ?)", arguments: [id])
            for table in ["message", "thread", "thread_label", "label", "snooze", "bump", "draft", "op", "contact", "loaded", "full_thread"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE accountId = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id])
        }
    }

    func replaceLabels(_ labels: [MailLabel], account: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM label WHERE accountId = ?", arguments: [account])
            for label in labels { try label.insert(db) }
        }
    }

    public func labels(account: String) throws -> [MailLabel] {
        try pool.read { try MailLabel.filter(Column("accountId") == account).order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }
    }

    // MARK: - Paging state for lists loaded on demand

    func loadedState(account: String, key: String) throws -> (pageToken: String?, done: Bool)? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT pageToken, done FROM loaded WHERE accountId = ? AND key = ?", arguments: [account, key])
                .map { ($0["pageToken"] as String?, ($0["done"] as Int) != 0) }
        }
    }

    func setLoadedState(account: String, key: String, pageToken: String?, done: Bool) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO loaded(accountId, key, pageToken, done) VALUES (?, ?, ?, ?)",
                           arguments: [account, key, pageToken, done ? 1 : 0])
        }
    }

    // MARK: - Writing threads that came from Gmail

    func knownMessageIds(account: String, among ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in
            var found = Set<String>()
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start..<min(start + 500, ids.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                found.formUnion(try String.fetchAll(db, sql: "SELECT id FROM message WHERE accountId = ? AND id IN (\(marks))",
                                                    arguments: StatementArguments([account] + chunk)))
            }
            return found
        }
    }

    /// Ids of stored messages that carry a label. Only used when comparing with Gmail after a long absence.
    func messageIds(account: String, withLabel label: String) throws -> [(id: String, threadId: String)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, threadId FROM message WHERE accountId = ? AND id NOT LIKE 'local-%' AND labelIds LIKE ?",
                             arguments: [account, "%\"\(label)\"%"]).map { (id: $0["id"], threadId: $0["threadId"]) }
        }
    }

    /// Stores single messages that came from Gmail and rebuilds the threads they belong to.
    private static func accountExists(_ db: Database, _ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM account WHERE id = ?)", arguments: [id]) ?? false
    }

    func saveMessages(account: String, messages: [Message]) throws {
        guard !messages.isEmpty else { return }
        let searchText = try searchText(account: account, messages: messages)
        try pool.write { db in
            // A download that finishes after the account was removed must not bring its mail back.
            guard try Self.accountExists(db, account) else { return }
            var touched = Set<String>()
            var pending = PendingModifies(account: account)
            let exists = try db.cachedStatement(sql: "SELECT 1 FROM message WHERE accountId = ? AND id = ?")
            let relabel = try db.cachedStatement(sql: "UPDATE message SET labelIds = ? WHERE accountId = ? AND id = ?")
            for var message in messages {
                touched.insert(message.threadId)
                for op in try pending.ops(db, threadId: message.threadId) { message.labelIds = Self.apply(add: op.addLabels, remove: op.removeLabels, to: message.labelIds) }
                if try Int.fetchOne(exists, arguments: [account, message.id]) != nil {
                    try relabel.execute(arguments: [Self.json(message.labelIds), account, message.id])
                } else {
                    try self.insertMessage(db, message, searchText: searchText[message.id])
                }
            }
            for threadId in touched { try self.recompute(db, account: account, threadId: threadId) }
        }
    }

    /// The text of a message that search looks through.
    private static func searchText(_ message: Message) -> String {
        message.bodyText.map { String($0.prefix(40_000)) } ?? message.bodyHTML.map { HTMLText.strip($0) } ?? ""
    }

    /// Search text for the messages that are new here, worked out before the database is locked for writing:
    /// turning a long newsletter into plain text takes milliseconds, and archiving a thread should not wait behind it.
    private func searchText(account: String, messages: [Message]) throws -> [String: String] {
        let known = try knownMessageIds(account: account, among: messages.map(\.id))
        var text: [String: String] = [:]
        for message in messages where !known.contains(message.id) && text[message.id] == nil { text[message.id] = Self.searchText(message) }
        return text
    }

    /// The label changes made here that Gmail has not received yet, thread by thread. Asked for once per message while
    /// sync stores mail; the queue is nearly always empty, and then one look at it answers for every thread.
    private struct PendingModifies {
        let account: String
        private var none: Bool?
        private var byThread: [String: [PendingOp]] = [:]

        init(account: String) { self.account = account }

        mutating func ops(_ db: Database, threadId: String) throws -> [PendingOp] {
            if none == nil {
                none = try Int.fetchOne(db, sql: "SELECT 1 FROM op WHERE accountId = ? AND kind = ? LIMIT 1", arguments: [account, PendingOp.modify]) == nil
            }
            if none == true { return [] }
            if let known = byThread[threadId] { return known }
            let ops = try PendingOp.fetchAll(db, sql: "SELECT * FROM op WHERE accountId = ? AND threadId = ? AND kind = ? ORDER BY id",
                                             arguments: [account, threadId, PendingOp.modify])
            byThread[threadId] = ops
            return ops
        }
    }

    struct LabelChange {
        var messageId: String
        var add: [String]
        var remove: [String]
    }

    /// Applies label changes Gmail reported. Returns the ids it does not have, which then need downloading.
    func applyLabelChanges(account: String, changes: [LabelChange], deleted: [String]) throws -> [String] {
        guard !changes.isEmpty || !deleted.isEmpty else { return [] }
        return try pool.write { db in
            var unknown: [String] = []
            var touched = Set<String>()
            var pending = PendingModifies(account: account)
            let lookup = try db.cachedStatement(sql: "SELECT threadId, labelIds FROM message WHERE accountId = ? AND id = ?")
            let relabel = try db.cachedStatement(sql: "UPDATE message SET labelIds = ? WHERE accountId = ? AND id = ?")
            for change in changes {
                guard let row = try Row.fetchOne(lookup, arguments: [account, change.messageId]) else {
                    if !unknown.contains(change.messageId) { unknown.append(change.messageId) }
                    continue
                }
                let current = Self.strings(row["labelIds"])
                let threadId: String = row["threadId"]
                var updated = Self.apply(add: change.add, remove: change.remove, to: current)
                // Changes made here that Gmail has not received yet stay on top of what Gmail reports.
                for op in try pending.ops(db, threadId: threadId) {
                    updated = Self.apply(add: op.addLabels, remove: op.removeLabels, to: updated)
                }
                if updated != current {
                    try relabel.execute(arguments: [Self.json(updated), account, change.messageId])
                    touched.insert(threadId)
                }
            }
            for id in deleted {
                guard let row = try Row.fetchOne(db, sql: "SELECT rowid, threadId FROM message WHERE accountId = ? AND id = ?", arguments: [account, id]) else { continue }
                let rowid: Int64 = row["rowid"]
                try db.execute(sql: "DELETE FROM message WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [rowid])
                touched.insert(row["threadId"])
            }
            for threadId in touched { try self.recompute(db, account: account, threadId: threadId) }
            return unknown
        }
    }

    /// Threads that look like conversations (a message refers to an earlier one) but were never downloaded whole.
    func incompleteThreads(account: String, limit: Int) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT message.threadId FROM message
                WHERE message.accountId = ? AND message.refs != '' AND message.id NOT LIKE 'local-%'
                AND NOT EXISTS (SELECT 1 FROM full_thread WHERE full_thread.accountId = message.accountId AND full_thread.threadId = message.threadId)
                ORDER BY message.internalDate DESC LIMIT ?
                """, arguments: [account, limit])
        }
    }

    public func threadNeedsCompleting(account: String, threadId: String) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM message WHERE accountId = ? AND threadId = ? AND refs != '' AND id NOT LIKE 'local-%')
                AND NOT EXISTS (SELECT 1 FROM full_thread WHERE accountId = ? AND threadId = ?)
                """, arguments: [account, threadId, account, threadId]) ?? false
        }
    }

    /// Stores the server's version of a thread. `messages` empty means the thread is gone.
    func saveThread(account: String, threadId: String, messages: [Message]) throws {
        let searchText = try searchText(account: account, messages: messages)
        try pool.write { try self.saveThread($0, account: account, threadId: threadId, messages: messages, searchText: searchText) }
    }

    func saveThreads(account: String, threads: [(id: String, messages: [Message])]) throws {
        guard !threads.isEmpty else { return }
        let searchText = try searchText(account: account, messages: threads.flatMap(\.messages))
        try pool.write { db in
            for thread in threads {
                try self.saveThread(db, account: account, threadId: thread.id, messages: thread.messages, searchText: searchText)
            }
        }
    }

    private func saveThread(_ db: Database, account: String, threadId: String, messages: [Message], searchText: [String: String]) throws {
        guard try Self.accountExists(db, account) else { return }
        let pending = try PendingOp.fetchAll(db, sql: "SELECT * FROM op WHERE accountId = ? AND threadId = ? AND kind = ? ORDER BY id",
                                             arguments: [account, threadId, PendingOp.modify])
        var existing: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, rowid FROM message WHERE accountId = ? AND threadId = ?", arguments: [account, threadId]) {
            existing[row["id"]] = row["rowid"]
        }
        let draftOps = try PendingOp.fetchAll(db, sql: "SELECT * FROM op WHERE accountId = ? AND threadId = ? AND kind IN (?, ?)",
                                              arguments: [account, threadId, PendingOp.sendGmailDraft, PendingOp.deleteGmailDraft])
        let sendingDrafts = Set(draftOps.filter { $0.kind == PendingOp.sendGmailDraft }.compactMap(\.draftId))
        let deletingDrafts = Set(draftOps.filter { $0.kind == PendingOp.deleteGmailDraft }.compactMap(\.draftId))
        var seen = Set<String>()
        for var message in messages {
            if deletingDrafts.contains(message.id) { continue }
            seen.insert(message.id)
            if sendingDrafts.contains(message.id) {
                if existing[message.id] == nil {
                    message.labelIds = [SystemLabel.sent]
                    try insertMessage(db, message, searchText: searchText[message.id])
                }
                continue
            }
            // Changes made here that Gmail has not received yet stay on top of what Gmail says.
            for op in pending {
                message.labelIds = Self.apply(add: op.addLabels, remove: op.removeLabels, to: message.labelIds)
            }
            if existing[message.id] != nil {
                try db.execute(sql: "UPDATE message SET labelIds = ? WHERE accountId = ? AND id = ?",
                               arguments: [Self.json(message.labelIds), account, message.id])
            } else {
                try insertMessage(db, message, searchText: searchText[message.id])
            }
        }
        // A message newer than everything in this answer arrived while the answer was on its way; it stays.
        let newestInAnswer = messages.map(\.internalDate).max() ?? .max
        var keptNewer = false
        for (id, rowid) in existing where !seen.contains(id) && !id.hasPrefix("local-") {
            if !messages.isEmpty, let date = try Int64.fetchOne(db, sql: "SELECT internalDate FROM message WHERE rowid = ?", arguments: [rowid]), date > newestInAnswer {
                keptNewer = true
                continue
            }
            try db.execute(sql: "DELETE FROM message WHERE rowid = ?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [rowid])
        }
        if messages.isEmpty || keptNewer {
            try db.execute(sql: "DELETE FROM full_thread WHERE accountId = ? AND threadId = ?", arguments: [account, threadId])
        } else {
            try db.execute(sql: "INSERT OR IGNORE INTO full_thread(accountId, threadId) VALUES (?, ?)", arguments: [account, threadId])
        }
        try recompute(db, account: account, threadId: threadId)
    }

    private func insertMessage(_ db: Database, _ message: Message, searchText: String? = nil) throws {
        try message.insert(db, onConflict: .replace)
        let rowid = db.lastInsertedRowID
        let body = searchText ?? Self.searchText(message)
        try db.execute(sql: "INSERT INTO message_fts(rowid, subject, people, body) VALUES (?, ?, ?, ?)",
                       arguments: [rowid, message.subject, [message.sender, message.toList, message.ccList].map(Message.readable).joined(separator: " "), body])
        guard !message.isLocal, !message.isDraft else { return }
        if message.labelIds.contains(SystemLabel.sent) {
            for address in EmailAddress.parseList(message.toList) + EmailAddress.parseList(message.ccList) {
                try bumpContact(db, account: message.accountId, address: address, weight: 5, date: message.internalDate)
            }
        } else {
            let from = message.from
            let local = from.email.split(separator: "@").first.map(String.init) ?? ""
            let automated = ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "mailer-daemon", "bounce"].contains { local.contains($0) }
            if !automated { try bumpContact(db, account: message.accountId, address: from, weight: 1, date: message.internalDate) }
        }
    }

    private func bumpContact(_ db: Database, account: String, address: EmailAddress, weight: Int, date: Int64) throws {
        guard address.email.contains("@"), address.email != account else { return }
        try db.execute(sql: """
            INSERT INTO contact(accountId, email, name, uses, lastUsed) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(accountId, email) DO UPDATE SET
                uses = uses + excluded.uses,
                name = CASE WHEN excluded.name != '' AND excluded.lastUsed >= lastUsed THEN excluded.name ELSE name END,
                lastUsed = max(lastUsed, excluded.lastUsed)
            """, arguments: [account, address.email, address.name, weight, date])
    }

    static func apply(add: [String], remove: [String], to labels: [String]) -> [String] {
        var result = labels.filter { !remove.contains($0) }
        // Names starting with "^" are stand-ins that only mean something when the change is sent to Gmail.
        for label in add where !label.hasPrefix("^") && !result.contains(label) { result.append(label) }
        return result
    }

    // MARK: - Snooze labels

    func snoozeLabelIds(account: String) throws -> [String] {
        try pool.read { try Self.snoozeLabelIds($0, account: account) }
    }

    private static func snoozeLabelIds(_ db: Database, account: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM label WHERE accountId = ? AND name LIKE ?", arguments: [account, SystemLabel.snoozePrefix + "%"])
    }

    func labelId(account: String, named name: String) throws -> String? {
        try pool.read { try String.fetchOne($0, sql: "SELECT id FROM label WHERE accountId = ? AND name = ?", arguments: [account, name]) }
    }

    func saveLabel(_ label: MailLabel) throws {
        try pool.write { try label.save($0) }
    }

    func hasLabels(account: String, ids: Set<String>) throws -> Bool {
        guard !ids.isEmpty else { return true }
        return try pool.read { db in
            let marks = databaseQuestionMarks(count: ids.count)
            let known = try Int.fetchOne(db, sql: "SELECT count(*) FROM label WHERE accountId = ? AND id IN (\(marks))", arguments: StatementArguments([account] + Array(ids))) ?? 0
            return known == ids.count
        }
    }

    /// Rebuilds every thread that carries a snooze label, after the label list changed.
    func recomputeSnoozed(account: String) throws {
        try pool.write { db in
            let ids = try Self.snoozeLabelIds(db, account: account)
            guard !ids.isEmpty else { return }
            let marks = databaseQuestionMarks(count: ids.count)
            for threadId in try String.fetchAll(db, sql: "SELECT DISTINCT threadId FROM thread_label WHERE accountId = ? AND labelId IN (\(marks))", arguments: StatementArguments([account] + ids)) {
                try self.recompute(db, account: account, threadId: threadId)
            }
        }
    }

    /// Rebuilds the thread row and its list memberships from its messages.
    func recompute(_ db: Database, account: String, threadId: String) throws {
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT id, internalDate, sender, toList, subject, snippet, labelIds, attachments
            FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate, id
            """), arguments: [account, threadId])
        guard !rows.isEmpty else {
            try db.execute(sql: "DELETE FROM thread_label WHERE accountId = ? AND threadId = ?", arguments: [account, threadId])
            try db.execute(sql: "DELETE FROM thread WHERE accountId = ? AND id = ?", arguments: [account, threadId])
            try db.execute(sql: "DELETE FROM snooze WHERE accountId = ? AND threadId = ?", arguments: [account, threadId])
            try db.execute(sql: "DELETE FROM bump WHERE accountId = ? AND threadId = ?", arguments: [account, threadId])
            return
        }
        var union: [String] = []
        var participants: [String] = []
        var visible = false
        var hasAttachments = false
        var hasRealMessage = false
        var face: EmailAddress?
        var fallbackFace: EmailAddress?
        var lastDate: Int64 = 0
        var snippet = ""
        for row in rows {
            let labels = Self.strings(row["labelIds"])
            for label in labels where !union.contains(label) { union.append(label) }
            if !labels.contains(SystemLabel.trash) && !labels.contains(SystemLabel.spam) { visible = true }
            let attachments: String = row["attachments"]
            if attachments.contains("\"isInline\":false") { hasAttachments = true }
            let isDraft = labels.contains(SystemLabel.draft)
            if !isDraft { hasRealMessage = true }
            if !isDraft || lastDate == 0 {
                lastDate = row["internalDate"]
                snippet = row["snippet"]
            }
            let sender: String = row["sender"]
            let address = EmailAddress.parseList(sender).first
            let name = address.map { $0.email == account ? "me" : $0.displayName } ?? sender
            if !name.isEmpty, !participants.contains(name) { participants.append(name) }
            if let address, address.email != account {
                face = address
            } else if let recipient = EmailAddress.parseList(row["toList"]).first(where: { $0.email != account }) {
                fallbackFace = recipient
            }
        }
        let subject: String = rows[0]["subject"]
        var snoozedUntil = try Int64.fetchOne(db.cachedStatement(sql: "SELECT until FROM snooze WHERE accountId = ? AND threadId = ?"), arguments: [account, threadId])
        if snoozedUntil != nil, union.contains(SystemLabel.inbox) {
            // It came back to the inbox by itself, for example because someone replied.
            try db.execute(sql: "DELETE FROM snooze WHERE accountId = ? AND threadId = ?", arguments: [account, threadId])
            snoozedUntil = nil
        }
        // A snooze made on another device shows up as its label.
        let custom = union.filter { $0.hasPrefix("Label_") }
        if snoozedUntil == nil, !custom.isEmpty, !union.contains(SystemLabel.inbox) {
            let marks = databaseQuestionMarks(count: custom.count)
            for name in try String.fetchAll(db, sql: "SELECT name FROM label WHERE accountId = ? AND id IN (\(marks)) AND name LIKE ?",
                                            arguments: StatementArguments([account] + custom + [SystemLabel.snoozePrefix + "%"])) {
                if let time = SystemLabel.snoozeTime(fromLabelName: name) { snoozedUntil = min(snoozedUntil ?? time, time) }
            }
        }
        let thread = MailThread(
            accountId: account, id: threadId, subject: subject, snippet: snippet, lastDate: lastDate,
            participants: participants, messageCount: rows.count,
            unread: union.contains(SystemLabel.unread), starred: union.contains(SystemLabel.starred),
            hasAttachments: hasAttachments, labelIds: union, snoozedUntil: snoozedUntil,
            avatarEmail: (face ?? fallbackFace)?.email ?? "", avatarName: (face ?? fallbackFace)?.displayName ?? "")
        // Most rebuilds change little or nothing, so only what differs from what is stored is written.
        let stored = try Self.fetchThreads(db, sql: "SELECT \(Self.threadColumns) FROM thread WHERE accountId = ? AND id = ?", arguments: [account, threadId]).first
        if stored == nil {
            try db.cachedStatement(sql: """
                INSERT INTO thread(accountId, id, subject, snippet, lastDate, participants, messageCount, unread, starred, hasAttachments,
                    labelIds, snoozedUntil, avatarEmail, avatarName) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """).execute(arguments: [
                    account, threadId, thread.subject, thread.snippet, thread.lastDate, Self.json(thread.participants), thread.messageCount, thread.unread,
                    thread.starred, thread.hasAttachments, Self.json(thread.labelIds), thread.snoozedUntil, thread.avatarEmail, thread.avatarName])
        } else if stored != thread {
            try db.cachedStatement(sql: """
                UPDATE thread SET subject = ?, snippet = ?, lastDate = ?, participants = ?, messageCount = ?, unread = ?, starred = ?, hasAttachments = ?,
                    labelIds = ?, snoozedUntil = ?, avatarEmail = ?, avatarName = ? WHERE accountId = ? AND id = ?
                """).execute(arguments: [
                    thread.subject, thread.snippet, thread.lastDate, Self.json(thread.participants), thread.messageCount, thread.unread, thread.starred,
                    thread.hasAttachments, Self.json(thread.labelIds), thread.snoozedUntil, thread.avatarEmail, thread.avatarName, account, threadId])
        }

        var memberships = union
        if visible { memberships.append(SystemLabel.all) }
        if snoozedUntil != nil { memberships.append(SystemLabel.snoozed) }
        if union.contains(SystemLabel.inbox) {
            let bulk = union.contains { SystemLabel.bulkCategories.contains($0) }
            let personal = union.contains("CATEGORY_PERSONAL") || union.contains(SystemLabel.sent) || union.contains(SystemLabel.starred)
            memberships.append(bulk && !personal ? SystemLabel.inboxOther : SystemLabel.inboxMain)
        } else if visible, snoozedUntil == nil, hasRealMessage {
            memberships.append(SystemLabel.done)
        }
        let bump = try Int64.fetchOne(db.cachedStatement(sql: "SELECT date FROM bump WHERE accountId = ? AND threadId = ?"), arguments: [account, threadId]) ?? 0
        var listed: [String: Int64] = [:]
        let current = try Row.fetchCursor(db.cachedStatement(sql: "SELECT labelId, sortDate FROM thread_label WHERE accountId = ? AND threadId = ?"), arguments: [account, threadId])
        while let row = try current.next() { listed[row[0]] = row[1] }
        for label in memberships {
            let isInbox = label == SystemLabel.inbox || label == SystemLabel.inboxMain || label == SystemLabel.inboxOther
            let sortDate = isInbox ? max(lastDate, bump) : (label == SystemLabel.snoozed ? (snoozedUntil ?? lastDate) : lastDate)
            if listed.removeValue(forKey: label) != sortDate {
                try db.cachedStatement(sql: "INSERT OR REPLACE INTO thread_label(accountId, labelId, threadId, sortDate) VALUES (?, ?, ?, ?)")
                    .execute(arguments: [account, label, threadId, sortDate])
            }
        }
        // What is left are lists the thread is no longer in.
        for label in listed.keys {
            try db.cachedStatement(sql: "DELETE FROM thread_label WHERE accountId = ? AND labelId = ? AND threadId = ?").execute(arguments: [account, label, threadId])
        }
    }

    // MARK: - Reading

    /// One account's list, or every account's merged by date when `account` is nil.
    private static func fetchThreads(_ db: Database, account: String?, label: String, limit: Int) throws -> [MailThread] {
        let ascending = label == SystemLabel.snoozed
        let sql = """
            SELECT \(threadColumns), thread_label.sortDate AS sortDate FROM thread_label
            JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId
            WHERE thread_label.accountId = ? AND thread_label.labelId = ?
            ORDER BY thread_label.sortDate \(ascending ? "ASC" : "DESC") LIMIT ?
            """
        let accounts = try account.map { [$0] } ?? String.fetchAll(db, sql: "SELECT id FROM account ORDER BY sortOrder, id")
        if accounts.count == 1 { return try fetchThreads(db, sql: sql, arguments: [accounts[0], label, limit]) }
        // Each account can fill the whole list by itself, but together they only need `limit` rows. The dates alone
        // (read straight from the index) say how many rows each account contributes, so only those are read in full.
        let dates = try db.cachedStatement(sql: """
            SELECT sortDate FROM thread_label WHERE accountId = ? AND labelId = ? ORDER BY sortDate \(ascending ? "ASC" : "DESC") LIMIT ?
            """)
        var order: [(date: Int64, account: Int)] = []
        for (index, id) in accounts.enumerated() {
            let rows = try Int64.fetchCursor(dates, arguments: [id, label, limit])
            while let date = try rows.next() { order.append((date, index)) }
        }
        order.sort { ascending ? $0.date < $1.date : $0.date > $1.date }
        var share = [Int](repeating: 0, count: accounts.count)
        for entry in order.prefix(limit) { share[entry.account] += 1 }
        var merged: [(MailThread, Int64)] = []
        merged.reserveCapacity(min(limit, order.count))
        let statement = try db.cachedStatement(sql: sql)
        for (index, id) in accounts.enumerated() where share[index] > 0 {
            let rows = try Row.fetchCursor(statement, arguments: [id, label, share[index]])
            while let row = try rows.next() { merged.append((try thread(row), row[14])) }
        }
        merged.sort { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }
        return merged.map(\.0)
    }

    public func threads(account: String?, label: String, limit: Int) throws -> [MailThread] {
        try pool.read { try Self.fetchThreads($0, account: account, label: label, limit: limit) }
    }

    public func thread(account: String, id: String) throws -> MailThread? {
        try pool.read { try Self.fetchThreads($0, sql: "SELECT \(Self.threadColumns) FROM thread WHERE accountId = ? AND id = ?", arguments: [account, id]).first }
    }

    public func messages(account: String, threadId: String) throws -> [Message] {
        try pool.read { db in
            try Message.fetchAll(db.cachedStatement(sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate, id"), arguments: [account, threadId])
        }
    }

    public func message(account: String, id: String) throws -> Message? {
        try pool.read { try Message.fetchOne($0.cachedStatement(sql: "SELECT * FROM message WHERE accountId = ? AND id = ?"), arguments: [account, id]) }
    }

    /// Of the given messages, the ones worth telling the person about: unread, in the inbox, from someone else,
    /// and (when the inbox is split) not promotions, social, updates or forums.
    func notable(account: String, ids: [String]) throws -> [Message] {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in
            let marks = databaseQuestionMarks(count: ids.count)
            return try Message.fetchAll(db, sql: "SELECT * FROM message WHERE accountId = ? AND id IN (\(marks)) ORDER BY internalDate",
                                        arguments: StatementArguments([account] + ids)).filter { message in
                message.labelIds.contains(SystemLabel.inbox) && message.isUnread && !message.labelIds.contains(SystemLabel.sent)
                    && (announceBulk || !message.labelIds.contains { SystemLabel.bulkCategories.contains($0) })
            }
        }
    }

    public func unreadCount(account: String, label: String = SystemLabel.inbox) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM thread_label JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId
                WHERE thread_label.accountId = ? AND thread_label.labelId = ? AND thread.unread = 1
                """, arguments: [account, label]) ?? 0
        }
    }

    /// A stream that yields the list again every time something in it changes.
    public func observeThreads(account: String?, label: String, limit: Int) -> AsyncStream<[MailThread]> {
        // The tables are named here, not left to be worked out from the first read: All Inboxes opened while
        // empty reads so little that it never heard of the mail that arrived next (EmptyListTests).
        stream(ValueObservation.tracking(region: Table("thread_label"), Table("thread"), Table("account")) { db in
            try Self.fetchThreads(db, account: account, label: label, limit: limit)
        })
    }

    /// Yields the conversation again when one of its messages changes. Every write to any message makes SQLite's
    /// change tracking re-read it (it cannot watch a single thread), but a re-read that finds the same messages is
    /// dropped here, so the open conversation is not drawn again for each batch of mail that sync stores.
    public func observeMessages(account: String, threadId: String) -> AsyncStream<[Message]> {
        let observation = ValueObservation.tracking { db in
            try Message.fetchAll(db.cachedStatement(sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate, id"), arguments: [account, threadId])
        }
        return stream(observation.removeDuplicates())
    }

    public func observeAccounts() -> AsyncStream<[Account]> {
        stream(ValueObservation.tracking { try Account.order(Column("sortOrder"), Column("id")).fetchAll($0) }.removeDuplicates())
    }

    /// Unread inbox threads per account.
    public func observeUnreadCounts() -> AsyncStream<[String: Int]> {
        let observation = ValueObservation.tracking { db -> [String: Int] in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT thread_label.accountId AS account, count(*) AS n FROM thread_label
                JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId
                WHERE thread_label.labelId = 'INBOX' AND thread.unread = 1 GROUP BY thread_label.accountId
                """) {
                counts[row["account"]] = row["n"]
            }
            return counts
        }
        return stream(observation.removeDuplicates())
    }

    private func stream<Reducer: ValueReducer>(_ observation: ValueObservation<Reducer>) -> AsyncStream<Reducer.Value> where Reducer.Value: Sendable {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let cancellable = observation.start(in: pool, scheduling: .async(onQueue: .global(qos: .userInitiated)), onError: { _ in
                continuation.finish()
            }, onChange: { value in
                continuation.yield(value)
            })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: - Search

    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// The order search results come in.
    public enum SearchOrder: String, CaseIterable, Sendable {
        case newest, oldest, relevant
    }

    /// Searches one account, or every account when `account` is nil. Every folder is searched, not only the inbox.
    public func search(account: String?, text: String, order: SearchOrder = .newest, limit: Int = 300) throws -> [MailThread] {
        guard let query = Self.ftsQuery(text) else { return [] }
        return try pool.read { db in
            guard order == .newest else {
                // The search index scores each message; lower is a closer match. A conversation takes its best message's.
                let sorting = order == .oldest ? "thread.lastDate ASC" : "hits.score ASC, thread.lastDate DESC"
                return try Self.fetchThreads(db, sql: """
                    SELECT \(Self.threadColumns) FROM thread JOIN (
                        SELECT message.accountId AS a, message.threadId AS t, MIN(message_fts.rank) AS score
                        FROM message_fts JOIN message ON message.rowid = message_fts.rowid
                        WHERE message_fts MATCH ?2 GROUP BY message.accountId, message.threadId) hits
                        ON hits.a = thread.accountId AND hits.t = thread.id
                    WHERE (?1 IS NULL OR thread.accountId = ?1)
                    ORDER BY \(sorting) LIMIT ?3
                    """, arguments: [account, query, limit])
            }
            let hits = try Int64.fetchAll(db.cachedStatement(sql: "SELECT rowid FROM message_fts WHERE message_fts MATCH ?"), arguments: [query])
            if hits.isEmpty { return [] }
            // A few letters match a large part of the mailbox. Looking up the thread of every matching message and
            // sorting all of those threads, to keep the newest ones, is then the slow way round.
            if hits.count >= Self.searchNewestFirstAbove, let found = try Self.searchNewestFirst(db, account: account, hits: hits, limit: limit) { return found }
            return try Self.fetchThreads(db, sql: """
                SELECT \(Self.threadColumns) FROM thread JOIN (
                    SELECT DISTINCT message.accountId AS a, message.threadId AS t
                    FROM message_fts JOIN message ON message.rowid = message_fts.rowid
                    WHERE message_fts MATCH ?2) hits ON hits.a = thread.accountId AND hits.t = thread.id
                WHERE (?1 IS NULL OR thread.accountId = ?1)
                ORDER BY thread.lastDate DESC LIMIT ?3
                """, arguments: [account, query, limit])
        }
    }

    /// From this many matching messages on, search walks the threads newest first instead (`searchNewestFirst`).
    /// (Variables only so that tests can force either way.)
    nonisolated(unsafe) static var searchNewestFirstAbove = 2000
    /// How many message rows that walk may pass before it gives up and the plain query runs after all.
    nonisolated(unsafe) static var searchWalkBudget = 60_000

    /// Walks threads from the newest down, keeping the ones that hold a matching message, and stops once it has `limit`
    /// of them. Both indexes it reads (threads by date, messages by thread) answer by themselves, so no thread or
    /// message row is touched until the winners are known. Returns nil when matches turn out to be so thinly spread
    /// that the walk passed its budget. Threads with the same date come in the order the plain query gives them:
    /// by their first matching message.
    private static func searchNewestFirst(_ db: Database, account: String?, hits: [Int64], limit: Int) throws -> [MailThread]? {
        guard limit > 0 else { return [] }
        let matching = Set(hits)
        var winners: [(thread: Int64, date: Int64, firstHit: Int64)] = []
        var current: Int64 = -1, currentDate: Int64 = 0, firstHit: Int64 = .max
        var walked = 0
        func close() {
            if current >= 0, firstHit != .max { winners.append((current, currentDate, firstHit)) }
        }
        let rows = try Row.fetchCursor(db.cachedStatement(sql: """
            SELECT thread.rowid, thread.lastDate, message.rowid FROM thread INDEXED BY thread_recent
            JOIN message INDEXED BY message_thread ON message.accountId = thread.accountId AND message.threadId = thread.id
            WHERE (?1 IS NULL OR thread.accountId = ?1)
            ORDER BY thread.lastDate DESC
            """), arguments: [account])
        while let row = try rows.next() {
            let thread: Int64 = row[0]
            if thread != current {
                close()
                let date: Int64 = row[1]
                // Enough threads, and the next one is older than the last kept: nothing later can displace them.
                if winners.count >= limit, let last = winners.last, date < last.date {
                    current = -1
                    break
                }
                current = thread
                currentDate = date
                firstHit = .max
            }
            walked += 1
            if walked > searchWalkBudget { return nil }
            let message: Int64 = row[2]
            if message < firstHit, matching.contains(message) { firstHit = message }
        }
        close()
        winners.sort { $0.date != $1.date ? $0.date > $1.date : $0.firstHit < $1.firstHit }
        let kept = winners.prefix(limit).map(\.thread)
        guard !kept.isEmpty else { return [] }
        var byRow: [Int64: MailThread] = [:]
        let found = try Row.fetchCursor(db, sql: "SELECT \(threadColumns), thread.rowid FROM thread WHERE rowid IN (\(databaseQuestionMarks(count: kept.count)))",
                                        arguments: StatementArguments(kept))
        while let row = try found.next() { byRow[row[14]] = try thread(row) }
        return kept.compactMap { byRow[$0] }
    }

    public func threads(account: String, ids: [String]) throws -> [MailThread] {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in
            let marks = databaseQuestionMarks(count: ids.count)
            let found = try Self.fetchThreads(db, sql: "SELECT \(Self.threadColumns) FROM thread WHERE accountId = ? AND id IN (\(marks))",
                                              arguments: StatementArguments([account] + ids))
            let byId = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
            return ids.compactMap { byId[$0] }
        }
    }

    public func contacts(account: String, matching text: String, limit: Int = 8) throws -> [Contact] {
        let needle = text.trimmed.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        guard !needle.isEmpty else { return [] }
        return try pool.read { db in
            try Contact.fetchAll(db, sql: """
                SELECT * FROM contact WHERE accountId = ?
                AND (email LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\' OR email LIKE ? ESCAPE '\\')
                ORDER BY uses DESC, lastUsed DESC LIMIT ?
                """, arguments: [account, needle + "%", needle + "%", "% " + needle + "%", "%@" + needle + "%", limit])
        }
    }

    // MARK: - Local changes waiting to reach Gmail

    /// Changes labels on whole threads right now and queues the same change for Gmail.
    public func modifyThreads(account: String, threadIds: [String], add: [String], remove: [String],
                              snoozeUntil: Int64? = nil, clearSnooze: Bool = false, bump: Bool = false) throws {
        guard !threadIds.isEmpty else { return }
        try pool.write { db in
            // What Gmail is asked to do, and what happens here right now, differ only by the snooze label.
            var opAdd = add
            var opRemove = remove
            var localRemove = remove
            if let snoozeUntil { opAdd.append(SystemLabel.snoozeToken + String(snoozeUntil)) }
            if clearSnooze {
                opRemove.append(SystemLabel.unsnoozeToken)
                localRemove += try Self.snoozeLabelIds(db, account: account)
            }
            for threadId in threadIds {
                if let snoozeUntil {
                    try db.execute(sql: "INSERT OR REPLACE INTO snooze(accountId, threadId, until) VALUES (?, ?, ?)", arguments: [account, threadId, snoozeUntil])
                } else if clearSnooze {
                    try db.execute(sql: "DELETE FROM snooze WHERE accountId = ? AND threadId = ?", arguments: [account, threadId])
                }
                if bump {
                    try db.execute(sql: "INSERT OR REPLACE INTO bump(accountId, threadId, date) VALUES (?, ?, ?)", arguments: [account, threadId, Self.now()])
                }
                if !opAdd.isEmpty || !opRemove.isEmpty {
                    for row in try Row.fetchAll(db.cachedStatement(sql: "SELECT id, labelIds FROM message WHERE accountId = ? AND threadId = ?"), arguments: [account, threadId]) {
                        let id: String = row["id"]
                        let current = Self.strings(row["labelIds"])
                        // Drafts inside a thread never enter the inbox or become unread.
                        let isDraft = current.contains(SystemLabel.draft)
                        let effectiveAdd = isDraft ? add.filter { $0 != SystemLabel.inbox && $0 != SystemLabel.unread } : add
                        let updated = Self.apply(add: effectiveAdd, remove: localRemove, to: current)
                        if updated != current {
                            try db.cachedStatement(sql: "UPDATE message SET labelIds = ? WHERE accountId = ? AND id = ?").execute(arguments: [Self.json(updated), account, id])
                        }
                    }
                    if !threadId.hasPrefix("local-") {
                        var op = PendingOp(id: nil, accountId: account, kind: PendingOp.modify, threadId: threadId, addLabels: opAdd,
                                           removeLabels: opRemove, draftId: nil, notBefore: 0, attempts: 0, lastError: nil)
                        try op.insert(db)
                    }
                }
                try self.recompute(db, account: account, threadId: threadId)
            }
            // The screen shows a change before it is stored and waits for the list to come round again with the
            // stored truth. A change that turns out to alter nothing must still send the list round.
            try db.notifyChanges(in: Table("thread"))
        }
    }

    /// Queues sending or deleting a draft that lives on Gmail, and reflects it locally at once.
    public func queueGmailDraft(account: String, threadId: String, messageId: String, send: Bool, delay: TimeInterval) throws {
        try pool.write { db in
            if send {
                try db.execute(sql: "UPDATE message SET labelIds = ?, internalDate = ? WHERE accountId = ? AND id = ?",
                               arguments: [Self.json([SystemLabel.sent]), Self.now(), account, messageId])
            } else if let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM message WHERE accountId = ? AND id = ?", arguments: [account, messageId]) {
                try db.execute(sql: "DELETE FROM message WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [rowid])
            }
            var op = PendingOp(id: nil, accountId: account, kind: send ? PendingOp.sendGmailDraft : PendingOp.deleteGmailDraft,
                               threadId: threadId, addLabels: [], removeLabels: [], draftId: messageId,
                               notBefore: Self.now() + Int64(delay * 1000), attempts: 0, lastError: nil)
            try op.insert(db)
            try self.recompute(db, account: account, threadId: threadId)
        }
    }

    /// Cancels a queued send of a Gmail draft. Returns true if it was still waiting.
    public func cancelGmailDraftSend(account: String, messageId: String) throws -> Bool {
        try pool.write { db in
            guard let op = try PendingOp.fetchOne(db, sql: "SELECT * FROM op WHERE accountId = ? AND kind = ? AND draftId = ? AND lastError IS NOT ?",
                                                  arguments: [account, PendingOp.sendGmailDraft, messageId, Self.inFlight]) else { return false }
            try db.execute(sql: "DELETE FROM op WHERE id = ?", arguments: [op.id])
            try db.execute(sql: "UPDATE message SET labelIds = ? WHERE accountId = ? AND id = ?",
                           arguments: [Self.json([SystemLabel.draft]), account, messageId])
            try self.recompute(db, account: account, threadId: op.threadId)
            return true
        }
    }

    func serverMessageIds(account: String, threadIds: [String]) throws -> [String] {
        guard !threadIds.isEmpty else { return [] }
        return try pool.read { db in
            let marks = databaseQuestionMarks(count: threadIds.count)
            return try String.fetchAll(db, sql: "SELECT id FROM message WHERE accountId = ? AND id NOT LIKE 'local-%' AND threadId IN (\(marks))",
                                       arguments: StatementArguments([account] + threadIds))
        }
    }

    func deleteOps(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try pool.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM op WHERE id = ?", arguments: [id]) }
        }
    }

    func readyOps(account: String, limit: Int) throws -> [PendingOp] {
        try pool.read { db in
            // Only the oldest waiting change of each thread, so changes to one thread stay in order.
            try PendingOp.fetchAll(db, sql: """
                SELECT * FROM op WHERE accountId = ? AND notBefore <= ?
                AND id IN (SELECT min(id) FROM op WHERE accountId = ? GROUP BY threadId)
                ORDER BY id LIMIT ?
                """, arguments: [account, Self.now(), account, limit])
        }
    }

    /// Milliseconds until the next delayed change is due, if any.
    func nextOpDelay(account: String) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT min(notBefore) FROM op WHERE accountId = ?", arguments: [account]).map { max(0, $0 - Self.now()) }
        }
    }

    static let inFlight = "sending"

    /// Marks a send as on its way. Returns false if it was cancelled in the meantime, in which case it must not go.
    /// Also counts the attempt, so a retry knows to check whether the earlier one actually arrived.
    func beginSend(_ id: Int64) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "UPDATE op SET lastError = ?, attempts = attempts + 1 WHERE id = ?", arguments: [Self.inFlight, id])
            return db.changesCount > 0
        }
    }

    /// Of these threads, the ones whose every message is on this device, so a change by message id covers them.
    func wholeThreads(account: String, among ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try pool.read { db in
            let marks = databaseQuestionMarks(count: ids.count)
            let partial = try String.fetchAll(db, sql: """
                SELECT DISTINCT threadId FROM message WHERE accountId = ? AND threadId IN (\(marks)) AND refs != ''
                AND NOT EXISTS (SELECT 1 FROM full_thread WHERE full_thread.accountId = message.accountId AND full_thread.threadId = message.threadId)
                """, arguments: StatementArguments([account] + ids))
            return Set(ids).subtracting(partial)
        }
    }

    func deleteOp(_ id: Int64) throws {
        try pool.write { try $0.execute(sql: "DELETE FROM op WHERE id = ?", arguments: [id]) }
    }

    func failOp(_ id: Int64, error: String) throws {
        try pool.write { try $0.execute(sql: "UPDATE op SET attempts = attempts + 1, lastError = ? WHERE id = ?", arguments: [error, id]) }
    }

    public func pendingOpCount() throws -> Int {
        try pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM op") ?? 0 }
    }

    /// Snoozed threads whose time has come, whichever device snoozed them.
    func dueSnoozes(account: String) throws -> [String] {
        // Every snoozed thread is in the snoozed list under its wake time, so the list's index answers this
        // without reading the account's threads. (Same threads, in the same order, as asking the thread table.)
        try pool.read { try String.fetchAll($0, sql: "SELECT threadId FROM thread_label WHERE accountId = ? AND labelId = ? AND sortDate <= ? ORDER BY threadId", arguments: [account, SystemLabel.snoozed, Self.now()]) }
    }

    func lastMessages(account: String, threadIds: [String]) throws -> [Message] {
        try pool.read { db in
            let newest = try db.cachedStatement(sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate DESC LIMIT 1")
            return try threadIds.compactMap { try Message.fetchOne(newest, arguments: [account, $0]) }
        }
    }

    func nextSnooze() throws -> Int64? {
        try pool.read { try Int64.fetchOne($0, sql: "SELECT min(until) FROM snooze") }
    }

    // MARK: - Drafts and sending

    public func saveDraft(_ draft: Draft) throws {
        var copy = draft
        copy.updatedAt = Self.now()
        try pool.write { db in
            try Self.keepRemote(db, &copy)
            try copy.save(db)
        }
    }

    /// The writing screen holds a copy of the draft from before it reached Gmail. What Gmail calls the draft is
    /// taken from the saved row, never from that copy.
    private static func keepRemote(_ db: Database, _ draft: inout Draft) throws {
        guard let saved = try Draft.fetchOne(db, key: draft.id) else { return }
        draft.remoteDraftId = saved.remoteDraftId
        draft.remoteMessageId = saved.remoteMessageId
        draft.remoteThreadId = saved.remoteThreadId
        draft.uploadedAt = saved.uploadedAt
    }

    public func deleteDraft(_ id: String) throws {
        try pool.write { try $0.execute(sql: "DELETE FROM draft WHERE id = ? AND queued = 0", arguments: [id]) }
    }

    /// Drafts whose latest version Gmail does not have yet.
    func draftsToUpload(account: String) throws -> [Draft] {
        try pool.read { try Draft.fetchAll($0, sql: "SELECT * FROM draft WHERE accountId = ? AND queued = 0 AND updatedAt > uploadedAt ORDER BY updatedAt", arguments: [account]) }
    }

    /// Records that Gmail now has the version of a draft saved at `version`. False if the draft has meanwhile
    /// been sent or thrown away, in which case the copy just made on Gmail is not wanted.
    func markUploaded(id: String, version: Int64, remoteDraftId: String, remoteMessageId: String, remoteThreadId: String?) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "UPDATE draft SET remoteDraftId = ?, remoteMessageId = ?, remoteThreadId = ?, uploadedAt = ? WHERE id = ? AND queued = 0",
                           arguments: [remoteDraftId, remoteMessageId, remoteThreadId, version, id])
            return db.changesCount > 0
        }
    }

    /// Drafts that Gmail has an identical copy of, by the id of that copy's message.
    func settledDrafts(account: String) throws -> [Draft] {
        try pool.read { try Draft.fetchAll($0, sql: "SELECT * FROM draft WHERE accountId = ? AND queued = 0 AND remoteMessageId IS NOT NULL AND updatedAt <= uploadedAt", arguments: [account]) }
    }

    /// Gmail's copies of the drafts kept here, by message id, including ones on their way out. The app shows
    /// its own version of these, not Gmail's, so each appears once.
    public func mirroredDraftMessages(account: String) throws -> [String: String] {
        try pool.read { db in
            var found: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, remoteMessageId, sourceMessageId FROM draft WHERE accountId = ?", arguments: [account]) {
                let id: String = row["id"]
                if let remote: String = row["remoteMessageId"] { found[remote] = id }
                if let source: String = row["sourceMessageId"], source.hasPrefix("draft:") { found[String(source.dropFirst(6))] = id }
            }
            return found
        }
    }

    /// Forgets one message, for example the old copy of a draft that has just been replaced.
    func removeMessage(account: String, id: String) throws {
        try pool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT rowid, threadId FROM message WHERE accountId = ? AND id = ?", arguments: [account, id]) else { return }
            let rowid: Int64 = row["rowid"]
            try db.execute(sql: "DELETE FROM message WHERE rowid = ?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [rowid])
            try self.recompute(db, account: account, threadId: row["threadId"])
        }
    }

    public func draft(_ id: String) throws -> Draft? {
        try pool.read { try Draft.fetchOne($0, key: id) }
    }

    public func drafts(account: String?) throws -> [Draft] {
        try pool.read { try Draft.fetchAll($0, sql: "SELECT * FROM draft WHERE (?1 IS NULL OR accountId = ?1) AND queued = 0 ORDER BY updatedAt DESC", arguments: [account]) }
    }

    public func observeDrafts(account: String?) -> AsyncStream<[Draft]> {
        stream(ValueObservation.tracking { db in
            try Draft.fetchAll(db, sql: "SELECT * FROM draft WHERE (?1 IS NULL OR accountId = ?1) AND queued = 0 ORDER BY updatedAt DESC", arguments: [account])
        })
    }

    public func draftForThread(account: String, threadId: String) throws -> Draft? {
        try pool.read { try Draft.fetchOne($0, sql: "SELECT * FROM draft WHERE accountId = ? AND threadId = ? AND queued = 0 ORDER BY updatedAt DESC", arguments: [account, threadId]) }
    }

    /// Puts a draft in the outbox and shows it in its thread immediately.
    func queueSend(draft: Draft, from: EmailAddress, html: String, delay: TimeInterval) throws {
        try pool.write { db in
            var copy = draft
            copy.updatedAt = Self.now()
            try Self.keepRemote(db, &copy)
            try copy.save(db)
            try db.execute(sql: "UPDATE draft SET queued = 1 WHERE id = ?", arguments: [draft.id])
            let localId = "local-\(draft.id)"
            let threadId = draft.threadId ?? localId
            let placeholder = Message(
                accountId: draft.accountId, id: localId, threadId: threadId, internalDate: Self.now(),
                sender: from.formatted, toList: draft.to, ccList: draft.cc, bccList: draft.bcc, replyTo: "",
                subject: draft.subject, snippet: String(draft.body.prefix(200)), labelIds: [SystemLabel.sent],
                messageIdHeader: "", refs: "", bodyHTML: html, bodyText: nil, attachments: [])
            try self.insertMessage(db, placeholder)
            var op = PendingOp(id: nil, accountId: draft.accountId, kind: PendingOp.send, threadId: threadId, addLabels: [], removeLabels: [],
                               draftId: draft.id, notBefore: Self.now() + Int64(delay * 1000), attempts: 0, lastError: nil)
            try op.insert(db)
            try self.recompute(db, account: draft.accountId, threadId: threadId)
        }
    }

    /// Takes a queued message back out of the outbox. Returns the draft if it had not been sent yet.
    public func cancelSend(draftId: String) throws -> Draft? {
        try pool.write { db in
            // Once the message is on its way to Gmail it can no longer be taken back.
            guard let op = try PendingOp.fetchOne(db, sql: "SELECT * FROM op WHERE kind = ? AND draftId = ? AND lastError IS NOT ?",
                                                  arguments: [PendingOp.send, draftId, Self.inFlight]) else { return nil }
            try db.execute(sql: "DELETE FROM op WHERE id = ?", arguments: [op.id])
            try self.removePlaceholder(db, account: op.accountId, draftId: draftId, threadId: op.threadId)
            try db.execute(sql: "UPDATE draft SET queued = 0 WHERE id = ?", arguments: [draftId])
            return try Draft.fetchOne(db, key: draftId)
        }
    }

    private func removePlaceholder(_ db: Database, account: String, draftId: String, threadId: String) throws {
        let localId = "local-\(draftId)"
        if let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM message WHERE accountId = ? AND id = ?", arguments: [account, localId]) {
            try db.execute(sql: "DELETE FROM message WHERE rowid = ?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid = ?", arguments: [rowid])
        }
        try recompute(db, account: account, threadId: threadId)
    }

    /// Called once Gmail accepted the message, or refused it for good.
    func finishSend(op: PendingOp, sent: Bool) throws {
        guard let draftId = op.draftId else { return }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM op WHERE id = ?", arguments: [op.id])
            try self.removePlaceholder(db, account: op.accountId, draftId: draftId, threadId: op.threadId)
            if sent {
                try db.execute(sql: "DELETE FROM draft WHERE id = ?", arguments: [draftId])
            } else {
                try db.execute(sql: "UPDATE draft SET queued = 0 WHERE id = ?", arguments: [draftId])
            }
        }
    }
}
