import Foundation
import Testing
@testable import AetherCore

@Suite("DirectionalRepeater")
struct DirectionalRepeaterTests {
    let t0 = ContinuousClock.now

    @Test("Fires once immediately, waits the initial delay, then repeats at the interval")
    func repeatCadence() {
        var r = DirectionalRepeater(initialDelay: .milliseconds(300), repeatInterval: .milliseconds(100))
        #expect(r.update(.right, at: t0) == .right)
        #expect(r.update(.right, at: t0 + .milliseconds(150)) == nil)  // within the initial delay
        #expect(r.update(.right, at: t0 + .milliseconds(300)) == .right)
        #expect(r.update(.right, at: t0 + .milliseconds(350)) == nil)
        #expect(r.update(.right, at: t0 + .milliseconds(400)) == .right)
    }

    @Test("Changing direction fires at once and restarts the delay")
    func directionChange() {
        var r = DirectionalRepeater(initialDelay: .milliseconds(300), repeatInterval: .milliseconds(100))
        _ = r.update(.right, at: t0)
        #expect(r.update(.down, at: t0 + .milliseconds(10)) == .down)
        #expect(r.update(.down, at: t0 + .milliseconds(200)) == nil)
    }

    @Test("Releasing resets; the next press fires immediately")
    func release() {
        var r = DirectionalRepeater()
        _ = r.update(.left, at: t0)
        #expect(r.update(nil, at: t0 + .milliseconds(20)) == nil)
        #expect(!r.isHolding)
        #expect(r.update(.left, at: t0 + .milliseconds(40)) == .left)
    }

    @Test("Stick vector → direction with deadzone and dominant axis", arguments: [
        (Float(0.0), Float(0.0), FocusDirection?.none),
        (0.3, -0.2, nil),            // inside deadzone (drift)
        (0.9, 0.2, .right),
        (-0.8, 0.5, .left),
        (0.4, 0.95, .up),
        (0.1, -1.0, .down),
    ])
    func stickDirection(x: Float, y: Float, expected: FocusDirection?) {
        #expect(DirectionalRepeater.direction(x: x, y: y) == expected)
    }
}

@Suite("SystemTelemetry")
struct SystemTelemetryTests {
    @Test("Live sample is sane; CPU usage appears from the second sample on")
    func liveSample() async throws {
        var telemetry = SystemTelemetry()
        let first = telemetry.sample()
        #expect(first.cpuUsage == nil)
        #expect(first.memoryTotalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(first.memoryUsedBytes > 0)
        #expect(first.memoryUsedBytes < first.memoryTotalBytes)
        #expect(first.memoryPressure != .unknown)

        try await Task.sleep(for: .milliseconds(250))
        let second = telemetry.sample()
        let cpu = try #require(second.cpuUsage)
        #expect((0...1).contains(cpu))
        if let gpu = second.gpuUsage { #expect((0...1).contains(gpu)) }
    }

    @Test("Audio device enumeration does not crash; the default output is a listed output")
    func audioOutputs() {
        let devices = AudioOutputs.all()
        if let current = AudioOutputs.defaultOutputID(), !devices.isEmpty {
            #expect(devices.contains { $0.id == current })
        }
    }
}
