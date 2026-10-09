@_spi(Bench) import BlitzCore
import CryptoKit
import Foundation
import GRDB
import SQLite3

// Benchmarks for the local database layer (Store.swift). Run each section on its own fresh working copy:
//
//   blitzbench store <data-dir> read|thread|search|write|misc|storage|observe|pages|digest|digest-write
//
// Nothing here prints mail content: thread ids, subjects and search words are picked from the mailbox by shape
// (the longest thread, the most common word) and only named by that shape in the output.

/// The parts of a mailbox the benchmarks aim at, found by shape so the same code runs on the made-up and the real one.
struct StoreTargets {
    var accounts: [String]
    /// The account with the most mail.
    var main: String
    var userLabel: String
    /// A single-message thread with the largest body, a thread of about 60 messages, and the longest thread.
    var newsletter: String
    var middle: String
    var longest: String
    var inbox: [String]
    var archived: [String]

    init(_ store: Store) throws {
        accounts = try store.accounts().map(\.id)
        (main, userLabel, newsletter, middle, longest) = try store.pool.read { db in
            let main = try String.fetchOne(db, sql: "SELECT accountId FROM message GROUP BY accountId ORDER BY count(*) DESC LIMIT 1") ?? ""
            let userLabel = try String.fetchOne(db, sql: "SELECT labelId FROM thread_label WHERE accountId = ? AND labelId LIKE 'Label\\_%' ESCAPE '\\' GROUP BY labelId ORDER BY count(*) DESC LIMIT 1", arguments: [main]) ?? "STARRED"
            let newsletter = try String.fetchOne(db, sql: """
                SELECT message.threadId FROM message JOIN thread ON thread.accountId = message.accountId AND thread.id = message.threadId
                WHERE message.accountId = ? AND thread.messageCount = 1 ORDER BY length(message.bodyHTML) DESC, message.id LIMIT 1
                """, arguments: [main]) ?? ""
            let middle = try String.fetchOne(db, sql: "SELECT id FROM thread WHERE accountId = ? ORDER BY abs(messageCount - 60), id LIMIT 1", arguments: [main]) ?? ""
            let longest = try String.fetchOne(db, sql: "SELECT id FROM thread WHERE accountId = ? ORDER BY messageCount DESC, id LIMIT 1", arguments: [main]) ?? ""
            return (main, userLabel, newsletter, middle, longest)
        }
        inbox = try store.threads(account: main, label: SystemLabel.inbox, limit: 700).map(\.id)
        archived = try store.threads(account: main, label: SystemLabel.done, limit: 3000).map(\.id)
    }
}

func storeBench(_ store: Store, _ args: [String]) throws {
    let targets = try StoreTargets(store)
    switch args.first ?? "" {
    case "read": try storeReadBench(store, targets)
    case "thread": try storeThreadBench(store, targets)
    case "search": try storeSearchBench(store, targets)
    case "write": try storeWriteBench(store, targets)
    case "misc": try storeMiscBench(store, targets)
    case "storage": try storeStorageBench(store, targets, path: store.pool.path)
    case "observe": try storeObserveBench(store, targets)
    case "pages": try storePagesBench(store, targets)
    case "strip-check": try storeStripCheck(store)
    case "spin": try storeSpin(store, targets, what: args.dropFirst().first ?? "")
    case "digest": try storeDigest(store, targets)
    case "digest-write": try storeWriteDigest(store, targets)
    default:
        print("usage: blitzbench store <data-dir> read|thread|search|write|misc|storage|observe|pages|digest|digest-write")
        exit(2)
    }
}

// MARK: - 1. Lists

private func snoozeSome(_ store: Store, _ targets: StoreTargets) throws {
    // Neither mailbox has snoozed mail, so some is snoozed here (the working copy is thrown away afterwards).
    let hour: Int64 = 3_600_000
    // A fixed time far ahead, so two runs snooze to the same moments.
    let base: Int64 = 4_000_000_000_000
    for (index, id) in targets.inbox.suffix(300).enumerated() {
        try store.modifyThreads(account: targets.main, threadIds: [id], add: [], remove: [SystemLabel.inbox], snoozeUntil: base + Int64(index % 40) * hour)
    }
}

func storeReadBench(_ store: Store, _ targets: StoreTargets) throws {
    try snoozeSome(store, targets)
    let labels = [("inbox", SystemLabel.inbox), ("all", SystemLabel.all), ("done", SystemLabel.done), ("user", targets.userLabel), ("snoozed", SystemLabel.snoozed)]
    for (scope, account) in [("one", Optional(targets.main)), ("merged", nil)] {
        for (name, label) in labels {
            for limit in [300, 600, 3000] {
                var rows = 0
                try measure("read.\(scope).\(name).\(limit)", runs: limit == 3000 ? 30 : 60) {
                    rows = try store.threads(account: account, label: label, limit: limit).count
                }
                report("read.\(scope).\(name).\(limit).rows", ["rows": Double(rows)])
            }
        }
    }
    // How much of a list read is turning rows into values rather than SQLite's work.
    let sql = """
        SELECT thread.*, thread_label.sortDate AS sortDate FROM thread_label
        JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId
        WHERE thread_label.accountId = ? AND thread_label.labelId = ? ORDER BY thread_label.sortDate DESC LIMIT ?
        """
    try measure("read.rawrows.all.3000", runs: 30) {
        try store.pool.read { db in
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: [targets.main, SystemLabel.all, 3000])
            var bytes = 0
            while let row = try cursor.next() { bytes += (row["subject"] as String).utf8.count + (row["labelIds"] as String).utf8.count }
            _ = bytes
        }
    }
    try measure("read.unreadCount", runs: 100) { _ = try store.unreadCount(account: targets.main) }
    try measure("read.thread.one", runs: 200) { _ = try store.thread(account: targets.main, id: targets.longest) }
    let some = Array(targets.inbox.prefix(50))
    try measure("read.threads.ids50", runs: 100) { _ = try store.threads(account: targets.main, ids: some) }
}

