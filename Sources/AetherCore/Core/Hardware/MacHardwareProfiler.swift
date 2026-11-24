import Foundation
import Darwin
import IOKit
import Metal

/// Detects the host Mac's chip, core layout, unified memory and GPU cores, then maps it to a tier.
///
/// Data sources, all public SDK:
/// - `sysctlbyname`: `machdep.cpu.brand_string`, `hw.optional.arm64`, `hw.perflevel{0,1}.physicalcpu`,
///   `hw.memsize`, `sysctl.proc_translated`.
/// - IORegistry `AGXAccelerator` → `gpu-core-count`. sysctl does not expose GPU cores;
///   this is the same key `system_profiler SPDisplaysDataType` reads.
/// - `MTLCreateSystemDefaultDevice()?.name`: chip-name fallback only.
public enum MacHardwareProfiler {

    /// Profile of this Mac, detected once and cached. Hardware does not change while the app runs.
    public static let current: MacHardwareProfile = detect()

    /// Runs detection now. Prefer `current`.
    public static func detect() -> MacHardwareProfile {
        let isAppleSilicon = (sysctlInteger("hw.optional.arm64", as: Int32.self) ?? 0) == 1
        let isTranslated = (sysctlInteger("sysctl.proc_translated", as: Int32.self) ?? 0) == 1

        var chipName = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        var chip = AppleChip(brandString: chipName)
        if chip == nil, isAppleSilicon, let metalName = MTLCreateSystemDefaultDevice()?.name {
            // Some VMs and early betas return a generic brand string; Metal still knows the GPU.
            chipName = metalName
            chip = AppleChip(brandString: metalName)
        }

        // Apple Silicon reports performance (perflevel0) and efficiency (perflevel1) clusters.
        // Intel has no perflevels, so fall back to hw.physicalcpu.
        let performanceCores = Int(
            sysctlInteger("hw.perflevel0.physicalcpu", as: Int32.self)
                ?? sysctlInteger("hw.physicalcpu", as: Int32.self)
                ?? 0
        )
        let efficiencyCores = isAppleSilicon
            ? Int(sysctlInteger("hw.perflevel1.physicalcpu", as: Int32.self) ?? 0)
            : 0

        let memoryBytes = sysctlInteger("hw.memsize", as: UInt64.self) ?? ProcessInfo.processInfo.physicalMemory
        let memoryGB = Int(memoryBytes / 1_073_741_824)

        return MacHardwareProfile(
            chipName: chipName,
            chip: chip,
            isAppleSilicon: isAppleSilicon,
            isRunningUnderRosetta: isTranslated,
            performanceCores: performanceCores,
            efficiencyCores: efficiencyCores,
            totalMemoryGB: memoryGB,
            gpuCoreCount: gpuCoreCount() ?? 0,
            tier: isAppleSilicon ? classify(chip: chip, memoryGB: memoryGB) : .entry
        )
    }

    /// Pure tier classification so it can be unit-tested without the hardware.
    ///
    /// Two ceilings, take the lower one:
    /// 1. Silicon class (ENGINE_BLUEPRINT §1):
    ///    - Ultra (any gen), or Max M3 and later  → Tier 4
    ///    - Max M1–M2, or Pro M2 and later        → Tier 3
    ///    - Pro M1, or any base chip              → Tier 2
    /// 2. Unified memory: Tier 4 needs ≥ 48 GB, Tier 2–3 need ≥ 16 GB, below 16 GB is Tier 1.
    ///    Under Wine + D3DMetal, AAA titles hit swap first, not GPU limits, so memory caps the tier.
    public static func classify(chip: AppleChip?, memoryGB: Int) -> HardwareTier {
        guard let chip else { return .entry }

        let siliconCeiling: HardwareTier = switch chip.variant {
        case .ultra: .ultra
        case .max: chip.generation >= 3 ? .ultra : .high
        case .pro: chip.generation >= 2 ? .high : .mid
        case .base: .mid
        }

        let memoryCeiling: HardwareTier = switch memoryGB {
        case 48...: .ultra
        case 16..<48: .high
        default: .entry
        }

        return min(siliconCeiling, memoryCeiling)
    }

    /// Current thermal pressure (cheap, safe to poll for the telemetry HUD).
    public static func currentThermalPressure() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }

    // MARK: - sysctl

    /// Reads a string sysctl. Two calls: size query, then fill.
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Reads a fixed-width integer sysctl. Returns `nil` if the key does not exist
    /// (e.g. `hw.perflevel1.physicalcpu` on Intel, `sysctl.proc_translated` on old macOS).
    static func sysctlInteger<T: FixedWidthInteger>(_ name: String, as type: T.Type) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: - IOKit

    /// GPU core count from the Apple GPU's IORegistry entry (`AGXAccelerator` class).
    static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AGXAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let property = IORegistryEntryCreateCFProperty(
                service,
                "gpu-core-count" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
            IOObjectRelease(service)

            if let cores = (property as? NSNumber)?.intValue, cores > 0 {
                return cores
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }
}
