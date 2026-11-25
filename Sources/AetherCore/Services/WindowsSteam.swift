import Foundation

/// The Windows Steam client, installed into its own Wine bottle ("steam").
///
/// - The user signs in inside Steam's own window: credentials go to Valve, never through Aether.
/// - Games installed there show up in the library (`LibraryScanner` reads the bottle's Steam library).
/// - Launching runs `steam.exe -applaunch <appid>`, so Steam's DRM check passes for games you own.
public enum WindowsSteam {
    public static let bottleName = "steam"

    /// Valve's official installer.
    public static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Steam's Chromium UI (CEF) misdraws under Wine with GPU acceleration; these keep it usable.
    public static let clientFlags = ["-no-cef-sandbox", "-cef-disable-gpu", "-cef-disable-gpu-compositing"]

    public static var bottle: URL { AetherPaths.bottle(for: bottleName) }

    public static var root: URL {
        bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
    }

    public static var executable: URL { root.appending(path: "steam.exe") }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: executable.path(percentEncoded: false))
    }

    public static func launchArguments(appID: String) -> [String] {
        clientFlags + ["-applaunch", appID]
    }

    /// Creates the bottle, downloads `SteamSetup.exe`, and runs it silently (`/S`).
    public static func install(base: WineRuntime, progress: RuntimeInstaller.Progress) async throws {
        let fm = FileManager.default
        if !WinePrefix.isInitialized(bottle) {
            progress(.installing)
            try await WinePrefix.initialize(bottle, runtime: base)
        }

        progress(.resolving)
        let downloads = AetherPaths.engineRoot.appending(path: "downloads", directoryHint: .isDirectory)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let setup = downloads.appending(path: "SteamSetup.exe")
        try await RuntimeInstaller.download(
            ReleaseAsset(tag: "", name: "SteamSetup.exe", url: installerURL, size: 0),
            to: setup,
            progress: progress
        )
        defer { try? fm.removeItem(at: setup) }

        progress(.installing)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
        environment["WINEPREFIX"] = bottle.path(percentEncoded: false)
        environment["WINEDEBUG"] = "-all"
        let status = await WinePrefix.run(base.wineBinary, [setup.path(percentEncoded: false), "/S"], environment: environment)
        _ = await WinePrefix.run(base.wineserver, ["-w"], environment: environment)
        guard isInstalled else {
            throw InstallerError.invalid("Steam's installer finished (exit \(status)) but steam.exe wasn't created. Try again from Engine Setup.")
        }
        progress(.done)
    }
}