// MARK: - 2. One conversation

func storeThreadBench(_ store: Store, _ targets: StoreTargets) throws {
    for (name, id) in [("newsletter", targets.newsletter), ("middle", targets.middle), ("longest", targets.longest)] {
        var count = 0, bytes = 0
        try measure("thread.\(name)", runs: 60) {
            let messages = try store.messages(account: targets.main, threadId: id)
            count = messages.count
            bytes = messages.reduce(0) { $0 + ($1.bodyHTML?.utf8.count ?? 0) + ($1.bodyText?.utf8.count ?? 0) }
        }
        report("thread.\(name).shape", ["messages": Double(count), "body_kb": Double(bytes) / 1024])
    }
    // Twenty different newsletters in a row, the way j/k through a list opens them.
    let singles = try store.pool.read { try String.fetchAll($0, sql: "SELECT id FROM thread WHERE accountId = ? AND messageCount = 1 ORDER BY lastDate DESC LIMIT 20", arguments: [targets.main]) }
    try measure("thread.20singles", runs: 40) {
        for id in singles { _ = try store.messages(account: targets.main, threadId: id) }
    }
    let lastOf = Array(targets.inbox.prefix(20))
    try measure("thread.lastMessages20", runs: 40) { _ = try store.benchLastMessages(account: targets.main, threadIds: lastOf) }
    let first = try store.messages(account: targets.main, threadId: targets.longest).first?.id ?? ""
    try measure("thread.message.one", runs: 200) { _ = try store.message(account: targets.main, id: first) }
}

// MARK: - 3. Search

/// Words to search for, picked by how many messages hold them. Returned as (name, text); the text is never printed.
func storeSearchQueries(_ store: Store) throws -> [(String, String)] {
    try store.pool.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS temp.bench_vocab USING fts5vocab('main', 'message_fts', 'row')")
        let rows = try Row.fetchAll(db, sql: "SELECT term, doc FROM temp.bench_vocab WHERE length(term) BETWEEN 5 AND 12 AND term NOT GLOB '*[^a-z]*' ORDER BY doc DESC, term")
        try db.execute(sql: "DROP TABLE temp.bench_vocab")
        guard let common = rows.first, let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM message") else { return [] }
        func nearest(_ docs: Int) -> String { rows.min { abs(($0["doc"] as Int) - docs) < abs(($1["doc"] as Int) - docs) }!["term"] }
        let commonTerm: String = common["term"]
        let usual = nearest(max(total / 50, 3))
        let second = nearest(max(total / 20, 4))
        // The longest of the words only one or two messages hold, so that few other words start with it.
        let rare: String = rows.filter { ($0["doc"] as Int) <= 2 }.max { ($0["term"] as String).count < ($1["term"] as String).count }?["term"] ?? nearest(2)
        return [("prefix1", String(usual.prefix(1))), ("prefix2", String(usual.prefix(2))), ("prefix3", String(usual.prefix(3))), ("prefix5", String(usual.prefix(5))),
                ("word", usual), ("twowords", usual + " " + second), ("wordprefix", second + " " + String(usual.prefix(2))),
                ("rare", rare), ("common", commonTerm), ("none", "zzqqxxjj")]
    }
}

func storeSearchBench(_ store: Store, _ targets: StoreTargets) throws {
    let queries = try storeSearchQueries(store)
    for (scope, account) in [("all", String?.none), ("one", Optional(targets.main))] {
        for (name, text) in queries {
            var hits = 0
            try measure("search.\(scope).\(name)", runs: 25, warmup: 2) { hits = try store.search(account: account, text: text).count }
            report("search.\(scope).\(name).hits", ["threads": Double(hits)])
        }
    }
    // Typing a word letter by letter: the sum is what the person waits through.
    let word = queries.first { $0.0 == "word" }?.1 ?? ""
    try measure("search.typing.word", runs: 15, warmup: 1) {
        for length in 1...word.count { _ = try store.search(account: nil, text: String(word.prefix(length))) }
    }
}

// MARK: - 4. Writes

private let benchWords = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike",
                          "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu"]

private func benchHTML(kilobytes: Int, salt: Int) -> String {
    var html = "<html><head><style>body{margin:0}.c{font-family:Helvetica;font-size:14px}</style></head><body><table width=\"100%\">"
    var index = salt
    while html.utf8.count < kilobytes * 1024 {
        html += "<tr><td class=\"c\" style=\"padding:16px 24px;border-bottom:1px solid #eee\"><h2 style=\"margin:0 0 8px\">"
        for _ in 0..<40 { index = (index &* 31 &+ 7) % 1_000_003; html += benchWords[index % benchWords.count] + " " }
        html += "</h2><a href=\"https://bench.invalid/\(index)\">\(benchWords[index % 7])</a></td></tr>"
    }
    return html + "</table></body></html>"
}

/// New mail the way sync hands it over: half newsletters in threads of their own, half short replies in known threads.
struct BenchMail {
    var account: String
    var replyTo: [String]
    var serial = 0
    let big = (0..<8).map { benchHTML(kilobytes: 20 + $0 * 12, salt: $0) }
    let small = (0..<8).map { "<div dir=\"ltr\">" + benchHTML(kilobytes: 1, salt: 100 + $0) + "</div>" }

