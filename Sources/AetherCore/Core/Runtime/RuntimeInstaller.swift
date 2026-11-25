import Foundation

/// A free component published as GitHub release assets. The asset is chosen by regex from the
/// latest release, so new upstream versions are picked up without code changes.
public struct ReleaseSource: Sendable, Equatable {
    public let id: String
    public let label: String
    public let repo: String
    public let assetPattern: String

    /// Gcenx's macOS Wine Staging builds (x86_64; run under Rosetta 2).
    public static let wineStaging = ReleaseSource(
        id: "wine-staging", label: "Wine Staging", repo: "Gcenx/macOS_Wine_builds",
        assetPattern: #"^wine-staging-[\d.]+-osx64\.tar\.xz$"#
    )
    /// DXMT: Metal-based D3D10/11.
    public static let dxmt = ReleaseSource(id: "dxmt", label: "DXMT", repo: "3Shain/dxmt", assetPattern: #"^dxmt-.*\.tar\.gz$"#)
    /// DXVK patched for macOS / MoltenVK.
    public static let dxvk = ReleaseSource(
        id: "dxvk", label: "DXVK (macOS)", repo: "Gcenx/DXVK-macOS", assetPattern: #"^dxvk-macOS-.*\.tar\.gz$"#
    )
}

public struct ReleaseAsset: Sendable, Equatable {
    public let tag: String
    public let name: String
    public let url: URL
    public let size: Int64

    /// "v11.21" → "11.21"
    public var version: String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }
}

public enum InstallProgress: Sendable, Equatable {
    case resolving
    case downloading(received: Int64, total: Int64?)
    case extracting
    case installing
    case done

    /// 0…1 when known.
    public var fraction: Double? {
        switch self {
        case .downloading(let received, let total?) where total > 0: Double(received) / Double(total)
        case .done: 1
        default: nil
        }
    }
}

public enum InstallerError: Error, Equatable, CustomStringConvertible {
    case assetNotFound(String)
    case http(Int)
    case truncated(received: Int64, expected: Int64)
    case command(String, Int32)
    case invalid(String)

    public var description: String {
        switch self {
        case .assetNotFound(let what): "Couldn't find a \(what) download in the latest release. The project may have renamed its files."
        case .http(let status): "Download failed (HTTP \(status))."
        case .truncated(let received, let expected): "Download was cut off (\(received) of \(expected) bytes). Try again."
        case .command(let command, let status): "`\(command)` failed (exit \(status))."
        case .invalid(let message): message
        }
    }
}

/// The setup wizard's engine: Rosetta, the free Wine runtime, DXMT, DXVK and the GPTK D3DMetal import.
/// Writes the same layout `WineRuntimeStore` reads (shared with the Rust engine):
/// `runtimes/<id>/runtime.json`, derived `runtimes/<id>+dxmt|+d3dmetal`, `components/dxvk/<version>`.
public struct RuntimeInstaller: Sendable {
    public typealias Progress = @Sendable (InstallProgress) -> Void

    public let root: URL

    public init(root: URL = AetherPaths.engineRoot) {
        self.root = root
    }

    var runtimesDirectory: URL { root.appending(path: "runtimes", directoryHint: .isDirectory) }
    var downloadsDirectory: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
    var dxvkDirectory: URL { root.appending(path: "components/dxvk", directoryHint: .isDirectory) }

    // MARK: Rosetta

    public static var isRosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Installs Rosetta 2 behind macOS's standard administrator password prompt. No Terminal needed.
    public static func installRosetta() async throws {
        if isRosettaInstalled { return }
        let script = #"do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges"#
        let status = await WinePrefix.run(URL(filePath: "/usr/bin/osascript"), ["-e", script], environment: ProcessInfo.processInfo.environment)
        guard status == 0 else { throw InstallerError.command("softwareupdate --install-rosetta", status) }
    }

    // MARK: Components

    /// Downloads the latest Wine Staging and registers it as a base runtime.
    public func installWine(progress: Progress) async throws -> WineRuntime {
        let (asset, staging) = try await fetch(.wineStaging, progress: progress)
        defer { try? FileManager.default.removeItem(at: staging) }
        progress(.installing)

        let id = Self.slugify("Wine Staging-\(asset.version)")
        let target = runtimesDirectory.appending(path: id, directoryHint: .isDirectory)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path(percentEncoded: false)) { try fm.removeItem(at: target) }
        try fm.createDirectory(at: runtimesDirectory, withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: target)

