import BlitzCore
import Foundation

/// Instant delivery needs a small relay you run yourself (see `Relay/`): Gmail tells the relay the moment mail
/// arrives, the relay tells every running app over an open connection, and tells Apple so the phone is woken.
/// Without `PushRelay.json` the apps fall back to checking every few seconds.
struct PushRelay: Decodable {
    var url: String
    var secret: String
    var sandbox: Bool?

    static let current: PushRelay? = {
        if Bootstrap.offline { return nil }
        let candidates = [Bootstrap.directory.appendingPathComponent("PushRelay.json"), Bundle.main.url(forResource: "PushRelay", withExtension: "json")]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let relay = try? JSONDecoder().decode(PushRelay.self, from: data) { return relay }
        }
        return nil
    }()
}


/// An open connection to the relay. The relay sends one small message the moment an account has something new,
/// and the app syncs that account at once instead of waiting for its next check.
final class LiveLink: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let relay: PushRelay
    private let service: MailService
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var wanted = false
    private var attempt = 0
    private var generation = 0

    init(relay: PushRelay, service: MailService) {
        self.relay = relay
        self.service = service
    }

    /// Makes sure the relay is watching these accounts. A Mac passes no device token.
    func register(deviceToken: String? = nil, avatars: Bool = true) {
        guard let url = URL(string: relay.url + "/register") else { return }
        let accounts = service.relayAccounts()
        guard !accounts.isEmpty else { return }
        // With a single inbox every new mail gets a banner; with the split, only mail from people.
        let allMail = !UserDefaults.standard.bool(forKey: MailList.splitKey)
        var body: [String: Any] = ["sandbox": relay.sandbox ?? false, "avatars": avatars, "allMail": allMail, "accounts": accounts]
        if let deviceToken { body["deviceToken"] = deviceToken }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(relay.secret, forHTTPHeaderField: "X-Blitz-Secret")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task.detached {
            if let (data, response) = try? await URLSession.shared.data(for: request) {
                NSLog("relay register %d %@", (response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data.prefix(200), as: UTF8.self))
            }
        }
    }

    /// Has the relay forget an account that was signed out here: no more watching, no more pushes, token deleted.
    func unregister(_ email: String) {
        guard let url = URL(string: relay.url + "/unregister") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(relay.secret, forHTTPHeaderField: "X-Blitz-Secret")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email])
        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }

    func start() {
        lock.withLock { wanted = true }
        connect()
    }

    func stop() {
        lock.withLock {
            wanted = false
            generation += 1
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }
    }

    private func connect() {
        let emails = ((try? service.store.accounts()) ?? []).map(\.id)
        guard lock.withLock({ wanted }), !emails.isEmpty,
              var components = URLComponents(string: relay.url.replacingOccurrences(of: "https://", with: "wss://") + "/live") else { return }
        components.queryItems = [URLQueryItem(name: "emails", value: emails.joined(separator: ","))]
        var request = URLRequest(url: components.url!)
        request.setValue(relay.secret, forHTTPHeaderField: "X-Blitz-Secret")
        let socket = session.webSocketTask(with: request)
        let current: Int = lock.withLock {
            generation += 1
            task?.cancel(with: .goingAway, reason: nil)
            task = socket
            return generation
        }
        socket.resume()
        listen(socket, generation: current)
        keepAlive(socket, generation: current)
    }

    private func listen(_ socket: URLSessionWebSocketTask, generation current: Int) {
        socket.receive { [weak self] result in
            guard let self, self.lock.withLock({ self.generation == current }) else { return }
            switch result {
            case .success(let message):
                self.lock.withLock { self.attempt = 0 }
                if case .string(let text) = message, let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let email = object["email"] as? String {
                    let service = self.service
                    #if DEBUG
                    NSLog("live signal %@ relay-at %@", email, String(describing: object["at"] ?? ""))
                    #endif
                    Task { await service.sync(for: email).sync() }
                }
                self.listen(socket, generation: current)
            case .failure:
                self.retry(generation: current)
            }
        }
    }

    private func keepAlive(_ socket: URLSessionWebSocketTask, generation current: Int) {
        Task { [weak self] in
            while let self, self.lock.withLock({ self.generation == current && self.wanted }) {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                socket.send(.string("ping")) { _ in }
            }
        }
    }

    private func retry(generation current: Int) {
        let delay: Double = lock.withLock {
            guard generation == current, wanted else { return -1 }
            attempt += 1
            return min(30, pow(2, Double(attempt - 1)))
        }
        guard delay >= 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            // Anything missed while the line was down is picked up by an ordinary sync.
            await self?.service.syncAll()
            self?.connect()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let current = lock.withLock { task === webSocketTask ? generation : -1 }
        if current >= 0 { retry(generation: current) }
    }
}
