import Foundation
import Darwin
import Synchronization

public enum BottleEngineError: Error, Equatable, CustomStringConvertible {
    case sessionAlreadyActive(pid: Int32)
    case unsupportedBackend(TranslationBackend)
    case executableNotFound(String)
    case wineBinaryNotFound(String)
    case wineserverNotFound(String)
    case d3dMetalLibraryNotFound(String)
    case launcherScriptNotFound(String)
    case bottleCreationFailed(path: String, reason: String)
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .sessionAlreadyActive(let pid): "A bottle session is already running (pid \(pid))."
        case .unsupportedBackend(let b): "Backend '\(b.rawValue)' is not supported yet (Phase 1: d3dmetal only)."
        case .executableNotFound(let p): "Game executable not found: \(p)"
        case .wineBinaryNotFound(let p): "Wine binary missing or not executable: \(p)"
        case .wineserverNotFound(let p): "wineserver missing or not executable: \(p)"
        case .d3dMetalLibraryNotFound(let p): "D3DMetal library directory not found: \(p)"
        case .launcherScriptNotFound(let p): "launch_d3dmetal.sh not found: \(p)"
        case .bottleCreationFailed(let p, let r): "Could not create bottle at \(p): \(r)"
        case .spawnFailed(let r): "Failed to spawn Wine: \(r)"
        }
    }
}

/// The exact command the engine will spawn. Built by a pure function so it can be unit-tested.
public struct LaunchCommand: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
}

