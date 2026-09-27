import AppKit
import ServiceManagement
import UnquarantineCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var loginItem: NSMenuItem!
    private var monitor: DownloadMonitor?
    private lazy var menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "clear", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18 * 100 / 110)
        image.isTemplate = true
        return image
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Avoid two monitors if the app is launched from more than one location.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.behavior = .removalAllowed
        setStatus(tooltip: "Unquarantine — watching Downloads")

        let menu = NSMenu()
        menu.delegate = self
        loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.isVisible = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard statusItem != nil else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        monitor = DownloadMonitor(folder: downloads) { [weak self] state in
            switch state {
            case .watching:
                self?.setStatus(tooltip: "Unquarantine — watching Downloads")
            case .cleared(let name):
                self?.setStatus(tooltip: "Unquarantine — cleared \(name)")
            case .problem(let message):
                self?.setStatus(tooltip: "Unquarantine — \(message)", hasError: true)
            }
        }
        monitor?.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLoginItem()
    }

    private func updateLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItem.state = .on
            loginItem.toolTip = nil
        case .requiresApproval:
            loginItem.state = .mixed
            loginItem.toolTip = "Waiting for approval in System Settings → General → Login Items"
        default:
            loginItem.state = .off
            loginItem.toolTip = nil
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at login"
            alert.informativeText = "\(error.localizedDescription)\n\nKeep Unquarantine in Applications before enabling launch at login."
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateLoginItem()
    }

    private func setStatus(tooltip: String, hasError: Bool = false) {
        let image = hasError
            ? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Unquarantine")
            : (menuBarIcon ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Unquarantine"))
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = image == nil ? "U" : ""
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel("Unquarantine")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
