import Foundation

// MARK: - Wire types

struct GHeader: Decodable { let name: String; let value: String }
struct GBody: Decodable { let attachmentId: String?; let size: Int?; let data: String? }
struct GPart: Decodable {
    let mimeType: String?
    let filename: String?
    let headers: [GHeader]?
    let body: GBody?
    let parts: [GPart]?
}
struct GMessage: Decodable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: GPart?
}
struct GThread: Decodable { let id: String; let historyId: String?; let messages: [GMessage]? }
struct GThreadRef: Decodable { let id: String }
struct GThreadList: Decodable { let threads: [GThreadRef]?; let nextPageToken: String? }
struct GMessageRef: Decodable { let id: String; let threadId: String?; let labelIds: [String]? }
struct GMessageList: Decodable { let messages: [GMessageRef]?; let nextPageToken: String? }
struct GHistoryMessage: Decodable { let message: GMessageRef }
struct GHistoryLabels: Decodable { let message: GMessageRef; let labelIds: [String]? }
struct GHistory: Decodable {
    let messagesAdded: [GHistoryMessage]?
    let messagesDeleted: [GHistoryMessage]?
    let labelsAdded: [GHistoryLabels]?
    let labelsRemoved: [GHistoryLabels]?
}
struct GHistoryList: Decodable { let history: [GHistory]?; let nextPageToken: String?; let historyId: String? }
struct GLabel: Decodable { let id: String; let name: String; let type: String? }
struct GLabelList: Decodable { let labels: [GLabel]? }
struct GProfile: Decodable { let emailAddress: String; let historyId: String }
struct GSendAs: Decodable { let sendAsEmail: String; let displayName: String?; let signature: String?; let isPrimary: Bool? }
struct GSendAsList: Decodable { let sendAs: [GSendAs]? }
struct GDraft: Decodable { let id: String; let message: GMessageRef? }
struct GDraftList: Decodable { let drafts: [GDraft]?; let nextPageToken: String? }
struct GErrorBody: Decodable {
    struct Detail: Decodable { let reason: String? }
    struct Inner: Decodable { let code: Int?; let message: String?; let errors: [Detail]?; let status: String? }
    let error: Inner?
}

public struct GmailError: Error, LocalizedError, Sendable {
    public let status: Int
    public let reason: String
    public let message: String
    /// Which service said it: "Gmail" or "Outlook".
    public let service: String

    init(status: Int, reason: String, message: String, service: String = "Gmail") {
        self.status = status
        self.reason = reason
        self.message = message
        self.service = service
    }

    public var errorDescription: String? { "\(service) \(status): \(message)" }
    public var isNotFound: Bool { status == 404 }
    /// The request can never succeed, so retrying it is pointless.
    public var isPermanent: Bool { status >= 400 && status < 500 && status != 429 && status != 401 && !isRateLimit }
    var isRateLimit: Bool {
        status == 429 || (status == 403 && ["rateLimitExceeded", "userRateLimitExceeded"].contains(reason))
    }
}

// MARK: - Rate limiting

/// Gmail gives each person a small allowance of "units" per minute (a message costs 20, a thread 40) and
/// enforces it late and unevenly: measured on 2026-10-08 it refused requests after roughly 2,000 units in a
/// minute, well under the documented 6,000, and then refused everything for about 45 seconds.
/// So this paces itself and adapts: a small burst so the first screen fills at once, a steady rate after,
/// slower whenever Gmail pushes back and gradually faster again while it does not.
actor QuotaBucket {
    private let capacity: Double = 1000
    private var rate: Double = 30
    private let minRate: Double = 8
    private let maxRate: Double = 90
    /// Kept back from background downloads so a tap (archive, send, search) never waits.
    private let reserve: Double = 300
    private var tokens: Double = 1000
    private var updated = Date()
    private var pausedUntil = Date.distantPast
    private var lastPenalty = Date.distantPast
    private var lastRaise = Date()
    /// Benchmarks only (see `GmailTransport`): how many times faster than real time this bucket's clock runs. Always 1 in the apps.
    private let speedup: Double
    private let started = Date()

    init(speedup: Double = 1) {
        self.speedup = speedup
    }

    private func clock() -> Date {
        speedup == 1 ? Date() : started.addingTimeInterval(Date().timeIntervalSince(started) * speedup)
    }

    private func refill() {
        let now = clock()
        tokens = min(capacity, tokens + now.timeIntervalSince(updated) * rate)
        updated = now
        if now.timeIntervalSince(lastPenalty) > 90, now.timeIntervalSince(lastRaise) > 60 {
            rate = min(maxRate, rate + 4)
            lastRaise = now
        }
    }

    func acquire(_ cost: Double, background: Bool) async throws {
        while true {
            try Task.checkCancellation()
            refill()
            let pause = pausedUntil.timeIntervalSince(clock())
            let needed = cost + (background ? reserve : 0)
            if pause <= 0 && tokens >= min(needed, capacity) {
                tokens -= cost
                return
            }
            let wait = max(pause, (needed - tokens) / rate, 0.02)
            try await Task.sleep(nanoseconds: UInt64(min(wait, 5) / speedup * 1e9))
        }
    }

    /// Gmail said we went over. Stop for a while and come back slower.
    func penalize() {
        let now = clock()
        // Twenty requests in flight all fail together; that is one event, not twenty.
        guard now.timeIntervalSince(lastPenalty) > 5 else { return }
        lastPenalty = now
        lastRaise = now
        rate = max(minRate, rate * 0.6)
        tokens = 0
        updated = now
        pausedUntil = now.addingTimeInterval(35)
    }
}

