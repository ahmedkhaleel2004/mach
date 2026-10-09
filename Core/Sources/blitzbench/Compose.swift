import BlitzCore
import Foundation

// blitzbench compose <data-dir>
//
// What writing mail costs below the screen: building a reply (the quoted original), the save that follows a pause
// in typing, the address lookup behind the suggestions, finding the name to send under, and putting a message in
// the outbox. Run against a throwaway copy: it writes drafts and queues (never sends) messages. Offline.

func composeBenchmark(_ store: Store, _ args: [String]) throws {
    let service = try MailService(directory: directory, client: OAuthClient(clientId: "", clientSecret: nil), tokens: FileTokenStore(directory: directory), offline: true)
    let store = service.store
    guard let account = try store.accounts().first else { return print("no accounts") }

    // The conversation with the most messages and the single biggest message, among the first 300 of the inbox.
    let inbox = try store.threads(account: nil, label: SystemLabel.inbox, limit: 300)
    var longest: [Message] = []
    var biggest: Message?
    for thread in inbox {
        let messages = try store.messages(account: thread.accountId, threadId: thread.id)
        if messages.count > longest.count { longest = messages }
        for message in messages where (message.bodyHTML?.utf8.count ?? 0) > (biggest?.bodyHTML?.utf8.count ?? 0) { biggest = message }
    }
    guard let last = longest.last, let biggest else { return print("empty inbox") }
    let accounts = try store.accounts()
    func owner(_ message: Message) -> Account { accounts.first { $0.id == message.accountId } ?? account }

    for (label, message) in [("longest_conversation", last), ("biggest_message", biggest)] {
        let size = Double(message.bodyHTML?.utf8.count ?? message.bodyText?.utf8.count ?? 0)
        try measure("compose.read_conversation.\(label)", runs: 30) { _ = try store.messages(account: message.accountId, threadId: message.threadId) }
        measure("compose.build_reply.\(label)", runs: 30) { _ = Composer.reply(to: message, all: true, account: owner(message)) }
        var draft = Composer.reply(to: message, all: false, account: owner(message))
        draft.body = String(repeating: "a few words ", count: 20)
        report("compose.sizes.\(label)", ["original_bytes": size, "quoted_bytes": Double(draft.quotedHTML.utf8.count)])
        try measure("compose.save_draft.\(label)", runs: 50) { try store.saveDraft(draft) }
        try store.deleteDraft(draft.id)
        try measure("compose.queue_send.\(label)", runs: 15, warmup: 1) {
            var fresh = draft
            fresh.id = UUID().uuidString
            fresh.to = "nobody@example.invalid"
            try service.send(fresh, undoWindow: 3600)
        }
    }
    try measure("compose.sender_name", runs: 30) { for item in accounts { _ = try store.senderName(account: item.id) } }

    // Typing a name one letter at a time: the start of the most-used contact's name.
    let name = try store.pool.read { db in try String.fetchOne(db, sql: "SELECT lower(name) FROM contact WHERE accountId = ? AND length(name) >= 6 ORDER BY uses DESC LIMIT 1", arguments: [account.id]) } ?? "example"
    let typed = String(name.prefix(8))
    try measure("compose.contacts_per_keystroke", runs: 200) {
        for end in 1...typed.count { _ = try store.contacts(account: account.id, matching: String(typed.prefix(end))) }
    }
    report("compose.contacts_keystrokes", ["letters": Double(typed.count)])
}
