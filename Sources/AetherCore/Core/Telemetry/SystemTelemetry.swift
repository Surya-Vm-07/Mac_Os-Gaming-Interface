import Darwin
import Foundation

public enum MemoryPressure: String, Sendable, Equatable {
    case normal, warning, critical, unknown
}

/// One telemetry reading for the Quick Access drawer.
public struct TelemetrySnapshot: Sendable, Equatable {
    /// 0…1 across all cores since the previous sample. `nil` on the first sample.
    public var cpuUsage: Double?
    /// 0…1 from the Apple GPU driver's `PerformanceStatistics`. `nil` if not exposed.
    public var gpuUsage: Double?
    /// Activity Monitor's "Memory Used": app memory + wired + compressed.
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var swapUsedBytes: UInt64
    public var memoryPressure: MemoryPressure
    public var thermal: ThermalPressure

    public var memoryUsedFraction: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}

/// Samples CPU, GPU, memory and thermals with Mach host statistics, sysctl and the IORegistry.
/// Each `sample()` costs well under a millisecond plus one IORegistry lookup. Poll it about once a
/// second, and only while the drawer is visible.
public struct SystemTelemetry: Sendable {
    private var previousCPU: CPUTicks?

    public init() {}

    public mutating func sample() -> TelemetrySnapshot {
        var cpuUsage: Double?
        if let ticks = Self.cpuTicks() {
            if let previous = previousCPU, ticks.total > previous.total {
                cpuUsage = Double(ticks.busy &- previous.busy) / Double(ticks.total - previous.total)
            }
            previousCPU = ticks
        }
        return TelemetrySnapshot(
            cpuUsage: cpuUsage.map { min(max($0, 0), 1) },
            gpuUsage: Self.gpuUtilization(),
            memoryUsedBytes: Self.memoryUsedBytes() ?? 0,
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: Self.swapUsedBytes(),
            memoryPressure: Self.memoryPressure(),
            thermal: MacHardwareProfiler.currentThermalPressure()
        )
    }

    // MARK: - CPU

    struct CPUTicks: Sendable {
        let busy: UInt64
        let total: UInt64
    }

    /// One host port for the whole process. `mach_host_self()` hands out a send right on every call.
    private static let host = mach_host_self()

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks order: USER, SYSTEM, IDLE, NICE
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    // MARK: - Memory

    static func memoryUsedBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(MacHardwareProfiler.sysctlInteger("hw.pagesize", as: Int64.self) ?? 16_384)
        let internal = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appMemory = internal > purgeable ? internal - purgeable : 0
        let pages = appMemory + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * pageSize
    }

    static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Kernel memory-pressure level: 1 normal, 2 warning, 4 critical.
    static func memoryPressure() -> MemoryPressure {
        switch MacHardwareProfiler.sysctlInteger("kern.memorystatus_vm_pressure_level", as: Int32.self) {
        case 1?: .normal
        case 2?: .warning
        case 4?: .critical
        default: .unknown
        }
    }

    // MARK: - GPU

    static func gpuUtilization() -> Double? {
        guard let stats = MacHardwareProfiler.agxRegistryValue("PerformanceStatistics") as? [String: Any],
              let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
        else { return nil }
        return min(max(percent / 100, 0), 1)
    }
}
