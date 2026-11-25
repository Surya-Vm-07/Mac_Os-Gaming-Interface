import AetherCore
import SwiftUI

/// Home page: focused-game header over a crossfading hero, a Recently Played shelf, and the full
/// cover grid. Ⓐ / click opens the game page; Ⓧ quick-plays.
struct LibraryHomeView: View {
    let shell: ShellCoordinator

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HeroBackdrop(
                url: library.focusedGame.flatMap { library.artwork[$0.id]?[.hero] ?? library.artwork[$0.id]?[.grid] },
                gameID: library.focusedGame?.id
            )
            VStack(alignment: .leading, spacing: 24) {
                HeroHeader(
                    game: library.focusedGame,
                    decision: library.focusedGame.flatMap { library.decision(for: $0) },
                    hardwareSummary: library.hardwareSummary,
                    isScanning: library.isScanning
                )
                if !library.recentGames.isEmpty {
                    RecentShelf(shell: shell)
                }
                SectionLabel(text: "ALL GAMES · \(library.games.count)")
                LibraryGrid(shell: shell)
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
        }
        .task(id: library.focusedGame?.id) {
            if let game = library.focusedGame {
                await library.loadArtwork(for: game, kinds: [.hero])
            }
        }
    }
}

// MARK: - Header

private struct HeroHeader: View {
    let game: GameItem?
    let decision: RoutingDecision?
    let hardwareSummary: String
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
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
                ControlHint(key: "Ⓐ ⏎", label: "Open")
                ControlHint(key: "Ⓧ ⇧⏎", label: "Quick play")
                ControlHint(key: "⌘F", label: "Search")
                ControlHint(key: "⌂ ⇧⌘G", label: "Quick Access")
            }
            .padding(.top, 2)
        }
        .padding(26)
        .frame(maxWidth: 780, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08))
        }
        .animation(AetherTheme.heroCrossfade, value: game?.id)
    }
}

// MARK: - Recently played

private struct RecentShelf: View {
    let shell: ShellCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "RECENTLY PLAYED")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(shell.library.recentGames) { game in
                        VStack(alignment: .leading, spacing: 6) {
                            // 120 pt tall at 2× = 240 px. Decode no larger than that.
                            ArtworkImage(url: shell.library.artwork[game.id]?[.grid], maxPixelSize: 240, placeholderTitle: game.title)
                                .frame(width: 80, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(game.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .frame(width: 80, alignment: .leading)
                        }
                        .onTapGesture { shell.openGame(game) }
                        .task { await shell.library.loadArtwork(for: game, kinds: [.grid]) }
                    }
                }
            }
        }
    }
}

// MARK: - Grid

private struct LibraryGrid: View {
    let shell: ShellCoordinator

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(AetherTheme.cardSize.width), spacing: AetherTheme.gridSpacing),
                        count: max(library.columns, 1)
                    ),
                    alignment: .leading,
                    spacing: 40
                ) {
                    ForEach(Array(library.games.enumerated()), id: \.element.id) { index, game in
                        GameCardView(
                            game: game,
                            decision: library.decision(for: game),
                            artworkURL: library.artwork[game.id]?[.grid],
                            isFocused: shell.zone == .content && index == library.focusedIndex
                        )
                        .id(game.id)
                        .onTapGesture { shell.openGame(game) }
                        .task { await library.loadArtwork(for: game, kinds: [.grid]) }
                    }
                }
                .padding(.horizontal, AetherTheme.gridInset)
                .padding(.vertical, 28) // room for the focus scale and glow
            }
            .onChange(of: library.focusedIndex) { _, index in
                guard library.games.indices.contains(index) else { return }
                withAnimation(AetherTheme.focusSpring) {
                    proxy.scrollTo(library.games[index].id, anchor: .center)
                }
            }
        }
        .onGeometryChange(for: Int.self) { geometry in
            AetherTheme.columns(forWidth: geometry.size.width)
        } action: { columns in
            library.columns = columns
        }
    }
}
