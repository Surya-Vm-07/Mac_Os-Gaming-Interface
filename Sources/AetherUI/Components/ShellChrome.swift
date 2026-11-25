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
            Button("Force Quit") {
                Task { await library.forceQuitActiveGame() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
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

/// The big primary action. Colour follows the engine: emerald native, cyan Wine, violet cloud.
struct PlayButton: View {
    let engine: ExecutionEngine?
    var isFocused = false
    var compact = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let tint = AetherTheme.tint(for: engine)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: engine == .cloudStream ? "icloud.fill" : "play.fill")
                    .font(.system(size: compact ? 13 : 16, weight: .bold))
                Text(label)
                    .font(.system(size: compact ? 13 : 17, weight: .heavy))
                    .tracking(1)
            }
            .foregroundStyle(Color.black.opacity(engine == nil ? 0.5 : 0.88))
            .padding(.horizontal, compact ? 18 : 34)
            .padding(.vertical, compact ? 9 : 15)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? Color.white : Color.white.opacity(isHovered ? 0.5 : 0.15), lineWidth: isFocused ? 2.5 : 1)
            )
            .shadow(color: tint.opacity(isHovered || isFocused ? 0.55 : 0.25), radius: isHovered || isFocused ? 22 : 10, y: 4)
            .brightness(isHovered ? 0.06 : 0)
            .scaleEffect(isFocused ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .disabled(engine == nil)
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
                        .strokeBorder(isFocused ? Color.white : AetherTheme.hairline, lineWidth: isFocused ? 2.5 : 1)
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
