import Foundation

/// Looks up people's Google profile pictures: your own, your contacts', and those of people you have written with.
/// This is where real faces come from; Gmail's own API has no pictures at all. The same lists say who you know, so
/// they are also who a new message can be addressed to, the way Gmail offers them, before any mail has gone
/// between you on this device.
public actor PeopleDirectory {
    private let auth: Authenticator
    private let cacheFile: URL
    private var photos: [String: String]?
    private var loading: Task<[String: String], Never>?
    private var retryAfter = Date.distantPast

    private let learned: @Sendable ([KnownPerson]) -> Void

    private struct Cache: Codable {
        var savedAt: Date
        var photos: [String: String]
        /// Missing in a file written before names were kept: such a file is read again from Google.
        var known: Bool?
    }

    private struct PhotoItem: Decodable {
        struct Metadata: Decodable { let primary: Bool? }
        let url: String?
        let `default`: Bool?
        let metadata: Metadata?
    }
    private struct EmailItem: Decodable { let value: String? }
    private struct NameItem: Decodable { let displayName: String? }
    private struct Person: Decodable {
        let names: [NameItem]?
        let photos: [PhotoItem]?
        let emailAddresses: [EmailItem]?
    }
    private struct Page: Decodable {
        let otherContacts: [Person]?
        let connections: [Person]?
        let nextPageToken: String?
    }

    init(account: String, auth: Authenticator, directory: URL, learned: @escaping @Sendable ([KnownPerson]) -> Void = { _ in }) {
        self.learned = learned
        self.auth = auth
        cacheFile = directory.appendingPathComponent("people-\(account).json")
    }

    /// The address of a person's picture, or nil if Google has none (or only its grey placeholder).
    public func photoURL(for email: String) async -> URL? {
        let map = await all()
        guard let found = map[email.lowercased()] else { return nil }
        // Google hands out a thumbnail size in the address; ask for one big enough for a notification.
        let sized = found.replacingOccurrences(of: "=s100", with: "=s192")
        return URL(string: sized)
    }

    /// Reads the lists from Google if a day has gone by since the last time. Costs nothing otherwise.
    public func refresh() async { _ = await all() }

    private func all() async -> [String: String] {
        if let photos { return photos }
        if let loading { return await loading.value }
        if Date() < retryAfter { return [:] }
        if let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           Date().timeIntervalSince(cache.savedAt) < 86400, cache.known == true {
            photos = cache.photos
            return cache.photos
        }
        let task = Task { await self.fetch() }
        loading = task
        let result = await task.value
        loading = nil
        // Nothing at all usually means the lookup was refused (an older sign-in without contacts access) or the
        // network was down. Remember that only briefly, not for a day.
        guard !result.isEmpty else {
            retryAfter = Date().addingTimeInterval(300)
            return [:]
        }
        photos = result
        if let data = try? JSONEncoder().encode(Cache(savedAt: Date(), photos: result, known: true)) { try? data.write(to: cacheFile, options: .atomic) }
        return result
    }

    private func get<T: Decodable>(_ type: T.Type, _ url: String) async -> T? {
        guard let address = URL(string: url), let token = try? await auth.accessToken() else { return nil }
        var request = URLRequest(url: address)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func fetch() async -> [String: String] {
        var map: [String: String] = [:]
        var people: [KnownPerson] = []
        var listed = Set<String>()
        func add(_ person: Person, saved: Bool? = nil) {
            if let saved {
                let name = person.names?.compactMap(\.displayName).first ?? ""
                for email in (person.emailAddresses ?? []).compactMap(\.value).map({ $0.lowercased() }) where email.contains("@") && listed.insert(email).inserted {
                    people.append(KnownPerson(email: email, name: name, saved: saved))
                }
            }
            let real = person.photos?.filter { $0.default != true && $0.url != nil } ?? []
            guard let url = (real.first { $0.metadata?.primary == true } ?? real.first)?.url else { return }
            for email in (person.emailAddresses ?? []).compactMap(\.value) where map[email.lowercased()] == nil {
                map[email.lowercased()] = url
            }
        }
        let base = "https://people.googleapis.com/v1"
        if let me = await get(Person.self, base + "/people/me?personFields=photos,emailAddresses") { add(me) }
        for (path, key) in [("/people/me/connections?personFields=names,emailAddresses,photos&pageSize=1000", "connections"),
                            ("/otherContacts?readMask=names,emailAddresses,photos&sources=READ_SOURCE_TYPE_CONTACT&sources=READ_SOURCE_TYPE_PROFILE&pageSize=1000", "other")] {
            var token: String?
            var pages = 0
            repeat {
                guard let page = await get(Page.self, base + path + (token.map { "&pageToken=\($0)" } ?? "")) else { break }
                for person in (key == "other" ? page.otherContacts : page.connections) ?? [] { add(person, saved: key != "other") }
                token = page.nextPageToken
                pages += 1
            } while token != nil && pages < 10
        }
        if !people.isEmpty { learned(people) }
        return map
    }
}

/// Someone in the account's Google contacts: saved there by hand, or kept by Google because mail went between you.
public struct KnownPerson: Sendable, Hashable {
    public let email: String
    public let name: String
    public let saved: Bool

    public init(email: String, name: String, saved: Bool) {
        self.email = email
        self.name = name
        self.saved = saved
    }
}