// MARK: - Client

/// Benchmarks and tests only: a stand-in for Gmail. `protocolClasses` answer the requests instead of the network, and
/// `speedup` runs the pacing clock that many times faster so a long paced sync can be measured in seconds.
/// The apps never set this.
public struct GmailTransport: @unchecked Sendable {
    public var protocolClasses: [AnyClass]
    public var speedup: Double

    public init(protocolClasses: [AnyClass], speedup: Double = 1) {
        self.protocolClasses = protocolClasses
        self.speedup = speedup
    }
}

public final class GmailAPI: @unchecked Sendable {
    private let session: URLSession
    private let auth: Authenticator
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    private let decoder = JSONDecoder()
    private let quota: QuotaBucket
    private static let debug = ProcessInfo.processInfo.environment["MACH_DEBUG"] != nil

    public init(auth: Authenticator, transport: GmailTransport? = nil) {
        self.auth = auth
        quota = QuotaBucket(speedup: transport?.speedup ?? 1)
        let config = URLSessionConfiguration.default
        if let transport { config.protocolClasses = transport.protocolClasses }
        config.httpMaximumConnectionsPerHost = 20
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// `once` is for requests that must not be repeated when the outcome is unknown (sending mail): a dropped
    /// connection or a server error is reported instead of retried, and the caller decides what is safe.
    private func send(_ method: String, _ path: String, query: [(String, String)] = [], json: Any? = nil,
                      cost: Double = 5, background: Bool = false, once: Bool = false) async throws -> Data {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" alone, but Google reads it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        var attempt = 0
        var refreshed = false
        while true {
            try await quota.acquire(cost, background: background)
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                attempt += 1
                if attempt > 4 || once { throw error }
                try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 0.6 * 1e9))
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                if Self.debug { FileHandle.standardError.write(Data("\(Date().timeIntervalSince1970) ok cost=\(cost)\n".utf8)) }
                return data
            }
            let parsed = try? decoder.decode(GErrorBody.self, from: data)
            let failure = GmailError(status: status, reason: parsed?.error?.errors?.first?.reason ?? parsed?.error?.status ?? "",
                                     message: parsed?.error?.message ?? String(decoding: data.prefix(300), as: UTF8.self))
            if status == 401, !refreshed {
                refreshed = true
                _ = try await auth.accessToken(forceRefresh: true)
                continue
            }
            if Self.debug {
                FileHandle.standardError.write(Data("\(Date().timeIntervalSince1970) \(status) \(failure.reason) \(path.prefix(30)) cost=\(cost)\n".utf8))
            }
            if failure.isRateLimit {
                attempt += 1
                if attempt > 8 { throw failure }
                await quota.penalize()
                continue
            }
            if status >= 500 {
                attempt += 1
                if attempt > 6 || once { throw failure }
                let delay = min(16, pow(2, Double(attempt - 1))) * 0.5 + Double.random(in: 0...0.4)
                try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                continue
            }
            throw failure
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [(String, String)] = [],
                                   cost: Double = 5, background: Bool = false) async throws -> T {
        try decoder.decode(T.self, from: try await send("GET", path, query: query, cost: cost, background: background))
    }

    // MARK: Reads

    func profile() async throws -> GProfile { try await get(GProfile.self, "/profile", cost: 1) }

    func labels() async throws -> [GLabel] { try await get(GLabelList.self, "/labels", cost: 1).labels ?? [] }

    func sendAs() async throws -> [GSendAs] { try await get(GSendAsList.self, "/settings/sendAs", cost: 1).sendAs ?? [] }

    /// Lists message ids, newest first. Cheap: 5 units for up to 500.
    func listMessages(labelIds: [String] = [], query: String? = nil, pageToken: String? = nil, max: Int = 500) async throws -> GMessageList {
        var q: [(String, String)] = [("maxResults", String(max))]
        for label in labelIds { q.append(("labelIds", label)) }
        if let query, !query.isEmpty { q.append(("q", query)) }
        if let pageToken { q.append(("pageToken", pageToken)) }
        return try await get(GMessageList.self, "/messages", query: q, cost: 5)
    }

    func message(_ id: String, background: Bool = true) async throws -> GMessage {
        try await get(GMessage.self, "/messages/\(id)", query: [("format", "full")], cost: 20, background: background)
    }

    func thread(_ id: String, background: Bool = true) async throws -> GThread {
        try await get(GThread.self, "/threads/\(id)", query: [("format", "full")], cost: 40, background: background)
    }

    func history(since startHistoryId: String, pageToken: String?) async throws -> GHistoryList {
        var q: [(String, String)] = [("startHistoryId", startHistoryId), ("maxResults", "500")]
        if let pageToken { q.append(("pageToken", pageToken)) }
        return try await get(GHistoryList.self, "/history", query: q, cost: 2)
    }

    public func attachment(messageId: String, attachmentId: String) async throws -> Data {
        let body = try await get(GBody.self, "/messages/\(messageId)/attachments/\(attachmentId)", cost: 20)
        guard let encoded = body.data, let data = Data(base64URL: encoded) else {
            throw GmailError(status: 0, reason: "decode", message: "The attachment could not be read.")
        }
        return data
    }

    // MARK: Writes

    func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        _ = try await send("POST", "/threads/\(id)/modify", json: ["addLabelIds": add, "removeLabelIds": remove], cost: 10)
    }

    func createLabel(name: String) async throws -> GLabel {
        let data = try await send("POST", "/labels", json: ["name": name, "labelListVisibility": "labelHide", "messageListVisibility": "hide"], cost: 5)
        return try decoder.decode(GLabel.self, from: data)
    }

    /// One call for many messages: 50 units for up to 1,000.
    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws {
        _ = try await send("POST", "/messages/batchModify", json: ["ids": messageIds, "addLabelIds": add, "removeLabelIds": remove], cost: 50)
    }

    /// Finds the Gmail draft that wraps the given message.
    func draftId(forMessage messageId: String) async throws -> String? {
        var pageToken: String?
        repeat {
            var q: [(String, String)] = [("maxResults", "500")]
            if let pageToken { q.append(("pageToken", pageToken)) }
            let page = try await get(GDraftList.self, "/drafts", query: q, cost: 5)
            if let match = page.drafts?.first(where: { $0.message?.id == messageId }) { return match.id }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return nil
    }

    func sendDraft(id: String) async throws -> String? {
        let data = try await send("POST", "/drafts/send", json: ["id": id], cost: 100, once: true)
        return try decoder.decode(GMessageRef.self, from: data).threadId
    }

    func deleteDraft(id: String) async throws {
        _ = try await send("DELETE", "/drafts/\(id)", cost: 10)
    }

    /// Returns the id of the thread the message landed in.
    /// Saves a message as a draft on Gmail: a new one, or over an existing one when `id` is given.
    func saveDraft(id: String?, raw: Data, threadId: String?) async throws -> GDraft {
        var message: [String: Any] = ["raw": raw.base64URLString()]
        if let threadId { message["threadId"] = threadId }
        let data = try await send(id == nil ? "POST" : "PUT", "/drafts" + (id.map { "/\($0)" } ?? ""), json: ["message": message], cost: 15)
        return try decoder.decode(GDraft.self, from: data)
    }

    func sendMessage(raw: Data, threadId: String?) async throws -> GMessageRef {
        var payload: [String: Any] = ["raw": raw.base64URLString()]
        if let threadId { payload["threadId"] = threadId }
        let data = try await send("POST", "/messages/send", json: payload, cost: 100, once: true)
        return try decoder.decode(GMessageRef.self, from: data)
    }
}

