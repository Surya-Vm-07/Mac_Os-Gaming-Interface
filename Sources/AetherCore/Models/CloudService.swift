import Foundation

/// Third-party cloud gaming services Aether can open. The user brings their own subscription;
/// Aether is the front end. Service names appear only to identify the service (nominative use).
public enum CloudService: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case xboxCloud
    case geforceNow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xboxCloud: "Xbox Cloud Gaming"
        case .geforceNow: "GeForce NOW"
        }
    }

    /// Web client that runs in Aether's embedded stream view.
    public var webURL: URL {
        switch self {
        case .xboxCloud: URL(string: "https://www.xbox.com/play")!
        case .geforceNow: URL(string: "https://play.geforcenow.com")!
        }
    }

    public var tagline: String {
        switch self {
        case .xboxCloud: "Hundreds of games, no purchase needed. Streams up to 1080p · 60 FPS."
        case .geforceNow: "Free-to-play hits on the free tier. Paid tiers stream at 60+ FPS."
        }
    }

    public var requirement: String {
        switch self {
        case .xboxCloud: "Needs an Xbox Game Pass Ultimate subscription."
        case .geforceNow: "Free account works for free-to-play games. Paid games must be in your Steam, Epic or Ubisoft library."
        }
    }

    /// The vendor's native macOS client, if installed. It usually streams more efficiently
    /// than the web client.
    public var nativeAppURL: URL? {
        switch self {
        case .xboxCloud:
            return nil
        case .geforceNow:
            let app = URL(filePath: "/Applications/GeForceNOW.app", directoryHint: .isDirectory)
            return FileManager.default.fileExists(atPath: app.path(percentEncoded: false)) ? app : nil
        }
    }
}
