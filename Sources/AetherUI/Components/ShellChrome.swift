import AppKit
import AetherCore
import SwiftUI

/// Full-bleed artwork behind a page, fading into obsidian. Exactly one is decoded at a time.
struct HeroBackdrop: View {
    let url: URL?
    let gameID: String?

    var body: some View {
        ZStack {
            if let url {
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

/// Key-cap style button hint: "Ⓐ ⏎  Play".
struct ControlHint: View {
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

/// Shown instead of the library while a Wine game runs: nothing image-backed stays mounted.
struct GameRunningView: View {
    let library: LibraryViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("GAME RUNNING")
                .font(AetherTheme.mono(13, weight: .bold))
                .tracking(4)
                .foregroundStyle(AetherTheme.cyan)
            Text(library.runningGameTitle ?? "")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(.white)
            Text("Launcher UI suspended to free memory. ⌂ / ⇧⌘G for Quick Access.")
                .font(AetherTheme.mono(12))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 12) {
                GhostButton(title: "Back to Library", systemImage: "square.grid.2x2") {
                    library.showLibraryDuringSession()
                }
                GhostButton(title: "Force Quit", systemImage: "xmark.octagon") {
                    Task { await library.forceQuitActiveGame() }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusToast: View {
    let message: String?

    var body: some View {
        VStack {
            Spacer()
            if let message {
                Text(message)
                    .font(AetherTheme.mono(12))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(AetherTheme.amber.opacity(0.5)))
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: message)
        .allowsHitTesting(false)
    }
}

/// Mono uppercase section label used across pages.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AetherTheme.mono(11, weight: .bold))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.45))
    }
}

// MARK: - Launcher building blocks

/// The big primary action: flat accent blue for every engine (the badge says how it runs).
struct PlayButton: View {
    let engine: ExecutionEngine?
    var isFocused = false
    var compact = false
    var isLaunching = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLaunching {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: engine == .cloudStream ? "icloud.fill" : "play.fill")
                        .font(.system(size: compact ? 13 : 16, weight: .bold))
                }
                Text(isLaunching ? "STARTING…" : label)
                    .font(.system(size: compact ? 13 : 17, weight: .heavy))
                    .tracking(1)
            }
            .foregroundStyle(Color.white.opacity(engine == nil ? 0.45 : 1))
            .padding(.horizontal, compact ? 18 : 34)
            .padding(.vertical, compact ? 9 : 15)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(engine == nil ? Color.white.opacity(0.08) : (isHovered ? AetherTheme.accentDeep : AetherTheme.accent))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? Color.white : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isFocused ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .disabled(engine == nil || isLaunching)
        .onHover { isHovered = $0 }
        .animation(AetherTheme.focusSpring, value: isHovered)
        .animation(AetherTheme.focusSpring, value: isFocused)
    }

    private var label: String {
        switch engine {
        case .cloudStream: "STREAM"
        case nil: "UNAVAILABLE"
        default: "PLAY"
        }
    }
}

/// Quiet secondary button (Details, Play Locally, Back).
struct GhostButton: View {
    let title: String
    let systemImage: String
    var isFocused = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.16 : 0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFocused ? Color.white : AetherTheme.hairline, lineWidth: isFocused ? 2 : 1)
                )
                .scaleEffect(isFocused ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AetherTheme.focusSpring, value: isFocused)
    }
}

/// "LAST PLAYED / 2 days ago" pair used in heroes and the game action bar.
struct StatPair: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AetherTheme.mono(10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
    }
}

/// Titled card surface for detail sections.
struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: title)
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AetherTheme.carbon, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AetherTheme.hairline))
    }
}

enum PlayStats {
    static func lastPlayed(_ record: PlayRecord?) -> String {
        record.map { $0.lastPlayed.formatted(.relative(presentation: .named)) } ?? "Never"
    }

    static func playTime(_ record: PlayRecord?) -> String {
        let seconds = record?.secondsPlayed ?? 0
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

/// "‹ Home" at the top of every secondary page: one click (or Ⓑ) back to the dashboard.
struct HomeBackButton: View {
    let shell: ShellCoordinator

    @State private var isHovered = false

    var body: some View {
        Button { shell.goHome() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                Text("Home").font(.system(size: 13, weight: .semibold))
                Text("Ⓑ / Esc").font(AetherTheme.mono(10)).foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(.white.opacity(isHovered ? 1 : 0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(isHovered ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(AetherTheme.hairline))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Always-visible exit for in-app cloud streams (top-left, compact so it doesn't cover the game).
struct StreamExitBar: View {
    let service: CloudService
    let shell: ShellCoordinator

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Button { shell.endStream() } label: {
                    Label("Library", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("End the stream and go back to the Home dashboard (⇧⌘W)")

                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 14)

                Text(service.displayName)
                    .font(AetherTheme.mono(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))

                Button { shell.toggleDrawer() } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Quick Access (⇧⌘G)")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(AetherTheme.hairline))
            .padding(.top, 12)
            .padding(.leading, 84) // clear of the window's traffic lights
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }
}

/// One picker for everything: a Windows .exe, one game's folder, or a whole folder / SSD of games.
@MainActor
enum GamePicker {
    static func chooseGamesLocation() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Volumes", directoryHint: .isDirectory)
        panel.message = "Choose a folder of Windows games (e.g. on your SSD), one game's folder, or a game's .exe."
        panel.prompt = "Add"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// "+ Add Games" button: opens the picker and hands the result to the library.
struct AddGamesButton: View {
    let library: LibraryViewModel

    var body: some View {
        GhostButton(title: "Add Games", systemImage: "plus") {
            guard let url = GamePicker.chooseGamesLocation() else { return }
            Task { await library.addGames(at: url) }
        }
        .help("Add a folder or SSD of Windows games, one game's folder, or a single .exe")
    }
}
