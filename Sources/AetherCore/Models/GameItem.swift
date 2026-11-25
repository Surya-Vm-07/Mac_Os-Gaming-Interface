import Foundation

/// One playable entry in the library, produced by `LibraryScanner`.
public struct GameItem: Identifiable, Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        case steam(appID: String)
        /// Installed through the Windows Steam client in the "steam" bottle; launched via that client.
        case windowsSteam(appID: String)
        case macApplication
        case customFolder
    }

    /// Stable id: `steam:<appid>`, `app:<bundle id>`, or `custom:<path>`.
    public let id: String
    public var title: String
    public var source: Source
    public var installation: GameInstallation
    public var installDirectory: URL?
    /// Matching `GameProfile.id`, if a curated profile exists.
    public var profileID: String?
    /// Bottle this game must run in (set for games installed into a specific bottle).
    public var bottleOverride: String?

    public init(
        id: String,
        title: String,
        source: Source,
        installation: GameInstallation,
        installDirectory: URL? = nil,
        profileID: String? = nil,
        bottleOverride: String? = nil
    ) {
        self.bottleOverride = bottleOverride
        self.id = id
        self.title = title
        self.source = source
        self.installation = installation
        self.installDirectory = installDirectory
        self.profileID = profileID
    }

    public var steamAppID: String? {
        switch source {
        case .steam(let appID), .windowsSteam(let appID): return appID
        case .macApplication, .customFolder: return nil
        }
    }

    /// Characters safe for a bottle folder name.
    public var bottleName: String {
        if let bottleOverride { return bottleOverride }
        if let profileID { return profileID }
        return String(id.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Lowercased alphanumerics, used to match titles across sources ("DOOM Eternal" == "Doom: Eternal").
    public static func normalizedTitle(_ title: String) -> String {
        String(title.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

extension GameProfile {
    /// Routing profile for a game with no curated entry. It can run locally with default D3DMetal
    /// settings and has no cloud fallback, because streaming needs a configured target.
    public static func generic(for game: GameItem) -> GameProfile {
        GameProfile(
            id: game.id,
            title: game.title,
            steamAppID: game.steamAppID,
            hasKernelAnticheat: false,
            nativeMacosAvailable: game.installation.nativeApplication != nil,
            minLocalTier: HardwareTier.mid.rawValue,
            preferredEngine: .localTranslation,
            localTranslation: LocalTranslationConfig(),
            cloudFallback: nil
        )
    }
}
