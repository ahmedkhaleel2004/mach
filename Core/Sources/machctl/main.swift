import MachCore
import Foundation

// Development tool: syncs a mailbox into a folder and prints what it found. It only reads from Gmail.
// usage: machctl <oauth-client.json> <google-token.json> <data-dir> [search words]

let args = CommandLine.arguments
// machctl signin <oauth-client.json> <url-file> <token-out.json> [email]
// Writes Google's sign-in address to <url-file>, waits for the browser to come back, then saves the refresh token.
if args.count >= 5, args[1] == "signin" {
    guard let client = OAuthClient.load(from: try Data(contentsOf: URL(fileURLWithPath: args[2]))) else {
        print("could not read the OAuth client file")
        exit(2)
    }
    let urlFile = args[3]
    let scope = ProcessInfo.processInfo.environment["MACH_SCOPE"] ?? OAuth.scope
    let tokens = try await OAuth.signIn(client: client, loginHint: args.count > 5 ? args[5] : nil, scope: scope) { url in
        try? url.absoluteString.write(toFile: urlFile, atomically: true, encoding: .utf8)
    }
    let data = try JSONSerialization.data(withJSONObject: ["refreshToken": tokens.refreshToken])
    try data.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: args[4])
    print("signed in")
    exit(0)
}
// machctl outlook <microsoft-client-id> <token.json> <data-dir> [search words]
// The same read-only run against an Outlook account. The token file holds a refresh token issued to that client id.
let outlook = args.count >= 5 && args[1] == "outlook"
let rest = outlook ? Array(args.dropFirst()) : args
guard rest.count >= 4 else {
    print("usage: machctl <oauth-client.json> <google-token.json> <data-dir> [search words]\n       machctl outlook <microsoft-client-id> <token.json> <data-dir> [search words]")
    exit(2)
}
let microsoft = outlook ? OAuthClient(clientId: rest[1], clientSecret: nil) : nil
guard let client = outlook ? OAuthClient(clientId: "", clientSecret: nil) : OAuthClient.load(from: try Data(contentsOf: URL(fileURLWithPath: rest[1]))) else {
    print("could not read the OAuth client file")
    exit(2)
}
let tokenJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: rest[2]))) as? [String: Any] ?? [:]
guard let refresh = (tokenJSON["refresh_token"] ?? tokenJSON["refreshToken"]) as? String else {
    print("no refresh token in the token file")
    exit(2)
}
let directory = URL(fileURLWithPath: rest[3])
let service = try MailService(directory: directory, client: client, microsoftClient: microsoft, tokens: FileTokenStore(directory: directory))
service.onReport = { account, message in print("[report] \(account): \(message)") }

let started = Date()
func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(started)) }

let account = try await service.addAccount(tokens: TokenSet(refreshToken: refresh, provider: outlook ? .microsoft : nil))
print("account \(account.id)")
await service.sync(for: account.id).sync()
let inbox = try service.store.threads(account: account.id, label: SystemLabel.inbox, limit: 100_000)
print("\(elapsed()) inbox threads: \(inbox.count), unread: \(try service.store.unreadCount(account: account.id))")
for thread in inbox.prefix(8) {
    print("  \(thread.unread ? "●" : " ") \(thread.participants.joined(separator: ", ").prefix(28)) | \(thread.subject.prefix(50)) | \(thread.messageCount)")
}
if rest.count > 4 {
    let words = rest[4...].joined(separator: " ")
    let t = Date()
    let hits = try service.store.search(account: account.id, text: words)
    print(String(format: "search \"%@\": %d hits in %.1f ms", words, hits.count, Date().timeIntervalSince(t) * 1000))
    for thread in hits.prefix(5) { print("  \(thread.subject.prefix(70))") }
}
let t = Date()
_ = try service.store.threads(account: account.id, label: SystemLabel.inbox, limit: 200)
print(String(format: "list read: %.2f ms", Date().timeIntervalSince(t) * 1000))
if let first = inbox.first {
    let t2 = Date()
    let messages = try service.store.messages(account: account.id, threadId: first.id)
    print(String(format: "thread read: %.2f ms (%d messages)", Date().timeIntervalSince(t2) * 1000, messages.count))
}
// Second pass exercises the incremental path.
let t3 = Date()
await service.sync(for: account.id).sync()
print(String(format: "incremental sync: %.0f ms", Date().timeIntervalSince(t3) * 1000))

