import AetherCore
import Foundation

/// Small, non-secret user preferences. API keys go to `SecretStore` (Keychain), never here.
public enum AetherPreferences {
    private static let metalHUDKey = "AetherMetalHUDEnabled"
    private static let defaultCloudKey = "AetherDefaultCloudService"
    private static let gamePresetsKey = "AetherGamePresets"

    /// Apple's Metal Performance HUD for Wine/D3DMetal launches. On by default: you want to *see* 60 FPS.
    public static var metalHUDEnabled: Bool {
        get { UserDefaults.standard.object(forKey: metalHUDKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: metalHUDKey) }
    }

    /// Per-game performance preset chosen by the user (`nil` = use the recommendation).
    public static var gamePresets: [String: PerformancePreset] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: gamePresetsKey) as? [String: String] ?? [:]
            return raw.compactMapValues(PerformancePreset.init(rawValue:))
        }
        set { UserDefaults.standard.set(newValue.mapValues(\.rawValue), forKey: gamePresetsKey) }
    }

    /// Where cloud-routed games go when their profile names no specific service.
    public static var defaultCloudService: CloudService {
        get { UserDefaults.standard.string(forKey: defaultCloudKey).flatMap(CloudService.init(rawValue:)) ?? .xboxCloud }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultCloudKey) }
    }
}
