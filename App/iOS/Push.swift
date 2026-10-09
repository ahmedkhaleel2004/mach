import MachCore
import UIKit

@MainActor
final class PhoneDelegate: NSObject, UIApplicationDelegate {
    static var deviceToken: String? {
        get { UserDefaults.standard.string(forKey: "pushToken") }
        set { UserDefaults.standard.set(newValue, forKey: "pushToken") }
    }
    static weak var service: MailService?

    // The App Store build has no relay to push to it, so it never asks Apple for a push address.
    #if !STORE
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.register()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NSLog("push registration failed: %@", String(describing: error))
    }

    /// A push also wakes the app briefly, so the new mail is already there when the banner is tapped.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let service = Self.service else { return .noData }
        #if DEBUG || BENCH
        let start = (Bench.now(), LaunchBench.cpu())
        defer { Bench.record("push.silent", ms: Bench.now() - start.0, ["cpu": LaunchBench.cpu() - start.1, "sinceStart": Bench.sinceProcessStart()]) }
        #endif
        await service.syncAll()
        return .newData
    }
    #endif

    static var live: LiveLink?

    /// Tells the relay which phone to notify and which accounts to watch. Safe to call often.
    static func register() {
        guard let token = deviceToken else { return }
        live?.register(deviceToken: token, avatars: AvatarStore.enabled)
    }
}
