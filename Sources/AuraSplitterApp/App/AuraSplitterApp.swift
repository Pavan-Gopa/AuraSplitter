import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App icon (dock)
        if let iconURL = Bundle.main.url(forResource: "AuraSplitter", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        
        setupStatusItem()
        
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        // Update system: dynamic tray menu + periodic checks.
        refreshStatusMenu()
        UpdateService.shared.startAutoChecks()
        observeUpdateState()
    }

    private var statusMenu: NSMenu?

    private var updateStateCancellable: AnyCancellable?
    private var winkTimer: Timer?

    /// Tray feedback: rebuild the menu for the update state and make the logo
    /// "wink" while an update is waiting.
    private func observeUpdateState() {
        updateStateCancellable = UpdateService.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusMenu()
                self?.updateWinkAnimation()
            }
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()
        let state = UpdateService.shared.state

        func addUpdateItem(_ title: String, action: Selector?, bold: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action != nil ? self : nil
            item.isEnabled = enabled
            if bold {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)]
                )
            }
            menu.addItem(item)
        }

        switch state {
        case .available(let release):
            addUpdateItem("Update to \(release.version.displayString) — Download", action: #selector(downloadUpdateClicked(_:)), bold: true)
        case .downloading(let release, let fraction):
            addUpdateItem("Downloading \(release.version.displayString)… \(Int(fraction * 100))%", action: nil, enabled: false)
        case .readyToInstall(let release, _):
            addUpdateItem("Install \(release.version.displayString) and Relaunch", action: #selector(installUpdateClicked(_:)), bold: true)
        case .checking:
            addUpdateItem("Checking for Updates…", action: nil, enabled: false)
        case .failed:
            addUpdateItem("Update check failed — retry", action: #selector(checkUpdatesClicked(_:)))
        case .upToDate(let current):
            addUpdateItem("Version \(current) — up to date", action: nil, enabled: false)
        case .idle:
            addUpdateItem("Version \(AppVersion.current) — up to date", action: nil, enabled: false)
        }
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkUpdatesClicked(_:)), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Show AuraSplitter", action: #selector(showApp), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusMenu = menu
    }

    private func updateWinkAnimation() {
        let state = UpdateService.shared.state
        var shouldWink = false
        if case .available = state { shouldWink = true }
        if case .readyToInstall = state { shouldWink = true }

        if shouldWink, winkTimer == nil {
            winkTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
                self?.performWink()
            }
        } else if !shouldWink, let timer = winkTimer {
            timer.invalidate()
            winkTimer = nil
            restoreTrayImage()
        }
    }

    private func performWink() {
        guard let button = statusItem?.button, let logo = trayLogoImage() else { return }
        // Quick open → squint → open reads as a wink at status-bar size.
        let squint = logo.copy() as! NSImage
        squint.size = NSSize(width: logo.size.width, height: max(4, logo.size.height * 0.25))
        button.image = squint
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            button.image = self.trayLogoImage()
        }
    }

    private func restoreTrayImage() {
        guard let button = statusItem?.button else { return }
        button.image = trayLogoImage() ?? button.image
    }

    private func trayLogoImage() -> NSImage? {
        if let svgURL = Bundle.main.url(forResource: "AuraSplitter_2", withExtension: "svg"),
           let image = NSImage(contentsOf: svgURL) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

    @objc func checkUpdatesClicked(_ sender: Any?) {
        Task { @MainActor in
            await UpdateService.shared.checkForUpdates(manual: true)
            showApp()
        }
    }

    @objc func downloadUpdateClicked(_ sender: Any?) {
        Task { @MainActor in
            showApp()
            await UpdateService.shared.downloadAndPrepare()
        }
    }

    @objc func installUpdateClicked(_ sender: Any?) {
        Task { @MainActor in
            showApp()
            UpdateService.shared.requestInstall()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            if let trayIconURL = Bundle.main.url(forResource: "AuraSplitter_2", withExtension: "svg"),
               let image = NSImage(contentsOf: trayIconURL) {
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                button.title = "Aura"
            }
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        // Build the context menu but do NOT assign it to statusItem.menu
        // so that left-click can trigger the action instead of showing the menu.
        refreshStatusMenu()
    }
    
    @objc func statusBarButtonClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            showApp()
            return
        }
        if event.type == .rightMouseUp {
            // Show context menu on right-click
            if let button = statusItem?.button, let menu = statusMenu {
                statusItem?.menu = menu
                button.performClick(nil)
                // Remove menu right after so next left-click goes to action again
                DispatchQueue.main.async { [weak self] in
                    self?.statusItem?.menu = nil
                }
            }
        } else {
            showApp()
        }
    }
    
    @objc func showApp() {
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showApp()
        }
        return true
    }

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Capture reference to main window and make AppDelegate the delegate to intercept close
        if window.title == "AuraSplitter" || window.title == "KirtanSplitter" {
            self.mainWindow = window
            window.delegate = self
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil) // Hide the window
        return false // Prevent destruction
    }
}

@main
struct AuraSplitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(UpdateService.shared)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { @MainActor in
                        await UpdateService.shared.checkForUpdates(manual: true)
                    }
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
