import AetherCore
import AppKit
import SwiftUI

/// Bottles: every Wine prefix, with the tools to install games into them.
/// Run a Windows installer → Add Game (pick the installed .exe) → it appears in the library and
/// always runs in that bottle.
struct BottlesView: View {
    let shell: ShellCoordinator

    @State private var bottles: [BottleInfo] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var pendingDelete: BottleInfo?
    @State private var newBottleName = ""

    private var library: LibraryViewModel { shell.library }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                HomeBackButton(shell: shell)

                VStack(alignment: .leading, spacing: 10) {
                    Text("BOTTLES")
                        .font(AetherTheme.mono(11, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(AetherTheme.cyan)
                    Text("Windows environments")
                        .font(.system(size: 40, weight: .heavy))
                        .tracking(-1.1)
                        .foregroundStyle(.white)
                    Text("Each bottle is an isolated Windows (Wine prefix). Games get their own automatically. To install a game from setup.exe: Run Installer, then Add Game.")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    TextField("New bottle name (e.g. Installers)", text: $newBottleName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AetherTheme.hairline))
                        .frame(maxWidth: 320)
                        .onSubmit(createBottle)
                    GhostButton(title: "Create", systemImage: "plus") { createBottle() }
                    Spacer()
                    GhostButton(title: "Refresh", systemImage: "arrow.clockwise") { reload() }
                }

                if bottles.isEmpty {
                    Text("No bottles yet. They're created the first time you play a Windows game, or create one above to run an installer.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(bottles.enumerated()), id: \.element.id) { index, bottle in
                            BottleRow(
                                bottle: bottle,
                                size: sizes[bottle.id],
                                isFocused: shell.zone == .content && index == shell.bottleIndex,
                                runInstaller: { runInstaller(in: bottle) },
                                addGame: { addGame(from: bottle) },
                                reveal: { NSWorkspace.shared.activateFileViewerSelecting([bottle.isInitialized ? bottle.driveC : bottle.url]) },
                                stop: { Task { await library.stopBottle(bottle) } },
                                delete: { pendingDelete = bottle }
                            )
                            .onTapGesture { shell.focusBottle(index) }
                        }
                    }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, AetherTheme.pageMargin)
            .padding(.vertical, 46)
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Delete bottle “\(pendingDelete?.id ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Bottle and Its Files", role: .destructive) {
                if let bottle = pendingDelete {
                    Task {
                        await library.stopBottle(bottle)
                        do { try BottleStore.delete(bottle) } catch { library.showStatus("Couldn't delete: \(error.localizedDescription)") }
                        reload()
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("Everything installed in it (games, saves, settings) is removed. This can't be undone.")
        }
    }

    // MARK: Actions

    private func reload() {
        bottles = BottleStore.list()
        let snapshot = bottles
        Task {
            sizes = await Self.computeSizes(snapshot)
        }
    }

    /// Walks each prefix off the main actor (a bottle can hold tens of thousands of files).
    nonisolated private static func computeSizes(_ bottles: [BottleInfo]) async -> [String: Int64] {
        var computed: [String: Int64] = [:]
        for bottle in bottles { computed[bottle.id] = BottleStore.size(of: bottle) }
        return computed
    }

    private func createBottle() {
        let name = newBottleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try BottleStore.create(named: name)
            newBottleName = ""
            reload()
        } catch {
            library.showStatus("Couldn't create bottle: \(error.localizedDescription)")
        }
    }

    private func runInstaller(in bottle: BottleInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Windows installer or program (.exe / .msi) to run in “\(bottle.id)”."
        panel.prompt = "Run"
        guard panel.runModal() == .OK, let exe = panel.url else { return }
        Task {
            await library.runExecutable(exe, inBottle: bottle)
            reload()
        }
    }

    private func addGame(from bottle: BottleInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = bottle.driveC.appending(path: "Program Files", directoryHint: .isDirectory)
        panel.message = "Choose the game's .exe (usually in Program Files)."
        panel.prompt = "Add Game"
        guard panel.runModal() == .OK, let exe = panel.url else { return }
        // The game folder's name is usually a better title than "Game.exe".
        let folder = exe.deletingLastPathComponent().lastPathComponent
        let title = ["bin", "binaries", "win64", "x64"].contains(folder.lowercased())
            ? exe.deletingPathExtension().lastPathComponent
            : folder
        Task { await library.addManualGame(title: title, executable: exe, bottle: bottle) }
    }
}

private struct BottleRow: View {
    let bottle: BottleInfo
    let size: Int64?
    let isFocused: Bool
    let runInstaller: () -> Void
    let addGame: () -> Void
    let reveal: () -> Void
    let stop: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AetherTheme.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bottle.id)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(bottle.url.path(percentEncoded: false))
                        .font(AetherTheme.mono(10.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(size.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "…")
                    .font(AetherTheme.mono(11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(bottle.isInitialized ? "READY" : "EMPTY")
                    .font(AetherTheme.mono(9.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(bottle.isInitialized ? AetherTheme.emerald : .white.opacity(0.4))
            }
            HStack(spacing: 8) {
                SmallAction(title: "Run Installer…", systemImage: "square.and.arrow.down", action: runInstaller)
                SmallAction(title: "Add Game…", systemImage: "plus.rectangle.on.rectangle", action: addGame)
                    .disabled(!bottle.isInitialized)
                SmallAction(title: "Show in Finder", systemImage: "folder", action: reveal)
                SmallAction(title: "Stop", systemImage: "stop.fill", action: stop)
                Spacer()
                SmallAction(title: "Delete", systemImage: "trash", destructive: true, action: delete)
            }
        }
        .padding(18)
        .background(AetherTheme.carbon, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? AetherTheme.cyan : AetherTheme.hairline, lineWidth: isFocused ? 2 : 1)
        )
    }
}

private struct SmallAction: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(destructive ? Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255) : .white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(isHovered ? 0.13 : 0.06)))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
    }
}
