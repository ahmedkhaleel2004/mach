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

    // Read from the palette in use each time, so every view that draws with one is drawn again when it changes.
    static var background: Color { Palettes.shared.colors.background }
    static var text: Color { Palettes.shared.colors.text }
    static var dim: Color { Palettes.shared.colors.dim }
    /// The word "Draft" on a conversation with an unsent reply, in the red Gmail uses for it.
    static var draft: Color { Palettes.shared.colors.draft }
    static var faint: Color { Palettes.shared.colors.faint }
    static var line: Color { Palettes.shared.colors.line }
    static var card: Color { Palettes.shared.colors.card }
    static var chip: Color { Palettes.shared.colors.chip }
    static var accent: Color { Palettes.shared.colors.accent }
    static var selection: Color { Palettes.shared.colors.selection }
    static var overlay: Color { Palettes.shared.colors.overlay }

    /// For the pieces of AppKit and UIKit behind the views. Looks the palette up when it is drawn, not when it is set.
    #if os(macOS)
    static let platformBackground = NSColor(name: nil) { appearance in
        let palette = Palettes.shared.current
        let dark = palette.dark ?? (appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        return NSColor(hex: (dark ? palette.night : palette.day).background)
    }
    #else
    static let platformBackground = UIColor { traits in
        let palette = Palettes.shared.current
        let dark = palette.dark ?? (traits.userInterfaceStyle == .dark)
        return UIColor(hex: (dark ? palette.night : palette.day).background)
    }
    #endif
}

/// One set of the app's colours, as hex numbers.
struct Shades: Equatable {
    var background, text, dim, faint, line, card, chip, accent, selection, overlay, draft: UInt32

    /// The same colours for the page that shows conversations (`thread.html`).
    var css: String {
        func hex(_ value: UInt32) -> String { String(format: "#%06x", value) }
        return "--bg:\(hex(background));--text:\(hex(text));--dim:\(hex(dim));--faint:\(hex(faint));--line:\(hex(line));--card:\(hex(card));--accent:\(hex(accent));--chip:\(hex(chip))"
    }
}

/// A named set of colours to choose in settings.
struct Palette: Identifiable, Equatable {
    let id: String
    let name: String
    /// nil: light by day and dark by night, with the system. Otherwise the palette is always one or the other.
    let dark: Bool?
    let day: Shades
    let night: Shades

    init(_ id: String, _ name: String, day: Shades, night: Shades) {
        self.id = id; self.name = name; self.dark = nil; self.day = day; self.night = night
    }

    init(_ id: String, _ name: String, dark: Bool, _ shades: Shades) {
        self.id = id; self.name = name; self.dark = dark; self.day = shades; self.night = shades
    }

    /// What the conversation page lays over its own colours. Empty for the palette the page was written in.
    var css: String {
        guard let dark else { return id == Palette.all[0].id ? "" : ":root{\(day.css)}@media (prefers-color-scheme: dark){:root{\(night.css)}}" }
        return ":root{color-scheme:\(dark ? "dark" : "light");\(day.css)}"
    }

