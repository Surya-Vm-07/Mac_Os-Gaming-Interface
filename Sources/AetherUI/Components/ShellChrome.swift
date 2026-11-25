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
