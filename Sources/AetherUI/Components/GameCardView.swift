import AetherCore
import SwiftUI

/// Portrait cover card with an execution badge. Focus: scale up, cyan rim and glow, title brightens.
public struct GameCardView: View {
    let game: GameItem
    let decision: RoutingDecision?
    let artworkURL: URL?
    let isFocused: Bool

    public init(game: GameItem, decision: RoutingDecision?, artworkURL: URL?, isFocused: Bool) {
        self.game = game
        self.decision = decision
        self.artworkURL = artworkURL
        self.isFocused = isFocused
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AetherTheme.cardCornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            // 300 pt tall at 2× = 600 px. Decode no larger than that.
            ArtworkImage(url: artworkURL, maxPixelSize: 600, placeholderTitle: game.title)
                .frame(width: AetherTheme.cardSize.width, height: AetherTheme.cardSize.height)
                .clipShape(shape)
                .overlay(alignment: .topLeading) {
                    ExecutionBadge(engine: decision?.engine).padding(10)
                }
                .overlay {
                    shape.strokeBorder(
                        isFocused ? AetherTheme.cyan : Color.white.opacity(0.08),
                        lineWidth: isFocused ? 3 : 1
                    )
                }
                .shadow(color: isFocused ? AetherTheme.cyan.opacity(0.45) : .black.opacity(0.4),
                        radius: isFocused ? 22 : 8, y: isFocused ? 0 : 6)

            Text(game.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.55))
        }
        .frame(width: AetherTheme.cardSize.width, alignment: .leading)
        .scaleEffect(isFocused ? AetherTheme.focusScale : 1)
        .zIndex(isFocused ? 1 : 0)
        .animation(AetherTheme.focusSpring, value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isFocused ? [.isSelected, .isButton] : .isButton)
    }
}
