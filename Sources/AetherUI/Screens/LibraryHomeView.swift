import AetherCore
import SwiftUI

/// Home: full-bleed featured hero for the focused game (Play, Details, stats), filter pills,
/// a Recently Played shelf, then the cover grid. Everything scrolls as one page.
struct LibraryHomeView: View {
    let shell: ShellCoordinator

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    FeaturedHero(shell: shell, game: library.focusedGame)
                        .id("hero")

                    VStack(alignment: .leading, spacing: 30) {
                        FilterBar(library: library)

                        if library.filter == .all, !library.recentGames.isEmpty {
                            RecentShelf(shell: shell)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            SectionLabel(text: "\(library.filter.title.uppercased()) · \(library.visibleGames.count)")
                            if library.visibleGames.isEmpty {
                                EmptyLibraryNote(filter: library.filter)
                                if library.filter == .all || library.filter == .windows {
                                    AddGamesButton(library: library)
                                }
                            } else {
                                CoverGrid(shell: shell)
                            }
                        }
                    }
                    .padding(.horizontal, AetherTheme.pageMargin)
                    .padding(.top, 26)
                    .padding(.bottom, 60)
                }
            }
            .onChange(of: library.focusedIndex) { _, index in
                let visible = library.visibleGames
                guard visible.indices.contains(index) else { return }
                withAnimation(AetherTheme.focusSpring) {
                    // Top row: show the hero too. Further down: centre the focused card.
                    if index < library.columns {
                        proxy.scrollTo("hero", anchor: .top)
                    } else {
                        proxy.scrollTo(visible[index].id, anchor: .center)
                    }
                }
            }
        }
        // Columns come from the page width (not the grid's own width), so the grid can never
        // grow wider than the window.
        .onGeometryChange(for: Int.self) { geometry in
            AetherTheme.columns(forWidth: geometry.size.width - AetherTheme.pageMargin * 2)
        } action: { columns in
            library.columns = columns
        }
        .task(id: library.focusedGame?.id) {
            if let game = library.focusedGame {
                await library.loadArtwork(for: game, kinds: [.hero, .grid])
            }
        }
    }
}

// MARK: - Featured hero

private struct FeaturedHero: View {
    let shell: ShellCoordinator
    let game: GameItem?

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        let decision = game.flatMap { library.decision(for: $0) }
        let record = game.flatMap { library.history.record(for: $0.id) }

        ZStack(alignment: .bottomLeading) {
            ArtworkImage(
                url: game.flatMap { library.artwork[$0.id]?[.hero] ?? library.artwork[$0.id]?[.grid] },
                maxPixelSize: 1920,
                placeholderSeed: game?.title ?? "Aether"
            )
            .id(game?.id)
            .transition(.opacity)
            .frame(maxWidth: .infinity)
            .frame(height: AetherTheme.heroHeight)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                // The banner itself is a Play button.
                if let game { Task { await shell.play(game, preference: .automatic) } }
            }

            // Readability: dark from the left (text side) and fade into the page at the bottom.
            LinearGradient(
                stops: [
                    .init(color: AetherTheme.obsidian.opacity(0.92), location: 0),
                    .init(color: AetherTheme.obsidian.opacity(0.55), location: 0.45),
                    .init(color: .clear, location: 0.8),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                colors: [.clear, .clear, AetherTheme.obsidian],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(game == nil ? "AETHER" : "FEATURED")
                        .font(AetherTheme.mono(11, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(AetherTheme.cyan)
                    Text(library.hardwareSummary)
                        .font(AetherTheme.mono(11))
                        .foregroundStyle(.white.opacity(0.5))
                    if library.isScanning {
                        ProgressView().controlSize(.small)
                    }
                }

                Text(game?.title ?? "Your library is empty")
                    .font(.system(size: 54, weight: .heavy))
                    .tracking(-1.6)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)

                if let game {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ExecutionBadge(engine: decision?.engine)
                        if decision?.engine == .localTranslation {
                            Text(library.preset(for: game).displayName.uppercased())
                                .font(AetherTheme.mono(10, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.white.opacity(0.1)))
                        }
                        Text(decision?.reason.description ?? "No engine can run this game on this Mac.")
                            .font(AetherTheme.mono(11))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }

                    HStack(spacing: 28) {
                        StatPair(label: "LAST PLAYED", value: PlayStats.lastPlayed(record))
                        StatPair(label: "PLAY TIME", value: PlayStats.playTime(record))
                        StatPair(label: "LAUNCHES", value: "\(record?.launches ?? 0)")
                    }
                    .padding(.top, 2)

                    HStack(spacing: 12) {
                        PlayButton(engine: decision?.engine, isLaunching: library.launchingGameID == game.id) {
                            Task { await shell.play(game, preference: .automatic) }
                        }
                        GhostButton(title: "Details", systemImage: "info.circle") {
                            shell.openGame(game)
                        }
                    }
                    .padding(.top, 6)
                } else {
                    Text("Add your Windows games (a folder, an SSD, or one .exe). Then click a cover to play.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    AddGamesButton(library: library)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, AetherTheme.pageMargin)
            .padding(.bottom, 34)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(height: AetherTheme.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(AetherTheme.heroCrossfade, value: game?.id)
    }
}

// MARK: - Filters

private struct FilterBar: View {
    let library: LibraryViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(LibraryFilter.allCases) { filter in
                FilterPill(
                    title: filter.title,
                    count: library.count(for: filter),
                    isSelected: library.filter == filter
                ) {
                    library.filter = filter
                }
            }
            Spacer(minLength: 12)
            AddGamesButton(library: library)
            ControlHint(key: "Ⓐ ⏎", label: "Play")
            ControlHint(key: "Ⓧ ⇧⏎", label: "Details")
            ControlHint(key: "LB RB  [ ]", label: "Switch")
            ControlHint(key: "⌂ ⇧⌘G", label: "Quick Access")
        }
    }
}

private struct FilterPill: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(count)")
                    .font(AetherTheme.mono(10, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? Color.white : Color.white.opacity(isHovered ? 0.14 : 0.07))
            )
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : AetherTheme.hairline))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Recently played

