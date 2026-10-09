import BlitzCore
import Foundation
import UserNotifications

/// Shows a banner for new mail and opens the conversation when the banner is clicked.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let open: @MainActor (String, String) -> Void
    private let isFrontmost: @MainActor () -> Bool

    init(open: @escaping @MainActor (String, String) -> Void, isFrontmost: @escaping @MainActor () -> Bool) {
        self.open = open
        self.isFrontmost = isFrontmost
        super.init()
        center.delegate = self
    }

    func askPermission() {
        if Bootstrap.offline { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func announce(_ messages: [Message]) {
        Task {
            for message in messages.suffix(5) { await announce(message) }
        }
    }

    private func announce(_ message: Message) async {
        do {
            #if DEBUG
            NSLog("announcing %@ (permission %d)", message.subject, await center.notificationSettings().authorizationStatus.rawValue)
            #endif
            let content = UNMutableNotificationContent()
            content.title = message.from.displayName
            content.subtitle = message.subject
            content.body = message.snippet
            content.sound = .default
            content.threadIdentifier = message.accountId + "/" + message.threadId
            content.userInfo = ["account": message.accountId, "thread": message.threadId]
            if AvatarStore.enabled, let picture = await AvatarStore.shared.data(for: message.from.email) {
                // The system moves the file it is given, so hand it a copy.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
                if (try? picture.write(to: copy)) != nil, let attachment = try? UNNotificationAttachment(identifier: "sender", url: copy) {
                    content.attachments = [attachment]
                }
            }
            // The same id as the push relay uses, so a message never shows twice.
            try? await center.add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Always shown, even with the app in front: new mail should be impossible to miss on any device.
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let account = info["account"] as? String, let thread = info["thread"] as? String else { return }
        await open(account, thread)
    }
}
