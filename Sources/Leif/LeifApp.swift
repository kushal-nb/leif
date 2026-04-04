import SwiftUI
import AppKit

@main
struct LeifApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Leif") {
            ContentView()
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { AppDelegate.configureWindow() }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .pasteboard) {
                Button("Find…") {
                    // Tag 1 = NSTextFinder.Action.showFindInterface — opens the find bar
                    // in whichever NSTextView is currently first responder.
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)),
                                     to: nil, from: item)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

// MARK: - AppDelegate: menu bar status item + global hotkey
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupMenuBarExtra()
        setupHotkey()
        // Give SwiftUI one run-loop tick to create the window, then configure it
        DispatchQueue.main.async { Self.configureWindow() }
    }

    /// Configures the main window with standard macOS collection behaviors so it
    /// participates in Spaces, Stage Manager, Mission Control, multi-monitor Move,
    /// and full-screen / Split View tiling (green button).
    static func configureWindow() {
        guard let win = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        win.collectionBehavior = [
            .managed,                  // participates in Spaces & Mission Control
            .participatesInCycle,      // included in Cmd+` window cycling
            .fullScreenAllowsTiling,   // allows Split View tiling via green button
        ]
        win.setFrameAutosaveName("LeifMainWindow")  // persists position across launches
    }

    // Restore the window when the user clicks the Dock icon with no visible windows
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            bringWindowForward()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // keep running in menu bar after window close
    }

    /// Always allow Quit (⌘Q / Quit menu) — never block shutdown on background filter/parse work.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    private func setupMenuBarExtra() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "doc.text.magnifyingglass",
                                   accessibilityDescription: "Leif")
            button.action = #selector(toggleWindow)
            button.target = self
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Leif  (Ctrl+Shift+Space)", action: #selector(toggleWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Leif", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }

    private func setupHotkey() {
        HotkeyManager.shared.register { [weak self] in
            DispatchQueue.main.async { self?.toggleWindow() }
        }
    }

    @objc private func toggleWindow() {
        NSApp.activate(ignoringOtherApps: true)
        bringWindowForward()
    }

    private func bringWindowForward() {
        // Find the main content window (handles minimized, hidden, or off-screen states)
        if let win = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI may have deallocated the window; ask all windows to come forward
            for win in NSApp.windows { win.makeKeyAndOrderFront(nil) }
        }
    }
}
