import MachCore
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
        // A banner for a mail that carries a sign-in code has a button that copies it.
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy Code", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.codeCategory, actions: [copy], intentIdentifiers: [])])
    }

    static let codeCategory = "code"
    static let copyAction = "copy-code"

    func askPermission() {
        if Bootstrap.offline { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Keeps the banners honest from here on: one for mail that has since been read, archived or deleted, on this
    /// device or any other, is taken down, off the screen and out of the notification list.
    func follow(_ service: MailService) {
        if Bootstrap.offline { return }
        lock.withLock { self.service = service }
        service.onSynced = { [weak self] _ in Task { await self?.tidy() } }
        Task { [weak self] in
            for await _ in service.store.observeWaitingThreads() { await self?.tidy() }
        }
    }

    private let lock = NSLock()
    private var service: MailService?
    private var ledger = BannerLedger()

    func tidy() async {
        guard let service = lock.withLock({ self.service }) else { return }
        let banners: [Banner] = await center.deliveredNotifications().compactMap { shown in
            let info = shown.request.content.userInfo
            guard let account = info["account"] as? String, let thread = info["thread"] as? String else { return nil }
            return Banner(id: shown.request.identifier, account: account, thread: thread, delivered: shown.date)
        }
        guard !banners.isEmpty, let waiting = try? service.store.waitingThreads() else { return }
        let stale = lock.withLock { ledger.stale(banners, waiting: waiting, synced: service.syncedFrom) }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
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
            if let code = message.code ?? OneTimeCode.find(subject: message.subject, text: message.snippet) {
                content.body = "Code \(code)  ·  " + message.snippet
                content.categoryIdentifier = Self.codeCategory
                content.userInfo["code"] = code
            }
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
        if response.actionIdentifier == Self.copyAction {
            if let code = info["code"] as? String { await MainActor.run { Clipboard.copy(code) } }
            return
        }
        guard let account = info["account"] as? String, let thread = info["thread"] as? String else { return }
        await open(account, thread)
    }
}
