import Foundation

/// Looks up people's Google profile pictures: your own, your contacts', and those of people you have written with.
/// This is where real faces come from; Gmail's own API has no pictures at all.
public actor PeopleDirectory {
    private let auth: Authenticator
    private let cacheFile: URL
    private var photos: [String: String]?
    private var loading: Task<[String: String], Never>?
    private var retryAfter = Date.distantPast

    private struct Cache: Codable {
        var savedAt: Date
        var photos: [String: String]
    }

    private struct PhotoItem: Decodable {
        struct Metadata: Decodable { let primary: Bool? }
        let url: String?
        let `default`: Bool?
        let metadata: Metadata?
    }
    private struct EmailItem: Decodable { let value: String? }
    private struct Person: Decodable {
        let photos: [PhotoItem]?
        let emailAddresses: [EmailItem]?
    }
    private struct Page: Decodable {
        let otherContacts: [Person]?
        let connections: [Person]?
        let nextPageToken: String?
    }

    init(account: String, auth: Authenticator, directory: URL) {
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

    private func all() async -> [String: String] {
        if let photos { return photos }
        if let loading { return await loading.value }
        if Date() < retryAfter { return [:] }
        if let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           Date().timeIntervalSince(cache.savedAt) < 86400 {
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
        if let data = try? JSONEncoder().encode(Cache(savedAt: Date(), photos: result)) { try? data.write(to: cacheFile, options: .atomic) }
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
        func add(_ person: Person, extraEmail: String? = nil) {
            let real = person.photos?.filter { $0.default != true && $0.url != nil } ?? []
            guard let url = (real.first { $0.metadata?.primary == true } ?? real.first)?.url else { return }
            for email in (person.emailAddresses ?? []).compactMap(\.value) + [extraEmail].compactMap({ $0 }) where map[email.lowercased()] == nil {
                map[email.lowercased()] = url
            }
        }
        let base = "https://people.googleapis.com/v1"
        if let me = await get(Person.self, base + "/people/me?personFields=photos,emailAddresses") { add(me) }
        for (path, key) in [("/people/me/connections?personFields=emailAddresses,photos&pageSize=1000", "connections"),
                            ("/otherContacts?readMask=emailAddresses,photos&sources=READ_SOURCE_TYPE_CONTACT&sources=READ_SOURCE_TYPE_PROFILE&pageSize=1000", "other")] {
            var token: String?
            var pages = 0
            repeat {
                guard let page = await get(Page.self, base + path + (token.map { "&pageToken=\($0)" } ?? "")) else { break }
                for person in (key == "other" ? page.otherContacts : page.connections) ?? [] { add(person) }
                token = page.nextPageToken
                pages += 1
            } while token != nil && pages < 10
        }
        return map
    }
}
