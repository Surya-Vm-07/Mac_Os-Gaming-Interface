import AetherCore
import AppKit
import Combine
import SwiftUI

/// Console-style home: crossfading hero backdrop, glass header for the focused game, cover grid.
///
/// Input is routed by `RootView` / `ShellCoordinator`. Keyboard and controller share one path.
public struct LibraryHomeView: View {
    let model: LibraryViewModel

    public init(model: LibraryViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            AetherTheme.obsidian.ignoresSafeArea()

            if model.isGameRunning {
                // Nothing image-backed stays in the hierarchy while a game runs.
                GameRunningView(model: model)
            } else {
                HeroBackdrop(
                    url: model.focusedGame.flatMap { model.artwork[$0.id]?[.hero] ?? model.artwork[$0.id]?[.grid] },
                    gameID: model.focusedGame?.id
                )
                VStack(alignment: .leading, spacing: 28) {
                    HeroHeader(
                        game: model.focusedGame,
                        decision: model.focusedDecision,
                        hardwareSummary: model.hardwareSummary,
                        isScanning: model.isScanning
                    )
                    LibraryGrid(model: model)
                }
                .padding(.horizontal, 48)
                .padding(.top, 44)
            }

            StatusToast(message: model.statusMessage)
        }
        .preferredColorScheme(.dark)
        .task(id: model.focusedGame?.id) {
            if let game = model.focusedGame {
                await model.loadArtwork(for: game, kinds: [.hero])
            }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Aether in the background (a game is fullscreen) → drop decoded artwork.
            ImagePipeline.shared.purge()
        }
    }
}

// MARK: - Grid

private struct LibraryGrid: View {
    let model: LibraryViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(AetherTheme.cardSize.width), spacing: AetherTheme.gridSpacing),
                        count: max(model.columns, 1)
                    ),
                    alignment: .leading,
                    spacing: 40
                ) {
                    ForEach(Array(model.games.enumerated()), id: \.element.id) { index, game in
                        GameCardView(
                            game: game,
                            decision: model.decisions[game.id],
                            artworkURL: model.artwork[game.id]?[.grid],
                            isFocused: index == model.focusedIndex
                        )
                        .id(game.id)
                        .onTapGesture(count: 2) {
                            model.focus(index)
                            Task { await model.playFocused() }
                        }
                        .onTapGesture { model.focus(index) }
                        .task { await model.loadArtwork(for: game, kinds: [.grid]) }
                    }
                }
                .padding(.horizontal, AetherTheme.gridInset)
                .padding(.vertical, 28) // room for the focus scale and glow
            }
            .onChange(of: model.focusedIndex) { _, index in
                guard model.games.indices.contains(index) else { return }
                withAnimation(AetherTheme.focusSpring) {
                    proxy.scrollTo(model.games[index].id, anchor: .center)
                }
            }
        }
        .onGeometryChange(for: Int.self) { geometry in
            AetherTheme.columns(forWidth: geometry.size.width)
        } action: { columns in
            model.columns = columns
        }
    }
}

// MARK: - Hero

private struct HeroBackdrop: View {
    let url: URL?
    let gameID: String?

    var body: some View {
        ZStack {
            if let url {
                // One wide hero at window size; replaced (not accumulated) on focus change.
                ArtworkImage(url: url, maxPixelSize: 1920)
                    .id(gameID)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: AetherTheme.obsidian.opacity(0.25), location: 0),
                    .init(color: AetherTheme.obsidian.opacity(0.85), location: 0.45),
                    .init(color: AetherTheme.obsidian, location: 0.75),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(AetherTheme.heroCrossfade, value: gameID)
    }
}

private struct HeroHeader: View {
    let game: GameItem?
    let decision: RoutingDecision?
    let hardwareSummary: String
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("AETHER")
                    .font(AetherTheme.mono(13, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(AetherTheme.cyan)
                Text(hardwareSummary)
                    .font(AetherTheme.mono(11))
                    .foregroundStyle(.white.opacity(0.5))
                if isScanning {
                    ProgressView().controlSize(.small)
                }
            }

            Text(game?.title ?? "Library")
                .font(AetherTheme.heroTitle)
                .tracking(AetherTheme.heroTracking)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white)
                .contentTransition(.opacity)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ExecutionBadge(engine: decision?.engine)
                if let decision {
                    Text(decision.reason.description)
                        .font(AetherTheme.mono(12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }

            HStack(spacing: 20) {
                ControlHint(key: "Ⓐ ⏎", label: "Play")
                if decision?.allowLocalOverride == true {
                    ControlHint(key: "Ⓧ ⇧⏎", label: "Play locally")
                }
                ControlHint(key: "Ⓨ R", label: "Rescan")
                ControlHint(key: "⌂ ⇧⌘G", label: "Quick Access")
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 780, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08))
        }
        .animation(AetherTheme.heroCrossfade, value: game?.id)
    }
}

private struct ControlHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(AetherTheme.mono(11, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            Text(label)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.75))
    }
}

// MARK: - Overlays

private struct GameRunningView: View {
    let model: LibraryViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("GAME RUNNING")
                .font(AetherTheme.mono(13, weight: .bold))
                .tracking(4)
                .foregroundStyle(AetherTheme.cyan)
            Text(model.runningGameTitle ?? "")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(.white)
            Text("Launcher UI suspended to free memory.")
                .font(AetherTheme.mono(12))
                .foregroundStyle(.white.opacity(0.5))
            Button("Force Quit") {
                Task { await model.forceQuitActiveGame() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.top, 8)
        }
    }
}

private struct StatusToast: View {
    let message: String?

    var body: some View {
        VStack {
            Spacer()
            if let message {
                Text(message)
                    .font(AetherTheme.mono(12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(AetherTheme.amber.opacity(0.5)))
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: message)
        .allowsHitTesting(false)
    }
}
