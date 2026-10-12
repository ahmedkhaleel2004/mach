#if STORE
import MachCore
import Foundation

/// Push for Outlook accounts in the App Store build (see `PushWatch`). Gmail accounts have none here: no server of
/// Mach's holds anything of a Google account, so their mail is found when the app is opened and in background refresh.
actor PublicPush {
    static let shared = PublicPush()

    /// Outlook keeps a promise to call for under a week; it is renewed when less than this is left of it.
    private static let renewWithin: TimeInterval = 4 * 86400
    private static let promiseLength: TimeInterval = 6 * 86400

    /// True for a build Apple sends test pushes to (one run from Xcode, or in the simulator).
    private static let sandbox: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return false }
        return text[key.upperBound...].prefix(60).contains("development")
        #endif
    }()

    /// Accounts whose new mail is announced by a push. Read by the app before it puts up a banner of its own.
    nonisolated static func covers(_ account: String) -> Bool {
        PushShare.all().contains { $0.email == account && $0.subscription != nil && ($0.subscriptionExpiry ?? .distantPast) > Date() }
    }

    /// Brings everything in line with the accounts signed in now: each Outlook account registered with the relay
    /// under this phone's push address, and Outlook's promise to call it made or renewed. Safe to call often;
    /// it does nothing when nothing is due.
    func refresh(service: MailService, deviceToken: String?, split: Bool) async {
        // One at a time: two passes side by side would each ask Outlook for a promise of its own.
        let earlier = running
        let pass = Task {
            await earlier?.value
            await self.bringInLine(service: service, deviceToken: deviceToken, split: split)
        }
        running = pass
        await pass.value
    }

    private var running: Task<Void, Never>?

    private func bringInLine(service: MailService, deviceToken: String?, split: Bool) async {
        let accounts = service.relayAccounts().filter { $0["provider"] == MailProvider.microsoft.rawValue }
        var watches = PushShare.all()
        // An account that is gone takes its arrangement with it.
        for watch in watches where !accounts.contains(where: { $0["email"] == watch.email }) { await end(watch) }
        watches.removeAll { watch in !accounts.contains { $0["email"] == watch.email } }
        guard let deviceToken else { return }
        for account in accounts {
            guard let email = account["email"], let refreshToken = account["refreshToken"], let clientId = account["clientId"] else { continue }
            var watch = watches.first { $0.email == email }
                ?? PushWatch(id: PushShare.random(), secret: PushShare.random(), email: email, clientId: clientId, refreshToken: refreshToken)
            if watch.refreshToken != refreshToken || watch.clientId != clientId {
                // Signed in afresh: the token at hand belongs to the old sign-in.
                watch.refreshToken = refreshToken
                watch.clientId = clientId
                watch.accessToken = nil
            }
            watch.quietOther = split
            PushShare.save(watch)
            // The relay first: Outlook checks that the address answers before it promises anything.
            if watch.registeredToken != deviceToken || Date().timeIntervalSince(watch.registeredAt ?? .distantPast) > 86400 {
                let answer = await PushShare.send("POST", PushShare.relay + "/v1/register",
                                                  json: ["id": watch.id, "secret": watch.secret, "deviceToken": deviceToken, "sandbox": Self.sandbox])
                guard answer.status == 200 else { continue }
                watch.registeredToken = deviceToken
                watch.registeredAt = Date()
                PushShare.save(watch)
            }
            let left = (watch.subscriptionExpiry ?? .distantPast).timeIntervalSinceNow
            guard watch.subscription == nil || left < Self.renewWithin else { continue }
            guard let token = await PushShare.accessToken(for: &watch) else { continue }
            let until = Date().addingTimeInterval(Self.promiseLength)
            let stamp = ISO8601DateFormatter().string(from: until)
            if let existing = watch.subscription, left > 0 {
                let renewed = await PushShare.outlook("PATCH", "/subscriptions/\(existing)", token: token, json: ["expirationDateTime": stamp])
                if renewed.status == 200 {
                    watch.subscriptionExpiry = until
                    PushShare.save(watch)
                    continue
                }
            }
            // Only mail that arrives unread: what a banner is for.
            let made = await PushShare.outlook("POST", "/subscriptions", token: token, json: [
                "changeType": "created", "notificationUrl": PushShare.relay + "/v1/outlook/" + watch.id,
                "resource": "me/mailFolders('inbox')/messages?$filter=isRead eq false", "expirationDateTime": stamp, "clientState": watch.secret,
            ])
            if made.status == 201, let id = made.body["id"] as? String {
                watch.subscription = id
                watch.subscriptionExpiry = until
            } else {
                watch.subscription = nil
                watch.subscriptionExpiry = nil
            }
            PushShare.save(watch)
        }
    }

    /// Signed out: Outlook is told to stop calling, the relay to forget, and the record is removed.
    func removed(_ email: String) async {
        for watch in PushShare.all() where watch.email == email { await end(watch) }
    }

    private func end(_ watch: PushWatch) async {
        var watch = watch
        if let subscription = watch.subscription, let token = await PushShare.accessToken(for: &watch) {
            _ = await PushShare.outlook("DELETE", "/subscriptions/\(subscription)", token: token)
        }
        _ = await PushShare.send("POST", PushShare.relay + "/v1/forget", json: ["id": watch.id, "secret": watch.secret])
        PushShare.delete(id: watch.id)
    }
}
#endif
