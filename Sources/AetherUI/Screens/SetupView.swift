import AetherCore
import SwiftUI

/// Engine Setup: everything needed to run Windows games for $0, in one page.
/// Controller: ↑/↓ select, Ⓐ install, Ⓑ back.
struct SetupView: View {
    let shell: ShellCoordinator

    private var setup: SetupModel { shell.setup }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ENGINE SETUP")
                        .font(AetherTheme.mono(11, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(AetherTheme.cyan)
                    Text("Play Windows games for $0.")
                        .font(.system(size: 44, weight: .heavy))
                        .tracking(-1.2)
                        .foregroundStyle(.white)
                    Text("Free Wine runtime plus Metal translation layers. No CrossOver, no Parallels, no Homebrew, no Terminal.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(spacing: 10) {
                    ForEach(Array(SetupModel.Step.allCases.enumerated()), id: \.element) { index, step in
                        SetupRow(
                            step: step,
                            setup: setup,
                            isFocused: shell.zone == .content && index == setup.focusedIndex
                        )
                        .onTapGesture { setup.focus(step) }
                    }
                }

                if let progress = setup.progress {
                    InstallProgressBar(progress: progress)
                }

                if let error = setup.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                            .font(AetherTheme.mono(12))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(AetherTheme.amber)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AetherTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AetherTheme.amber.opacity(0.35)))
                }

                HStack {
                    GhostButton(title: "Re-check", systemImage: "arrow.clockwise") { setup.refresh() }
                    Spacer()
                    Text(setup.isReady ? "READY TO PLAY" : "ROSETTA + WINE REQUIRED")
                        .font(AetherTheme.mono(11, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(setup.isReady ? AetherTheme.emerald : .white.opacity(0.4))
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, AetherTheme.pageMargin)
            .padding(.vertical, 50)
        }
        .onAppear { setup.refresh() }
    }
}

private struct SetupRow: View {
    let step: SetupModel.Step
    let setup: SetupModel
    let isFocused: Bool

    var body: some View {
        let done = setup.isDone(step)
        HStack(spacing: 16) {
            Image(systemName: step.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(done ? AetherTheme.emerald : AetherTheme.cyan)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if !step.isRequired {
                        Text("OPTIONAL")
                            .font(AetherTheme.mono(9, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                Text(setup.detail(step))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if setup.busyStep == step {
                ProgressView().controlSize(.small)
            } else if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AetherTheme.emerald)
            } else if let title = setup.actionTitle(step) {
                Button {
                    Task { await setup.perform(step) }
                } label: {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AetherTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(setup.busyStep != nil)
                .opacity(setup.busyStep != nil ? 0.4 : 1)
            } else {
                Text("NEEDS WINE")
                    .font(AetherTheme.mono(10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(AetherTheme.carbon, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? AetherTheme.cyan : AetherTheme.hairline, lineWidth: isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

private struct InstallProgressBar: View {
    let progress: InstallProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(AetherTheme.accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AetherTheme.accent)
            }
            Text(label)
                .font(AetherTheme.mono(11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var label: String {
        switch progress {
        case .resolving: "Finding the latest release…"
        case .downloading(let received, let total):
            "Downloading \(megabytes(received))" + (total.map { " / \(megabytes($0))" } ?? "")
        case .extracting: "Extracting…"
        case .installing: "Installing…"
        case .done: "Done"
        }
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
