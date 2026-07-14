import AppKit
import SwiftUI

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
    }

    private var statusMenu: NSMenu?

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            if let trayIconURL = Bundle.main.url(forResource: "AuraSplitter_White", withExtension: "svg"),
               let image = NSImage(contentsOf: trayIconURL) {
                image.isTemplate = true
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
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show AuraSplitter", action: #selector(showApp), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusMenu = menu
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
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}