    static let all: [Palette] = [
        Palette("mach", "Mach",
                day: Shades(background: 0xFFFFFF, text: 0x1B1B1F, dim: 0x6E6E78, faint: 0x9A9AA5, line: 0xE7E7EC, card: 0xF6F6F8, chip: 0xEFEFF3, accent: 0x5B5BD6, selection: 0xEEEEFB, overlay: 0xFFFFFF, draft: 0xD93025),
                night: Shades(background: 0x111114, text: 0xECECF1, dim: 0x9C9CA8, faint: 0x6C6C78, line: 0x26262C, card: 0x1A1A1F, chip: 0x222228, accent: 0x9D9DFF, selection: 0x1E1E2B, overlay: 0x1C1C22, draft: 0xF28B82)),
        Palette("snow", "Snow", dark: false,
                Shades(background: 0xFFFFFF, text: 0x0F172A, dim: 0x5B6678, faint: 0x94A0B4, line: 0xE3E8EF, card: 0xF4F7FA, chip: 0xEBF0F5, accent: 0x2563EB, selection: 0xE8F0FE, overlay: 0xFFFFFF, draft: 0xD93025)),
        Palette("paper", "Paper", dark: false,
                Shades(background: 0xFBF7EF, text: 0x2B2620, dim: 0x6F665A, faint: 0xA2988A, line: 0xE9E1D2, card: 0xF3EDE0, chip: 0xECE4D4, accent: 0xB4581B, selection: 0xF4E8D6, overlay: 0xFFFCF5, draft: 0xC0392B)),
        Palette("blossom", "Blossom", dark: false,
                Shades(background: 0xFFF8FA, text: 0x2A1B22, dim: 0x7A6470, faint: 0xAD98A3, line: 0xF3DFE6, card: 0xFCEEF2, chip: 0xF7E4EA, accent: 0xD6336C, selection: 0xFCE4EC, overlay: 0xFFFFFF, draft: 0xC92A2A)),
        Palette("mint", "Mint", dark: false,
                Shades(background: 0xF6FBF8, text: 0x14261E, dim: 0x5A7166, faint: 0x93A89E, line: 0xDCEBE3, card: 0xECF6F0, chip: 0xE2F0E8, accent: 0x0F9D6B, selection: 0xDDF3E8, overlay: 0xFFFFFF, draft: 0xD93025)),
        Palette("carbon", "Carbon", dark: true,
                Shades(background: 0x000000, text: 0xF2F2F2, dim: 0xA0A0A0, faint: 0x6A6A6A, line: 0x1F1F1F, card: 0x0E0E0E, chip: 0x1A1A1A, accent: 0xE6E6E6, selection: 0x1C1C1C, overlay: 0x141414, draft: 0xFF7B72)),
        Palette("midnight", "Midnight", dark: true,
                Shades(background: 0x0B1020, text: 0xE6EAF5, dim: 0x98A2BD, faint: 0x626C88, line: 0x1C2440, card: 0x111830, chip: 0x18203C, accent: 0x6EA8FE, selection: 0x16224A, overlay: 0x141C36, draft: 0xFF8A80)),
        Palette("dracula", "Dracula", dark: true,
                Shades(background: 0x282A36, text: 0xF8F8F2, dim: 0xB6B9C8, faint: 0x7A86B0, line: 0x3A3D4D, card: 0x2F3241, chip: 0x383B4C, accent: 0xBD93F9, selection: 0x44475A, overlay: 0x30323F, draft: 0xFF5555)),
        Palette("nord", "Nord", dark: true,
                Shades(background: 0x2E3440, text: 0xECEFF4, dim: 0xB4BDCC, faint: 0x7B869B, line: 0x3B4252, card: 0x343B49, chip: 0x3B4252, accent: 0x88C0D0, selection: 0x434C5E, overlay: 0x353C4A, draft: 0xD9747E)),
        Palette("gruvbox", "Gruvbox", dark: true,
                Shades(background: 0x282828, text: 0xEBDBB2, dim: 0xBDAE93, faint: 0x8A7D70, line: 0x3C3836, card: 0x2E2C2B, chip: 0x3C3836, accent: 0xFABD2F, selection: 0x3F3A36, overlay: 0x32302F, draft: 0xFB4934)),
        Palette("forest", "Forest", dark: true,
                Shades(background: 0x0F1712, text: 0xE3EDE5, dim: 0x9BB0A1, faint: 0x61756A, line: 0x1E2B23, card: 0x15201A, chip: 0x1B2921, accent: 0x6FD49A, selection: 0x1A3226, overlay: 0x17231C, draft: 0xFF8A80)),
    ]
}

/// The palette in use. Every view that draws with one of `Theme`'s colours reads it, so choosing another redraws them all.
@Observable final class Palettes {
    static let shared = Palettes()
    static let key = "palette"

    /// The palette's colours made once, not for every row that asks.
    struct Colors {
        let background, text, dim, faint, line, card, chip, accent, selection, overlay, draft: Color

        init(_ palette: Palette) {
            func make(_ shade: KeyPath<Shades, UInt32>) -> Color { Color(light: palette.day[keyPath: shade], dark: palette.night[keyPath: shade]) }
            background = make(\.background); text = make(\.text); dim = make(\.dim); faint = make(\.faint); line = make(\.line); card = make(\.card)
            chip = make(\.chip); accent = make(\.accent); selection = make(\.selection); overlay = make(\.overlay); draft = make(\.draft)
        }
    }

    private(set) var current: Palette
    private(set) var colors: Colors

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key)
        let palette = Palette.all.first { $0.id == saved } ?? Palette.all[0]
        current = palette
        colors = Colors(palette)
    }

    func choose(_ palette: Palette) {
        guard palette != current else { return }
        current = palette
        colors = Colors(palette)
        UserDefaults.standard.set(palette.id, forKey: Self.key)
    }
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
