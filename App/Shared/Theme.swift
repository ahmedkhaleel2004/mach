import MachCore
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

extension Color {
    /// A color with separate light and dark values.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
        #endif
    }
}

extension PlatformColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The same palette as `thread.html`, so the list and the open thread look like one surface.
enum Theme {
    /// How big list rows and the open email are on the Mac. 1.0 is the old size; the default is a step up.
    static let scaleKey = "displayScale"
    static let defaultScale = 1.2
    /// The same idea on the iPhone, where it sizes every piece of text in the app and the open email.
    static let phoneScaleKey = "phoneScale"
    static let phoneDefaultScale = 1.15

    /// A size in points, grown by the iPhone's text size setting. Unchanged on the Mac, whose rows scale themselves.
    static func pt(_ size: CGFloat) -> CGFloat {
        #if os(iOS)
        return (size * CGFloat(TextSize.shared.value)).rounded()
        #else
        return size
        #endif
    }

    static let background = Color(light: 0xFFFFFF, dark: 0x111114)
    static let text = Color(light: 0x1B1B1F, dark: 0xECECF1)
    static let dim = Color(light: 0x6E6E78, dark: 0x9C9CA8)
    /// The word "Draft" on a conversation with an unsent reply, in the red Gmail uses for it.
    static let draft = Color(light: 0xD93025, dark: 0xF28B82)
    static let faint = Color(light: 0x9A9AA5, dark: 0x6C6C78)
    static let line = Color(light: 0xE7E7EC, dark: 0x26262C)
    static let card = Color(light: 0xF6F6F8, dark: 0x1A1A1F)
    static let chip = Color(light: 0xEFEFF3, dark: 0x222228)
    static let accent = Color(light: 0x5B5BD6, dark: 0x9D9DFF)
    static let selection = Color(light: 0xEEEEFB, dark: 0x1E1E2B)
    static let overlay = Color(light: 0xFFFFFF, dark: 0x1C1C22)

    #if os(macOS)
    static let platformBackground = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x111114) : NSColor(hex: 0xFFFFFF) }
    #else
    static let platformBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x111114) : UIColor(hex: 0xFFFFFF) }
    #endif
}

enum Dates {
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current)
        return formatter
    }()
    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()
    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()
    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()
    private static let long: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdjmm")
        return formatter
    }()

    private static let complete: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    /// Everything, for the details of an open message.
    static func full(_ date: Date) -> String { complete.string(from: date) }

    /// Short form for list rows: a time today, a day this year, a full date before that.
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) { return monthDay.string(from: date) }
        return full.string(from: date)
    }

    /// Longer form for an open message.
    static func detailed(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) { return long.string(from: date) }
        return full.string(from: date)
    }

    static func snooze(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day, days < 7 {
            return weekdayTime.string(from: date)
        }
        return long.string(from: date)
    }
}

/// The lists a person can open.
struct MailList: Hashable, Identifiable {
    var label: String
    var title: String
    var id: String { label }

    /// Everything in the inbox, in one list. The default.
    static let inbox = MailList(label: SystemLabel.inbox, title: "Inbox")
    /// With "Split inbox" on: mail from people here, and promotions, updates and the like in Other.
    static let main = MailList(label: SystemLabel.inboxMain, title: "Inbox")
    static let other = MailList(label: SystemLabel.inboxOther, title: "Other")
    static let splitKey = "splitInbox"
    static let starred = MailList(label: SystemLabel.starred, title: "Starred")
    static let snoozed = MailList(label: SystemLabel.snoozed, title: "Snoozed")
    static let drafts = MailList(label: SystemLabel.draft, title: "Drafts")
    static let sent = MailList(label: SystemLabel.sent, title: "Sent")
    static let done = MailList(label: SystemLabel.done, title: "Done")
    static let all = MailList(label: SystemLabel.all, title: "All Mail")
    static let spam = MailList(label: SystemLabel.spam, title: "Spam")
    static let trash = MailList(label: SystemLabel.trash, title: "Trash")

    static let standard: [MailList] = [.starred, .snoozed, .drafts, .sent, .all, .spam, .trash]

    var icon: String {
        switch label {
        case SystemLabel.inbox, SystemLabel.inboxMain: return "tray"
        case SystemLabel.inboxOther: return "tray.2"
        case SystemLabel.starred: return "star"
        case SystemLabel.snoozed: return "clock"
        case SystemLabel.draft: return "doc"
        case SystemLabel.sent: return "paperplane"
        case SystemLabel.all, SystemLabel.done: return "tray.full"
        case SystemLabel.spam: return "exclamationmark.octagon"
        case SystemLabel.trash: return "trash"
        default: return "tag"
        }
    }

    var isInbox: Bool { label == SystemLabel.inbox || label == SystemLabel.inboxMain || label == SystemLabel.inboxOther }

    /// The label Gmail knows this list by, if it has one, for loading older mail.
    var serverLabel: String? {
        switch label {
        case SystemLabel.inboxMain, SystemLabel.inboxOther: return SystemLabel.inbox
        case SystemLabel.done, SystemLabel.all: return SystemLabel.all
        case SystemLabel.snoozed: return nil
        default: return label
        }
    }
}

/// The iPhone's text size, read by every view that draws text so a move of the slider redraws them all.
@Observable final class TextSize {
    static let shared = TextSize()
    var value: Double = UserDefaults.standard.object(forKey: Theme.phoneScaleKey) as? Double ?? Theme.phoneDefaultScale {
        didSet { UserDefaults.standard.set(value, forKey: Theme.phoneScaleKey) }
    }
}
