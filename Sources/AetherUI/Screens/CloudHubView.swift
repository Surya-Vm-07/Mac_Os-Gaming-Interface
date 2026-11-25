import AetherCore
import SwiftUI

/// Cloud Gaming page: one card per service. Ⓐ streams inside Aether, Ⓧ sets the default service
/// for cloud-routed games, Ⓨ opens the vendor's native app when installed.
struct CloudHubView: View {
    let shell: ShellCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CLOUD GAMING")
                    .font(AetherTheme.mono(12, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(AetherTheme.violet)
                Text("AAA at 60 FPS. Zero install.")
                    .font(.system(size: 44, weight: .heavy))
                    .tracking(-1.2)
                    .foregroundStyle(.white)
                Text("Games run on remote GPUs; this Mac only decodes video. About 300 MB of RAM, cool and quiet, on any tier.")
                    .font(AetherTheme.mono(12))
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack(alignment: .top, spacing: 24) {
                ForEach(Array(CloudService.allCases.enumerated()), id: \.element) { index, service in
                    CloudServiceCard(
                        service: service,
                        isDefault: shell.defaultCloudService == service,
                        isFocused: shell.zone == .content && index == shell.cloudIndex
                    )
                    .onTapGesture { shell.startStream(service) }
                }
            }

            HStack(spacing: 20) {
                ControlHint(key: "Ⓐ ⏎", label: "Stream")
                ControlHint(key: "Ⓧ ⇧⏎", label: "Set as default")
                ControlHint(key: "Ⓨ", label: "Open native app")
                ControlHint(key: "⌂ ⇧⌘G", label: "End stream")
            }

            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RadialGradient(
                colors: [AetherTheme.violet.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 700
            )
        )
    }
}

private struct CloudServiceCard: View {
    let service: CloudService
    let isDefault: Bool
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "icloud.and.arrow.down.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AetherTheme.violet)
                Spacer()
                if isDefault {
                    Text("DEFAULT")
                        .font(AetherTheme.mono(10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(AetherTheme.violet)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(AetherTheme.violet.opacity(0.6)))
                }
            }
            Text(service.displayName)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(.white)
            Text(service.tagline)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Text(service.requirement)
                .font(AetherTheme.mono(11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            if service.nativeAppURL != nil {
                Text("NATIVE APP INSTALLED · Ⓨ")
                    .font(AetherTheme.mono(10, weight: .bold))
                    .foregroundStyle(AetherTheme.emerald)
            }
        }
        .padding(24)
        .frame(width: 360, alignment: .topLeading)
        .frame(minHeight: 240, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isFocused ? AetherTheme.cyan : Color.white.opacity(0.08), lineWidth: isFocused ? 2 : 1)
        )
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(AetherTheme.focusSpring, value: isFocused)
        .contentShape(Rectangle())
    }
}
