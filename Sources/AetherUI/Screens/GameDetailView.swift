import AetherCore
import SwiftUI

/// Game page: wide banner with the title, an action bar (Play / Play Locally / Back plus stats),
/// then two panels: "How it runs" (engine, reason, performance preset) and "Details".
/// Controller: ←/→ between actions, Ⓐ activates, Ⓧ plays, Ⓑ back.
struct GameDetailView: View {
    let shell: ShellCoordinator
    let game: GameItem

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        let decision = library.decision(for: game)
        let record = library.history.record(for: game.id)
        let actions = shell.detailActions(for: game)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                banner

                // Action bar
                HStack(spacing: 14) {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        let focused = shell.zone == .content && index == shell.detailIndex
                        switch action {
                        case .play:
                            PlayButton(engine: decision?.engine, isFocused: focused) { shell.perform(.play, for: game) }
                        case .playLocally:
                            GhostButton(title: "Play Locally", systemImage: "desktopcomputer", isFocused: focused) {
                                shell.perform(.playLocally, for: game)
                            }
                        case .back:
                            GhostButton(title: "Back", systemImage: "chevron.left", isFocused: focused) {
                                shell.perform(.back, for: game)
                            }
                        }
                    }

                    Rectangle().fill(AetherTheme.hairline).frame(width: 1, height: 40).padding(.horizontal, 8)

                    StatPair(label: "LAST PLAYED", value: PlayStats.lastPlayed(record))
                    StatPair(label: "PLAY TIME", value: PlayStats.playTime(record))
                    StatPair(label: "LAUNCHES", value: "\(record?.launches ?? 0)")

                    Spacer(minLength: 12)
                    ExecutionBadge(engine: decision?.engine)
                }
                .padding(.horizontal, AetherTheme.pageMargin)
                .padding(.vertical, 18)
                .background(AetherTheme.carbon.opacity(0.85))
                .overlay(alignment: .top) { Rectangle().fill(AetherTheme.hairline).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(AetherTheme.hairline).frame(height: 1) }

                // Panels
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        howItRuns
                        details.frame(width: 360)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        howItRuns
                        details
                    }
                }
                .padding(.horizontal, AetherTheme.pageMargin)
                .padding(.vertical, 30)
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
                maxPixelSize: 1920,
                placeholderSeed: game.title
            )
            .frame(maxWidth: .infinity)
            .frame(height: 380)
            .clipped()

            LinearGradient(
                colors: [.clear, AetherTheme.obsidian.opacity(0.35), AetherTheme.obsidian.opacity(0.95)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 22) {
                // Small cover, like a store capsule next to the title.
                ArtworkImage(url: library.artwork[game.id]?[.grid], maxPixelSize: 360, placeholderTitle: game.title)
                    .frame(width: 120, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text(sourceLabel.uppercased())
                        .font(AetherTheme.mono(11, weight: .bold))
                        .tracking(2.5)
                        .foregroundStyle(AetherTheme.cyan)
                    Text(game.title)
                        .font(.system(size: 50, weight: .heavy))
                        .tracking(-1.5)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                }
            }
            .padding(.horizontal, AetherTheme.pageMargin)
            .padding(.bottom, 26)
        }
        .frame(height: 380)
        .clipped()
    }

    // MARK: Panels

    private var howItRuns: some View {
        let decision = library.decision(for: game)
        return Panel(title: "HOW IT RUNS") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ExecutionBadge(engine: decision?.engine)
                Text(decision?.reason.description ?? "No engine can run this game on this Mac.")
                    .font(AetherTheme.mono(12))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if game.installation.windowsExecutable != nil {
                Divider().overlay(AetherTheme.hairline)
                presetPicker
            }
        }
    }

    private var details: some View {
        let profile = library.profile(for: game)
        let location = game.installation.nativeApplication ?? game.installation.windowsExecutable ?? game.installDirectory
        return Panel(title: "DETAILS") {
            DetailRow(label: "SOURCE", value: sourceLabel)
            DetailRow(label: "REQUIREMENT", value: requirementLabel(profile))
            DetailRow(label: "THIS MAC", value: "Tier \(library.hardware.tier.rawValue) · \(library.hardware.totalMemoryGB) GB")
            if let location {
                DetailRow(label: "LOCATION", value: location.path(percentEncoded: false))
            }
        }
    }

    /// Per-game performance preset (Windows games). Presets whose graphics stack is not installed
    /// stay listed but marked, so the user sees what the setup wizard would unlock.
    private var presetPicker: some View {
        let current = library.preset(for: game)
        let selection = Binding<PerformancePreset>(
            get: { library.preset(for: game) },
            set: { library.setPreset($0, for: game) }
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SectionLabel(text: "PERFORMANCE PRESET")
                Spacer()
                if let base = library.wineBase {
                    Text("\(base.name) \(base.version)")
                        .font(AetherTheme.mono(10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Picker("Preset", selection: selection) {
                ForEach(PerformancePreset.allCases) { preset in
                    Text(library.isAvailable(preset, for: game) ? preset.displayName : "\(preset.displayName) (not installed)")
                        .tag(preset)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 300, alignment: .leading)
            Text(current.summary)
                .font(AetherTheme.mono(11))
                .foregroundStyle(.white.opacity(0.6))
            if !library.isAvailable(current, for: game) {
                Text("This preset's graphics stack isn't installed. Run the setup wizard, or pick another preset.")
                    .font(AetherTheme.mono(11, weight: .bold))
                    .foregroundStyle(AetherTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceLabel: String {
        switch game.source {
        case .steam(let appID): "Steam · \(appID)"
        case .macApplication: "Mac app"
        case .customFolder: "Aether Games folder"
        }
    }

    private func requirementLabel(_ profile: GameProfile) -> String {
        if profile.hasKernelAnticheat { return "Cloud only (kernel anti-cheat)" }
        if profile.minLocalTier > HardwareTier.ultra.rawValue { return "Cloud only" }
        return "Tier \(profile.minLocalTier)+ for local play"
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AetherTheme.mono(10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(AetherTheme.mono(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
