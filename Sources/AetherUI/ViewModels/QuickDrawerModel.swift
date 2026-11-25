import AetherCore
import CoreAudio
import Observation

/// State for the Quick Access drawer: live telemetry, Metal HUD toggle, audio output, force quit.
/// Telemetry is sampled only while the drawer is open.
@MainActor
@Observable
public final class QuickDrawerModel {

    public enum Row: Hashable, Sendable {
        case metalHUD
        case audio(AudioDeviceID)
        case forceQuit
        case close
    }

    public private(set) var isPresented = false
    public private(set) var focusedRow = 0
    public private(set) var telemetry: TelemetrySnapshot?
    public private(set) var audioDevices: [AudioOutputDevice] = []
    public private(set) var defaultOutputID: AudioDeviceID?
    public private(set) var metalHUDEnabled = AetherPreferences.metalHUDEnabled

    /// Set by the coordinator: closing returns the user to their game.
    @ObservationIgnored public var onCloseRequest: (@MainActor () -> Void)?

    @ObservationIgnored private let library: LibraryViewModel
    @ObservationIgnored private var sampler = SystemTelemetry()
    @ObservationIgnored private var samplingTask: Task<Void, Never>?

    public init(library: LibraryViewModel) {
        self.library = library
    }

    public var rows: [Row] {
        var rows: [Row] = [.metalHUD]
        rows += audioDevices.map { .audio($0.id) }
        if library.canForceQuit { rows.append(.forceQuit) }
        rows.append(.close)
        return rows
    }

    public var sessionTitle: String? { library.activeSessionTitle }

    // MARK: - Presentation

    public func present() {
        guard !isPresented else { return }
        audioDevices = AudioOutputs.all()
        defaultOutputID = AudioOutputs.defaultOutputID()
        metalHUDEnabled = AetherPreferences.metalHUDEnabled
        focusedRow = 0
        isPresented = true
        startSampling()
    }

    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        samplingTask?.cancel()
        samplingTask = nil
        telemetry = nil
    }

    // MARK: - Input

    public func move(_ direction: FocusDirection) {
        let count = rows.count
        switch direction {
        case .up: focusedRow = max(focusedRow - 1, 0)
        case .down: focusedRow = min(focusedRow + 1, count - 1)
        case .left, .right: break
        }
    }

    public func focus(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        focusedRow = index
    }

    public func activateFocused() async {
        let rows = rows
        guard rows.indices.contains(focusedRow) else { return }
        switch rows[focusedRow] {
        case .metalHUD:
            metalHUDEnabled.toggle()
            AetherPreferences.metalHUDEnabled = metalHUDEnabled
        case .audio(let id):
            if AudioOutputs.setDefaultOutput(id) {
                defaultOutputID = id
            }
        case .forceQuit:
            await library.forceQuitActiveGame()
            dismiss()
        case .close:
            onCloseRequest?()
        }
        focusedRow = min(focusedRow, self.rows.count - 1)
    }

    // MARK: - Telemetry

    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.telemetry = self.sampler.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
