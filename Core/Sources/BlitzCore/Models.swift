import Foundation
import GRDB

// MARK: - Well-known Gmail label ids

public enum SystemLabel {
    public static let inbox = "INBOX"
    public static let sent = "SENT"
    public static let draft = "DRAFT"
    public static let starred = "STARRED"
    public static let unread = "UNREAD"
    public static let trash = "TRASH"
    public static let spam = "SPAM"
    public static let important = "IMPORTANT"
    /// Local pseudo-label: every thread that is not in trash or spam.
    public static let all = "^all"
    /// Local pseudo-label: threads snoozed from this app.
    public static let snoozed = "^snoozed"
    /// Local pseudo-label: inbox threads from people (not promotions, social, updates or forums).
    public static let inboxMain = "^inbox_main"
    /// Local pseudo-label: the rest of the inbox.
    public static let inboxOther = "^inbox_other"
    /// Local pseudo-label: dealt with. Not in the inbox, not snoozed, not trash or spam.
    public static let done = "^done"
    /// A snooze is kept on Gmail itself as a hidden label whose name carries the wake time,
    /// so every device (and the push relay) knows about it and any of them can bring the mail back.
    public static let snoozePrefix = "Snoozed/"
    /// Stand-ins inside a queued change, turned into real label ids when the change is sent.
    static let snoozeToken = "^snooze:"
    static let unsnoozeToken = "^unsnooze"

    private static let snoozeFormat: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
        return formatter
    }()

    public static func snoozeLabelName(until milliseconds: Int64) -> String {
        // Whole minutes, so everything snoozed to "tomorrow 8am" shares one label.
        let minute = (milliseconds / 60000) * 60
        return snoozePrefix + snoozeFormat.string(from: Date(timeIntervalSince1970: Double(minute)))
    }

    public static func snoozeTime(fromLabelName name: String) -> Int64? {
        guard name.hasPrefix(snoozePrefix), let date = snoozeFormat.date(from: String(name.dropFirst(snoozePrefix.count))) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    static let bulkCategories = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]
}

// MARK: - Records

public struct Account: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "account"
    /// The email address.
    public var id: String
    public var name: String
    public var historyId: String?
    public var sortOrder: Int
    public var signature: String

    public init(id: String, name: String, historyId: String? = nil, sortOrder: Int = 0, signature: String = "") {
        self.id = id
        self.name = name
        self.historyId = historyId
        self.sortOrder = sortOrder
        self.signature = signature
    }
}

public struct MailLabel: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "label"
    public var accountId: String
    public var id: String
    public var name: String
    public var type: String

    public init(accountId: String, id: String, name: String, type: String) {
        self.accountId = accountId
        self.id = id
        self.name = name
        self.type = type
    }
}

public struct MailThread: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "thread"
    public var accountId: String
    public var id: String
    public var subject: String
    public var snippet: String
    /// Milliseconds since 1970 of the newest message.
    public var lastDate: Int64
    /// Display names of the senders, oldest first, de-duplicated.
    public var participants: [String]
    public var messageCount: Int
    public var unread: Bool
    public var starred: Bool
    public var hasAttachments: Bool
    public var labelIds: [String]
    public var snoozedUntil: Int64?
    /// Whose face stands for this conversation: the latest sender who is not you (or who you wrote to).
    public var avatarEmail: String
    public var avatarName: String

    public init(accountId: String, id: String, subject: String, snippet: String, lastDate: Int64, participants: [String],
                messageCount: Int, unread: Bool, starred: Bool, hasAttachments: Bool, labelIds: [String], snoozedUntil: Int64?,
                avatarEmail: String = "", avatarName: String = "") {
        self.avatarEmail = avatarEmail
        self.avatarName = avatarName
        self.accountId = accountId
        self.id = id
        self.subject = subject
        self.snippet = snippet
        self.lastDate = lastDate
        self.participants = participants
        self.messageCount = messageCount
        self.unread = unread
        self.starred = starred
        self.hasAttachments = hasAttachments
        self.labelIds = labelIds
        self.snoozedUntil = snoozedUntil
    }

    public var date: Date { Date(timeIntervalSince1970: Double(lastDate) / 1000) }
}

public struct Attachment: Codable, Hashable, Sendable {
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var attachmentId: String
    public var contentId: String?
    public var isInline: Bool

    public init(filename: String, mimeType: String, size: Int, attachmentId: String, contentId: String?, isInline: Bool) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.attachmentId = attachmentId
        self.contentId = contentId
        self.isInline = isInline
    }
}

public struct Message: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "message"
    public var accountId: String
    public var id: String
    public var threadId: String
    public var internalDate: Int64
    public var sender: String
    public var toList: String
    public var ccList: String
    public var bccList: String
    public var replyTo: String
    public var subject: String
    public var snippet: String
    public var labelIds: [String]
    public var messageIdHeader: String
    public var refs: String
    public var bodyHTML: String?
    public var bodyText: String?
    public var attachments: [Attachment]

    public var date: Date { Date(timeIntervalSince1970: Double(internalDate) / 1000) }
    public var isUnread: Bool { labelIds.contains(SystemLabel.unread) }
    public var isDraft: Bool { labelIds.contains(SystemLabel.draft) }
    public var isLocal: Bool { id.hasPrefix("local-") }
    public var from: EmailAddress { EmailAddress.parseList(sender).first ?? EmailAddress(name: "", email: sender) }

    /// An address header as stored (encoded names and all) made readable: `Jane Doe <jane@x.com>, bob@y.com`.
    public static func readable(_ header: String) -> String {
        let list = EmailAddress.parseList(header)
        return list.isEmpty ? MIMEWords.decode(header) : list.map(\.formatted).joined(separator: ", ")
    }
}