        guard let wineRoot = Self.findDirectory(in: target, maxDepth: 6, where: { dir in
            let bin = dir.appending(path: "bin")
            return (Self.isFile(bin.appending(path: "wine")) || Self.isFile(bin.appending(path: "wine64")))
                && Self.isFile(bin.appending(path: "wineserver"))
        }) else {
            throw InstallerError.invalid("The Wine download has no bin/wine + bin/wineserver.")
        }
        let runtime = WineRuntime(
            id: id, name: "Wine Staging", version: asset.version, flavor: .base, baseId: nil,
            wineRoot: Self.relativePath(of: wineRoot, to: target), installedAt: Int64(Date().timeIntervalSince1970),
            directory: target
        )
        try write(runtime)
        progress(.done)
        return runtime
    }

    /// Downloads DXMT and builds `<base>+dxmt`: an APFS clone of the base with DXMT merged into `lib/wine`.
    public func installDXMT(base: WineRuntime, progress: Progress) async throws -> WineRuntime {
        let (_, staging) = try await fetch(.dxmt, progress: progress)
        defer { try? FileManager.default.removeItem(at: staging) }
        progress(.installing)
        guard let archRoot = Self.findDirectory(in: staging, maxDepth: 6, where: {
            Self.isDirectory($0.appending(path: "x86_64-windows")) || Self.isDirectory($0.appending(path: "x86_64-unix"))
        }) else {
            throw InstallerError.invalid("The DXMT download has no x86_64-windows / x86_64-unix folder.")
        }
        let runtime = try await derive(base, flavor: .dxmt, label: "DXMT") { lib in
            try await Self.merge(archRoot, into: lib.appending(path: "wine", directoryHint: .isDirectory))
        }
        progress(.done)
        return runtime
    }

    /// Downloads DXVK into `components/dxvk/<version>/{x64,x32}`. It is copied into each bottle at launch.
    public func installDXVK(progress: Progress) async throws -> URL {
        let (asset, staging) = try await fetch(.dxvk, progress: progress)
        defer { try? FileManager.default.removeItem(at: staging) }
        progress(.installing)
        guard let root = Self.findDirectory(in: staging, maxDepth: 5, where: { Self.isFile($0.appending(path: "x64/d3d11.dll")) }) else {
            throw InstallerError.invalid("The DXVK download has no x64/d3d11.dll.")
        }
        let fm = FileManager.default
        let destination = dxvkDirectory.appending(path: asset.version, directoryHint: .isDirectory)
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for arch in ["x64", "x32"] where Self.isDirectory(root.appending(path: arch)) {
            try fm.copyItem(at: root.appending(path: arch), to: destination.appending(path: arch))
        }
        progress(.done)
        return destination
    }

    /// Builds `<base>+d3dmetal` from the user's own Game Porting Toolkit (mounted DMG or folder).
    /// Apple's license forbids redistributing D3DMetal, so it is never downloaded here.
    public func importGPTK(base: WineRuntime, from source: URL) async throws -> WineRuntime {
        guard let gptkLib = Self.findGPTKLib(in: source) else {
            throw InstallerError.invalid(
                "No Game Porting Toolkit in \(source.lastPathComponent) (expected …/lib/external/D3DMetal.framework). "
                + "Download it free from developer.apple.com/games, open the .dmg, then choose the mounted volume."
            )
        }
        return try await derive(base, flavor: .d3dmetal, label: "D3DMetal") { lib in
            try await Self.merge(gptkLib, into: lib)
        }
    }

    /// GPTK `lib` folders on mounted volumes and in ~/Downloads (only toolkit-named entries are searched).
    public static func detectGPTK() -> [URL] {
        let fm = FileManager.default
        let looksLikeGPTK: (URL) -> Bool = { url in
            let name = url.lastPathComponent.lowercased()
            return name.contains("game porting") || name.contains("evaluation environment") || name.contains("gptk")
        }
        let volumes = (try? fm.contentsOfDirectory(at: URL(filePath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
        let downloads = (try? fm.contentsOfDirectory(at: URL.downloadsDirectory, includingPropertiesForKeys: nil)) ?? []
        return (volumes + downloads).filter(looksLikeGPTK).compactMap(findGPTKLib(in:))
    }

    static func findGPTKLib(in root: URL) -> URL? {
        findDirectory(in: root, maxDepth: 6) { dir in
            dir.lastPathComponent == "lib" && isDirectory(dir.appending(path: "external/D3DMetal.framework"))
        }
    }

    // MARK: Download pipeline

    /// Latest release → download (streamed, with progress) → extract into a fresh staging folder.
    func fetch(_ source: ReleaseSource, progress: Progress) async throws -> (ReleaseAsset, URL) {
        progress(.resolving)
        let asset = try await Self.resolveLatest(source)
        let fm = FileManager.default
        try fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let archive = downloadsDirectory.appending(path: asset.name)
        try await Self.download(asset, to: archive, progress: progress)
        defer { try? fm.removeItem(at: archive) }

        progress(.extracting)
        let staging = downloadsDirectory.appending(path: "\(source.id)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let status = await WinePrefix.run(
            URL(filePath: "/usr/bin/tar"),
            ["-xf", archive.path(percentEncoded: false), "-C", staging.path(percentEncoded: false)],
            environment: ProcessInfo.processInfo.environment
        )
        guard status == 0 else {
            try? fm.removeItem(at: staging)
            throw InstallerError.command("tar -xf \(asset.name)", status)
        }
        return (asset, staging)
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let assets: [GitHubAsset]
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int64
    }

    static func selectAsset(_ source: ReleaseSource, from json: Data) throws -> ReleaseAsset {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        let pattern = try Regex(source.assetPattern)
        guard let asset = release.assets.first(where: { $0.name.wholeMatch(of: pattern) != nil }) else {
            throw InstallerError.assetNotFound(source.label)
        }
        return ReleaseAsset(tag: release.tag_name, name: asset.name, url: asset.browser_download_url, size: asset.size)
    }

    static func resolveLatest(_ source: ReleaseSource) async throws -> ReleaseAsset {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(source.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AetherLauncher/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallerError.http(http.statusCode)
        }
        return try selectAsset(source, from: data)
    }

    /// Streams to `<dest>.part` in 1 MiB writes, reporting every ~512 KiB, then renames.
    static func download(_ asset: ReleaseAsset, to destination: URL, progress: Progress) async throws {
        var request = URLRequest(url: asset.url)
        request.setValue("AetherLauncher/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallerError.http(http.statusCode)
        }
        let total: Int64? = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let partial = destination.appendingPathExtension("part")
        let fm = FileManager.default
        try? fm.removeItem(at: partial)
        fm.createFile(atPath: partial.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: partial)

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport: Int64 = 0
        progress(.downloading(received: 0, total: total))
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if received - lastReport >= 512 * 1024 {
                        lastReport = received
                        progress(.downloading(received: received, total: total))
                    }
                }
            }
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: partial)
            throw error
        }
        if let total, received != total {
            try? fm.removeItem(at: partial)
            throw InstallerError.truncated(received: received, expected: total)
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        progress(.downloading(received: received, total: total))
    }

    // MARK: Derived runtimes

    /// APFS clone (`cp -c`, near-zero disk) of `base`, then `overlay` on the clone's `lib` folder.
    /// A failed overlay removes the half-built clone.
    func derive(
        _ base: WineRuntime,
        flavor: RuntimeFlavor,
        label: String,
        overlay: @Sendable (URL) async throws -> Void
    ) async throws -> WineRuntime {
        guard base.flavor == .base else { throw InstallerError.invalid("Derived runtimes must be built from a base runtime.") }
        let id = "\(base.id)+\(flavor.rawValue)"
        let target = runtimesDirectory.appending(path: id, directoryHint: .isDirectory)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path(percentEncoded: false)) { try fm.removeItem(at: target) }

        var status = await WinePrefix.run(
            URL(filePath: "/bin/cp"),
            ["-cR", base.directory.path(percentEncoded: false), target.path(percentEncoded: false)],
            environment: [:]
        )
        if status != 0 {
            try? fm.removeItem(at: target) // not APFS: plain copy
            status = await WinePrefix.run(
                URL(filePath: "/bin/cp"),
                ["-R", base.directory.path(percentEncoded: false), target.path(percentEncoded: false)],
                environment: [:]
            )
        }
        guard status == 0 else { throw InstallerError.command("cp -R \(base.id)", status) }

        let runtime = WineRuntime(
            id: id, name: "\(base.name) + \(label)", version: base.version, flavor: flavor, baseId: base.id,
            wineRoot: base.wineRoot, installedAt: Int64(Date().timeIntervalSince1970), directory: target
        )
        do {
            try await overlay(runtime.libDirectory)
            try write(runtime)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        return runtime
    }

    /// `ditto` merges a tree, preserving symlinks and framework structure (D3DMetal.framework).
    static func merge(_ source: URL, into destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let status = await WinePrefix.run(
            URL(filePath: "/usr/bin/ditto"),
            [source.path(percentEncoded: false), destination.path(percentEncoded: false)],
            environment: [:]
        )
        guard status == 0 else { throw InstallerError.command("ditto \(source.lastPathComponent)", status) }
    }

    func write(_ runtime: WineRuntime) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runtime).write(to: runtime.directory.appending(path: "runtime.json"), options: .atomic)
    }

    // MARK: File helpers

    /// "Wine Staging-11.21" → "wine-staging-11-21" (matches the Rust engine's ids).
    public static func slugify(_ input: String) -> String {
        var slug = ""
        var lastDash = true
        for scalar in input.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.append(Character(scalar).lowercased())
                lastDash = false
            } else if !lastDash {
                slug.append("-")
                lastDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "untitled" : String(slug.prefix(48))
    }

    /// Shallowest directory under `root` (inclusive, up to `maxDepth`) matching `predicate`.
    static func findDirectory(in root: URL, maxDepth: Int, where predicate: (URL) -> Bool) -> URL? {
        if predicate(root) { return root }
        var level = [root]
        for _ in 0..<maxDepth {
            var next: [URL] = []
            for dir in level {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
                )) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                    if predicate(child) { return child }
                    next.append(child)
                }
            }
            level = next
        }
        return nil
    }

    static func relativePath(of url: URL, to base: URL) -> String {
        let full = url.standardizedFileURL.path(percentEncoded: false)
        var prefix = base.standardizedFileURL.path(percentEncoded: false)
        if !prefix.hasSuffix("/") { prefix += "/" }
        var relative = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
        while relative.hasSuffix("/") { relative.removeLast() }
        return relative
    }

    static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && !isDir.boolValue
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }
}
