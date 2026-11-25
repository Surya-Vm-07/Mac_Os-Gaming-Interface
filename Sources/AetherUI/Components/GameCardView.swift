import AetherCore
import SwiftUI

/// Portrait cover tile. Hover lifts the card and shows a quick-play button; controller focus adds a
/// cyan rim. Below the cover: title plus a "how it runs" line.
public struct GameCardView: View {
    let game: GameItem
    let decision: RoutingDecision?
    let artworkURL: URL?
    let isFocused: Bool
    let onPlay: (() -> Void)?

    @State private var isHovered = false

    public init(game: GameItem, decision: RoutingDecision?, artworkURL: URL?, isFocused: Bool, onPlay: (() -> Void)? = nil) {
        self.game = game
        self.decision = decision
        self.artworkURL = artworkURL
        self.isFocused = isFocused
        self.onPlay = onPlay
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AetherTheme.cardCornerRadius, style: .continuous)
        let lifted = isHovered || isFocused

        VStack(alignment: .leading, spacing: 9) {
            // 264 pt tall at 2× ≈ 528 px. Decode no larger than that.
            ArtworkImage(url: artworkURL, maxPixelSize: 540, placeholderTitle: game.title)
                .frame(width: AetherTheme.cardSize.width, height: AetherTheme.cardSize.height)
                .clipShape(shape)
                .overlay(alignment: .bottom) {
                    // Sheen + quick play on hover / focus.
                    ZStack(alignment: .bottomTrailing) {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        if lifted, let onPlay, decision != nil {
                            Button(action: onPlay) {
                                Image(systemName: decision?.engine == .cloudStream ? "icloud.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(AetherTheme.tint(for: decision?.engine)))
                                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .clipShape(shape)
                    .opacity(lifted ? 1 : 0)
                }
                .overlay {
                    shape.strokeBorder(
                        isFocused ? AetherTheme.cyan : Color.white.opacity(isHovered ? 0.28 : 0.07),
                        lineWidth: isFocused ? 3 : 1
                    )
                }
                .shadow(
                    color: isFocused ? AetherTheme.cyan.opacity(0.4) : .black.opacity(lifted ? 0.6 : 0.35),
                    radius: lifted ? 20 : 8,
                    y: lifted ? 10 : 4
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(game.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(lifted ? Color.white : Color.white.opacity(0.8))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(AetherTheme.tint(for: decision?.engine))
                        .frame(width: 6, height: 6)
                    Text(decision?.engine.badgeLabel ?? "UNAVAILABLE")
                        .font(AetherTheme.mono(9.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: AetherTheme.cardSize.width, alignment: .leading)
        .scaleEffect(isFocused ? AetherTheme.focusScale : (isHovered ? 1.02 : 1))
        .offset(y: isHovered && !isFocused ? -4 : 0)
        .zIndex(lifted ? 1 : 0)
        .onHover { isHovered = $0 }
        .animation(AetherTheme.focusSpring, value: isFocused)
        .animation(AetherTheme.focusSpring, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isFocused ? [.isSelected, .isButton] : .isButton)
    }
}
