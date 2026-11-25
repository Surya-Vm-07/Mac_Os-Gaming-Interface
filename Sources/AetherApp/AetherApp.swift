import AetherUI
import AppKit
import SwiftUI

/// Makes a bare SwiftPM executable act like a real app (Dock icon, key window, keyboard focus).
/// Harmless inside a proper Xcode .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = LibraryViewModel.makeDefault()

    var body: some Scene {
        WindowGroup("Aether") {
            LibraryHomeView(model: library)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}