    mutating func next(_ count: Int, inbox: Bool = true) -> [Message] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return (0..<count).map { _ in
            serial += 1
            let newsletter = serial % 2 == 0
            let id = "bench\(serial)"
            var labels = newsletter ? ["CATEGORY_UPDATES", "UNREAD"] : ["CATEGORY_PERSONAL", "UNREAD"]
            if inbox { labels.append("INBOX") }
            return Message.bench(
                accountId: account, id: id, threadId: newsletter || replyTo.isEmpty ? "benchthread\(serial)" : replyTo[serial % replyTo.count],
                internalDate: now + Int64(serial), sender: newsletter ? "Bench News <news\(serial % 50)@bench.invalid>" : "Pat Bench <pat\(serial % 50)@bench.invalid>",
                toList: "Me <\(account)>", subject: "Bench subject \(benchWords[serial % benchWords.count]) \(serial)", snippet: "bench snippet \(serial)",
                labelIds: labels, refs: newsletter ? "" : "<earlier@bench.invalid>", bodyHTML: (newsletter ? big : small)[serial % 8] + "<!-- \(serial) -->")
        }
    }
}

func storeWriteBench(_ store: Store, _ targets: StoreTargets) throws {
    let account = targets.main
    let inbox = targets.inbox
    guard inbox.count >= 200 else { print("{\"error\":\"inbox too small for the write benchmark\"}"); return }
    // One key press on one thread.
    var flip = 0
    try measure("write.modify.read1", runs: 60) {
        flip += 1
        try store.modifyThreads(account: account, threadIds: [inbox[0]], add: flip % 2 == 0 ? [SystemLabel.unread] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.unread])
    }
    try measure("write.modify.star1", runs: 60) {
        flip += 1
        try store.modifyThreads(account: account, threadIds: [inbox[1]], add: flip % 2 == 0 ? [SystemLabel.starred] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.starred])
    }
    var next = 2
    try measure("write.modify.archive1", runs: 60) {
        try store.modifyThreads(account: account, threadIds: [inbox[next]], add: [], remove: [SystemLabel.inbox])
        next += 1
    }
    try measure("write.modify.snooze1", runs: 30) {
        try store.modifyThreads(account: account, threadIds: [inbox[next]], add: [], remove: [SystemLabel.inbox], snoozeUntil: Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000)
        next += 1
    }
    let long = [targets.longest]
    try measure("write.modify.read1.longest", runs: 30) {
        flip += 1
        try store.modifyThreads(account: account, threadIds: long, add: flip % 2 == 0 ? [SystemLabel.unread] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.unread])
    }
    // A selection of 50.
    let fifty = Array(inbox[110..<160])
    try measure("write.modify.archive50", runs: 20) {
        flip += 1
        try store.modifyThreads(account: account, threadIds: fifty, add: flip % 2 == 0 ? [SystemLabel.inbox] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.inbox])
    }
    try measure("write.modify.read50", runs: 20) {
        flip += 1
        try store.modifyThreads(account: account, threadIds: fifty, add: flip % 2 == 0 ? [SystemLabel.unread] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.unread])
    }
    // What sync writes.
    var mail = BenchMail(account: account, replyTo: Array(targets.archived.prefix(400)))
    for size in [1, 20, 100] {
        try measure("write.save.new\(size)", runs: size == 100 ? 12 : 25, warmup: 2) {
            try store.benchSaveMessages(account: account, messages: mail.next(size))
        }
    }
    let known = mail.next(100)
    try store.benchSaveMessages(account: account, messages: known)
    try measure("write.save.known100", runs: 20) { try store.benchSaveMessages(account: account, messages: known) }
    let lastIds = try store.benchLastMessages(account: account, threadIds: Array(inbox[160..<260].prefix(100))).map(\.id)
    try measure("write.labelChanges100", runs: 20) {
        flip += 1
        _ = try store.benchApplyLabelChanges(account: account, changes: lastIds.map { (messageId: $0, add: flip % 2 == 0 ? [SystemLabel.unread] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.unread]) }, deleted: [])
    }
    // A key press while sync is storing new mail: how long marking one thread read takes when it has to wait its turn.
    let stop = Counter()
    let syncing = Thread {
        var incoming = BenchMail(account: account, replyTo: [])
        incoming.serial = 1_000_000
        while stop.count == 0 { try? store.benchSaveMessages(account: account, messages: incoming.next(20, inbox: false)) }
        stop.add()
    }
    syncing.start()
    Thread.sleep(forTimeInterval: 0.2)
    try measure("write.modify.read1.duringSync", runs: 60) {
        flip += 1
        try store.modifyThreads(account: account, threadIds: [inbox[0]], add: flip % 2 == 0 ? [SystemLabel.unread] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.unread])
        Thread.sleep(forTimeInterval: 0.011)
    }
    stop.add()
    while stop.count < 2 { Thread.sleep(forTimeInterval: 0.01) }
    // Rebuilding threads from their messages, by itself.
    let singles = try store.pool.read { try String.fetchAll($0, sql: "SELECT id FROM thread WHERE accountId = ? AND messageCount = 1 ORDER BY lastDate DESC LIMIT 100", arguments: [account]) }
    try measure("write.recompute.100singles", runs: 20) { try store.benchRecompute(account: account, threadIds: singles) }
    try measure("write.recompute.middle", runs: 40) { try store.benchRecompute(account: account, threadIds: [targets.middle]) }
    try measure("write.recompute.longest", runs: 40) { try store.benchRecompute(account: account, threadIds: long) }
    // Turning HTML into the plain text search looks through: the 200 largest bodies that have no text part.
    let bodies = try store.pool.read { try String.fetchAll($0, sql: "SELECT bodyHTML FROM message WHERE bodyText IS NULL AND bodyHTML IS NOT NULL ORDER BY length(bodyHTML) DESC, id LIMIT 200") }
    var kilobytes = 0
    measure("write.strip.200largest", runs: 8, warmup: 1) { kilobytes = bodies.reduce(0) { $0 + HTMLText.strip($1).utf8.count } / 1024 }
    measure("write.strip.200largest.reference", runs: 4, warmup: 1) { kilobytes = bodies.reduce(0) { $0 + HTMLText.stripReference($1).utf8.count } / 1024 }
    report("write.strip.200largest.shape", ["html_kb": Double(bodies.reduce(0) { $0 + $1.utf8.count } / 1024), "text_kb": Double(kilobytes)])
    let whole = try store.messages(account: account, threadId: targets.middle)
    try measure("write.saveThread.middle", runs: 20) { try store.benchSaveThreads(account: account, threads: [(id: targets.middle, messages: whole)]) }
}

