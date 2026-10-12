import CryptoKit
import Foundation
import Security

/// One Outlook account's standing arrangement for push in the App Store build.
///
/// The public relay (Relay/public.js) is told a random id, a random secret and this phone's push address, and
/// nothing else: no sign-in, no email address, no mail. Outlook is asked, from the phone, to call the relay when
/// mail arrives. The relay's push carries only the new message's id; the notification extension reads this record
/// and asks Outlook for the sender and subject itself. So the record lives where both the app and the extension can
/// read it: the keychain group they share.
struct PushWatch: Codable {
    var id: String
    var secret: String
    var email: String
    var clientId: String
    var refreshToken: String
    var accessToken: String?
    var accessExpiry: Date?
    /// Outlook's name for its promise to call the relay, and when that promise runs out.
    var subscription: String?
    var subscriptionExpiry: Date?
    /// The push address the relay was last told, and when.
    var registeredToken: String?
    var registeredAt: Date?
    /// True when the inbox is split: mail Outlook files under "Other" then arrives quietly.
    var quietOther: Bool?
}

enum PushShare {
    static let relay = "https://mach-push.gitdiagram-presence.workers.dev"
    private static let service = "com.ahmedkhaleel.mach.push"
    private static let graph = "https://graph.microsoft.com/v1.0"

    /// The keychain group the app and its notification extension share, as the build spells it. Nil in a build
    /// that has none (every build but the App Store one).
    static var group: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "MachKeychainGroup") as? String
        return value.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    /// The name a banner for a message goes by. Apple allows 64 bytes and Outlook's ids are longer, so a long id
    /// is stood in for by a fingerprint: the same one the relays use, so one message is one banner.
    static func bannerId(_ messageId: String) -> String {
        guard messageId.utf8.count > 64 else { return messageId }
        let digest = Data(SHA256.hash(data: Data(messageId.utf8))).base64EncodedString()
        return String(digest.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "").prefix(40))
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: The records

    private static func query(_ id: String?) -> [String: Any]? {
        guard let group else { return nil }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccessGroup as String: group]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }

    static func all() -> [PushWatch] {
        guard var query = query(nil) else { return [] }
        // The names first, then each record by its name: the keychain does not hand out many secrets in one answer.
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let items = found as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.compactMap { find(id: $0) }
    }

    static func find(id: String) -> PushWatch? {
        guard var query = query(id) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return try? JSONDecoder().decode(PushWatch.self, from: data)
    }

    static func save(_ watch: PushWatch) {
        guard var query = query(watch.id), let data = try? JSONEncoder().encode(watch) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            query[kSecValueData as String] = data
            // A push can come while the phone is locked.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func delete(id: String) {
        guard let query = query(id) else { return }
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Talking to Outlook and to the relay

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    static func send(_ method: String, _ address: String, token: String? = nil, json: [String: Any]? = nil) async -> (status: Int, body: [String: Any]) {
        guard let url = URL(string: address) else { return (0, [:]) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Ids in the form that survives a move between folders: the form the app knows a message by.
            request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        }
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await session.data(for: request) else { return (0, [:]) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    static func outlook(_ method: String, _ path: String, token: String, json: [String: Any]? = nil) async -> (status: Int, body: [String: Any]) {
        await send(method, graph + path, token: token, json: json)
    }

    /// A token Outlook accepts right now, renewed with the account's sign-in when the one at hand has run out.
    /// The record is updated and saved when that happens.
    static func accessToken(for watch: inout PushWatch) async -> String? {
        if let token = watch.accessToken, let expiry = watch.accessExpiry, expiry.timeIntervalSinceNow > 120 { return token }
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let form = ["grant_type": "refresh_token", "client_id": watch.clientId, "refresh_token": watch.refreshToken]
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }.joined(separator: "&").utf8)
        guard let (data, _) = try? await session.data(for: request), let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = answer["access_token"] as? String else { return nil }
        watch.accessToken = token
        watch.accessExpiry = Date().addingTimeInterval((answer["expires_in"] as? Double) ?? 3000)
        if let renewed = answer["refresh_token"] as? String { watch.refreshToken = renewed }
        save(watch)
        return token
    }
}
