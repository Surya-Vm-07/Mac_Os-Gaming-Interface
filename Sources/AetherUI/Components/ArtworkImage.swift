import AppKit
import ImageIO
import SwiftUI

/// Decodes artwork **at display size** with ImageIO and keeps it in a bounded in-memory cache.
///
/// Memory discipline:
/// - A 600×900 cover is decoded as at most `maxPixelSize` px instead of at full resolution.
/// - `NSCache` is capped (128 MB / 300 images) and evicts under memory pressure.
/// - `purge()` drops everything. It runs when a game launches and when Aether loses focus.
@MainActor
public final class ImagePipeline {
    public static let shared = ImagePipeline()

    private let cache = NSCache<NSString, CGImage>()

    private init() {
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 300
    }

    public func image(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let key = "\(url.path(percentEncoded: false))#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let decoded = await Self.decode(url, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(decoded, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        return decoded
    }

    public func purge() {
        cache.removeAllObjects()
    }

    /// Runs off the main actor (nonisolated async). Returns a freshly created image, so `sending`
    /// lets it cross back to the main actor safely.
    nonisolated static func decode(_ url: URL, maxPixelSize: Int) async -> sending CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}

/// Fills its frame with cached artwork, crossfading in. Shows a titled gradient placeholder.
struct ArtworkImage: View {
    let url: URL?
    let maxPixelSize: Int
    var placeholderTitle: String? = nil

    @State private var image: CGImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                let loaded = await ImagePipeline.shared.image(for: url, maxPixelSize: maxPixelSize)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let placeholderTitle {
                Text(placeholderTitle)
                    .font(.system(size: 18, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(16)
            }
        }
    }
}
