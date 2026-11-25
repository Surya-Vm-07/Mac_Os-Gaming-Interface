import AetherCore
import AppKit
import Observation

/// State for the Engine Setup page: Rosetta → Wine Staging → graphics stacks. Terminal-free.
@MainActor
@Observable
public final class SetupModel {

    public enum Step: String, CaseIterable, Identifiable, Sendable {
        case rosetta, wine, d3dmetal, dxmt, dxvk
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .rosetta: "Rosetta 2"
            case .wine: "Wine Staging runtime"
            case .d3dmetal: "D3DMetal (Apple GPTK)"
            case .dxmt: "DXMT"
            case .dxvk: "DXVK (macOS)"
            }
        }

        public var systemImage: String {
            switch self {
            case .rosetta: "checkmark.shield"
            case .wine: "wineglass"
            case .d3dmetal: "cpu"
            case .dxmt: "square.stack.3d.up"
            case .dxvk: "square.stack.3d.down.right"
            }
        }

        public var isRequired: Bool { self == .rosetta || self == .wine }
    }

    public private(set) var rosettaInstalled = RuntimeInstaller.isRosettaInstalled
    public private(set) var base: WineRuntime?
    public private(set) var flavors: Set<RuntimeFlavor> = []
    public private(set) var hasDXVK = false
    public private(set) var gptkCandidates: [URL] = []
    public private(set) var busyStep: Step?
    public private(set) var progress: InstallProgress?
    public private(set) var errorMessage: String?
    public private(set) var focusedIndex = 0

    @ObservationIgnored private let installer = RuntimeInstaller()
    @ObservationIgnored private let store = WineRuntimeStore()
    @ObservationIgnored private let onChange: @MainActor () -> Void

    public init(onChange: @escaping @MainActor () -> Void = {}) {
        self.onChange = onChange
        refresh()
    }

    /// Rosetta and one Wine runtime: enough to play.
    public var isReady: Bool { rosettaInstalled && base != nil }

    public func refresh() {
        rosettaInstalled = RuntimeInstaller.isRosettaInstalled
        base = store.newestBase()
        flavors = base.map { store.installedFlavors(baseID: $0.id) } ?? []
        hasDXVK = store.installedDXVK() != nil
        gptkCandidates = RuntimeInstaller.detectGPTK()
    }

    public func isDone(_ step: Step) -> Bool {
        switch step {
        case .rosetta: rosettaInstalled
        case .wine: base != nil
        case .d3dmetal: flavors.contains(.d3dmetal)
        case .dxmt: flavors.contains(.dxmt)
        case .dxvk: hasDXVK
        }
    }

    public func detail(_ step: Step) -> String {
        switch step {
        case .rosetta:
            "Windows games are x86_64; Rosetta translates them for Apple Silicon. macOS asks for your password."
        case .wine:
            base.map { "\($0.name) \($0.version) installed." }
                ?? "Free Gcenx macOS build from GitHub (~200 MB). No CrossOver, no Homebrew."
        case .d3dmetal:
            isDone(.d3dmetal)
                ? "Imported. DX12/DX11 AAA path ready."
                : gptkCandidates.isEmpty
                    ? "Apple doesn't allow redistributing it: download the free Game Porting Toolkit from developer.apple.com/games, open the .dmg, then import."
                    : "Game Porting Toolkit found: \(gptkCandidates[0].deletingLastPathComponent().lastPathComponent)."
        case .dxmt:
            "Open-source D3D10/11 → Metal. Often the fastest path for DX11 games, and the best fit for 8 GB Macs."
        case .dxvk:
            "D3D9–11 → Vulkan → Metal. Best for older DX9 games."
        }
    }

    /// Button title, or `nil` when the step is done or blocked (needs the Wine runtime first).
    public func actionTitle(_ step: Step) -> String? {
        guard !isDone(step) else { return nil }
        switch step {
        case .rosetta: return "Install"
        case .wine: return "Download"
        case .d3dmetal: return base == nil ? nil : (gptkCandidates.isEmpty ? "Choose Folder…" : "Import")
        case .dxmt: return base == nil ? nil : "Download"
        case .dxvk: return "Download"
        }
    }

    // MARK: Input

    public func move(_ delta: Int) {
        focusedIndex = min(max(focusedIndex + delta, 0), Step.allCases.count - 1)
    }

    public func focus(_ step: Step) {
        focusedIndex = Step.allCases.firstIndex(of: step) ?? 0
    }

    public var focusedStep: Step { Step.allCases[focusedIndex] }

    // MARK: Actions

    public func perform(_ step: Step) async {
        guard busyStep == nil, actionTitle(step) != nil else { return }
        busyStep = step
        errorMessage = nil
        progress = nil
        defer {
            busyStep = nil
            progress = nil
            refresh()
            onChange()
        }

        let report: RuntimeInstaller.Progress = { [weak self] update in
            Task { @MainActor in self?.progress = update }
        }
        do {
            switch step {
            case .rosetta:
                try await RuntimeInstaller.installRosetta()
            case .wine:
                _ = try await installer.installWine(progress: report)
            case .dxmt:
                guard let base else { return }
                _ = try await installer.installDXMT(base: base, progress: report)
            case .dxvk:
                _ = try await installer.installDXVK(progress: report)
            case .d3dmetal:
                guard let base else { return }
                guard let source = gptkCandidates.first ?? chooseGPTKFolder() else { return }
                progress = .installing
                _ = try await installer.importGPTK(base: base, from: source)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func chooseGPTKFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Volumes", directoryHint: .isDirectory)
        panel.message = "Choose the mounted Game Porting Toolkit volume (or the folder you copied it to)."
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
