import AetherCore
import SwiftUI

/// Right-hand glass panel: session, live telemetry, Metal HUD, audio output, force quit.
/// Fully navigable with ↑/↓ + Ⓐ, closed with Ⓑ or ⌂.
public struct QuickOverlayDrawer: View {
    let drawer: QuickDrawerModel

    public init(drawer: QuickDrawerModel) {
        self.drawer = drawer
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 22) {
                header
                TelemetryPanel(snapshot: drawer.telemetry)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(drawer.rows.enumerated()), id: \.element) { index, row in
                        DrawerRow(
                            title: title(for: row),
                            detail: detail(for: row),
                            tint: tint(for: row),
                            isFocused: index == drawer.focusedRow
                        )
                        .onTapGesture {
                            drawer.focus(index)
                            Task { await drawer.activateFocused() }
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("↑↓ select   Ⓐ ⏎ confirm   Ⓑ esc close")
                    .font(AetherTheme.mono(10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(26)
            .frame(width: 380)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.ultraThinMaterial)
            .overlay(alignment: .leading) {
                Rectangle().fill(AetherTheme.cyan.opacity(0.35)).frame(width: 1)
            }
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUICK ACCESS")
                .font(AetherTheme.mono(12, weight: .bold))
                .tracking(4)
                .foregroundStyle(AetherTheme.cyan)
            Text(drawer.sessionTitle ?? "No active game")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    // MARK: Row content

    private func title(for row: QuickDrawerModel.Row) -> String {
        switch row {
        case .metalHUD: "Metal Performance HUD"
        case .audio(let id): drawer.audioDevices.first { $0.id == id }?.name ?? "Audio device"
        case .library: "Go to Library"
        case .endStream: "End Cloud Stream"
        case .forceQuit: "Force Quit Game"
        case .close: drawer.sessionTitle == nil ? "Close" : "Return to Game"
        }
    }

    private func detail(for row: QuickDrawerModel.Row) -> String? {
        switch row {
        case .metalHUD: drawer.metalHUDEnabled ? "ON · next launch" : "OFF"
        case .audio(let id): id == drawer.defaultOutputID ? "OUTPUT ●" : nil
        case .library: drawer.sessionTitle == nil ? nil : "GAME KEEPS RUNNING"
        case .endStream, .forceQuit, .close: nil
        }
    }

    private func tint(for row: QuickDrawerModel.Row) -> Color {
        switch row {
        case .forceQuit: .red
        case .endStream: AetherTheme.amber
        case .audio(let id) where id == drawer.defaultOutputID: AetherTheme.emerald
        case .metalHUD where drawer.metalHUDEnabled: AetherTheme.cyan
        default: .white
        }
    }
}

private struct DrawerRow: View {
    let title: String
    let detail: String?
    let tint: Color
    let isFocused: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint == .white ? Color.white : tint)
                .lineLimit(1)
            Spacer()
            if let detail {
                Text(detail)
                    .font(AetherTheme.mono(10, weight: .bold))
                    .foregroundStyle(tint.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFocused ? Color.white.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? AetherTheme.cyan : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(AetherTheme.focusSpring, value: isFocused)
        .contentShape(Rectangle())
    }
}

private struct TelemetryPanel: View {
    let snapshot: TelemetrySnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Meter(label: "CPU", fraction: snapshot?.cpuUsage, text: percent(snapshot?.cpuUsage))
            Meter(label: "GPU", fraction: snapshot?.gpuUsage, text: percent(snapshot?.gpuUsage))
            Meter(label: "RAM", fraction: snapshot?.memoryUsedFraction, text: memoryText, tint: pressureTint)
            HStack(spacing: 14) {
                stat("SWAP", snapshot.map { gigabytes($0.swapUsedBytes) } ?? "--")
                stat("PRESSURE", snapshot?.memoryPressure.rawValue.uppercased() ?? "--", tint: pressureTint)
                stat("THERMAL", snapshot?.thermal.rawValue.uppercased() ?? "--", tint: thermalTint)
            }
        }
        .padding(16)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var memoryText: String {
        guard let snapshot else { return "--" }
        return "\(gigabytes(snapshot.memoryUsedBytes)) / \(gigabytes(snapshot.memoryTotalBytes))"
    }

    private var pressureTint: Color {
        switch snapshot?.memoryPressure {
        case .warning: AetherTheme.amber
        case .critical: .red
        default: AetherTheme.emerald
        }
    }

    private var thermalTint: Color {
        switch snapshot?.thermal {
        case .fair: AetherTheme.amber
        case .serious, .critical: .red
        default: AetherTheme.emerald
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private func stat(_ label: String, _ value: String, tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AetherTheme.mono(9)).foregroundStyle(.white.opacity(0.45))
            Text(value).font(AetherTheme.mono(11, weight: .bold)).foregroundStyle(tint)
        }
    }
}

private struct Meter: View {
    let label: String
    let fraction: Double?
    let text: String
    var tint: Color = AetherTheme.cyan

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(AetherTheme.mono(10, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 32, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: 6)
            Text(text)
                .font(AetherTheme.mono(10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 92, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}
