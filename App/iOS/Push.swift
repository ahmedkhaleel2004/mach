import MachCore
import UIKit

@MainActor
final class PhoneDelegate: NSObject, UIApplicationDelegate {
    static var deviceToken: String? {
        get { UserDefaults.standard.string(forKey: "pushToken") }
        set { UserDefaults.standard.set(newValue, forKey: "pushToken") }
    }
    static weak var service: MailService?
    static var tidy: (() async -> Void)?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.register()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NSLog("push registration failed: %@", String(describing: error))
    }

    /// A push also wakes the app briefly, so the new mail is already there when the banner is tapped, and the
    /// banners of mail dealt with on another device are gone before the phone is picked up.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let service = Self.service else { return .noData }
        #if DEBUG || BENCH
        let start = (Bench.now(), LaunchBench.cpu())
        defer { Bench.record("push.silent", ms: Bench.now() - start.0, ["cpu": LaunchBench.cpu() - start.1, "sinceStart": Bench.sinceProcessStart()]) }
        #endif
        // A push means mail has just arrived (or was dealt with elsewhere): the inbox is looked at first.
        await service.syncAll(newMail: true)
        await Self.tidy?()
        #if STORE
        // Each push is also a chance to renew Outlook's promise to send the next one.
        await PublicPush.shared.refresh(service: service, deviceToken: Self.deviceToken, split: UserDefaults.standard.bool(forKey: MailList.splitKey))
        #endif
        return .newData
    }

    static var live: LiveLink?

    /// Tells the relay which phone to notify and which accounts to watch. Safe to call often.
    static func register() {
        #if STORE
        // The App Store build has no relay of yours in it. Its Outlook accounts go through the public one, which is
        // told nothing about them (see `PublicPush`).
        guard let service else { return }
        let token = deviceToken
        let split = UserDefaults.standard.bool(forKey: MailList.splitKey)
        Task { await PublicPush.shared.refresh(service: service, deviceToken: token, split: split) }
        #else
        guard let token = deviceToken else { return }
        live?.register(deviceToken: token, avatars: AvatarStore.enabled)
        #endif
    }
}
