import Foundation
import Testing
@testable import AetherCore

// MARK: - Fixtures

enum Fixtures {
    static func mac(_ tier: HardwareTier, appleSilicon: Bool = true) -> MacHardwareProfile {
        MacHardwareProfile(
            chipName: appleSilicon ? "Apple M-Test" : "Intel(R) Core(TM) i9-9980HK",
            chip: appleSilicon ? AppleChip(generation: 3, variant: .pro) : nil,
            isAppleSilicon: appleSilicon,
            performanceCores: 8,
            efficiencyCores: appleSilicon ? 4 : 0,
            totalMemoryGB: 32,
            gpuCoreCount: appleSilicon ? 18 : 0,
            tier: tier
        )
    }

    static let d3dmetal = LocalTranslationConfig(
        backend: .d3dmetal,
        windowsVersion: "win10",
        envVars: ["WINEMSYNC": "1", "D3DM_ENABLE_METALFX": "1"],
        launchArgs: ["-dx12"]
    )

    static let moonlight = CloudFallbackConfig(geforceNowID: "gfn-test", moonlightAppName: "Test Game")

    static func game(
        kernelAntiCheat: Bool = false,
        minTier: Int = 2,
        preferred: ExecutionEngine = .localTranslation,
        local: LocalTranslationConfig? = d3dmetal,
        cloud: CloudFallbackConfig? = moonlight
    ) -> GameProfile {
        GameProfile(
            id: "test-game",
            title: "Test Game",
            steamAppID: "42",
            hasKernelAnticheat: kernelAntiCheat,
            anticheatName: kernelAntiCheat ? "Riot Vanguard" : nil,
            nativeMacosAvailable: false,
            minLocalTier: minTier,
            preferredEngine: preferred,
            localTranslation: local,
            cloudFallback: cloud
        )
    }

    static let windowsInstall = GameInstallation(windowsExecutable: URL(filePath: "/Volumes/SSD/Games/Test/game.exe"))
    static let nativeInstall = GameInstallation(nativeApplication: URL(filePath: "/Applications/Test Game.app"))
    static let bothInstalled = GameInstallation(
        nativeApplication: URL(filePath: "/Applications/Test Game.app"),
        windowsExecutable: URL(filePath: "/Volumes/SSD/Games/Test/game.exe")
    )
}

// MARK: - Router

@Suite("EngineRouter")
struct EngineRouterTests {
    let router = EngineRouter()

    // Native

    @Test("Installed native build routes to Native, even on Tier 1")
    func nativeInstalled() throws {
        let decision = try router.route(profile: Fixtures.game(), installation: Fixtures.bothInstalled, hardware: Fixtures.mac(.entry))
        #expect(decision == RoutingDecision(engine: .native, reason: .nativeBinaryInstalled, allowLocalOverride: false))
    }

    @Test("Native beats kernel anti-cheat (the native build ships its own AC)")
    func nativeBeatsAntiCheat() throws {
        let decision = try router.route(profile: Fixtures.game(kernelAntiCheat: true), installation: Fixtures.nativeInstall, hardware: Fixtures.mac(.high))
        #expect(decision.engine == .native)
    }

