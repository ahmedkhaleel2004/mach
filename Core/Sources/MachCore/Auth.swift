import CryptoKit
import Foundation
#if os(macOS)
import Network
#endif
import Security

public struct OAuthClient: Codable, Sendable {
    public var clientId: String
    public var clientSecret: String?

    public init(clientId: String, clientSecret: String?) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    /// The two kinds of key Google hands out for an app like this one. A Mac uses a "Desktop app" key, which comes
    /// with a secret and answers on a port of this machine. An iPhone uses an "iOS" key, which has no secret and
    /// answers through an address only this app opens.
    public enum Kind: Sendable {
        case desktop, phone

        public static var current: Kind {
            #if os(iOS)
            return .phone
            #else
            return .desktop
            #endif
        }
    }

    /// Reads any of the shapes a key file comes in:
    /// - the JSON Google lets you download for a Desktop client: `{"installed": {"client_id": …, "client_secret": …}}`
    /// - an iOS client, which is only an id: `{"client_id": "….apps.googleusercontent.com"}`
    ///   (the `.plist` Google offers for an iOS client reads too, by its `CLIENT_ID`)
    /// - both in one file, for a checkout that builds the Mac and the iPhone app: the Desktop JSON with
    ///   `"ios": {"client_id": …}` added beside `"installed"`
    /// - our own `{"clientId": …, "clientSecret": …}`
    /// When a file holds more than one, each platform takes its own kind.
    public static func load(from data: Data, for kind: Kind = .current) -> OAuthClient? {
        if let direct = try? JSONDecoder().decode(OAuthClient.self, from: data) { return direct }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object = json ?? (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        func client(_ entry: Any?, secret: Bool) -> OAuthClient? {
            guard let entry = entry as? [String: Any], let id = (entry["client_id"] ?? entry["CLIENT_ID"]) as? String, !id.isEmpty else { return nil }
            return OAuthClient(clientId: id, clientSecret: secret ? entry["client_secret"] as? String : nil)
        }
        let desktop = client(object["installed"], secret: true) ?? client(object["web"], secret: true)
        let phone = client(object["ios"], secret: false) ?? client(object, secret: false)
        return kind == .phone ? phone ?? desktop : desktop ?? phone
    }

    /// The address scheme Google sends an iOS client's sign-in back to: the client id written backwards,
    /// `com.googleusercontent.apps.<id>`. Nil when the id is not one of Google's.
    public var redirectScheme: String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientId.hasSuffix(suffix), clientId.count > suffix.count else { return nil }
        return "com.googleusercontent.apps." + clientId.dropLast(suffix.count)
    }

    /// True for a key an iPhone can sign in with: no secret, and an address to come back to.
    public var worksOnPhone: Bool { clientSecret == nil && redirectScheme != nil }
}

public struct TokenSet: Codable, Sendable {
    public var refreshToken: String
    public var accessToken: String
    public var expiry: Date
    /// The Google sign-in key these tokens were issued under, when it is not the app's own.
    /// Tokens only refresh with the key that issued them, and an account in a company's Google Workspace
    /// may be limited to that company's key.
    public var client: OAuthClient?

    public init(refreshToken: String, accessToken: String = "", expiry: Date = .distantPast, client: OAuthClient? = nil) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiry = expiry
        self.client = client
    }
}

public protocol TokenStore: Sendable {
    func load(account: String) -> TokenSet?
    func save(_ tokens: TokenSet, account: String)
    func delete(account: String)
}

/// Tokens in the system keychain. What the apps use.
public struct KeychainTokenStore: TokenStore {
    private let service: String

    public init(service: String = "com.ahmedkhaleel.mach.tokens") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load(account: String) -> TokenSet? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet, account: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    public func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Tokens in a folder of JSON files. Used by the command-line tool and tests.
public struct FileTokenStore: TokenStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ account: String) -> URL { directory.appendingPathComponent("\(account).token.json") }

    public func load(account: String) -> TokenSet? {
        (try? Data(contentsOf: url(account))).flatMap { try? JSONDecoder().decode(TokenSet.self, from: $0) }
    }

    public func save(_ tokens: TokenSet, account: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: url(account), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(account).path)
    }

    public func delete(account: String) {
        try? FileManager.default.removeItem(at: url(account))
    }
}

