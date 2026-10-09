import Intents
import UIKit
import UserNotifications

/// Runs for a moment when a push arrives and turns it into a "communication" notification:
/// the sender's picture where the app icon would be, the way Messages and Mail show them.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?
    private var work: Task<Void, Never>?
    private let lock = NSLock()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        fallback = request.content
        let info = request.content.userInfo
        guard info["avatars"] as? Bool ?? true, let email = info["senderEmail"] as? String, !email.isEmpty else {
            contentHandler(request.content)
            return
        }
        let name = (info["senderName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? email
        let thread = (info["thread"] as? String) ?? email
        let content = request.content
        // The relay sends the sender's Google profile picture when your contacts have one: a real face.
        let photo = (info["senderPhoto"] as? String).flatMap(URL.init(string:))
        work = Task { [weak self] in
            var picture = await Self.within(seconds: Self.pictureWait) {
                var found: Data?
                if let photo { found = await AvatarStore.shared.data(for: email, at: photo) }
                if found == nil { found = await AvatarStore.shared.data(for: email) }
                return found
            }
            if picture == nil { picture = Self.initialsImage(name: name, email: email) }
            let image = picture.map { INImage(imageData: $0) }
            let person = INPerson(personHandle: INPersonHandle(value: email, type: .emailAddress), nameComponents: nil,
                                  displayName: name, image: image, contactIdentifier: nil, customIdentifier: email)
            let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                             speakableGroupName: nil, conversationIdentifier: thread, serviceName: nil,
                                             sender: person, attachments: nil)
            if let image { intent.setImage(image, forParameterNamed: \.sender) }
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            try? await interaction.donate()
            guard !Task.isCancelled, let self else { return }
            let updated = (try? content.updating(from: intent)) ?? content
            self.finish(updated)
        }
    }

    /// The longest a banner waits for the sender's picture before it shows with their initials instead. On a working
    /// connection a picture takes well under a second. Without this, three lookups in a row, each allowed 8 seconds,
    /// could hold new mail back for 24 on a bad one.
    private static let pictureWait = 3.0

    /// The lookup's answer if it comes in time, else nil. A late lookup carries on, and what it finds is kept for
    /// the next banner from that sender.
    private static func within(seconds: Double, _ lookup: @escaping @Sendable () async -> Data?) async -> Data? {
        final class Answer: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Data?, Never>?
            init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
            func give(_ data: Data?) {
                let waiting: CheckedContinuation<Data?, Never>? = lock.withLock {
                    defer { continuation = nil }
                    return continuation
                }
                waiting?.resume(returning: data)
            }
        }
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            Task { answer.give(await lookup()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                answer.give(nil)
            }
        }
    }

    /// The system must hear back exactly once, whether the picture arrived or time ran out.
    private func finish(_ content: UNNotificationContent) {
        let pending: ((UNNotificationContent) -> Void)? = lock.withLock {
            defer { handler = nil }
            return handler
        }
        pending?(content)
    }

    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        if let fallback { finish(fallback) }
    }

    /// A colored circle with the sender's initials, for people and companies with no picture.
    private static func initialsImage(name: String, email: String) -> Data? {
        let size = CGSize(width: 160, height: 160)
        let hex = AvatarStore.colorHex(for: email)
        let color = UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            let text = AvatarStore.initials(name) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 62, weight: .semibold), .foregroundColor: UIColor.white]
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2), withAttributes: attributes)
        }
    }
}