/// A message being written. Lives only in the local database until it is sent.
public struct Draft: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "draft"
    public var id: String
    public var accountId: String
    public var threadId: String?
    /// Gmail id of the message this replies to or forwards.
    public var sourceMessageId: String?
    public var to: String
    public var cc: String
    public var bcc: String
    public var subject: String
    public var body: String
    /// HTML of the quoted original, appended below the body when sending.
    public var quotedHTML: String
    public var inReplyTo: String
    public var refs: String
    public var attachmentPaths: [String]
    public var updatedAt: Int64
    /// The copy of this draft kept on Gmail, so it is there on every device and in Gmail itself: Gmail's ids for
    /// the draft, its message and its conversation. Nil until the first save has reached Gmail.
    public var remoteDraftId: String?
    public var remoteMessageId: String?
    public var remoteThreadId: String?
    /// The `updatedAt` of the version Gmail has. Anything newer still has to go up.
    public var uploadedAt: Int64 = 0

    public init(id: String = UUID().uuidString, accountId: String, threadId: String? = nil, sourceMessageId: String? = nil,
                to: String = "", cc: String = "", bcc: String = "", subject: String = "", body: String = "",
                quotedHTML: String = "", inReplyTo: String = "", refs: String = "", attachmentPaths: [String] = []) {
        self.id = id
        self.accountId = accountId
        self.threadId = threadId
        self.sourceMessageId = sourceMessageId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.quotedHTML = quotedHTML
        self.inReplyTo = inReplyTo
        self.refs = refs
        self.attachmentPaths = attachmentPaths
        self.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Nothing worth keeping has been written. A reply's recipients and subject are filled in for you, so they
    /// do not count; neither do the files a forward brings along.
    public var isEmpty: Bool {
        guard body.trimmed.isEmpty else { return false }
        if threadId != nil { return attachmentPaths.isEmpty }
        let noRecipients = to.trimmed.isEmpty && cc.trimmed.isEmpty && bcc.trimmed.isEmpty
        if !quotedHTML.isEmpty { return noRecipients }
        return noRecipients && subject.trimmed.isEmpty && attachmentPaths.isEmpty
    }

    /// The Message-ID this draft is sent with. Fixed per draft, so a repeated attempt is recognisable.
    public var outgoingMessageId: String { "<\(id.lowercased())@mail.blitzmail.app>" }
}

/// A change made locally that still has to reach Gmail.
public struct PendingOp: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "op"
    public var id: Int64?
    public var accountId: String
    public var kind: String
    public var threadId: String
    public var addLabels: [String]
    public var removeLabels: [String]
    /// For sends: the draft id. The local placeholder message id is `local-<draftId>`.
    public var draftId: String?
    /// Do not run before this time (ms). Gives "undo send" its window.
    public var notBefore: Int64
    public var attempts: Int
    public var lastError: String?

    public static let modify = "modify"
    public static let send = "send"
    /// Sends a draft that already exists on Gmail. `draftId` holds the id of the draft's message.
    public static let sendGmailDraft = "sendGmailDraft"
    /// Deletes a draft on Gmail. `draftId` holds the id of the draft's message.
    public static let deleteGmailDraft = "deleteGmailDraft"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Contact: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "contact"
    public var accountId: String
    public var email: String
    public var name: String
    public var uses: Int
    public var lastUsed: Int64

    public var address: EmailAddress { EmailAddress(name: name, email: email) }
}

// MARK: - Addresses

public struct EmailAddress: Hashable, Codable, Sendable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// The name if there is one, otherwise the part before the @.
    public var displayName: String {
        if !name.isEmpty { return name }
        return email.split(separator: "@").first.map(String.init) ?? email
    }

    public var formatted: String {
        if name.isEmpty { return email }
        let needsQuotes = name.unicodeScalars.contains { !(CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "." || $0 == "-" || $0 == "_") }
        let shown = needsQuotes ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : name
        return "\(shown) <\(email)>"
    }

    /// Parses an address header such as `"Doe, Jane" <jane@x.com>, bob@y.com`.
    public static func parseList(_ header: String) -> [EmailAddress] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var depth = 0
        var escaped = false
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if !inQuotes {
                if ch == "<" { depth += 1 } else if ch == ">" { depth = max(0, depth - 1) }
                if (ch == "," || ch == ";") && depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        parts.append(current)
        return parts.compactMap(parseOne)
    }

    private static func parseOne(_ raw: String) -> EmailAddress? {
        let text = raw.trimmed
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = String(text[text.index(after: open)..<close]).trimmed
            var name = String(text[..<open]).trimmed
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            name = OutgoingMessage.clean(MIMEWords.decode(name)).trimmed
            guard !email.isEmpty, !email.contains(" ") else { return nil }
            return EmailAddress(name: name == email ? "" : name, email: email.lowercased())
        }
        guard text.contains("@") else { return nil }
        return EmailAddress(name: "", email: text.lowercased())
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
