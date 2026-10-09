import CryptoKit
import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Finds a picture for an email address and remembers it.
///
/// The same rules as Gmail: a person's picture comes from their Google profile (through your contacts); failing
/// that, a company's verified brand logo; failing that, a coloured initial. Looking up a logo tells Google's
/// name service which company wrote to you, which is why this can be turned off.
final class AvatarStore: @unchecked Sendable {
    static let shared = AvatarStore()
    static let settingKey = "showAvatars"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    /// Set by the app: asks Google for a person's profile picture. The notification extension has no such access.
    nonisolated(unsafe) static var googleLookup: (@Sendable (String) async -> URL?)?

    private let lock = NSLock()
    private var memory: [String: Data?] = [:]
    /// Bytes of picture files held in `memory`.
    private var held = 0
    #if os(iOS)
    /// On a phone the files are only kept for a while: each is also on disk, and the list keeps its own decoded
    /// copies. Without a limit this grew by one file for every sender ever scrolled past.
    private static let limit = 2 * 1024 * 1024
    #else
    private static let limit = Int.max
    #endif

    /// Remembers what was found for an address. Call with the lock held.
    private func remember(_ key: String, _ data: Data?) {
        held += (data?.count ?? 0) - ((memory[key] ?? nil)?.count ?? 0)
        memory[key] = .some(data)
        if held > Self.limit { dropPictures(keeping: key) }
    }

    /// Lets go of every picture file held in memory. "No picture" answers are kept: they are tiny and save a lookup.
    private func dropPictures(keeping key: String? = nil) {
        let kept = key.flatMap { memory[$0] ?? nil }
        memory = memory.filter { $0.value == nil }
        held = 0
        if let key, let kept {
            memory[key] = .some(kept)
            held = kept.count
        }
    }