/// Runs one Wine + D3DMetal session at a time: spawn, log streaming, lifecycle, clean teardown.
///
/// Lifecycle of a session:
/// ```
/// launch() ──► .launched(pid) ──► .stdout/.stderr … ──► .processExited(exit)
///          ──► `wineserver -w` (wait until every process in the prefix is gone) ──► stream finishes
/// ```
/// Waiting on the prefix, not just the PID, matters: many game launchers spawn the real game
/// and exit at once. Ending the session on the launcher PID would show "stopped" while the
/// game is still on screen.
///
/// `terminate()` escalates: SIGTERM to Wine → grace period → `wineserver -k` (kills every client
/// in the prefix, so no zombies) → SIGKILL as a last resort.
public actor BottleEngine {

    public enum State: Sendable, Equatable {
        case idle
        case running(pid: Int32)
        case terminating(pid: Int32)
    }

    public let runtime: BottleRuntime
    public private(set) var state: State = .idle

    private var process: Process?
    private var activeBottle: URL?
    private var monitorTask: Task<Void, Never>?

    public init(runtime: BottleRuntime) {
        self.runtime = runtime
    }

    public var isActive: Bool { state != .idle }

    // MARK: - Launch

    /// Validates the toolchain, creates the bottle if needed, and spawns the game.
    /// - Returns: an event stream that finishes when the whole Wine prefix has shut down.
    ///   Bounded buffer (newest 4096 events), so a slow or absent reader cannot grow RAM without limit.
    public func launch(_ request: BottleLaunchRequest) throws -> AsyncStream<BottleEvent> {
        switch state {
        case .running(let pid), .terminating(let pid):
            throw BottleEngineError.sessionAlreadyActive(pid: pid)
        case .idle:
            break
        }

        try Self.validate(request, runtime: runtime)
        try Self.ensureBottleExists(at: request.bottle)

        let command = Self.makeLaunchCommand(for: request, runtime: runtime)

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.workingDirectory
        // Detach stdin so Wine never blocks reading a terminal it does not have.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (events, continuation) = AsyncStream.makeStream(
            of: BottleEvent.self,
            bufferingPolicy: .bufferingNewest(4096)
        )
        let pump = OutputPump(
            continuation: continuation,
            handles: [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
        )

        // Callbacks run on Foundation's background threads, so mark them @Sendable explicitly.
        // That keeps them nonisolated and avoids Swift 6's runtime actor-isolation traps.
        stdoutPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil // EOF
                pump.channelClosed(.stdout)
            } else {
                pump.ingest(data, from: .stdout)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                pump.channelClosed(.stderr)
            } else {
                pump.ingest(data, from: .stderr)
            }
        }

        let (exits, exitContinuation) = AsyncStream.makeStream(
            of: BottleExit.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        process.terminationHandler = { @Sendable finished in
            exitContinuation.yield(BottleExit(process: finished))
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            pump.finish()
            throw BottleEngineError.spawnFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        self.process = process
        self.activeBottle = request.bottle
        self.state = .running(pid: pid)
        continuation.yield(.launched(pid: pid))

        let runtime = self.runtime
        let bottle = request.bottle
        monitorTask = Task { [weak self] in
            var exit = BottleExit(reason: .exited, status: -1)
            for await reported in exits { exit = reported }

            // terminationHandler can run before the last pipe bytes are read. Wait for EOF on
            // both pipes, but at most 500 ms: wineserver inherits the write ends and may hold
            // them open for the rest of the session.
            let drainDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while !pump.isDrained, ContinuousClock.now < drainDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }

            // Flush partial lines, then report the primary exit.
            pump.reportProcessExit(exit)

            // Block until every Wine process in this prefix (child launchers, the game itself) is gone.
            // Returns at once if wineserver is not running. terminate() unblocks it via `-k`.
            _ = await BottleEngine.runWineserver(["-w"], runtime: runtime, prefix: bottle)

            pump.finish()
            await self?.sessionDidEnd(pid: pid)
        }

        return events
    }

    // MARK: - Termination

    /// Stops the active session and everything it spawned. Safe to call repeatedly or when idle.
    /// - Parameter gracePeriod: time Wine gets after SIGTERM before the prefix is force-killed.
    public func terminate(gracePeriod: Duration = .seconds(5)) async {
        guard let process, let bottle = activeBottle else { return }
        let pid = process.processIdentifier
        state = .terminating(pid: pid)

        // 1. Polite: SIGTERM lets Wine tear down its windows and flush saves.
        if process.isRunning {
            process.terminate()
        }

        // 2. Wait up to the grace period without blocking the actor's executor.
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        // 3. Kill every remaining client of this prefix's wineserver: child exes, crash
        //    handlers, services. This is the reliable way to leave no zombies, because Wine
        //    processes get re-parented and do not form one process group.
        _ = await Self.runWineserver(["-k"], runtime: runtime, prefix: bottle)

        // 4. Last resort for a Wine loader that ignored everything.
        if process.isRunning {
            kill(pid, SIGKILL)
        }

        // 5. Wait for the monitor to drain logs and finish the event stream.
        await monitorTask?.value
    }

    // MARK: - Internals

    private func sessionDidEnd(pid: Int32) {
        switch state {
        case .running(let current), .terminating(let current):
            guard current == pid else { return }
        case .idle:
            return
        }
        state = .idle
        process = nil
        activeBottle = nil
        monitorTask = nil
    }

    /// Builds the zsh invocation of `launch_d3dmetal.sh`. Pure: no file system access.
    ///
    /// Environment precedence (lowest → highest): inherited env → profile `env_vars`
    /// → `additionalEnvironment` → engine-owned keys (`WINEPREFIX`, `MTL_HUD_ENABLED`).
    /// `DYLD_*` keys are dropped: SIP strips them at the zsh boundary anyway, and the
    /// script injects the D3DMetal path through `arch -e`.
    public static func makeLaunchCommand(
        for request: BottleLaunchRequest,
        runtime: BottleRuntime,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchCommand {
        var environment = baseEnvironment.filter { !$0.key.hasPrefix("DYLD_") }
        for (key, value) in request.translation.envVars where !key.hasPrefix("DYLD_") {
            environment[key] = value
        }
        for (key, value) in request.additionalEnvironment where !key.hasPrefix("DYLD_") {
            environment[key] = value
        }
        let hud = request.metalHUDEnabled ? "1" : "0"
        environment["WINEPREFIX"] = request.bottle.path(percentEncoded: false)
        environment["MTL_HUD_ENABLED"] = hud

        let arguments = [
            runtime.launcherScript.path(percentEncoded: false),
            request.bottle.path(percentEncoded: false),
            runtime.wineBinary.path(percentEncoded: false),
            runtime.d3dMetalLibraryDirectory.path(percentEncoded: false),
            request.executable.path(percentEncoded: false),
            hud,
        ] + request.translation.launchArgs + request.additionalArguments

        return LaunchCommand(
            executableURL: URL(filePath: "/bin/zsh"),
            arguments: arguments,
            environment: environment,
            // Many games load assets relative to the CWD, so start next to the .exe.
            workingDirectory: request.executable.deletingLastPathComponent()
        )
    }

    /// Fails fast in Swift with typed errors, before anything is spawned.
    static func validate(_ request: BottleLaunchRequest, runtime: BottleRuntime) throws {
        guard request.translation.backend == .d3dmetal else {
            throw BottleEngineError.unsupportedBackend(request.translation.backend)
        }
        let fm = FileManager.default
        let exe = request.executable.path(percentEncoded: false)
        guard fm.fileExists(atPath: exe) else { throw BottleEngineError.executableNotFound(exe) }

        let wine = runtime.wineBinary.path(percentEncoded: false)
        guard fm.isExecutableFile(atPath: wine) else { throw BottleEngineError.wineBinaryNotFound(wine) }

        let wineserver = runtime.wineserverBinary.path(percentEncoded: false)
        guard fm.isExecutableFile(atPath: wineserver) else { throw BottleEngineError.wineserverNotFound(wineserver) }

        let d3d = runtime.d3dMetalLibraryDirectory.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: d3d, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BottleEngineError.d3dMetalLibraryNotFound(d3d)
        }

        let script = runtime.launcherScript.path(percentEncoded: false)
        guard fm.fileExists(atPath: script) else { throw BottleEngineError.launcherScriptNotFound(script) }
    }

    private static func ensureBottleExists(at bottle: URL) throws {
        do {
            try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        } catch {
            throw BottleEngineError.bottleCreationFailed(
                path: bottle.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }
    }

    /// Runs `wineserver <args>` for a prefix under Rosetta and returns its exit status (-1 if it
    /// could not start). Async: never blocks a thread with `waitUntilExit()`.
    static func runWineserver(_ arguments: [String], runtime: BottleRuntime, prefix: URL) async -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/arch")
        process.arguments = ["-x86_64", runtime.wineserverBinary.path(percentEncoded: false)] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = prefix.path(percentEncoded: false)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { @Sendable finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // run() threw, so terminationHandler will never fire. Resume exactly once here.
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}

// MARK: - Output pump

/// Turns raw pipe chunks into line events.
///
/// `@unchecked Sendable` because it holds `FileHandle`s (thread-safe for `readabilityHandler`
/// assignment). All mutable state is behind a `Mutex`. Events are yielded inside the lock so
/// `.processExited` always comes after the final flushed output lines.
final class OutputPump: @unchecked Sendable {
    enum Channel: Sendable, Hashable { case stdout, stderr }

    /// Upper bound for a line with no newline (binary garbage, progress bars).
    static let maxLineBytes = 64 * 1024

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var openChannels: Set<Channel> = [.stdout, .stderr]
        var finished = false
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<BottleEvent>.Continuation
    private let handles: [FileHandle]

    init(continuation: AsyncStream<BottleEvent>.Continuation, handles: [FileHandle]) {
        self.continuation = continuation
        self.handles = handles
    }

    func ingest(_ data: Data, from channel: Channel) {
        let continuation = self.continuation
        state.withLock { state in
            guard !state.finished else { return }
            switch channel {
            case .stdout:
                state.stdout.append(data)
                Self.drainLines(&state.stdout, channel: .stdout, into: continuation)
            case .stderr:
                state.stderr.append(data)
                Self.drainLines(&state.stderr, channel: .stderr, into: continuation)
            }
        }
    }

    /// Called on EOF of a pipe.
    func channelClosed(_ channel: Channel) {
        state.withLock { _ = $0.openChannels.remove(channel) }
    }

    /// `true` once both pipes reached EOF.
    var isDrained: Bool {
        state.withLock { $0.openChannels.isEmpty }
    }

    /// Flushes any trailing partial lines and emits `.processExited`.
    func reportProcessExit(_ exit: BottleExit) {
        let continuation = self.continuation
        state.withLock { state in
            guard !state.finished else { return }
            Self.flush(&state.stdout, channel: .stdout, into: continuation)
            Self.flush(&state.stderr, channel: .stderr, into: continuation)
            continuation.yield(.processExited(exit))
        }
    }

    /// Stops reading and ends the stream. Idempotent.
    func finish() {
        let continuation = self.continuation
        let alreadyFinished = state.withLock { state -> Bool in
            if state.finished { return true }
            Self.flush(&state.stdout, channel: .stdout, into: continuation)
            Self.flush(&state.stderr, channel: .stderr, into: continuation)
            state.finished = true
            return false
        }
        guard !alreadyFinished else { return }
        // wineserver may still hold the pipe's write end, so EOF is not guaranteed. Detach explicitly.
        for handle in handles { handle.readabilityHandler = nil }
        continuation.finish()
    }

    private static func drainLines(
        _ buffer: inout Data,
        channel: Channel,
        into continuation: AsyncStream<BottleEvent>.Continuation
    ) {
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            emit(buffer[lineStart..<newline], channel: channel, into: continuation)
            lineStart = buffer.index(after: newline)
        }
        buffer.removeSubrange(buffer.startIndex..<lineStart)

        if buffer.count > maxLineBytes {
            emit(buffer[...], channel: channel, into: continuation)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private static func flush(
        _ buffer: inout Data,
        channel: Channel,
        into continuation: AsyncStream<BottleEvent>.Continuation
    ) {
        guard !buffer.isEmpty else { return }
        emit(buffer[...], channel: channel, into: continuation)
        buffer.removeAll()
    }

    private static func emit(
        _ bytes: Data.SubSequence,
        channel: Channel,
        into continuation: AsyncStream<BottleEvent>.Continuation
    ) {
        var slice = bytes
        if slice.last == 0x0D { slice = slice.dropLast() } // CRLF from Windows programs
        let line = String(decoding: slice, as: UTF8.self)
        switch channel {
        case .stdout: continuation.yield(.stdout(line))
        case .stderr: continuation.yield(.stderr(line))
        }
    }
}