private struct RecentShelf: View {
    let shell: ShellCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "RECENTLY PLAYED")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(shell.library.recentGames) { game in
                        RecentTile(shell: shell, game: game)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

/// Wide tile: cover thumbnail + title + last played, like a "continue playing" row.
private struct RecentTile: View {
    let shell: ShellCoordinator
    let game: GameItem

    @State private var isHovered = false

    var body: some View {
        let record = shell.library.history.record(for: game.id)
        HStack(spacing: 12) {
            ArtworkImage(url: shell.library.artwork[game.id]?[.grid], maxPixelSize: 200, placeholderSeed: game.title)
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(PlayStats.lastPlayed(record))
                    .font(AetherTheme.mono(10))
                    .foregroundStyle(.white.opacity(0.5))
                ExecutionBadge(engine: shell.library.decision(for: game)?.engine)
                    .scaleEffect(0.85, anchor: .leading)
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? AetherTheme.carbonHigh : AetherTheme.carbon)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AetherTheme.hairline))
        .overlay {
            if shell.library.launchingGameID == game.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.5))
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .onHover { isHovered = $0 }
        .onTapGesture { Task { await shell.play(game, preference: .automatic) } }
        .contextMenu {
            Button("Play") { Task { await shell.play(game, preference: .automatic) } }
            Button("Details") { shell.openGame(game) }
        }
        .task { await shell.library.loadArtwork(for: game, kinds: [.grid]) }
    }
}

// MARK: - Grid

private struct CoverGrid: View {
    let shell: ShellCoordinator

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(AetherTheme.cardSize.width), spacing: AetherTheme.gridSpacing, alignment: .top),
                count: max(library.columns, 1)
            ),
            alignment: .leading,
            spacing: 30
        ) {
            ForEach(Array(library.visibleGames.enumerated()), id: \.element.id) { index, game in
                GameCardView(
                    game: game,
                    decision: library.decision(for: game),
                    artworkURL: library.artwork[game.id]?[.grid],
                    isFocused: shell.zone == .content && index == library.focusedIndex,
                    isLaunching: library.launchingGameID == game.id,
                    onDetails: { shell.openGame(game) }
                )
                .id(game.id)
                .onTapGesture {
                    library.focus(index)
                    Task { await shell.play(game, preference: .automatic) }
                }
                .contextMenu {
                    Button("Play") { Task { await shell.play(game, preference: .automatic) } }
                    Button("Play Locally (low spec)") { Task { await shell.play(game, preference: .preferLocal) } }
                    Button("Details") { shell.openGame(game) }
                }
                .task { await library.loadArtwork(for: game, kinds: [.grid]) }
            }
        }
        .padding(AetherTheme.gridInset)
        .padding(.horizontal, -AetherTheme.gridInset) // inset is only room for the focus glow
    }
}

private struct EmptyLibraryNote: View {
    let filter: LibraryFilter

    var body: some View {
        Text(filter == .all
             ? "No games yet. Click Add Games and choose your SSD or games folder. Each game becomes a cover you click to play."
             : filter == .windows
                ? "No Windows games yet. Add Games → pick the folder (or SSD) that holds them."
                : "No \(filter.title.lowercased()) games.")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.vertical, 30)
    }
}