    @Test("Profile says native exists but it is not installed: does not route Native")
    func nativeAvailableButNotInstalled() throws {
        var profile = Fixtures.game()
        profile.nativeMacosAvailable = true
        let decision = try router.route(profile: profile, installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.high))
        #expect(decision.engine == .localTranslation)
    }

    // Local D3DMetal

    @Test("Tier meets min_local_tier: Local D3DMetal", arguments: [HardwareTier.mid, .high, .ultra])
    func localWhenTierMet(tier: HardwareTier) throws {
        let decision = try router.route(profile: Fixtures.game(minTier: 2), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(tier))
        #expect(decision == RoutingDecision(
            engine: .localTranslation,
            reason: .meetsTier(actual: tier, required: 2),
            allowLocalOverride: false
        ))
    }

    @Test("Exact tier boundary counts as meeting it")
    func localAtExactBoundary() throws {
        let decision = try router.route(profile: Fixtures.game(minTier: 3), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.high))
        #expect(decision.engine == .localTranslation)
    }

    // Kernel anti-cheat → Cloud

    @Test("Kernel anti-cheat forces Cloud on Tier 4, with no local override")
    func kernelAntiCheatForcesCloud() throws {
        let decision = try router.route(profile: Fixtures.game(kernelAntiCheat: true), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.ultra))
        #expect(decision == RoutingDecision(
            engine: .cloudStream,
            reason: .kernelAntiCheat(name: "Riot Vanguard"),
            allowLocalOverride: false
        ))
    }

    @Test("Kernel anti-cheat ignores the user's prefer-local request")
    func kernelAntiCheatIgnoresPreferLocal() throws {
        let decision = try router.route(
            profile: Fixtures.game(kernelAntiCheat: true),
            installation: Fixtures.windowsInstall,
            hardware: Fixtures.mac(.ultra),
            preference: .preferLocal
        )
        #expect(decision.engine == .cloudStream)
    }

    @Test("Kernel anti-cheat with no stream configured throws noViableEngine")
    func kernelAntiCheatWithoutCloudThrows() {
        #expect(throws: RoutingError.noViableEngine(gameID: "test-game", blockedBy: .kernelAntiCheat(name: "Riot Vanguard"))) {
            try router.route(profile: Fixtures.game(kernelAntiCheat: true, cloud: nil), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.ultra))
        }
    }

    // Low tier → Cloud

    @Test("Below min_local_tier: Cloud by default, local override offered")
    func lowTierRoutesToCloud() throws {
        let decision = try router.route(profile: Fixtures.game(minTier: 3), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.entry))
        #expect(decision == RoutingDecision(
            engine: .cloudStream,
            reason: .belowTier(actual: .entry, required: 3),
            allowLocalOverride: true
        ))
    }

    @Test("Below tier + user override: Local low-spec")
    func lowTierUserOverride() throws {
        let decision = try router.route(
            profile: Fixtures.game(minTier: 3),
            installation: Fixtures.windowsInstall,
            hardware: Fixtures.mac(.mid),
            preference: .preferLocal
        )
        #expect(decision.engine == .localTranslation)
        #expect(decision.reason == .userLocalOverride(actual: .mid, required: 3))
    }

    @Test("Below tier with no stream configured: Local low-spec, not an error")
    func lowTierWithoutCloudRunsLocal() throws {
        let decision = try router.route(profile: Fixtures.game(minTier: 4, cloud: nil), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.entry))
        #expect(decision.engine == .localTranslation)
        #expect(decision.reason == .belowTierNoCloudFallback(actual: .entry, required: 4))
    }

    // Hard local blockers

    @Test("Intel Mac cannot run D3DMetal: Cloud")
    func intelRoutesToCloud() throws {
        let decision = try router.route(profile: Fixtures.game(), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.entry, appleSilicon: false))
        #expect(decision.engine == .cloudStream)
        #expect(decision.reason == .hardwareNotAppleSilicon)
    }

    @Test("min_local_tier 99 means never local, even on Tier 4")
    func neverLocalSentinel() throws {
        let decision = try router.route(profile: Fixtures.game(minTier: 99), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.ultra))
        #expect(decision.reason == .localTranslationUnsupportedByProfile)
        #expect(decision.allowLocalOverride == false)
    }

    @Test("No Windows build installed: Cloud")
    func notInstalledRoutesToCloud() throws {
        let decision = try router.route(profile: Fixtures.game(), installation: .notInstalled, hardware: Fixtures.mac(.ultra))
        #expect(decision.reason == .windowsBuildNotInstalled)
    }

    @Test("No local profile and no stream: throws")
    func nothingViableThrows() {
        #expect(throws: RoutingError.noViableEngine(gameID: "test-game", blockedBy: .noLocalTranslationProfile)) {
            try router.route(profile: Fixtures.game(local: nil, cloud: nil), installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.ultra))
        }
    }

    @Test("Curated cloud preference wins over tier, but can be overridden")
    func curatedCloudPreference() throws {
        let profile = Fixtures.game(preferred: .cloudStream)
        let auto = try router.route(profile: profile, installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.ultra))
        #expect(auto == RoutingDecision(engine: .cloudStream, reason: .curatedCloudPreference, allowLocalOverride: true))

        let forced = try router.route(profile: profile, installation: Fixtures.windowsInstall, hardware: Fixtures.mac(.ultra), preference: .preferLocal)
        #expect(forced.engine == .localTranslation)
    }

    // Blueprint profiles end to end

    @Test("Bundled VALORANT profile routes to Cloud on every tier")
    func bundledValorant() throws {
        let catalog = try GameManifestLoader(userProfileDirectories: []).load()
        let valorant = try #require(catalog.profile(id: "valorant"))
        for tier in HardwareTier.allCases {
            let decision = try router.route(profile: valorant, installation: Fixtures.windowsInstall, hardware: Fixtures.mac(tier))
            #expect(decision.engine == .cloudStream)
            #expect(decision.reason == .kernelAntiCheat(name: "Riot Vanguard"))
        }
    }
}