// MARK: - 5. The smaller queries, and their plans

func storeMiscBench(_ store: Store, _ targets: StoreTargets) throws {
    let account = targets.main
    try snoozeSome(store, targets)
    // Give the queue of changes some length: 500 threads marked read while "offline".
    for id in targets.archived.prefix(500) { try store.modifyThreads(account: account, threadIds: [id], add: [], remove: [SystemLabel.unread]) }
    try store.pool.write { try $0.execute(sql: "UPDATE account SET name = ''") }

    try measure("misc.senderName", runs: 20) { _ = try store.senderName(account: account) }
    try measure("misc.messageIds.inbox", runs: 20) { _ = try store.benchMessageIds(account: account, withLabel: SystemLabel.inbox) }
    try measure("misc.messageIds.unread", runs: 20) { _ = try store.benchMessageIds(account: account, withLabel: SystemLabel.unread) }
    try measure("misc.incompleteThreads", runs: 20) { _ = try store.benchIncompleteThreads(account: account, limit: 20) }
    try measure("misc.readyOps", runs: 100) { _ = try store.benchReadyOps(account: account, limit: 50) }
    try measure("misc.nextOpDelay", runs: 100) { _ = try store.benchNextOpDelay(account: account) }
    try measure("misc.pendingOpCount", runs: 100) { _ = try store.pendingOpCount() }
    try measure("misc.dueSnoozes", runs: 100) { _ = try store.benchDueSnoozes(account: account) }
    try measure("misc.nextSnooze", runs: 100) { _ = try store.benchNextSnooze() }
    try measure("misc.unreadCount", runs: 100) { _ = try store.unreadCount(account: account) }
    try measure("misc.labels", runs: 100) { _ = try store.labels(account: account) }
    let hundred = Array(targets.archived.prefix(100))
    try measure("misc.wholeThreads100", runs: 50) { _ = try store.benchWholeThreads(account: account, among: hundred) }
    try measure("misc.serverMessageIds100", runs: 50) { _ = try store.benchServerMessageIds(account: account, threadIds: hundred) }
    try measure("misc.threadNeedsCompleting", runs: 200) { _ = try store.threadNeedsCompleting(account: account, threadId: targets.longest) }
    let ids = try store.benchServerMessageIds(account: account, threadIds: hundred)
    try measure("misc.knownMessageIds", runs: 50) { _ = try store.benchKnownMessageIds(account: account, among: ids + ["nope1", "nope2"]) }
    try measure("misc.notable20", runs: 50) { _ = try store.benchNotable(account: account, ids: Array(ids.prefix(20))) }
    // Recipient suggestions: the first letters of the most used contact, typed one at a time.
    let email = try store.pool.read { try String.fetchOne($0, sql: "SELECT email FROM contact WHERE accountId = ? ORDER BY uses DESC, email LIMIT 1", arguments: [account]) } ?? "a"
    for length in [1, 2, 4] {
        let needle = String(email.prefix(length))
        try measure("misc.contacts.\(length)", runs: 100) { _ = try store.contacts(account: account, matching: needle) }
    }
    try measure("misc.contacts.nomatch", runs: 100) { _ = try store.contacts(account: account, matching: "zzqqxxjj") }

    // Query plans of the statements above, as SQLite reports them.
    let plans: [(String, String)] = [
        ("list", "SELECT thread.*, thread_label.sortDate AS sortDate FROM thread_label JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId WHERE thread_label.accountId = 'a' AND thread_label.labelId = 'INBOX' ORDER BY thread_label.sortDate DESC LIMIT 300"),
        ("unreadCount", "SELECT count(*) FROM thread_label JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId WHERE thread_label.accountId = 'a' AND thread_label.labelId = 'INBOX' AND thread.unread = 1"),
        ("unreadCounts", "SELECT thread_label.accountId AS account, count(*) AS n FROM thread_label JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId WHERE thread_label.labelId = 'INBOX' AND thread.unread = 1 GROUP BY thread_label.accountId"),
        ("messages", "SELECT * FROM message WHERE accountId = 'a' AND threadId = 't' ORDER BY internalDate, id"),
        ("search", "SELECT thread.* FROM thread JOIN (SELECT DISTINCT message.accountId AS a, message.threadId AS t FROM message_fts JOIN message ON message.rowid = message_fts.rowid WHERE message_fts MATCH '\"x\"*') hits ON hits.a = thread.accountId AND hits.t = thread.id WHERE (NULL IS NULL OR thread.accountId = NULL) ORDER BY thread.lastDate DESC LIMIT 200"),
        ("senderName.received", "SELECT toList, ccList FROM message WHERE accountId = 'a' AND labelIds NOT LIKE '%\"SENT\"%' AND toList LIKE '%<a>%' ORDER BY internalDate DESC LIMIT 400"),
        ("messageIds", "SELECT id, threadId FROM message WHERE accountId = 'a' AND id NOT LIKE 'local-%' AND labelIds LIKE '%\"INBOX\"%'"),
        ("incompleteThreads", "SELECT DISTINCT message.threadId FROM message WHERE message.accountId = 'a' AND message.refs != '' AND message.id NOT LIKE 'local-%' AND NOT EXISTS (SELECT 1 FROM full_thread WHERE full_thread.accountId = message.accountId AND full_thread.threadId = message.threadId) ORDER BY message.internalDate DESC LIMIT 20"),
        ("readyOps", "SELECT * FROM op WHERE accountId = 'a' AND notBefore <= 1 AND id IN (SELECT min(id) FROM op WHERE accountId = 'a' GROUP BY threadId) ORDER BY id LIMIT 50"),
        ("pendingForThread", "SELECT * FROM op WHERE accountId = 'a' AND threadId = 't' AND kind = 'modify' ORDER BY id"),
        ("dueSnoozes", "SELECT id FROM thread WHERE accountId = 'a' AND snoozedUntil IS NOT NULL AND snoozedUntil <= 1"),
        ("contacts", "SELECT * FROM contact WHERE accountId = 'a' AND (email LIKE 'x%' ESCAPE '\\' OR name LIKE 'x%' ESCAPE '\\' OR name LIKE '% x%' ESCAPE '\\' OR email LIKE '%@x%' ESCAPE '\\') ORDER BY uses DESC, lastUsed DESC LIMIT 8"),
        ("recompute.read", "SELECT id, internalDate, sender, toList, subject, snippet, labelIds, attachments FROM message WHERE accountId = 'a' AND threadId = 't' ORDER BY internalDate, id"),
        ("recompute.clear", "DELETE FROM thread_label WHERE accountId = 'a' AND threadId = 't'"),
        ("modify.read", "SELECT id, labelIds FROM message WHERE accountId = 'a' AND threadId = 't'"),
        ("wholeThreads", "SELECT DISTINCT threadId FROM message WHERE accountId = 'a' AND threadId IN ('t') AND refs != '' AND NOT EXISTS (SELECT 1 FROM full_thread WHERE full_thread.accountId = message.accountId AND full_thread.threadId = message.threadId)"),
    ]
    try store.pool.read { db in
        for (name, sql) in plans {
            let steps = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }
            print("{\"plan\":\"\(name)\",\"steps\":\"\(steps.joined(separator: " | ").replacingOccurrences(of: "\"", with: "'"))\"}")
        }
    }
}

