import Foundation

/// A new-mail banner that is on the screen or in the notification list.
public struct Banner: Sendable, Hashable {
    public let id: String
    public let account: String
    public let thread: String
    public let delivered: Date

    public init(id: String, account: String, thread: String, delivered: Date) {
        self.id = id
        self.account = account
        self.thread = thread
        self.delivered = delivered
    }
}

/// Decides which banners have nothing left to say: their mail has been read, archived or deleted, here or on
/// another device.
///
/// A banner can arrive before its mail has been stored (a push gets there first), so "not waiting in the inbox"
/// is not enough to take one down. It goes when the conversation has left the inbox's unread mail and either
///   - it was seen waiting there while the banner was up, so it left under our eyes, or
///   - the account has been checked against Gmail since the banner arrived, so what is stored is the truth.
public struct BannerLedger: Sendable {
    private var seenWaiting: Set<String> = []

    public init() {}

    /// The ids of the banners to take down. `synced` is when the account's last finished check of Gmail began.
    public mutating func stale(_ banners: [Banner], waiting: Set<String>, synced: (String) -> Date?) -> [String] {
        var stale: [String] = []
        for banner in banners {
            if waiting.contains(banner.account + "/" + banner.thread) {
                seenWaiting.insert(banner.id)
            } else if seenWaiting.contains(banner.id) || synced(banner.account).map({ $0 > banner.delivered }) == true {
                stale.append(banner.id)
            }
        }
        // Banners that are gone need no remembering.
        seenWaiting.formIntersection(banners.map(\.id))
        seenWaiting.subtract(stale)
        return stale
    }
}
