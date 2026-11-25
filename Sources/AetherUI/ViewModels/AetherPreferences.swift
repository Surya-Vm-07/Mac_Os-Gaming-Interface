import Foundation

/// Small, non-secret user preferences. API keys go to `SecretStore` (Keychain), never here.
public enum AetherPreferences {
    private static let metalHUDKey = "AetherMetalHUDEnabled"

    /// Apple's Metal Performance HUD for Wine/D3DMetal launches. Default on: you want to *see* 60 FPS.
    public static var metalHUDEnabled: Bool {
        get { UserDefaults.standard.object(forKey: metalHUDKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: metalHUDKey) }
    }
}
