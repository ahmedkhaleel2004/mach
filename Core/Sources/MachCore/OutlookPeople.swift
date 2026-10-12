import Foundation

/// Who an Outlook account knows: the contacts saved in it, and the people it writes with. They are who a new
/// message can be addressed to before any mail has gone between you on this device, and a saved contact's picture
/// is the face shown for that person. The Outlook counterpart of `PeopleDirectory`.
///
/// Reading them needs a permission that sign-ins made before it was asked for do not have. Outlook then refuses,
/// `denied` says so, and everything else carries on without them.
public actor OutlookPeople {
    private let account: String
    private let api: GraphAPI
    private let cacheFile: URL
    private let learned: @Sendable ([KnownPerson]) -> Void
    private let denied: @Sendable () -> Void
    /// Each known address, and the saved contact it belongs to ("" for someone who is not a saved contact).
    private var contacts: [String: String]?
    private var loading: Task<[String: String]?, Never>?
    private var retryAfter = Date.distantPast
    /// True once Outlook has refused the lists for want of permission.
    public private(set) var needsPermission = false

    private struct Cache: Codable {
        var savedAt: Date
        var contacts: [String: String]
    }

    private struct Address: Decodable { let address: String? }
    private struct Entry: Decodable {
        let id: String?
        let displayName: String?
        let emailAddresses: [Address]?
        let scoredEmailAddresses: [Address]?
        let personType: Kind?

        struct Kind: Decodable { let `class`: String? }
    }

    init(account: String, api: GraphAPI, directory: URL, learned: @escaping @Sendable ([KnownPerson]) -> Void = { _ in },
         denied: @escaping @Sendable () -> Void = {}) {
        self.account = account
        self.api = api
        self.learned = learned
        self.denied = denied
        cacheFile = directory.appendingPathComponent("people-\(account).json")
    }

    /// Reads the lists from Outlook if a day has gone by since the last time. Costs nothing otherwise.
    public func refresh() async { _ = await all() }

    /// The picture saved on the contact with this address, or the account's own picture for its own address.
    public func photo(for email: String) async -> Data? {
        let key = email.lowercased()
        let path: String
        if key == account {
            path = "/me/photo/$value"
        } else if let id = await all()[key], !id.isEmpty {
            path = "/me/contacts/\(GraphAPI.segment(id))/photo/$value"
        } else {
            return nil
        }
        // No picture is an ordinary answer (404), as is a sign-in that may not read it.
        return try? await api.send("GET", GraphAPI.url(path), background: true)
    }

    private func all() async -> [String: String] {
        if let contacts { return contacts }
        if let loading { return await loading.value ?? [:] }
        if Date() < retryAfter { return [:] }
        if let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           Date().timeIntervalSince(cache.savedAt) < 86400 {
            contacts = cache.contacts
            return cache.contacts
        }
        let task = Task { await self.fetch() }
        loading = task
        let result = await task.value
        loading = nil
        // Refused or offline: looked at again later, not kept for a day.
        guard let result else {
            retryAfter = Date().addingTimeInterval(needsPermission ? 6 * 3600 : 300)
            return [:]
        }
        contacts = result
        if let data = try? JSONEncoder().encode(Cache(savedAt: Date(), contacts: result)) { try? data.write(to: cacheFile, options: .atomic) }
        return result
    }

    private func list(_ path: String, _ select: String) async throws -> [Entry] {
        var found: [Entry] = []
        var next: URL? = GraphAPI.url(path, [("$select", select), ("$top", "500")])
        var pages = 0
        while let url = next, pages < 10 {
            let page = try await api.get(MSPage<Entry>.self, url, background: true)
            found += page.value
            next = page.nextLink.flatMap(URL.init(string:))
            pages += 1
        }
        return found
    }

    /// Nil when Outlook would not say.
    private func fetch() async -> [String: String]? {
        var map: [String: String] = [:]
        var people: [KnownPerson] = []
        func add(_ entry: Entry, addresses: [Address]?, saved: Bool) {
            for email in (addresses ?? []).compactMap(\.address).map({ $0.lowercased() }) where email.contains("@") && map[email] == nil {
                map[email] = saved ? entry.id ?? "" : ""
                people.append(KnownPerson(email: email, name: entry.displayName == email ? "" : entry.displayName ?? "", saved: saved))
            }
        }
        do {
            // Saved contacts first: theirs is the name that is kept, and they are the ones with pictures.
            for entry in try await list("/me/contacts", "displayName,emailAddresses") { add(entry, addresses: entry.emailAddresses, saved: true) }
            for entry in try await list("/me/people", "displayName,scoredEmailAddresses,personType") where entry.personType?.class != "Group" {
                add(entry, addresses: entry.scoredEmailAddresses, saved: false)
            }
        } catch let error as GmailError where error.status == 403 || error.status == 401 {
            if !needsPermission {
                needsPermission = true
                denied()
            }
            return nil
        } catch {
            return nil
        }
        needsPermission = false
        if !people.isEmpty { learned(people) }
        return map
    }
}
