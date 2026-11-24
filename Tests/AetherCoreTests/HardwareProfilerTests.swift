import Testing
@testable import AetherCore

struct TierCase: Sendable, CustomTestStringConvertible {
    let brand: String
    let memoryGB: Int
    let expected: HardwareTier
    var testDescription: String { "\(brand) \(memoryGB)GB → \(expected)" }
}

@Suite("MacHardwareProfiler")
struct HardwareProfilerTests {

    @Test("Brand-string parsing", arguments: [
        ("Apple M1", AppleChip(generation: 1, variant: .base)),
        ("Apple M2 Pro", AppleChip(generation: 2, variant: .pro)),
        ("Apple M3 Max", AppleChip(generation: 3, variant: .max)),
        ("Apple M1 Ultra", AppleChip(generation: 1, variant: .ultra)),
        ("Apple M4 Pro", AppleChip(generation: 4, variant: .pro)),
        ("Apple M5", AppleChip(generation: 5, variant: .base)),
    ])
    func parsesAppleBrandStrings(brand: String, expected: AppleChip) {
        #expect(AppleChip(brandString: brand) == expected)
    }

    @Test("Non-Apple brand strings do not parse", arguments: [
        "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz",
        "VirtualApple @ 2.50GHz processor",
        "",
    ])
    func rejectsNonAppleBrands(brand: String) {
        #expect(AppleChip(brandString: brand) == nil)
    }

    /// Mirrors the tiering matrix in ENGINE_BLUEPRINT.md §1.
    @Test("Tier matrix", arguments: [
        TierCase(brand: "Apple M1", memoryGB: 8, expected: .entry),
        TierCase(brand: "Apple M2", memoryGB: 8, expected: .entry),
        TierCase(brand: "Apple M3", memoryGB: 8, expected: .entry),
        TierCase(brand: "Apple M1", memoryGB: 16, expected: .mid),
        TierCase(brand: "Apple M4", memoryGB: 24, expected: .mid),
        TierCase(brand: "Apple M1 Pro", memoryGB: 16, expected: .mid),
        TierCase(brand: "Apple M1 Pro", memoryGB: 32, expected: .mid),
        TierCase(brand: "Apple M2 Pro", memoryGB: 16, expected: .high),
        TierCase(brand: "Apple M3 Pro", memoryGB: 18, expected: .high),
        TierCase(brand: "Apple M4 Pro", memoryGB: 24, expected: .high),
        TierCase(brand: "Apple M1 Max", memoryGB: 32, expected: .high),
        TierCase(brand: "Apple M2 Max", memoryGB: 96, expected: .high),
        TierCase(brand: "Apple M3 Max", memoryGB: 36, expected: .high),   // memory-capped
        TierCase(brand: "Apple M3 Max", memoryGB: 48, expected: .ultra),
        TierCase(brand: "Apple M4 Max", memoryGB: 64, expected: .ultra),
        TierCase(brand: "Apple M2 Ultra", memoryGB: 64, expected: .ultra),
        TierCase(brand: "Apple M3 Ultra", memoryGB: 96, expected: .ultra),
    ])
    func tierMatrix(_ c: TierCase) {
        #expect(MacHardwareProfiler.classify(chip: AppleChip(brandString: c.brand), memoryGB: c.memoryGB) == c.expected)
    }

    @Test("Unknown chip is conservatively Tier 1")
    func unknownChipIsEntry() {
        #expect(MacHardwareProfiler.classify(chip: nil, memoryGB: 128) == .entry)
    }

    @Test("Live detection returns sane values on this Mac")
    func liveDetection() {
        let hw = MacHardwareProfiler.detect()
        #expect(hw.totalMemoryGB > 0)
        #expect(hw.performanceCores > 0)
        if hw.isAppleSilicon {
            #expect(hw.chip != nil, "Brand string '\(hw.chipName)' did not parse")
            #expect(hw.efficiencyCores > 0)
        }
    }

    @Test("Live sysctl helpers read known keys and reject unknown ones")
    func sysctlHelpers() {
        #expect(MacHardwareProfiler.sysctlString("machdep.cpu.brand_string") != nil)
        #expect((MacHardwareProfiler.sysctlInteger("hw.memsize", as: UInt64.self) ?? 0) > 0)
        #expect(MacHardwareProfiler.sysctlInteger("aether.does.not.exist", as: Int32.self) == nil)
    }
}
