import AetherCore
import SwiftUI

/// Left rail: brand, search, Browse (Home, Cloud Gaming), and the full game list.
/// Controller: ↑/↓ moves, Ⓐ or → opens, ← from the content's left edge comes here.
struct SidebarView: View {
    @Bindable var shell: ShellCoordinator
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AETHER")
                .font(AetherTheme.mono(15, weight: .heavy))
                .tracking(5)
                .foregroundStyle(AetherTheme.cyan)
                .padding(.top, 34)
                .padding(.horizontal, 18)

            searchField
                .padding(.horizontal, 14)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shell.sidebarEntries.enumerated()), id: \.element) { index, entry in
                            if index == 0 {
                                SectionLabel(text: "BROWSE").padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
                            } else if index == 2 {
                                SectionLabel(text: "LIBRARY · \(shell.filteredGames.count)")
                                    .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
                            }
                            SidebarRow(
                                entry: entry,
                                shell: shell,
                                isSelected: shell.isSelected(entry),
                                isFocused: shell.zone == .sidebar && index == shell.sidebarIndex
                            )
                            .id(entry)
                            .onTapGesture { shell.open(entry) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 20)
                }
                .onChange(of: shell.sidebarIndex) { _, index in
                    let entries = shell.sidebarEntries
                    guard entries.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(entries[index]) }
                }
            }
        }
        .frame(width: 270)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.35))
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
        }
        .onChange(of: shell.searchFocusToken) { _, _ in searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.5))
            TextField("Search library", text: $shell.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    searchFocused = false
                    shell.submitSearch()
                }
                .onExitCommand {
                    searchFocused = false
                    shell.endSearch()
                }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SidebarRow: View {
    let entry: SidebarEntry
    let shell: ShellCoordinator
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected || isFocused ? Color.white : Color.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 4)
            if case .game(let id) = entry, let game = shell.library.game(withID: id) {
                Circle()
                    .fill(AetherTheme.tint(for: shell.library.decision(for: game)?.engine))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AetherTheme.cyan.opacity(0.18) : (isFocused ? Color.white.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isFocused ? AetherTheme.cyan : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }

    private var title: String {
        switch entry {
        case .home: "Home"
        case .cloudHub: "Cloud Gaming"
        case .game(let id): shell.library.game(withID: id)?.title ?? "Unknown"
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch entry {
        case .home:
            Image(systemName: "house.fill").frame(width: 22).foregroundStyle(.white.opacity(0.8))
        case .cloudHub:
            Image(systemName: "icloud.fill").frame(width: 22).foregroundStyle(AetherTheme.violet)
        case .game(let id):
            // 28 pt at 2× = 56 px; tiny, and NSCache-bounded.
            ArtworkImage(url: shell.library.artwork[id]?[.grid], maxPixelSize: 64)
                .frame(width: 22, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}