// MARK: - 6. The file

private func fileSize(_ path: String) -> Double {
    Double((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
}

func storeStorageBench(_ store: Store, _ targets: StoreTargets, path: String) throws {
    try measure("storage.open", runs: 40) {
        let again = try Store(path: path)
        _ = try again.accounts()
    }
    report("storage.file", ["mb": fileSize(path) / 1_048_576, "wal_mb": fileSize(path + "-wal") / 1_048_576])
    // A long burst of sync writes: 3,000 new messages in batches of 20.
    var mail = BenchMail(account: targets.main, replyTo: Array(targets.archived.prefix(400)))
    var peak = 0.0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<150 {
        try store.benchSaveMessages(account: targets.main, messages: mail.next(20, inbox: false))
        peak = max(peak, fileSize(path + "-wal"))
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    report("storage.burst3000", ["seconds": seconds, "wal_peak_mb": peak / 1_048_576, "wal_after_mb": fileSize(path + "-wal") / 1_048_576, "file_mb": fileSize(path) / 1_048_576])
    let checkpoint = DispatchTime.now().uptimeNanoseconds
    _ = try store.pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    report("storage.checkpoint", ["ms": Double(DispatchTime.now().uptimeNanoseconds - checkpoint) / 1e6, "file_mb": fileSize(path) / 1_048_576])
    let sizes = try store.pool.read { try Row.fetchAll($0, sql: "SELECT name, sum(pgsize) AS bytes FROM dbstat GROUP BY name ORDER BY bytes DESC LIMIT 8") }
    for row in sizes { report("storage.table.\(row["name"] as String)", ["mb": Double(row["bytes"] as Int64) / 1_048_576]) }
}

/// Pages of the file a statement has to read when nothing is cached: the cost of a first touch, without the noise of timing it.
func storePagesBench(_ store: Store, _ targets: StoreTargets) throws {
    let path = store.pool.path
    let queries = try storeSearchQueries(store)
    func pages(_ name: String, _ sql: String, _ arguments: StatementArguments) throws {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        try queue.read { db in
            try db.execute(sql: "PRAGMA mmap_size = 0")
            var before: Int32 = 0, after: Int32 = 0, high: Int32 = 0
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_MISS, &before, &high, 0)
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            var rows = 0
            while try cursor.next() != nil { rows += 1 }
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_MISS, &after, &high, 0)
            report("pages.\(name)", ["pages": Double(after - before), "rows": Double(rows)])
        }
    }
    let account = targets.main
    try pages("list.inbox300", StoreSQL.list, [account, SystemLabel.inbox, 300])
    try pages("list.all3000", StoreSQL.list, [account, SystemLabel.all, 3000])
    try pages("recompute.read.longest", "SELECT id, internalDate, sender, toList, subject, snippet, labelIds, attachments FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate, id", [account, targets.longest])
    try pages("recompute.read.newsletter", "SELECT id, internalDate, sender, toList, subject, snippet, labelIds, attachments FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate, id", [account, targets.newsletter])
    try pages("modify.read.longest", "SELECT id, labelIds FROM message WHERE accountId = ? AND threadId = ?", [account, targets.longest])
    try pages("messages.longest", "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate, id", [account, targets.longest])
    try pages("messages.newsletter", "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY internalDate, id", [account, targets.newsletter])
    try pages("messageIds.inbox", "SELECT id, threadId FROM message WHERE accountId = ? AND id NOT LIKE 'local-%' AND labelIds LIKE ?", [account, "%\"INBOX\"%"])
    // Search, the way it now runs for a broad query: the matching row ids, then threads newest first through two indexes.
    for (name, text) in queries where ["prefix2", "word"].contains(name) {
        try pages("search.match.\(name)", "SELECT rowid FROM message_fts WHERE message_fts MATCH ?", ["\"\(text)\"*"])
        try pages("search.join.\(name)", StoreSQL.searchJoin, ["\"\(text)\"*"])
    }
    if try store.pool.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = 'thread_recent')") }) == true {
        try pages("search.walk.2000rows", StoreSQL.searchWalk, [])
    }
}

