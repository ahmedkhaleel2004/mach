import ImageIO
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pictures decoded once and kept ready to draw. Decoding an image inside a row while the list is scrolling is
/// what makes a list stutter, so it happens here, off the main thread, a single time per sender.
final class AvatarImages: @unchecked Sendable {
    static let shared = AvatarImages()
    private let cache = NSCache<NSString, Box>()

    final class Box {
        let image: Image
        init(_ image: Image) { self.image = image }
    }

    init() {
        cache.countLimit = 600
        // Counted in bytes of decoded picture, so a mailbox full of pictured senders cannot grow without end.
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    #if os(macOS)
    /// The size a picture is drawn at in a Mac list row, in pixels: 26 points on a 2x screen.
    private static let drawnPixels = 52

    /// Decodes a picture straight to the size it is drawn at. A 192-pixel profile picture kept whole is 147 KB of
    /// bitmap per sender and is scaled down again on every draw; at this size it fits one 16 KB page of memory
    /// (one pixel more each way and it would need two) and is drawn as it is.
    private static func small(_ data: Data) -> (image: Image, bytes: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        // A site icon file can hold several sizes; take the largest, as before.
        var best = 0, bestWidth = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > bestWidth { (best, bestWidth) = (index, width) }
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: drawnPixels]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary) else { return nil }
        // Each decoded picture gets whole pages of memory to itself.
        return (Image(decorative: picture, scale: 1), (picture.bytesPerRow * picture.height + 16383) / 16384 * 16384)
    }
    #endif

    /// The system is short of memory: every picture can be decoded again from its file.
    func releaseMemory() { cache.removeAllObjects() }

    func ready(_ email: String) -> Image? {
        cache.object(forKey: email.lowercased() as NSString)?.image
    }

    func load(_ email: String) async -> Image? {
        if let ready = ready(email) { return ready }
        guard let data = await AvatarStore.shared.data(for: email) else { return nil }
        let decoded: (image: Image, bytes: Int)? = await Task.detached(priority: .utility) {
            #if os(macOS)
            return Self.small(data) ?? NSImage(data: data).map { (Image(nsImage: $0), Int($0.size.width * $0.size.height) * 4) }
            #else
            // A small, already-decoded copy: drawing it costs nothing.
            let side = 96 * 3
            return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: side, height: side)).map { (Image(uiImage: $0), Int($0.size.width * $0.scale * $0.size.height * $0.scale) * 4) }
            #endif
        }.value
        if let decoded { cache.setObject(Box(decoded.image), forKey: email.lowercased() as NSString, cost: decoded.bytes) }
        return decoded?.image
    }
}

/// A round picture for a sender: initials at once, the real picture as soon as it is known.
struct AvatarView: View, Equatable {
    let name: String
    let email: String
    var size: CGFloat = 32
    @State private var image: Image?
    @AppStorage(AvatarStore.settingKey) private var enabled = true

    /// Where it is used with `.equatable()`, the picture is left alone unless it is for someone else.
    nonisolated static func == (a: AvatarView, b: AvatarView) -> Bool {
        a.name == b.name && a.email == b.email && a.size == b.size
    }

    var body: some View {
        #if DEBUG || BENCH
        let _ = BodyCount.bump("AvatarView")
        #endif
        ZStack {
            Circle().fill(Color(light: AvatarStore.colorHex(for: email), dark: AvatarStore.colorHex(for: email)))
            Text(AvatarStore.initials(name.isEmpty ? email : name))
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
            if let image = image ?? (enabled ? AvatarImages.shared.ready(email) : nil) {
                image.resizable().interpolation(.high).scaledToFill().background(Color.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: email + String(enabled)) {
            guard enabled else {
                image = nil
                return
            }
            image = AvatarImages.shared.ready(email)
            if image == nil { image = await AvatarImages.shared.load(email) }
        }
    }
}
