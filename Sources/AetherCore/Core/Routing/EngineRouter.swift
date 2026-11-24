import Foundation

/// The 3-Engine decision core (PROJECT_SPEC §3). Pure and deterministic: no I/O, no globals.
///
/// Precedence, first match wins:
/// 1. Native build installed                         → Native
/// 2. Kernel anti-cheat                              → Cloud (no override allowed)
/// 3. Local translation impossible: Intel Mac, no Wine profile,
///    profile says "never local", or .exe not installed → Cloud
/// 4. Profile curated as cloud-preferred             → Cloud (override allowed)
/// 5. Hardware tier ≥ `min_local_tier`               → Local (D3DMetal)
/// 6. Below tier                                     → Cloud by default; Local if the user
///                                                     overrides or no stream is configured
public struct EngineRouter: Sendable {

    public init() {}

    public func route(
        profile: GameProfile,
        installation: GameInstallation,
        hardware: MacHardwareProfile,
        preference: RoutingPreference = .automatic
    ) throws(RoutingError) -> RoutingDecision {

        // 1. Native always wins: no translation cost, and macOS Game Mode engages.
        //    Native builds with anti-cheat (e.g. EAC for macOS) are fine here.
        if installation.nativeApplication != nil {
            return RoutingDecision(engine: .native, reason: .nativeBinaryInstalled, allowLocalOverride: false)
        }

        let cloudAvailable = profile.cloudFallback?.isAvailable == true

        // 2. Kernel anti-cheat (Vanguard, Ricochet, ...) will not run under Wine. No override:
        //    a local attempt fails or risks a ban.
        if profile.hasKernelAnticheat {
            let reason = RoutingReason.kernelAntiCheat(name: profile.anticheatName)
            guard cloudAvailable else { throw RoutingError.noViableEngine(gameID: profile.id, blockedBy: reason) }
            return RoutingDecision(engine: .cloudStream, reason: reason, allowLocalOverride: false)
        }

        // 3. Hard blockers for local translation.
        if let blocker = localTranslationBlocker(profile: profile, installation: installation, hardware: hardware) {
            guard cloudAvailable else { throw RoutingError.noViableEngine(gameID: profile.id, blockedBy: blocker) }
            return RoutingDecision(engine: .cloudStream, reason: blocker, allowLocalOverride: false)
        }

        let tier = hardware.tier
        let required = profile.minLocalTier

        // 4. Curators flagged this title as better streamed (broken shaders, stutter, ...).
        if profile.preferredEngine == .cloudStream, cloudAvailable {
            if preference == .preferLocal {
                return RoutingDecision(
                    engine: .localTranslation,
                    reason: .userLocalOverride(actual: tier, required: required),
                    allowLocalOverride: false
                )
            }
            return RoutingDecision(engine: .cloudStream, reason: .curatedCloudPreference, allowLocalOverride: true)
        }

        // 5. Hardware can hold 60 FPS locally (with MetalFX upscaling).
        if tier.meets(minimumTier: required) {
            return RoutingDecision(
                engine: .localTranslation,
                reason: .meetsTier(actual: tier, required: required),
                allowLocalOverride: false
            )
        }

        // 6. Below threshold. Local low-spec is the only option without a stream.
        guard cloudAvailable else {
            return RoutingDecision(
                engine: .localTranslation,
                reason: .belowTierNoCloudFallback(actual: tier, required: required),
                allowLocalOverride: false
            )
        }
        if preference == .preferLocal {
            return RoutingDecision(
                engine: .localTranslation,
                reason: .userLocalOverride(actual: tier, required: required),
                allowLocalOverride: false
            )
        }
        return RoutingDecision(
            engine: .cloudStream,
            reason: .belowTier(actual: tier, required: required),
            allowLocalOverride: true
        )
    }

    /// First reason local translation is impossible, or `nil` if it is possible.
    private func localTranslationBlocker(
        profile: GameProfile,
        installation: GameInstallation,
        hardware: MacHardwareProfile
    ) -> RoutingReason? {
        if !hardware.isAppleSilicon { return .hardwareNotAppleSilicon }
        if profile.localTranslation == nil { return .noLocalTranslationProfile }
        // min_local_tier above the top tier (the blueprint uses 99) means "never local".
        if profile.minLocalTier > HardwareTier.ultra.rawValue { return .localTranslationUnsupportedByProfile }
        if installation.windowsExecutable == nil { return .windowsBuildNotInstalled }
        return nil
    }
}
