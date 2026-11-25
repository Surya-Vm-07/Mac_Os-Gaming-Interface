import AetherCore
import SwiftUI

/// Game page: wide banner, Play / Play Locally / Back action bar, routing explanation, and stats.
/// Controller: ←/→ between actions, Ⓐ activates, Ⓑ back, Ⓧ plays directly.
struct GameDetailView: View {
    let shell: ShellCoordinator
    let game: GameItem

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        let decision = library.decision(for: game)
        let actions = shell.detailActions(for: game)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                banner

                HStack(spacing: 14) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        DetailActionButton(
                            action: action,
                            engine: decision?.engine,
                            isFocused: shell.zone == .content && index == shell.detailIndex
                        )
                        .onTapGesture { shell.perform(action, for: game) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 40)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ExecutionBadge(engine: decision?.engine)
                    Text(decision?.reason.description ?? "No engine can run this game on this Mac.")
                        .font(AetherTheme.mono(12))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 40)

                stats
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
            }
        }
        .task(id: game.id) {
            await library.loadArtwork(for: game, kinds: [.hero, .grid])
        }
    }

    // MARK: Banner

    private var banner: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(
                url: library.artwork[game.id]?[.hero] ?? library.artwork[game.id]?[.grid],
                maxPixelSize: 1920
            )
            .frame(maxWidth: .infinity)
            .frame(height: 360)

            LinearGradient(
                colors: [.clear, AetherTheme.obsidian.opacity(0.7), AetherTheme.obsidian],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)

            Text(game.title)
                .font(AetherTheme.heroTitle)
                .tracking(AetherTheme.heroTracking)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 40)
                .padding(.bottom, 10)
        }
        .frame(height: 360)
        .clipped()
    }

    // MARK: Stats

    private var stats: some View {
        let record = library.history.record(for: game.id)
        let profile = library.profile(for: game)

        return Grid(alignment: .leading, horizontalSpacing: 48, verticalSpacing: 18) {
            GridRow {
                StatCell(label: "LAST PLAYED", value: record.map { $0.lastPlayed.formatted(.relative(presentation: .named)) } ?? "Never")
                StatCell(label: "PLAY TIME", value: playTime(record?.secondsPlayed ?? 0))
                StatCell(label: "LAUNCHES", value: "\(record?.launches ?? 0)")
            }
            GridRow {
                StatCell(label: "SOURCE", value: sourceLabel)
                StatCell(label: "LOCAL REQUIREMENT", value: requirementLabel(profile))
                StatCell(label: "THIS MAC", value: "TIER \(library.hardware.tier.rawValue) · \(library.hardware.totalMemoryGB) GB")
            }
            if let location = (game.installation.nativeApplication ?? game.installation.windowsExecutable ?? game.installDirectory) {
                GridRow {
                    StatCell(label: "LOCATION", value: location.path(percentEncoded: false))
                        .gridCellColumns(3)
                }
            }
        }
        .padding(22)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sourceLabel: String {
        switch game.source {
        case .steam(let appID): "Steam · \(appID)"
        case .macApplication: "macOS app"
        case .customFolder: "Custom folder"
        }
    }

    private func requirementLabel(_ profile: GameProfile) -> String {
        if profile.hasKernelAnticheat { return "Cloud only (kernel anti-cheat)" }
        if profile.minLocalTier > HardwareTier.ultra.rawValue { return "Cloud only" }
        return "TIER \(profile.minLocalTier)+"
    }

    private func playTime(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

private struct StatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: label)
            Text(value)
                .font(AetherTheme.mono(13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct DetailActionButton: View {
    let action: DetailAction
    let engine: ExecutionEngine?
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(label)
                .font(.system(size: 16, weight: .heavy))
                .tracking(0.5)
        }
        .padding(.horizontal, isPrimary ? 34 : 22)
        .padding(.vertical, 14)
        .foregroundStyle(isPrimary ? Color.black : Color.white)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPrimary ? AetherTheme.tint(for: engine) : Color.white.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? Color.white : Color.clear, lineWidth: 2.5)
        )
        .shadow(color: isFocused ? AetherTheme.tint(for: engine).opacity(0.5) : .clear, radius: 16)
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(AetherTheme.focusSpring, value: isFocused)
        .contentShape(Rectangle())
    }

    private var isPrimary: Bool { action == .play }

    private var label: String {
        switch action {
        case .play:
            if engine == nil { return "UNAVAILABLE" }
            return engine == .cloudStream ? "STREAM" : "PLAY"
        case .playLocally:
            return "PLAY LOCALLY"
        case .back:
            return "BACK"
        }
    }

    private var icon: String {
        switch action {
        case .play: engine == .cloudStream ? "icloud.fill" : "play.fill"
        case .playLocally: "desktopcomputer"
        case .back: "chevron.left"
        }
    }
}
