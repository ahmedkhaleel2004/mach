import BlitzCore
import BlitzFake
import Foundation
import GRDB

// Sync benchmarks. Gmail is played by `FakeGmail` (in memory, a fixed delay per request); nothing reaches the network.
// Run every one of them against a throwaway copy of a mailbox (`bench/data.sh fresh synth|real <dir>`): they write to it.
//
//   blitzbench sync-signal  <dir> [latency-ms=120] [runs=30]   a relay signal to the new mail being on screen
//   blitzbench sync-cpu     <dir> [runs=200]                   CPU to turn one downloaded message into a record
//   blitzbench sync-initial <dir> [speedup=30] [inbox=2000]    a first sync and backfill under the paced allowance
//   blitzbench sync-first50 <dir> [runs=3]                     seconds until the first 50 inbox threads show, real pacing
//   blitzbench sync-outbox  <dir> [latency-ms=120]             an action (archive) to its request leaving
//   blitzbench sync-poll    <dir> [latency-ms=120]             what one idle check costs

private struct FakeTokens: TokenStore {
    func load(account: String) -> TokenSet? {
        TokenSet(refreshToken: "none", accessToken: "fake-" + account, expiry: .distantFuture)
    }
    func save(_ tokens: TokenSet, account: String) {}
    func delete(account: String) {}
}

/// Ids no earlier run of a benchmark has used, so copies of a mailbox can be reused.
private func freshPrefix() -> String { "b" + UUID().uuidString.prefix(6).lowercased() }

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failure: Error?
    func finish(_ error: Error?) { lock.withLock { done = true; failure = error } }
    var state: (Bool, Error?) { lock.withLock { (done, failure) } }
}

