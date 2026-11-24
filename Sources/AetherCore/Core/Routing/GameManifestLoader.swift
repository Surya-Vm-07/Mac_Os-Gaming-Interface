import Foundation

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case bundledManifestMissing
    case unsupportedSchemaVersion(String)
    case invalidManifest(String)

    public var description: String {
        switch self {
        case .bundledManifestMissing:
            "Bundled game_profiles.json is missing from the AetherCore resource bundle."
        case .unsupportedSchemaVersion(let v):
            "Unsupported manifest schema_version '\(v)' (supported: \(GameManifestLoader.supportedMajorVersion).x)."
        case .invalidManifest(let detail):
            "Invalid manifest: \(detail)"
        }
    }
}

/// A non-fatal problem in a user or community manifest. A bad community file never takes down
/// the whole library.
public struct ManifestIssue: Sendable, Equatable, CustomStringConvertible {
    public let file: URL
    public let message: String

    public var description: String { "\(file.lastPathComponent): \(message)" }
}

/// Profiles merged from every source, keyed by profile id.
public struct ProfileCatalog: Sendable {
    public private(set) var profilesByID: [String: GameProfile]
    public let issues: [ManifestIssue]

    init(profilesByID: [String: GameProfile], issues: [ManifestIssue]) {
        self.profilesByID = profilesByID
        self.issues = issues
    }

    public func profile(id: String) -> GameProfile? { profilesByID[id] }

    public func profile(steamAppID: String) -> GameProfile? {
        profilesByID.values.first { $0.steamAppID == steamAppID }
    }

    /// All profiles sorted by title, for stable UI and CLI output.
    public var allProfiles: [GameProfile] {
        profilesByID.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// Loads the bundled `Profiles/game_profiles.json`, then overlays every `*.json` in the user
/// profile directories. Later sources win by `id`, so users can patch flags without
/// touching the app bundle.
public struct GameManifestLoader: Sendable {
    public static let supportedMajorVersion = 1

    public var userProfileDirectories: [URL]
    public var includeBundledProfiles: Bool

    public init(
        userProfileDirectories: [URL] = [AetherPaths.userProfiles],
        includeBundledProfiles: Bool = true
    ) {
        self.userProfileDirectories = userProfileDirectories
        self.includeBundledProfiles = includeBundledProfiles
    }

    public static var bundledManifestURL: URL? {
        Bundle.module.url(forResource: "game_profiles", withExtension: "json", subdirectory: "Profiles")
    }

    /// Decodes one manifest and checks its schema version. Throws `ManifestError`.
    public static func decode(_ data: Data) throws -> GameManifest {
        let manifest: GameManifest
        do {
            manifest = try JSONDecoder().decode(GameManifest.self, from: data)
        } catch let error as DecodingError {
            throw ManifestError.invalidManifest(describe(error))
        }

        let major = manifest.schemaVersion.split(separator: ".").first.flatMap { Int($0) }
        guard major == supportedMajorVersion else {
            throw ManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        return manifest
    }

    /// Builds the merged catalog.
    /// - Throws: only if the *bundled* manifest is missing or broken (a packaging bug).
    ///   User-file problems go in `ProfileCatalog.issues`.
    public func load(fileManager: FileManager = .default) throws -> ProfileCatalog {
        var profiles: [String: GameProfile] = [:]
        var issues: [ManifestIssue] = []

        if includeBundledProfiles {
            guard let url = Self.bundledManifestURL else { throw ManifestError.bundledManifestMissing }
            let manifest = try Self.decode(try Data(contentsOf: url))
            merge(manifest, from: url, into: &profiles, issues: &issues)
        }

        for directory in userProfileDirectories {
            // A missing directory is normal on first launch.
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            let manifests = entries
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } // deterministic override order

            for url in manifests {
                do {
                    let manifest = try Self.decode(try Data(contentsOf: url))
                    merge(manifest, from: url, into: &profiles, issues: &issues)
                } catch {
                    issues.append(ManifestIssue(file: url, message: String(describing: error)))
                }
            }
        }

        return ProfileCatalog(profilesByID: profiles, issues: issues)
    }

    private func merge(
        _ manifest: GameManifest,
        from url: URL,
        into profiles: inout [String: GameProfile],
        issues: inout [ManifestIssue]
    ) {
        var seenInFile = Set<String>()
        for profile in manifest.profiles {
            if !seenInFile.insert(profile.id).inserted {
                issues.append(ManifestIssue(file: url, message: "Duplicate id '\(profile.id)'; last entry wins."))
            }
            profiles[profile.id] = profile
        }
    }

    /// Turns a `DecodingError` into a short, path-qualified message.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { key in
                if let index = key.intValue { "[\(index)]" } else { ".\(key.stringValue)" }
            }.joined()
        }
        switch error {
        case .keyNotFound(let key, let ctx): return "missing key '\(key.stringValue)' at \(path(ctx))"
        case .typeMismatch(_, let ctx): return "type mismatch at \(path(ctx)): \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx): return "null value at \(path(ctx))"
        case .dataCorrupted(let ctx): return "corrupted data at \(path(ctx)): \(ctx.debugDescription)"
        @unknown default: return String(describing: error)
        }
    }
}