/// The statements `pages` replays by hand. Kept next to the benchmark; update when Store.swift's change.
enum StoreSQL {
    static let list = """
        SELECT thread.*, thread_label.sortDate AS sortDate FROM thread_label
        JOIN thread ON thread.accountId = thread_label.accountId AND thread.id = thread_label.threadId
        WHERE thread_label.accountId = ? AND thread_label.labelId = ? ORDER BY thread_label.sortDate DESC LIMIT ?
        """
    /// Finding the thread of every matching message, which is what search did for every query before.
    static let searchJoin = """
        SELECT DISTINCT message.accountId AS a, message.threadId AS t
        FROM message_fts JOIN message ON message.rowid = message_fts.rowid WHERE message_fts MATCH ?
        """
    /// The newest-first walk, cut where it typically stops for a broad query.
    static let searchWalk = """
        SELECT thread.rowid, thread.lastDate, message.rowid FROM thread INDEXED BY thread_recent
        JOIN message INDEXED BY message_thread ON message.accountId = thread.accountId AND message.threadId = thread.id
        ORDER BY thread.lastDate DESC LIMIT 2000
        """
}

// MARK: - Lists that refresh themselves while sync writes

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private func cpuMilliseconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
}

func storeObserveBench(_ store: Store, _ targets: StoreTargets) throws {
    let other = targets.accounts.first { $0 != targets.main } ?? targets.main
    var mail = BenchMail(account: other, replyTo: [])
    /// Fifty small sync writes to the other account that never enter any inbox: nothing on screen changes.
    func burst() throws -> (cpu: Double, wall: Double) {
        let cpu = cpuMilliseconds(), start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<50 { try store.benchSaveMessages(account: other, messages: mail.next(2, inbox: false)) }
        Thread.sleep(forTimeInterval: 0.4)
        return (cpuMilliseconds() - cpu, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 - 400)
    }
    _ = try burst()
    let plain = try burst()
    report("observe.burst.unobserved", ["cpu_ms_per_write": plain.cpu / 50, "wall_ms_per_write": plain.wall / 50])
    let cases: [(String, (Counter) -> Task<Void, Never>)] = [
        ("inbox600", { counter in Task.detached { for await _ in store.observeThreads(account: nil, label: SystemLabel.inbox, limit: 600) { counter.add() } } }),
        ("all3000", { counter in Task.detached { for await _ in store.observeThreads(account: nil, label: SystemLabel.all, limit: 3000) { counter.add() } } }),
        ("unreadCounts", { counter in Task.detached { for await _ in store.observeUnreadCounts() { counter.add() } } }),
        ("messages.longest", { counter in Task.detached { for await _ in store.observeMessages(account: targets.main, threadId: targets.longest) { counter.add() } } }),
        ("messages.newsletter", { counter in Task.detached { for await _ in store.observeMessages(account: targets.main, threadId: targets.newsletter) { counter.add() } } }),
    ]
    for (name, start) in cases {
        let counter = Counter()
        let task = start(counter)
        Thread.sleep(forTimeInterval: 0.3)
        let first = counter.count
        let observed = try burst()
        report("observe.\(name)", ["cpu_ms_per_write": observed.cpu / 50, "extra_cpu_ms_per_write": (observed.cpu - plain.cpu) / 50,
                                   "wall_ms_per_write": observed.wall / 50, "refreshes": Double(counter.count - first)])
        task.cancel()
        Thread.sleep(forTimeInterval: 0.2)
    }
    // What the app has running at once: the list, the badge counts and the open conversation.
    let counter = Counter()
    let tasks = [cases[0].1(counter), cases[2].1(counter), cases[3].1(counter)]
    Thread.sleep(forTimeInterval: 0.3)
    let first = counter.count
    let observed = try burst()
    report("observe.app", ["cpu_ms_per_write": observed.cpu / 50, "extra_cpu_ms_per_write": (observed.cpu - plain.cpu) / 50,
                           "wall_ms_per_write": observed.wall / 50, "refreshes": Double(counter.count - first)])
    tasks.forEach { $0.cancel() }
}

// MARK: - Proof that results stay the same

private func digest<T: Encodable>(_ name: String, _ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let hash = SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    print("\(name) \(hash.prefix(24))")
}