    /// The system is short of memory: the files can all be read from disk again.
    func releaseMemory() {
        lock.withLock { dropPictures() }
    }
    private var running: [String: Task<Data?, Never>] = [:]
    private let folder: URL = {
        var url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("avatars4", isDirectory: true)
        #if DEBUG || BENCH
        // A benchmark brings its own made-up pictures, and so never reads or writes the real ones.
        if let custom = ProcessInfo.processInfo.environment["MACH_AVATAR_DIR"], !custom.isEmpty { url = URL(fileURLWithPath: custom, isDirectory: true) }
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com", "icloud.com",
        "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "gmx.com", "gmx.net", "hey.com", "fastmail.com", "zoho.com",
    ]

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The part of a domain a company owns: `mail.news.shop.co.uk` gives `shop.co.uk`.
    static func siteDomain(of email: String) -> String? {
        guard let domain = email.split(separator: "@").last.map(String.init)?.lowercased(), domain.contains(".") else { return nil }
        if freeMail.contains(domain) { return nil }
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return domain }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let keep = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Forgets every "no picture" answer. Called when an account is added, because its contacts may hold faces
    /// that could not be seen before.
    func forgetMisses() {
        lock.withLock { memory = memory.filter { $0.value != nil } }
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "none" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// What is already known without touching the network. Outer nil: not looked up yet. Inner nil: there is no picture.
    func known(_ email: String) -> Data?? {
        let key = email.lowercased()
        return lock.withLock { memory[key] }
    }

    /// Downloads a picture from a known address (the push relay sends the sender's Google picture this way)
    /// and remembers it for that email.
    func data(for email: String, at address: URL) async -> Data? {
        let key = email.lowercased()
        guard let (data, response) = try? await session.data(from: address), (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 200, Self.isUsable(data) else { return nil }
        lock.withLock { remember(key, data) }
        try? data.write(to: folder.appendingPathComponent(String(Self.hash(key).prefix(32))), options: .atomic)
        return data
    }

    func data(for email: String) async -> Data? {
        let key = email.lowercased()
        guard key.contains("@") else { return nil }
        let task: Task<Data?, Never> = lock.withLock {
            if let existing = running[key] { return existing }
            if let cached = memory[key] { return Task { cached } }
            let created = Task { [self] in
                let result = await load(key)
                lock.withLock {
                    remember(key, result)
                    running[key] = nil
                }
                return result
            }
            running[key] = created
            return created
        }
        return await task.value
    }

    /// A person's picture at a size that stays sharp when shown large. Only Google pictures come any bigger.
    func sharp(for email: String, side: Int = 640) async -> Data? {
        let key = email.lowercased()
        if let google = await Self.googleLookup?(key) {
            let address = google.absoluteString.replacingOccurrences(of: "=s192", with: "=s\(side)")
            if address.contains("=s\(side)"), let data = await fetch(address), Self.isUsable(data) { return data }
        }
        return nil
    }

    /// Stops a download from being sent on to another address.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Downloads a small file, giving up as soon as it turns out bigger than `limit` rather than after.
    /// `strict` is for addresses that came from a stranger: https only, and never redirected anywhere else.
    private func fetch(_ address: String, limit: Int = 3_000_000, strict: Bool = false) async -> Data? {
        guard let url = URL(string: address), url.scheme == "https" else { return nil }
        guard let (bytes, response) = try? await session.bytes(from: url, delegate: strict ? NoRedirect() : nil),
              let http = response as? HTTPURLResponse, http.statusCode == 200, http.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        return data.count > 200 ? data : nil
    }

    /// The same order Gmail uses: the person's own Google picture, else their company's verified brand logo,
    /// else nothing, and the coloured initial shows.
    private func load(_ email: String) async -> Data? {
        let name = String(Self.hash(email).prefix(32))
        let file = folder.appendingPathComponent(name)
        // Marks a picture that is a brand logo, not the person's own. A person's picture replaces it once known.
        let brand = folder.appendingPathComponent(name + ".brand")
        let missing = folder.appendingPathComponent(name + ".none")
        let isBrand = FileManager.default.fileExists(atPath: brand.path)
        if !isBrand, let data = try? Data(contentsOf: file) { return data }
        if let google = await Self.googleLookup?(email), let data = await fetch(google.absoluteString), Self.isUsable(data) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.removeItem(at: brand)
            return data
        }
        if isBrand, let data = try? Data(contentsOf: file) { return data }
        if let stamp = (try? missing.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(stamp) < 86400 {
            return nil
        }
        // Benchmarks never look anything up (the extension shares this file, so it reads the setting itself).
        if ProcessInfo.processInfo.environment["MACH_OFFLINE"] == "1" { return nil }
        if let data = await brandLogo(for: email) {
            try? data.write(to: file, options: .atomic)
            try? Data().write(to: brand, options: .atomic)
            return data
        }
        try? Data().write(to: missing, options: .atomic)
        return nil
    }

    /// Set by the app: turns a logo drawn as vector shapes into an ordinary picture.
    nonisolated(unsafe) static var drawLogo: (@Sendable (Data) async -> Data?)?

    /// An ordinary https address on the public internet: never a bare number, a local name or this device.
    private static func isPublicWebAddress(_ address: String) -> Bool {
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.contains("."), host.contains(where: \.isLetter), !host.contains(":") else { return false }
        return ![".local", ".internal", ".lan", ".home", ".localhost"].contains { host.hasSuffix($0) }
    }

    private struct DNSAnswer: Decodable {
        struct Record: Decodable { let data: String? }
        let Answer: [Record]?
    }

    /// A company's logo as it publishes it for mail apps (the BIMI record on its domain). Like Gmail, only a logo
    /// whose certificate was issued for that domain by a trademark-checking authority counts, so nobody can put
    /// another company's logo on their own mail.
    private func brandLogo(for email: String) async -> Data? {
        guard let draw = Self.drawLogo, let full = email.split(separator: "@").last.map({ String($0).lowercased() }),
              let site = Self.siteDomain(of: email) else { return nil }
        for domain in full == site ? [site] : [full, site] {
            let saved = folder.appendingPathComponent("brand-" + domain)
            if let data = try? Data(contentsOf: saved) {
                if !data.isEmpty { return data }
                if let stamp = (try? saved.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   Date().timeIntervalSince(stamp) < 7 * 86400 { continue }
            }
            var found: Data?
            if let reply = await fetch("https://dns.google/resolve?type=TXT&name=default._bimi." + domain),
               let answer = try? JSONDecoder().decode(DNSAnswer.self, from: reply) {
                for record in (answer.Answer ?? []).compactMap(\.data) {
                    var fields: [String: String] = [:]
                    for part in record.replacingOccurrences(of: "\"", with: "").split(separator: ";") {
                        let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        if pair.count == 2 { fields[pair[0].lowercased()] = pair[1] }
                    }
                    // The record only says where the certificate is. Nothing in it is believed until the
                    // certificate checks out, and the logo shown is the one inside the certificate.
                    guard fields["v"]?.uppercased() == "BIMI1", let proof = fields["a"], Self.isPublicWebAddress(proof),
                          let pem = await fetch(proof, limit: 400_000, strict: true),
                          let svg = BrandMark.logo(pem: pem, domain: domain), let picture = await draw(svg) else { continue }
                    found = picture
                    break
                }
            }
            try? (found ?? Data()).write(to: saved, options: .atomic)
            if let found { return found }
        }
        return nil
    }

    /// Rejects the tiny generic icons some sites answer with.
    private static func isUsable(_ data: Data) -> Bool {
        #if os(macOS)
        guard let image = NSBitmapImageRep(data: data) else { return false }
        return image.pixelsWide >= 32
        #else
        guard let image = UIImage(data: data) else { return false }
        return image.size.width * image.scale >= 32
        #endif
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    private static let palette: [UInt32] = [0x5B5BD6, 0x0E9F6E, 0xD9730D, 0xC2410C, 0x0891B2, 0xBE185D, 0x7C3AED, 0x2563EB, 0x65A30D, 0xB45309]

    static func colorHex(for email: String) -> UInt32 {
        let sum = email.lowercased().utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