// MARK: - Converting wire messages to records

extension GMessage {
    func record(accountId: String) -> Message {
        let parsed = PayloadParser.parse(payload)
        func header(_ name: String) -> String { MIMEWords.decode(parsed.headers[name] ?? "") }
        // Address headers stay as sent and are decoded per address after splitting. Decoding first would let an
        // encoded name smuggle in commas and angle brackets and pose as a second, trusted address.
        func addresses(_ name: String) -> String { parsed.headers[name] ?? "" }
        let html = parsed.htmlWithEmbeddedImages
        let text = parsed.text
        var snippetText = HTMLText.tidy(HTMLText.decodeEntities(snippet ?? ""))
        if snippetText.isEmpty, let text { snippetText = HTMLText.tidy(String(text.prefix(200))) }
        return Message(
            accountId: accountId, id: id, threadId: threadId ?? id,
            internalDate: Int64(internalDate ?? "") ?? 0,
            sender: addresses("from"), toList: addresses("to"), ccList: addresses("cc"), bccList: addresses("bcc"),
            replyTo: addresses("reply-to"), subject: header("subject"), snippet: snippetText,
            labelIds: labelIds ?? [], messageIdHeader: parsed.headers["message-id"] ?? "",
            refs: parsed.headers["references"] ?? parsed.headers["in-reply-to"] ?? "",
            bodyHTML: html, bodyText: text, attachments: parsed.attachments)
    }
}

/// Benchmarks and tests only: turns one `messages.get` answer into a record, exactly as a download does.
public enum WireMessage {
    public static func record(from json: Data, accountId: String) throws -> Message {
        try JSONDecoder().decode(GMessage.self, from: json).record(accountId: accountId)
    }
}