/// Runs async work from the tool's plain main thread.
private func runAsync(_ body: @escaping @Sendable () async throws -> Void) throws {
    let flag = Flag()
    Task.detached {
        do {
            try await body()
            flag.finish(nil)
        } catch {
            flag.finish(error)
        }
    }
    while true {
        let (done, failure) = flag.state
        if let failure { throw failure }
        if done { return }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

private func service(_ directory: URL, speedup: Double = 1) throws -> MailService {
    let mail = try MailService(directory: directory, client: OAuthClient(clientId: "bench", clientSecret: nil), tokens: FakeTokens(),
                               transport: GmailTransport(protocolClasses: [FakeGmailProtocol.self], speedup: speedup))
    // A sync that fails must not pass for a fast one.
    mail.onReport = { account, message in FileHandle.standardError.write(Data("sync reported: \(message)\n".utf8)) }
    return mail
}

private func sleep(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

/// Remembers when each thread of a list first became visible to an observer, the way a screen would see it.
private final class Watcher: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Double] = [:]
    private var counts: [(count: Int, at: Double)] = []
    private var task: Task<Void, Never>?

    init(store: Store, account: String, label: String = SystemLabel.inbox, limit: Int = 200) {
        task = Task.detached { [weak self] in
            for await threads in store.observeThreads(account: account, label: label, limit: limit) {
                let now = uptime()
                guard let self else { return }
                self.lock.withLock {
                    for thread in threads where self.seen[thread.id] == nil { self.seen[thread.id] = now }
                    self.counts.append((threads.count, now))
                }
            }
        }
    }

    func stop() { task?.cancel() }

    /// When the list first held at least `count` threads.
    func time(reaching count: Int) -> Double? { lock.withLock { counts.first { $0.count >= count }?.at } }

    func wait(for ids: [String], timeout: Double = 120) async -> [Double]? {
        let deadline = uptime() + timeout
        while uptime() < deadline {
            let times = lock.withLock { ids.compactMap { seen[$0] } }
            if times.count == ids.count { return times }
            await sleep(0.0005)
        }
        return nil
    }

    func wait(reaching count: Int, timeout: Double) async -> Double? {
        let deadline = uptime() + timeout
        while uptime() < deadline {
            if let at = time(reaching: count) { return at }
            await sleep(0.001)
        }
        return nil
    }
}

private func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
private func p90(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[min(values.count - 1, values.count * 9 / 10)] }

/// Marks the mailbox as fully filled in, the state it is in every day after the first: nothing left to backfill.
private func markSettled(_ store: Store, account: String) throws {
    try store.pool.write { db in
        try db.execute(sql: "INSERT OR IGNORE INTO full_thread(accountId, threadId) SELECT DISTINCT accountId, threadId FROM message WHERE accountId = ?", arguments: [account])
        for key in [SystemLabel.starred, SystemLabel.draft, SystemLabel.sent] {
            try db.execute(sql: "INSERT OR REPLACE INTO loaded(accountId, key, pageToken, done) VALUES (?, ?, NULL, 1)", arguments: [account, key])
        }
        try db.execute(sql: "INSERT OR REPLACE INTO loaded(accountId, key, pageToken, done) VALUES (?, 'backfilled', '100000', 0)", arguments: [account])
    }
}

/// The account a benchmark plays with: the mailbox's first one, or a made-up one in an empty folder.
private func settledAccount(_ store: Store, historyId: String) throws -> String {
    var account = try store.accounts().first?.id
    if account == nil {
        try store.saveAccount(Account(id: "bench@example.com", name: "Bench"))
        account = "bench@example.com"
    }
    try markSettled(store, account: account!)
    try store.pool.write { try $0.execute(sql: "UPDATE account SET historyId = ? WHERE id = ?", arguments: [historyId, account!]) }
    return account!
}

// MARK: - Signal to stored

private func syncSignal(_ directory: URL, _ args: [String]) throws {
    let latency = (Double(args.first ?? "") ?? 120) / 1000
    let runs = args.count > 1 ? Int(args[1]) ?? 30 : 30
    try runAsync {
        for (batch, count) in [(1, runs), (20, max(5, runs / 3)), (40, max(3, runs / 6))] {
            var visible: [Double] = [], first: [Double] = [], returned: [Double] = [], lead: [Double] = [], rounds: [Double] = [], requests: [Double] = []
            var between: [Double] = [], afterLast: [Double] = []
            // A fresh service per run: a full allowance each time, as when mail arrives in an idle app.
            for run in 0..<(count + 2) {
                let mail = try service(directory)
                let server = FakeGmail(email: try settledAccount(mail.store, historyId: "0"), latency: latency, idPrefix: freshPrefix())
                let account = try settledAccount(mail.store, historyId: server.historyId)
                let watcher = Watcher(store: mail.store, account: account)
                let sync = mail.sync(for: account)
                await sync.sync()
                await sleep(0.3)
                let ids = server.deliver(batch)
                server.resetLog()
                let start = uptime()
                await sync.sync()
                let end = uptime()
                guard let times = await watcher.wait(for: ids, timeout: 30) else {
                    let stored = try await mail.store.pool.read { db in try ids.filter { try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM message WHERE id = ?)", arguments: [$0]) ?? false }.count }
                    throw BenchError("new mail never became visible: \(stored) of \(ids.count) stored, \(server.calls.count) requests")
                }
                await sleep(0.2)
                let summary = server.summary()
                watcher.stop()
                server.close()
                // The first two runs warm the caches.
                guard run >= 2 else { continue }
                visible.append((times.max()! - start) * 1000)
                first.append((times.min()! - start) * 1000)
                returned.append((end - start) * 1000)
                let calls = server.calls
                lead.append(((calls.map(\.start).min() ?? start) - start) * 1000)
                // Our own work between the change log's answer and the first download leaving, and between the last
                // download's answer and the mail being on screen.
                if let history = calls.first(where: { $0.kind == "history" }), let firstGet = calls.filter({ $0.kind == "messages.get" }).map(\.start).min() {
                    between.append((firstGet - history.end) * 1000)
                }
                if let lastGet = calls.filter({ $0.kind == "messages.get" }).map(\.end).max() { afterLast.append((times.max()! - lastGet) * 1000) }
                rounds.append(Double(summary.rounds))
                requests.append(Double(summary.requests))
            }
            report("sync.signal.\(batch)", ["latency_ms": latency * 1000, "visible_median_ms": median(visible), "visible_p90_ms": p90(visible), "first_visible_median_ms": median(first),
                                           "sync_returned_median_ms": median(returned), "before_first_request_median_ms": median(lead),
                                           "between_requests_median_ms": median(between), "last_answer_to_visible_median_ms": median(afterLast), "before_first_request_p90_ms": p90(lead),
                                           "overhead_median_ms": median(zip(visible, rounds).map { $0 - $1 * latency * 1000 }),
                                           "round_trips": median(rounds), "requests": median(requests), "runs": Double(visible.count)])
        }
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - CPU per message

/// A `messages.get` answer rebuilt from a stored message, so the decoding can be timed on a mailbox's own mail.
private func wire(_ message: Message) -> Data {
    func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var headers: [[String: String]] = [
        ["name": "Delivered-To", "value": message.accountId], ["name": "Received", "value": "by 2002:a05:7300:a48f:b0:17c:5f5a:8f3d with SMTP id x15csp1234567dyb; Thu, 8 Oct 2026 06:12:44 -0700 (PDT)"],
        ["name": "From", "value": message.sender], ["name": "To", "value": message.toList], ["name": "Subject", "value": MIMEWords.encode(message.subject)],
        ["name": "Message-ID", "value": message.messageIdHeader], ["name": "MIME-Version", "value": "1.0"],
    ]
    if !message.ccList.isEmpty { headers.append(["name": "Cc", "value": message.ccList]) }
    if !message.refs.isEmpty { headers.append(["name": "References", "value": message.refs]) }
    var parts: [[String: Any]] = []
    if let text = message.bodyText {
        parts.append(["mimeType": "text/plain", "filename": "", "headers": [["name": "Content-Type", "value": "text/plain; charset=\"UTF-8\""]], "body": ["size": text.utf8.count, "data": encode(text)]])
    }
    if let html = message.bodyHTML {
        parts.append(["mimeType": "text/html", "filename": "", "headers": [["name": "Content-Type", "value": "text/html; charset=\"UTF-8\""]], "body": ["size": html.utf8.count, "data": encode(html)]])
    }
    for attachment in message.attachments {
        parts.append(["mimeType": attachment.mimeType, "filename": attachment.filename, "headers": [["name": "Content-Disposition", "value": attachment.isInline ? "inline" : "attachment"]],
                      "body": ["attachmentId": attachment.attachmentId, "size": attachment.size]])
    }
    let object: [String: Any] = ["id": message.id, "threadId": message.threadId, "labelIds": message.labelIds, "snippet": message.snippet, "internalDate": String(message.internalDate),
                                 "payload": ["mimeType": "multipart/mixed", "filename": "", "headers": headers, "body": ["size": 0], "parts": parts]]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

/// What storing a message does with its body for search, on top of making the record (see `Store.insertMessage`).
private func searchText(_ message: Message) -> String {
    message.bodyText.map { String($0.prefix(40_000)) } ?? message.bodyHTML.map { HTMLText.strip($0) } ?? ""
}

private func syncCPU(_ store: Store, _ args: [String]) throws {
    let runs = Int(args.first ?? "") ?? 200
    for kind in FakeGmail.Kind.allCases {
        let json = FakeGmail.sampleMessage(kind)
        let record = try WireMessage.record(from: json, accountId: "bench@example.com")
        var sink = 0
        try measure("sync.cpu.record.\(kind)", runs: runs, warmup: 10) { sink &+= try WireMessage.record(from: json, accountId: "bench@example.com").subject.count }
        measure("sync.cpu.strip.\(kind)", runs: runs, warmup: 10) { sink &+= HTMLText.strip(record.bodyHTML ?? "").count }
        report("sync.cpu.size.\(kind)", ["json_kb": Double(json.count) / 1024, "html_kb": Double(record.bodyHTML?.utf8.count ?? 0) / 1024, "sink": Double(sink % 2)])
    }
    // The mailbox's own newest mail, rebuilt into the shape Gmail sends it in.
    let messages = try store.pool.read { try Message.fetchAll($0, sql: "SELECT * FROM message WHERE id NOT LIKE 'local-%' ORDER BY internalDate DESC LIMIT 400") }
    guard !messages.isEmpty else { return }
    let wires = messages.map(wire)
    var recordTimes: [Double] = [], stripTimes: [Double] = []
    for round in 0..<6 {
        var records: [Double] = [], strips: [Double] = []
        for (index, json) in wires.enumerated() {
            let start = DispatchTime.now().uptimeNanoseconds
            let record = try WireMessage.record(from: json, accountId: messages[index].accountId)
            let middle = DispatchTime.now().uptimeNanoseconds
            _ = searchText(record)
            let end = DispatchTime.now().uptimeNanoseconds
            records.append(Double(middle - start) / 1e6)
            strips.append(Double(end - middle) / 1e6)
        }
        // The first round warms up.
        if round == 0 { continue }
        if recordTimes.isEmpty {
            recordTimes = records
            stripTimes = strips
        } else {
            recordTimes = zip(recordTimes, records).map(min)
            stripTimes = zip(stripTimes, strips).map(min)
        }
    }
    let total = zip(recordTimes, stripTimes).map(+)
    report("sync.cpu.mailbox", ["messages": Double(wires.count), "json_kb_mean": Double(wires.reduce(0) { $0 + $1.count }) / 1024 / Double(wires.count),
                                "record_mean_ms": recordTimes.reduce(0, +) / Double(wires.count), "record_p90_ms": p90(recordTimes),
                                "search_text_mean_ms": stripTimes.reduce(0, +) / Double(wires.count), "search_text_p90_ms": p90(stripTimes),
                                "total_mean_ms": total.reduce(0, +) / Double(wires.count), "total_p90_ms": p90(total), "total_max_ms": total.max() ?? 0])
}

// MARK: - Initial sync and backfill

private func waitQuiet(_ server: FakeGmail, for seconds: Double) async {
    var last = server.calls.count
    var quietSince = uptime()
    while uptime() - quietSince < seconds {
        await sleep(0.05)
        let now = server.calls.count
        if now != last {
            last = now
            quietSince = uptime()
        }
    }
}

private func syncInitial(_ directory: URL, _ args: [String]) throws {
    let speedup = Double(args.first ?? "") ?? 30
    let inbox = args.count > 1 ? Int(args[1]) ?? 2000 : 2000
    try runAsync {
        let mail = try service(directory, speedup: speedup)
        let account = "initial-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        try mail.store.saveAccount(Account(id: account, name: "Bench", sortOrder: 99))
        let server = FakeGmail(email: account, latency: 0.12 / speedup, idPrefix: freshPrefix())
        server.seed(inbox: inbox, archived: 1500)
        let watcher = Watcher(store: mail.store, account: account)
        let cpuStart = cpuSeconds()
        let start = uptime()
        await mail.sync(for: account).sync()
        let initialSeconds = (uptime() - start) * speedup
        let initial = server.summary()
        let stored = try await mail.store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE accountId = ?", arguments: [account]) ?? 0 }
        var values: [String: Double] = ["speedup": speedup, "inbox_messages": Double(inbox), "virtual_seconds": initialSeconds, "requests": Double(initial.requests), "units": Double(initial.units),
                                        "megabytes": Double(initial.bytes) / 1_048_576, "messages_stored": Double(stored), "units_per_message": Double(initial.units) / Double(max(stored, 1)),
                                        "messages_per_second": Double(stored) / initialSeconds]
        for count in [1, 20, 50] {
            if let at = watcher.time(reaching: count) { values["first_\(count)_threads_virtual_s"] = (at - start) * speedup }
        }
        report("sync.initial", values)
        // The backfill runs after every sync; the apps sync every 15 seconds, so keep going until a pass finds nothing to do.
        var passes = 0
        while passes < 60 {
            await waitQuiet(server, for: 2)
            let before = server.calls.count
            await mail.sync(for: account).sync()
            await waitQuiet(server, for: 2)
            passes += 1
            if server.calls.count - before <= 1 { break }
        }
        let total = server.summary()
        let seconds = (uptime() - start) * speedup
        let storedAll = try await mail.store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE accountId = ?", arguments: [account]) ?? 0 }
        let repeats = server.repeats
        report("sync.initial.with_backfill", ["virtual_seconds": seconds, "requests": Double(total.requests), "units": Double(total.units), "megabytes": Double(total.bytes) / 1_048_576,
                                              "messages_stored": Double(storedAll), "units_per_message": Double(total.units) / Double(max(storedAll, 1)),
                                              "messages_get": Double(total.byKind["messages.get"] ?? 0), "threads_get": Double(total.byKind["threads.get"] ?? 0),
                                              "lists": Double(total.byKind["messages.list"] ?? 0), "repeated_messages": Double(repeats.messages), "repeated_megabytes": Double(repeats.bytes) / 1_048_576,
                                              "cpu_seconds": cpuSeconds() - cpuStart, "passes": Double(passes)])
        watcher.stop()
        server.close()
    }
}

private func syncFirst50(_ directory: URL, _ args: [String]) throws {
    let runs = Int(args.first ?? "") ?? 3
    try runAsync {
        var results: [Int: [Double]] = [:]
        for _ in 0..<runs {
            let mail = try service(directory)
            let account = "first-\(UUID().uuidString.prefix(8).lowercased())@example.com"
            try mail.store.saveAccount(Account(id: account, name: "Bench", sortOrder: 99))
            let server = FakeGmail(email: account, latency: 0.12)
            // No conversations here, so the number is the same on every run: one message, one thread.
            server.changeLabels(messageIds: server.seed(inbox: 0, archived: 70), add: ["INBOX"], remove: [])
            let watcher = Watcher(store: mail.store, account: account)
            let start = uptime()
            let sync = mail.sync(for: account)
            Task.detached { await sync.sync() }
            for count in [1, 20, 35, 50] {
                guard let at = await watcher.wait(reaching: count, timeout: 90) else { throw BenchError("only got to \(count) threads") }
                results[count, default: []].append(at - start)
            }
            // Let the rest of this small mailbox finish so it does not run into the next measurement.
            _ = await watcher.wait(reaching: 70, timeout: 90)
            await waitQuiet(server, for: 1.5)
            watcher.stop()
            server.close()
        }
        report("sync.first_threads", ["runs": Double(runs), "first_1_s": median(results[1] ?? []), "first_20_s": median(results[20] ?? []),
                                      "first_35_s": median(results[35] ?? []), "first_50_s": median(results[50] ?? []), "first_50_max_s": (results[50] ?? []).max() ?? 0])
    }
}

// MARK: - Outbox

private func syncOutbox(_ directory: URL, _ args: [String]) throws {
    let latency = (Double(args.first ?? "") ?? 120) / 1000
    try runAsync {
        // Fill a made-up account quickly, then act on it at real speed.
        let account = "outbox-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let server = FakeGmail(email: account, latency: 0.001)
        let ids = server.seed(inbox: 0, archived: 140)
        server.changeLabels(messageIds: ids, add: ["INBOX"], remove: [])
        let filler = try service(directory, speedup: 2000)
        try filler.store.saveAccount(Account(id: account, name: "Bench", sortOrder: 99))
        await filler.sync(for: account).sync()
        await waitQuiet(server, for: 1)
        await filler.sync(for: account).stop()
        try markSettled(filler.store, account: account)
        server.latency = latency

        func waitDrained(_ mail: MailService) async {
            while ((try? await mail.store.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM op WHERE accountId = ?", arguments: [account]) }) ?? 0) > 0 { await sleep(0.002) }
            await sleep(0.05)
        }

        // One action at a time.
        var leave: [Double] = [], done: [Double] = []
        let single = try service(directory)
        _ = single.sync(for: account)
        for index in 0..<22 {
            server.resetLog()
            let start = uptime()
            single.modify(account: account, threadIds: [ids[index]], remove: [SystemLabel.inbox])
            while server.calls.isEmpty { await sleep(0.0002) }
            await waitDrained(single)
            guard index >= 2, let call = server.calls.min(by: { $0.start < $1.start }) else { continue }
            leave.append((call.start - start) * 1000)
            done.append((call.end - start) * 1000)
        }
        report("sync.outbox.one", ["latency_ms": latency * 1000, "request_leaves_median_ms": median(leave), "request_leaves_p90_ms": p90(leave), "answered_median_ms": median(done), "runs": Double(leave.count)])

        // Fifty in quick succession, the way holding down `e` does it: one thread per call.
        var firstLeave: [Double] = [], lastLeave: [Double] = [], allDone: [Double] = [], requests: [Double] = [], units: [Double] = [], rounds: [Double] = [], batches: [Double] = []
        for run in 0..<2 {
            let mail = try service(directory)
            _ = mail.sync(for: account)
            server.resetLog()
            let start = uptime()
            for index in 0..<50 { mail.modify(account: account, threadIds: [ids[30 + run * 50 + index]], remove: [SystemLabel.inbox]) }
            await sleep(0.05)
            await waitDrained(mail)
            await sleep(0.3)
            let calls = server.calls.filter { $0.method == "POST" }
            let summary = server.summary()
            firstLeave.append(((calls.map(\.start).min() ?? start) - start) * 1000)
            lastLeave.append(((calls.map(\.start).max() ?? start) - start) * 1000)
            allDone.append(((calls.map(\.end).max() ?? start) - start) * 1000)
            requests.append(Double(calls.count))
            batches.append(Double(calls.filter { $0.kind == "batchModify" }.count))
            units.append(Double(calls.reduce(0) { $0 + $1.units }))
            rounds.append(Double(summary.rounds))
            let archived = ids[(30 + run * 50)..<(80 + run * 50)].filter { server.labels(of: $0)?.contains("INBOX") == false }.count
            guard archived == 50 else { throw BenchError("only \(archived) of 50 changes reached the server") }
        }
        report("sync.outbox.fifty", ["latency_ms": latency * 1000, "first_request_leaves_ms": median(firstLeave), "last_request_leaves_ms": median(lastLeave), "all_answered_ms": median(allDone),
                                     "requests": median(requests), "batch_requests": median(batches), "units": median(units), "round_trips": median(rounds)])
        server.close()
    }
}

// MARK: - Idle polling

private func syncPoll(_ directory: URL, _ args: [String]) throws {
    let latency = (Double(args.first ?? "") ?? 120) / 1000
    try runAsync {
        let mail = try service(directory)
        let accounts = try mail.store.accounts().map(\.id)
        var servers: [FakeGmail] = []
        if accounts.isEmpty { _ = try settledAccount(mail.store, historyId: "1000") }
        for account in try mail.store.accounts().map(\.id) {
            let server = FakeGmail(email: account, latency: latency, idPrefix: freshPrefix())
            try markSettled(mail.store, account: account)
            let historyId = server.historyId
            try await mail.store.pool.write { try $0.execute(sql: "UPDATE account SET historyId = ? WHERE id = ?", arguments: [historyId, account]) }
            servers.append(server)
        }
        await mail.syncAll()
        await sleep(0.3)
        // Wall time and requests of one idle check of every account.
        var wall: [Double] = []
        for server in servers { server.resetLog() }
        for _ in 0..<15 {
            let start = uptime()
            await mail.syncAll()
            wall.append((uptime() - start) * 1000)
            await sleep(0.25)
        }
        let requests = Double(servers.reduce(0) { $0 + $1.summary().requests }) / 15
        let units = Double(servers.reduce(0) { $0 + $1.summary().units }) / 15
        let bytes = Double(servers.reduce(0) { $0 + $1.summary().bytes }) / 15
        // CPU of one idle check, with the answer coming back at once so only our own work is counted.
        for server in servers { server.latency = 0 }
        for _ in 0..<20 { await mail.syncAll() }
        await sleep(0.3)
        let cpuStart = cpuSeconds()
        let polls = 400
        for _ in 0..<polls { await mail.syncAll() }
        await sleep(0.3)
        let cpu = (cpuSeconds() - cpuStart) / Double(polls) * 1000
        report("sync.poll.idle", ["accounts": Double(servers.count), "latency_ms": latency * 1000, "wall_median_ms": median(wall), "requests_per_poll": requests, "units_per_poll": units,
                                  "bytes_per_poll": bytes, "cpu_ms_per_poll": cpu,
                                  "requests_per_hour_at_15s": requests * 240, "cpu_seconds_per_hour_at_15s": cpu * 240 / 1000, "units_per_hour_at_15s": units * 240])
        for server in servers { server.close() }
    }
}

func registerSyncBenchmarks(directory: URL) {
    setlinebuf(stdout)
    benchmarks["sync-signal"] = { _, args in try syncSignal(directory, args) }
    benchmarks["sync-cpu"] = { store, args in try syncCPU(store, args) }
    benchmarks["sync-initial"] = { _, args in try syncInitial(directory, args) }
    benchmarks["sync-first50"] = { _, args in try syncFirst50(directory, args) }
    benchmarks["sync-outbox"] = { _, args in try syncOutbox(directory, args) }
    benchmarks["sync-poll"] = { _, args in try syncPoll(directory, args) }
}