/// Prints a fingerprint of the result of every read the store offers, over many arguments. Two builds that print the
/// same lines on copies of the same mailbox return the same results.
func storeDigest(_ store: Store, _ targets: StoreTargets) throws {
    try snoozeSome(store, targets)
    let labels = [SystemLabel.inbox, SystemLabel.all, SystemLabel.done, targets.userLabel, SystemLabel.snoozed, SystemLabel.inboxMain, SystemLabel.inboxOther,
                  SystemLabel.sent, SystemLabel.starred, SystemLabel.unread, SystemLabel.draft, SystemLabel.trash, "nope"]
    for account in targets.accounts.map(Optional.init) + [nil] {
        let scope = account.map { "account\(targets.accounts.firstIndex(of: $0)!)" } ?? "merged"
        for label in labels {
            for limit in [1, 7, 300, 600, 3000, 100_000] {
                try digest("threads \(scope) \(label) \(limit)", try store.threads(account: account, label: label, limit: limit))
            }
        }
        for (name, text) in try storeSearchQueries(store) {
            try digest("search \(scope) \(name)", try store.search(account: account, text: text))
            try digest("search \(scope) \(name) limit5", try store.search(account: account, text: text, limit: 5))
        }
    }
    for (index, account) in targets.accounts.enumerated() {
        let scope = "account\(index)"
        let threads = try store.threads(account: account, label: SystemLabel.all, limit: 100_000)
        // Every thread's messages, in one fingerprint per 500 threads.
        for start in stride(from: 0, to: threads.count, by: 500) {
            let chunk = threads[start..<min(start + 500, threads.count)]
            try digest("messages \(scope) \(start)", try chunk.map { try store.messages(account: account, threadId: $0.id) })
        }
        let ids = threads.prefix(300).map(\.id)
        try digest("threadsById \(scope)", try store.threads(account: account, ids: ids.reversed() + ["nope"]))
        try digest("thread \(scope)", try ids.prefix(50).map { try store.thread(account: account, id: $0) })
        try digest("lastMessages \(scope)", try store.benchLastMessages(account: account, threadIds: Array(ids.prefix(100))))
        let messageIds = try store.benchServerMessageIds(account: account, threadIds: Array(ids)).sorted()
        try digest("serverMessageIds \(scope)", messageIds)
        try digest("message \(scope)", try messageIds.prefix(50).map { try store.message(account: account, id: $0) })
        try digest("notable \(scope)", try store.benchNotable(account: account, ids: Array(messageIds.prefix(400))))
        try digest("known \(scope)", try store.benchKnownMessageIds(account: account, among: messageIds + ["nope"]).sorted())
        try digest("unread \(scope)", try labels.map { try store.unreadCount(account: account, label: $0) })
        try digest("senderName \(scope)", try store.senderName(account: account))
        try store.pool.write { try $0.execute(sql: "UPDATE account SET name = '' WHERE id = ?", arguments: [account]) }
        try digest("senderName guessed \(scope)", try store.senderName(account: account))
        try digest("labels \(scope)", try store.labels(account: account))
        for label in [SystemLabel.inbox, SystemLabel.unread, SystemLabel.sent, targets.userLabel] {
            try digest("messageIds \(scope) \(label)", try store.benchMessageIds(account: account, withLabel: label).sorted())
        }
        try digest("incomplete \(scope)", try store.benchIncompleteThreads(account: account, limit: 50))
        try digest("whole \(scope)", try store.benchWholeThreads(account: account, among: Array(ids)).sorted())
        try digest("needsCompleting \(scope)", try ids.map { try store.threadNeedsCompleting(account: account, threadId: $0) })
        try digest("readyOps \(scope)", try store.benchReadyOps(account: account, limit: 50).map { "\($0.id ?? 0) \($0.threadId) \($0.addLabels) \($0.removeLabels)" })
        try digest("dueSnoozes \(scope)", try store.benchDueSnoozes(account: account).sorted())
        try digest("snoozeLabels \(scope)", try store.benchSnoozeLabelIds(account: account))
        let emails = try store.pool.read { try String.fetchAll($0, sql: "SELECT email FROM contact WHERE accountId = ? ORDER BY uses DESC, email LIMIT 40", arguments: [account]) }
        var needles = ["a", "e", "s", "ma", "no", "zzqq", "%", "_", "@"]
        for email in emails { needles += [String(email.prefix(1)), String(email.prefix(3)), String(email.split(separator: "@").last?.prefix(2) ?? "")] }
        try digest("contacts \(scope)", try needles.map { try store.contacts(account: account, matching: $0) })
        try digest("contacts \(scope) limit50", try needles.map { try store.contacts(account: account, matching: $0, limit: 50) })
    }
    try digest("accounts", try store.accounts())
    try digest("nextSnooze", try store.benchNextSnooze().map { _ in true })
}

