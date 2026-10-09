import BlitzCore
import Foundation

// Development tool: syncs a mailbox into a folder and prints what it found. It only reads from Gmail.
// usage: blitzctl <oauth-client.json> <google-token.json> <data-dir> [search words]

let args = CommandLine.arguments
// blitzctl signin <oauth-client.json> <url-file> <token-out.json> [email]
// Writes Google's sign-in address to <url-file>, waits for the browser to come back, then saves the refresh token.
if args.count >= 5, args[1] == "signin" {
    guard let client = OAuthClient.load(from: try Data(contentsOf: URL(fileURLWithPath: args[2]))) else {
        print("could not read the OAuth client file")
        exit(2)
    }
    let urlFile = args[3]
    let scope = ProcessInfo.processInfo.environment["BLITZ_SCOPE"] ?? OAuth.scope
    let tokens = try await OAuth.signIn(client: client, loginHint: args.count > 5 ? args[5] : nil, scope: scope) { url in
        try? url.absoluteString.write(toFile: urlFile, atomically: true, encoding: .utf8)
    }
    let data = try JSONSerialization.data(withJSONObject: ["refreshToken": tokens.refreshToken])
    try data.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: args[4])
    print("signed in")
    exit(0)
}
guard args.count >= 4 else {
    print("usage: blitzctl <oauth-client.json> <google-token.json> <data-dir> [search words]")
    exit(2)
}
guard let client = OAuthClient.load(from: try Data(contentsOf: URL(fileURLWithPath: args[1]))) else {
    print("could not read the OAuth client file")
    exit(2)
}
let tokenJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as? [String: Any] ?? [:]
guard let refresh = (tokenJSON["refresh_token"] ?? tokenJSON["refreshToken"]) as? String else {
    print("no refresh token in the token file")
    exit(2)
}
let directory = URL(fileURLWithPath: args[3])
let service = try MailService(directory: directory, client: client, tokens: FileTokenStore(directory: directory))
service.onReport = { account, message in print("[report] \(account): \(message)") }

let started = Date()
func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(started)) }

let account = try await service.addAccount(tokens: TokenSet(refreshToken: refresh))
print("account \(account.id)")
await service.sync(for: account.id).sync()
let inbox = try service.store.threads(account: account.id, label: SystemLabel.inbox, limit: 100_000)
print("\(elapsed()) inbox threads: \(inbox.count), unread: \(try service.store.unreadCount(account: account.id))")
for thread in inbox.prefix(8) {
    print("  \(thread.unread ? "●" : " ") \(thread.participants.joined(separator: ", ").prefix(28)) | \(thread.subject.prefix(50)) | \(thread.messageCount)")
}
if args.count > 4 {
    let words = args[4...].joined(separator: " ")
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