if ProcessInfo.processInfo.environment["MACH_SETTLE"] != nil {
    // Lets the background fill-in finish, then says what ended up on the device.
    try await Task.sleep(nanoseconds: 12_000_000_000)
    for label in [SystemLabel.inbox, SystemLabel.done, SystemLabel.draft, SystemLabel.sent, SystemLabel.spam, SystemLabel.trash, SystemLabel.all] {
        print("\(label): \(try service.store.threads(account: account.id, label: label, limit: 100_000).count) threads")
    }
    print("labels: \(try service.store.labels(account: account.id).map(\.name))")
    print("cursor set: \(try service.store.account(account.id)?.historyId?.count ?? 0) chars, name: \(try service.store.account(account.id)?.name ?? "")")
}

// MACH_SELFTEST=1 with `outlook`: writes to the mailbox. Sends the account a message from itself and puts that one
// conversation through everything the app can do to mail, checking after each step that the service agrees.
if outlook, ProcessInfo.processInfo.environment["MACH_SELFTEST"] != nil {
    let me = account.id
    let sync = service.sync(for: me)
    let stamp = String(Int(Date().timeIntervalSince1970))
    let subject = "Mach self-test \(stamp)"
    func settle() async {
        await sync.flush()
        await sync.sync()
        await sync.sync()
    }
    func thread() throws -> MailThread? {
        for label in [SystemLabel.all, SystemLabel.trash, SystemLabel.spam] {
            if let found = try service.store.threads(account: me, label: label, limit: 100_000).first(where: { $0.subject.hasSuffix(subject) }) { return found }
        }
        return nil
    }
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(name) \(detail)")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mach-selftest-\(stamp)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("note.txt")
    try Data("attached by the self-test".utf8).write(to: file)

    var draft = Draft(accountId: me, to: me, bcc: "", subject: subject, body: "Your verification code is 482913.\nSent by the self-test.", attachmentPaths: [file.path])
    // Saved as a draft first, the way typing does.
    service.saveDraft(draft)
    await sync.saveDrafts()
    let saved = try service.store.draft(draft.id)
    check("draft saved to Outlook", saved?.remoteMessageId != nil)
    draft.body += "\nEdited."
    service.saveDraft(draft)
    await sync.saveDrafts()
    let resaved = try service.store.draft(draft.id)
    check("edited draft replaced the first", resaved?.remoteMessageId != nil && resaved?.remoteMessageId != saved?.remoteMessageId)
    try service.send(try service.store.draft(draft.id) ?? draft, undoWindow: 0)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    await settle()
    // Delivery to yourself takes a moment.
    for _ in 0..<15 {
        if let found = try thread(), found.labelIds.contains(SystemLabel.inbox) { break }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await sync.sync()
    }
    guard let arrived = try thread() else {
        print("FAIL the message never arrived")
        exit(1)
    }
    var messages = try service.store.messages(account: me, threadId: arrived.id)
    check("arrived in the inbox, unread", arrived.labelIds.contains(SystemLabel.inbox) && arrived.unread, "labels \(arrived.labelIds) messages \(messages.count)")
    check("sent copy is in the same conversation", messages.contains { $0.labelIds.contains(SystemLabel.sent) })
    let leftover = try service.store.draft(draft.id)
    check("no draft left behind", !messages.contains { $0.isDraft } && leftover == nil)
    check("code found", arrived.code == "482913", arrived.code ?? "none")
    let received = messages.first { $0.labelIds.contains(SystemLabel.inbox) }
    check("Message-ID kept", messages.allSatisfy { $0.messageIdHeader == draft.outgoingMessageId }, messages.map(\.messageIdHeader).joined(separator: " "))
    if let received, let attachment = received.attachments.first {
        let data = try await service.attachmentData(account: me, messageId: received.id, attachment: attachment)
        check("attachment downloads", String(decoding: data, as: UTF8.self) == "attached by the self-test", "\(attachment.filename) \(attachment.mimeType) \(data.count) bytes")
    } else {
        check("attachment listed", false)
    }
    func step(_ name: String, add: [String] = [], remove: [String] = [], snoozeUntil: Date? = nil, clearSnooze: Bool = false,
              expect: (MailThread) -> Bool) async throws {
        service.modify(account: me, threadIds: [arrived.id], add: add, remove: remove, snoozeUntil: snoozeUntil, clearSnooze: clearSnooze)
        try await Task.sleep(nanoseconds: 300_000_000)
        await settle()
        let now = try thread()
        let pending = try service.store.pendingOpCount()
        check(name, now.map(expect) ?? false, "labels \(now?.labelIds ?? []) snoozed \(now?.snoozedUntil.map(String.init) ?? "no") pending \(pending)")
    }
    try await step("mark read", remove: [SystemLabel.unread]) { !$0.unread }
    try await step("mark unread", add: [SystemLabel.unread]) { $0.unread }
    try await step("star", add: [SystemLabel.starred]) { $0.starred }
    try await step("unstar", remove: [SystemLabel.starred]) { !$0.starred }
    try await step("archive", remove: [SystemLabel.inbox]) { !$0.labelIds.contains(SystemLabel.inbox) }
    try await step("back to inbox", add: [SystemLabel.inbox], remove: [SystemLabel.trash, SystemLabel.spam], clearSnooze: true) { $0.labelIds.contains(SystemLabel.inbox) }
    let wake = Date().addingTimeInterval(86_400)
    try await step("snooze", remove: [SystemLabel.inbox], snoozeUntil: wake) { !$0.labelIds.contains(SystemLabel.inbox) && $0.snoozedUntil != nil && $0.labelIds.contains { $0.hasPrefix("Label_Snoozed/") } }
    try await step("unsnooze", add: [SystemLabel.inbox, SystemLabel.unread], clearSnooze: true) { $0.labelIds.contains(SystemLabel.inbox) && $0.snoozedUntil == nil && !$0.labelIds.contains { $0.hasPrefix("Label_Snoozed/") } }
    try await step("spam", add: [SystemLabel.spam], remove: [SystemLabel.inbox]) { $0.labelIds.contains(SystemLabel.spam) && !$0.labelIds.contains(SystemLabel.inbox) }
    try await step("not spam", add: [SystemLabel.inbox], remove: [SystemLabel.trash, SystemLabel.spam], clearSnooze: true) { $0.labelIds.contains(SystemLabel.inbox) && !$0.labelIds.contains(SystemLabel.spam) }

    // A reply, to see that it lands in the same conversation.
    if let received {
        var reply = Composer.reply(to: received, all: false, account: account)
        reply.body = "Reply from the self-test."
        try service.send(reply, undoWindow: 0)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await settle()
        for _ in 0..<15 {
            messages = try service.store.messages(account: me, threadId: arrived.id)
            if messages.filter({ $0.labelIds.contains(SystemLabel.inbox) }).count >= 2 { break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await sync.sync()
        }
        check("reply threads into the conversation", messages.count >= 4, "\(messages.count) messages, refs \(messages.map { $0.refs.isEmpty ? "-" : "refs" })")
    }
    try await step("trash", add: [SystemLabel.trash], remove: [SystemLabel.inbox]) { $0.labelIds.contains(SystemLabel.trash) && !$0.labelIds.contains(SystemLabel.inbox) && !$0.labelIds.contains(SystemLabel.sent) }

    // A second device: a fresh copy of the mailbox must come to the same view of this conversation.
    let other = folder.appendingPathComponent("second")
    let second = try MailService(directory: other, client: client, microsoftClient: microsoft, tokens: FileTokenStore(directory: directory))
    try second.store.saveAccount(Account(id: me, name: "", provider: .microsoft))
    await second.sync(for: me).sync()
    _ = await second.sync(for: me).complete(threadId: arrived.id, urgent: true)
    let mine = try service.store.messages(account: me, threadId: arrived.id).map { $0.id + " " + $0.labelIds.sorted().joined(separator: ",") }.sorted()
    let theirs = try second.store.messages(account: me, threadId: arrived.id).map { $0.id + " " + $0.labelIds.sorted().joined(separator: ",") }.sorted()
    check("a fresh device sees the same thing", mine == theirs && !mine.isEmpty, "\(mine.count) vs \(theirs.count)")
    print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
}