public enum AuthError: Error, LocalizedError {
    case signedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: return "Google sign-in has expired. Sign in again."
        case .failed(let message): return message
        }
    }
}

private struct TokenResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let expires_in: Double?
    let error: String?
    let error_description: String?
}

/// Hands out a valid access token for one account, refreshing it when needed.
public actor Authenticator {
    private let account: String
    private let client: OAuthClient
    private let store: TokenStore
    private var tokens: TokenSet?
    private var refreshing: Task<String, Error>?

    public init(account: String, client: OAuthClient, store: TokenStore) {
        self.account = account
        self.client = client
        self.store = store
        tokens = store.load(account: account)
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if let refreshing { return try await refreshing.value }
        guard let current = tokens else { throw AuthError.signedOut }
        if !forceRefresh, !current.accessToken.isEmpty, current.expiry.timeIntervalSinceNow > 90 {
            return current.accessToken
        }
        let task = Task { try await self.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh(_ current: TokenSet) async throws -> String {
        let response = try await OAuth.postToken(OAuth.refreshForm(client: current.client ?? self.client, refreshToken: current.refreshToken))
        guard let access = response.access_token else {
            if response.error == "invalid_grant" { throw AuthError.signedOut }
            throw AuthError.failed(response.error_description ?? response.error ?? "Could not refresh the Google sign-in.")
        }
        let updated = TokenSet(refreshToken: response.refresh_token ?? current.refreshToken, accessToken: access,
                               expiry: Date().addingTimeInterval(response.expires_in ?? 3000), client: current.client)
        tokens = updated
        store.save(updated, account: account)
        return access
    }
}

public enum OAuth {
    /// Mail, plus read-only contacts and profile: the last three exist only to show people's pictures.
    public static let scope = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/contacts.readonly",
        "https://www.googleapis.com/auth/contacts.other.readonly",
        "https://www.googleapis.com/auth/userinfo.profile",
    ].joined(separator: " ")

    fileprivate static func postToken(_ form: [String: String]) async throws -> TokenResponse {
        let (data, _) = try await URLSession.shared.data(for: formRequest("https://oauth2.googleapis.com/token", form))
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func formRequest(_ address: String, _ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        return request
    }

    // What is sent to Google's token address. A key with no secret (an iOS client) sends none: the code verifier
    // is what proves the request comes from the app that started the sign-in.

    static func refreshForm(client: OAuthClient, refreshToken: String) -> [String: String] {
        var form = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.clientId]
        if let secret = client.clientSecret { form["client_secret"] = secret }
        return form
    }

    static func codeForm(client: OAuthClient, code: String, redirect: String, verifier: String) -> [String: String] {
        var form = ["grant_type": "authorization_code", "code": code, "client_id": client.clientId,
                    "redirect_uri": redirect, "code_verifier": verifier]
        if let secret = client.clientSecret { form["client_secret"] = secret }
        return form
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString()
    }

    static func authorizationURL(client: OAuthClient, redirect: String, challenge: String, state: String,
                                 loginHint: String?, scope: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        if let loginHint { components.queryItems?.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        return components.url!
    }

    /// Where an iOS client's sign-in comes back to, or nil if the key is not an iOS one.
    public static func phoneRedirect(for client: OAuthClient) -> String? {
        client.redirectScheme.map { $0 + ":/oauth2redirect" }
    }

    /// What Google put on the address it sent the sign-in back to.
    static func callbackParameters(_ url: URL) -> [String: String] {
        var parameters: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
        return parameters
    }

    /// The sign-in code out of Google's reply, once the reply is known to answer this attempt.
    static func code(from callback: [String: String], state: String) throws -> String {
        guard callback["state"] == state else { throw AuthError.failed("The sign-in reply did not match the request.") }
        guard let code = callback["code"] else {
            throw AuthError.failed(callback["error"] == "access_denied" ? "Sign-in was cancelled." : "Google did not return a sign-in code.")
        }
        return code
    }

    private static func exchange(_ form: [String: String]) async throws -> TokenSet {
        let response = try await postToken(form)
        guard let access = response.access_token, let refresh = response.refresh_token else {
            throw AuthError.failed(response.error_description ?? response.error ?? "Google did not return tokens.")
        }
        return TokenSet(refreshToken: refresh, accessToken: access, expiry: Date().addingTimeInterval(response.expires_in ?? 3000))
    }

    /// Runs Google's sign-in for an iOS client and returns the tokens.
    ///
    /// `present` shows Google's page in the system sign-in sheet and returns the address the sheet came back with:
    /// it is given the page and the address scheme to wait for. Nothing listens on the network, and no secret is sent.
    public static func signIn(client: OAuthClient, loginHint: String? = nil, scope: String = OAuth.scope,
                              present: @escaping @Sendable (URL, String) async throws -> URL) async throws -> TokenSet {
        guard client.clientSecret == nil, let scheme = client.redirectScheme, let redirect = phoneRedirect(for: client) else {
            throw AuthError.failed("This build's Google sign-in key is not an iOS one.")
        }
        let verifier = randomString(64)
        let state = randomString(24)
        let page = authorizationURL(client: client, redirect: redirect, challenge: challenge(for: verifier), state: state,
                                    loginHint: loginHint, scope: scope)
        let callback = callbackParameters(try await present(page, scheme))
        return try await exchange(codeForm(client: client, code: try code(from: callback, state: state), redirect: redirect, verifier: verifier))
    }

    /// Tells Google to forget a sign-in, so the token is worth nothing once the account is signed out here.
    /// Best effort: with no connection the token simply stays valid until it is removed at myaccount.google.com.
    public static func revoke(_ token: String) async {
        _ = try? await URLSession.shared.data(for: revokeRequest(token))
    }

    static func revokeRequest(_ token: String) -> URLRequest {
        formRequest("https://oauth2.googleapis.com/revoke", ["token": token])
    }

    #if os(macOS)
    /// Runs Google's sign-in in a browser and returns the tokens. For a Desktop client, on a Mac.
    ///
    /// Google sends the browser back to a one-shot listener on this device, so no server is involved.
    /// `open` must show the URL to the person (the default browser).
    public static func signIn(client: OAuthClient, loginHint: String? = nil, scope: String = OAuth.scope,
                              open: @escaping @Sendable (URL) -> Void) async throws -> TokenSet {
        let verifier = randomString(64)
        let state = randomString(24)
        let listener = try LoopbackListener(state: state)
        let port = try await listener.start()
        let redirect = "http://127.0.0.1:\(port)"
        open(authorizationURL(client: client, redirect: redirect, challenge: challenge(for: verifier), state: state,
                              loginHint: loginHint, scope: scope))

        // Nobody waits forever: an abandoned browser tab ends the attempt after five minutes.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            if !Task.isCancelled { listener.fail(AuthError.failed("Sign-in timed out. Try again.")) }
        }
        defer { timeout.cancel() }
        let callback = try await withTaskCancellationHandler {
            try await listener.waitForCallback()
        } onCancel: {
            listener.cancel()
        }
        return try await exchange(codeForm(client: client, code: try code(from: callback, state: state), redirect: redirect, verifier: verifier))
    }
    #endif

    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

#if os(macOS)
/// Accepts the single browser redirect that ends a sign-in.
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mach.oauth.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var started = false
    private let state: String

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                // Always called on `queue`, so `started` is safe to touch here.
                guard let self, !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    cont.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self.started = true
                    cont.resume(throwing: error)
                case .cancelled:
                    self.started = true
                    cont.resume(throwing: AuthError.failed("Could not start sign-in on this device."))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let requestLine = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let pieces = requestLine.split(separator: " ")
            var parameters: [String: String] = [:]
            if pieces.count >= 2, let components = URLComponents(string: "http://127.0.0.1" + pieces[1]) {
                for item in components.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
            }
            // Browsers also ask for /favicon.ico, and anything on this machine can knock on the port:
            // only Google's redirect knows the state value this sign-in started with.
            let isCallback = parameters["state"] == self.state && (parameters["code"] != nil || parameters["error"] != nil)
            let page = "<!doctype html><meta charset=utf-8><title>Mach</title><body style=\"font:16px -apple-system,sans-serif;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0\"><div>\(isCallback ? "Signed in. You can close this tab." : "")</div>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback { self.finish(.success(parameters)) }
        }
    }

    private func finish(_ value: Result<[String: String], Error>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = value
            self.listener.cancel()
            self.continuation?.resume(with: value)
            self.continuation = nil
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.result {
                    cont.resume(with: result)
                } else {
                    self.continuation = cont
                }
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }
}
#endif
