import MachCore
import Foundation

/// Finds the Google sign-in key and opens the local database.
enum Bootstrap {
    /// `MACH_DATA_DIR` points the app at another folder, so a test build never touches real mail.
    static let directory: URL = {
        if let custom = ProcessInfo.processInfo.environment["MACH_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #if BENCH
        // A benchmark build without its own folder would open the real mailbox. It refuses to start instead.
        FileHandle.standardError.write(Data("BENCH build: set MACH_DATA_DIR\n".utf8))
        exit(2)
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mach", isDirectory: true)
        #endif
    }()

    /// `MACH_OFFLINE=1`: no sync, no relay, no picture lookups, no permission prompts. For benchmarks.
    static let offline = ProcessInfo.processInfo.environment["MACH_OFFLINE"] == "1"

    /// The key ships inside the app when `App/Resources/OAuthClient.json` exists at build time.
    /// A copy in the app's data folder wins, so a downloaded build can be pointed at your own Google project.
    /// The Mac wants a Desktop key and the iPhone an iOS one; `OAuthClient.load` lists the shapes the file may have.
    static func client() -> OAuthClient? {
        let candidates = [directory.appendingPathComponent("OAuthClient.json"), Bundle.main.url(forResource: "OAuthClient", withExtension: "json")]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let client = OAuthClient.load(from: data) { return client }
        }
        return nil
    }

    /// The Microsoft app Outlook accounts sign in through. Its id is not a secret (a Microsoft key for an app
    /// like this has none), so unlike Google's it can ship in the source. `MicrosoftClient.json` in the data folder
    /// or the app (`{"client_id": "…"}`) points a build at another one.
    static let microsoftClientId = "50ef94ae-f0ab-4e14-8648-fb64d2126ef2"

    static func microsoftClient() -> OAuthClient? {
        let candidates = [directory.appendingPathComponent("MicrosoftClient.json"), Bundle.main.url(forResource: "MicrosoftClient", withExtension: "json")]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = (object["client_id"] ?? object["clientId"]) as? String, !id.isEmpty {
                return OAuthClient(clientId: id, clientSecret: nil)
            }
        }
        return microsoftClientId.isEmpty ? nil : OAuthClient(clientId: microsoftClientId, clientSecret: nil)
    }

    /// Starts opening the database on another thread. The phone calls this before UIKit starts up, so the two
    /// overlap; `service()` then hands over the finished database, or waits for it. Nothing is ever shown without it.
    static func prewarm() {
        // The main thread may end up waiting for this, so it must not run at a lower priority than the main thread.
        DispatchQueue.global(qos: .userInteractive).async {
            guard let store = opened?.0.store else { return }
            // The first read on a connection also loads the tables' layout. Done here, the launch's own reads find it ready.
            _ = try? store.accounts()
        }
    }

    /// Made once. Swift lets only one thread build it; a second one that asks meanwhile waits for the first.
    private static let opened: (MailService, hasClient: Bool)? = open()

    static func service() -> (MailService, hasClient: Bool)? { opened }

    private static func open() -> (MailService, hasClient: Bool)? {
        let found = client()
        // A custom data folder keeps its sign-ins beside it, so a test build never reads or deletes the real ones.
        let custom = ProcessInfo.processInfo.environment["MACH_DATA_DIR"]?.isEmpty == false
        let tokens: TokenStore = custom ? FileTokenStore(directory: directory) : KeychainTokenStore()
        let service = try? MailService(directory: directory, client: found ?? OAuthClient(clientId: "", clientSecret: nil),
                                       microsoftClient: microsoftClient(), tokens: tokens, offline: offline)
        #if os(iOS)
        // An iPhone signs in with an iOS key only. A Desktop key still keeps sign-ins made with it alive.
        return service.map { ($0, found?.worksOnPhone == true) }
        #else
        return service.map { ($0, found != nil) }
        #endif
    }

    private struct Seed: Decodable {
        var refreshToken: String
        var clientId: String?
        var clientSecret: String?
        /// "microsoft" for an Outlook account; left out for Gmail.
        var provider: String?
    }

    /// A `seed.json` in the data folder is turned into signed-in accounts once and then deleted.
    /// It is a list of `{refreshToken, clientId?, clientSecret?, provider?}`; the key is only needed when the token
    /// was issued under a different Google project (or Microsoft app) than the app's own.
    static func importSeed(into service: MailService) async {
        guard !offline else { return }
        let url = directory.appendingPathComponent("seed.json")
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        let seeds = (try? JSONDecoder().decode([Seed].self, from: data))
            ?? ((try? JSONDecoder().decode([String].self, from: data)) ?? []).map { Seed(refreshToken: $0) }
        for seed in seeds {
            let client = seed.clientId.map { OAuthClient(clientId: $0, clientSecret: seed.clientSecret) }
            _ = try? await service.addAccount(tokens: TokenSet(refreshToken: seed.refreshToken, client: client, provider: seed.provider.flatMap(MailProvider.init(rawValue:))))
        }
        AvatarStore.shared.forgetMisses()
    }
}
