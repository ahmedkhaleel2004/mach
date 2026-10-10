import Foundation

/// Which mail service an account lives on.
public enum MailProvider: String, Codable, Sendable {
    case google
    case microsoft

    /// What the service is called in messages to the person.
    public var name: String { self == .google ? "Gmail" : "Outlook" }
}

struct RemoteRef: Sendable {
    var id: String
    var threadId: String?
}

struct RemotePage: Sendable {
    var refs: [RemoteRef]
    var next: String?
}

struct RemoteLabel: Sendable {
    var id: String
    var name: String
    var type: String
}

struct RemoteDraft: Sendable {
    var id: String
    var messageId: String?
    var threadId: String?
}

/// What changed on the service since a cursor.
struct RemoteChanges: Sendable {
    /// Messages that are new on the service.
    var added: [String] = []
    var deleted: [String] = []
    var labels: [Store.LabelChange] = []
    /// Of the messages in `labels` that are not on this device, the ones worth downloading. Nil means all of them.
    var wanted: Set<String>?
    /// True when a message this device has never seen counts as new mail (the service does not say which are new).
    var unknownAreNew = false
    var cursor: String?
}

/// One mail service, spoken to in Gmail's terms: messages carry label ids (`SystemLabel`), conversations are threads.
/// `AccountSync` does the same work against any of them.
protocol MailBackend: Sendable {
    var provider: MailProvider { get }
    /// True when one change by message id can cover many threads at once (`batchModify`).
    var batchesByMessage: Bool { get }
    /// True when the label list from the service is not the whole truth: labels named on messages are learned as
    /// they are seen (`Label_<name>`), and the ones already learned are kept.
    var derivesLabels: Bool { get }

    /// A cursor taken now: `changes(since:)` reports everything after it.
    func cursor() async throws -> String
    func labels() async throws -> [RemoteLabel]
    /// The name mail is sent under, and the signature.
    func identity() async throws -> (name: String, signature: String)?
    /// Message ids of one list, newest first. `label` nil with no query means all mail outside spam and trash.
    func list(label: String?, query: String?, pageToken: String?, max: Int) async throws -> RemotePage
    func message(_ id: String, background: Bool) async throws -> Message
    func thread(_ id: String, background: Bool) async throws -> [Message]
    /// Throws an error with `isNotFound` when the cursor is too old to answer from.
    func changes(since cursor: String) async throws -> RemoteChanges
    func attachment(messageId: String, attachmentId: String) async throws -> Data

    func modifyThread(_ id: String, add: [String], remove: [String]) async throws
    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws
    func createLabel(name: String) async throws -> RemoteLabel

    func draftId(forMessage messageId: String) async throws -> String?
    func sendDraft(id: String) async throws
    func deleteDraft(id: String) async throws
    func saveDraft(id: String?, raw: Data, threadId: String?) async throws -> RemoteDraft
    /// Returns the id of the sent message when the service says it.
    func sendMessage(raw: Data, threadId: String?) async throws -> String?
    /// The id of a message that already went out with this Message-ID, if there is one.
    func sentMessage(withMessageId header: String) async throws -> String?
}

/// Gmail, which the terms above are already in.
struct GmailBackend: MailBackend {
    let api: GmailAPI
    let accountId: String

    var provider: MailProvider { .google }
    var batchesByMessage: Bool { true }
    var derivesLabels: Bool { false }

    func cursor() async throws -> String { try await api.profile().historyId }

    func labels() async throws -> [RemoteLabel] {
        try await api.labels().map { RemoteLabel(id: $0.id, name: $0.name, type: $0.type ?? "user") }
    }

    func identity() async throws -> (name: String, signature: String)? {
        let identities = try await api.sendAs()
        guard let primary = identities.first(where: { $0.isPrimary == true }) ?? identities.first else { return nil }
        return (primary.displayName ?? "", primary.signature ?? "")
    }

    func list(label: String?, query: String?, pageToken: String?, max: Int) async throws -> RemotePage {
        let page: GMessageList
        if let label {
            page = try await api.listMessages(labelIds: [label], query: query, pageToken: pageToken, max: max)
        } else {
            page = try await api.listMessages(query: query ?? "-in:spam -in:trash", pageToken: pageToken, max: max)
        }
        return RemotePage(refs: (page.messages ?? []).map { RemoteRef(id: $0.id, threadId: $0.threadId) }, next: page.nextPageToken)
    }

    func message(_ id: String, background: Bool) async throws -> Message {
        try await api.message(id, background: background).record(accountId: accountId)
    }

    func thread(_ id: String, background: Bool) async throws -> [Message] {
        (try await api.thread(id, background: background).messages ?? []).map { $0.record(accountId: accountId) }
    }

    func changes(since cursor: String) async throws -> RemoteChanges {
        var result = RemoteChanges()
        var pageToken: String?
        repeat {
            let page = try await api.history(since: cursor, pageToken: pageToken)
            for record in page.history ?? [] {
                for item in record.messagesAdded ?? [] { result.added.append(item.message.id) }
                for item in record.messagesDeleted ?? [] { result.deleted.append(item.message.id) }
                for item in record.labelsAdded ?? [] { result.labels.append(.init(messageId: item.message.id, add: item.labelIds ?? [], remove: [])) }
                for item in record.labelsRemoved ?? [] { result.labels.append(.init(messageId: item.message.id, add: [], remove: item.labelIds ?? [])) }
            }
            if let id = page.historyId { result.cursor = id }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    func attachment(messageId: String, attachmentId: String) async throws -> Data {
        try await api.attachment(messageId: messageId, attachmentId: attachmentId)
    }

    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        try await api.modifyThread(id, add: add, remove: remove)
    }

    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws {
        try await api.batchModify(messageIds: messageIds, add: add, remove: remove)
    }

    func createLabel(name: String) async throws -> RemoteLabel {
        let created = try await api.createLabel(name: name)
        return RemoteLabel(id: created.id, name: created.name, type: "user")
    }

    func draftId(forMessage messageId: String) async throws -> String? { try await api.draftId(forMessage: messageId) }

    func sendDraft(id: String) async throws { _ = try await api.sendDraft(id: id) }

    func deleteDraft(id: String) async throws { try await api.deleteDraft(id: id) }

    func saveDraft(id: String?, raw: Data, threadId: String?) async throws -> RemoteDraft {
        let saved = try await api.saveDraft(id: id, raw: raw, threadId: threadId)
        return RemoteDraft(id: saved.id, messageId: saved.message?.id, threadId: saved.message?.threadId)
    }

    func sendMessage(raw: Data, threadId: String?) async throws -> String? {
        try await api.sendMessage(raw: raw, threadId: threadId).id
    }

    func sentMessage(withMessageId header: String) async throws -> String? {
        // Not the saved draft, which carries the same id and has not gone anywhere.
        let query = "-in:draft rfc822msgid:" + header.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return try await api.listMessages(query: query, max: 1).messages?.first?.id
    }
}