/// Fingerprints of every table after a fixed series of writes: two builds that print the same lines write the same data.
func storeWriteDigest(_ store: Store, _ targets: StoreTargets) throws {
    let account = targets.main
    let inbox = targets.inbox, archived = targets.archived
    guard inbox.count >= 200 else { return }
    try store.modifyThreads(account: account, threadIds: Array(inbox[0..<20]), add: [], remove: [SystemLabel.inbox])
    try store.modifyThreads(account: account, threadIds: Array(inbox[10..<40]), add: [SystemLabel.starred], remove: [SystemLabel.unread])
    try store.modifyThreads(account: account, threadIds: Array(inbox[30..<60]), add: [SystemLabel.unread, targets.userLabel], remove: [])
    try store.modifyThreads(account: account, threadIds: Array(inbox[60..<80]), add: [], remove: [SystemLabel.inbox], snoozeUntil: 4_000_000_000_000)
    try store.modifyThreads(account: account, threadIds: Array(inbox[70..<75]), add: [SystemLabel.inbox], remove: [], clearSnooze: true)
    try store.modifyThreads(account: account, threadIds: Array(inbox[80..<90]), add: [SystemLabel.trash], remove: [SystemLabel.inbox])
    try store.modifyThreads(account: account, threadIds: Array(archived.prefix(20)), add: [SystemLabel.inbox], remove: [])
    try store.modifyThreads(account: account, threadIds: [targets.longest, targets.middle, "nope"], add: [SystemLabel.starred, SystemLabel.inbox], remove: [SystemLabel.unread])
    var mail = BenchMail(account: account, replyTo: Array(archived.prefix(60)) + Array(inbox[0..<40]))
    var saved: [Message] = []
    for size in [1, 20, 100, 7] {
        var batch = mail.next(size)
        // Fixed dates, so two runs write the same rows.
        for index in batch.indices { batch[index].internalDate = 3_000_000_000_000 + Int64(saved.count + index) }
        try store.benchSaveMessages(account: account, messages: batch)
        saved += batch
    }
    try store.benchSaveMessages(account: account, messages: Array(saved.prefix(40)).map { var m = $0; m.labelIds = ["CATEGORY_PERSONAL"]; return m })
    let lastIds = try store.benchLastMessages(account: account, threadIds: Array(inbox[90..<190])).map(\.id)
    let unknown = try store.benchApplyLabelChanges(account: account, changes: lastIds.enumerated().map { index, id in
        (messageId: id, add: index % 3 == 0 ? [SystemLabel.unread] : [SystemLabel.starred], remove: index % 2 == 0 ? [SystemLabel.inbox] : [SystemLabel.unread])
    } + [(messageId: "nope", add: ["X"], remove: [])], deleted: Array(saved.suffix(5).map(\.id)) + [lastIds[0]])
    try digest("unknown", unknown)
    let whole = try store.messages(account: account, threadId: targets.middle)
    try store.benchSaveThreads(account: account, threads: [(id: targets.middle, messages: Array(whole.dropLast(2))), (id: inbox[190], messages: [])])
    try store.benchRecompute(account: account, threadIds: Array(inbox[0..<100]))
    try store.benchRecomputeSnoozed(account: account)
    try store.pool.read { db in
        for (table, order) in [("thread", "accountId, id"), ("thread_label", "accountId, labelId, threadId"), ("snooze", "accountId, threadId"), ("contact", "accountId, email"),
                               ("op", "id"), ("full_thread", "accountId, threadId"), ("label", "accountId, id")] {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(order)")
            try digest("table \(table) \(rows.count)", rows.map { row in row.map { "\($0.0)=\($0.1)" } })
        }
        let messages = try Row.fetchAll(db, sql: "SELECT accountId, id, threadId, internalDate, sender, toList, subject, snippet, labelIds, refs, attachments, length(bodyHTML) AS html, length(bodyText) AS text FROM message ORDER BY accountId, id")
        try digest("table message \(messages.count)", messages.map { row in row.map { "\($0.0)=\($0.1)" } })
        try digest("fts rows", try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts") ?? -1)
        try digest("fts orphans", try Int.fetchOne(db, sql: "SELECT count(*) FROM message_fts WHERE rowid NOT IN (SELECT rowid FROM message)") ?? -1)
    }
    for (name, text) in try storeSearchQueries(store) + [("bench", "bench subject"), ("benchbody", "whiskey xray")] {
        try digest("search after \(name)", try store.search(account: nil, text: text))
    }
    try digest("threads after", try store.threads(account: nil, label: SystemLabel.inbox, limit: 100_000))
}

/// Repeats one operation for eight seconds, for looking at with a profiler (`sample <pid>`).
func storeSpin(_ store: Store, _ targets: StoreTargets, what: String) throws {
    let account = targets.main
    var mail = BenchMail(account: account, replyTo: Array(targets.archived.prefix(400)))
    let fifty = Array(targets.inbox.prefix(50))
    let known = mail.next(100)
    try store.benchSaveMessages(account: account, messages: known)
    let word = try storeSearchQueries(store).first { $0.0 == "word" }?.1 ?? ""
    let singles = try store.pool.read { try String.fetchAll($0, sql: "SELECT id FROM thread WHERE accountId = ? AND messageCount = 1 ORDER BY lastDate DESC LIMIT 100", arguments: [account]) }
    FileHandle.standardError.write(Data("spinning\n".utf8))
    let end = Date().addingTimeInterval(8)
    var flip = 0
    while Date() < end {
        flip += 1
        switch what {
        case "list": _ = try store.threads(account: nil, label: SystemLabel.all, limit: 3000)
        case "modify": try store.modifyThreads(account: account, threadIds: fifty, add: flip % 2 == 0 ? [SystemLabel.unread] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.unread])
        case "save": try store.benchSaveMessages(account: account, messages: mail.next(20))
        case "known": try store.benchSaveMessages(account: account, messages: known)
        case "search": _ = try store.search(account: nil, text: String(word.prefix(2)))
        case "thread": _ = try store.messages(account: account, threadId: targets.longest)
        case "recompute": try store.benchRecompute(account: account, threadIds: singles)
        case "labels": _ = try store.benchApplyLabelChanges(account: account, changes: known.map { (messageId: $0.id, add: flip % 2 == 0 ? [SystemLabel.unread] : [], remove: flip % 2 == 0 ? [] : [SystemLabel.unread]) }, deleted: [])
        default: return
        }
    }
}

/// Runs the faster HTML-to-text over every stored body and counts where it differs from the version it replaced.
func storeStripCheck(_ store: Store) throws {
    var checked = 0, different = 0
    try store.pool.read { db in
        let bodies = try String.fetchCursor(db, sql: "SELECT bodyHTML FROM message WHERE bodyHTML IS NOT NULL")
        while let html = try bodies.next() {
            checked += 1
            if HTMLText.strip(html) != HTMLText.stripReference(html) || HTMLText.strip(html, limit: 500) != HTMLText.stripReference(html, limit: 500) { different += 1 }
        }
    }
    report("strip.check", ["bodies": Double(checked), "different": Double(different)])
}
