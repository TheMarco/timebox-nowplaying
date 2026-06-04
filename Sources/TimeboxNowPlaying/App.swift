import SwiftUI
import AppKit

@main
struct TimeboxNowPlayingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible window; the UI is the menu-bar NSStatusItem created by the delegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = TimeboxController()
    private let permission = BluetoothPermission()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Timebox Now Playing")
        item.button?.toolTip = "Timebox Now Playing"
        item.isVisible = true

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // Trigger the macOS Bluetooth permission prompt; re-scan once granted.
        permission.onChange = { [weak self] in self?.controller.refreshDevices() }
        permission.start()
        controller.refreshDevices()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let nowPlaying = NSMenuItem(title: "♪ \(controller.nowPlayingText)", action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        menu.addItem(nowPlaying)

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: controller.isConnected ? "Disconnect" : "Connect to Timebox",
            action: controller.isConnected ? #selector(disconnect) : #selector(connect),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let intervalItem = NSMenuItem(title: "Switch every \(controller.intervalSeconds)s", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in [3, 5, 10, 15, 30, 60] {
            let option = NSMenuItem(title: "\(seconds)s", action: #selector(setInterval(_:)), keyEquivalent: "")
            option.target = self
            option.tag = seconds
            option.state = (seconds == controller.intervalSeconds) ? .on : .off
            submenu.addItem(option)
        }
        intervalItem.submenu = submenu
        menu.addItem(intervalItem)

        let styleItem = NSMenuItem(title: "Clock style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        let analog = NSMenuItem(title: "Analog", action: #selector(setAnalogClock), keyEquivalent: "")
        analog.target = self
        analog.state = (controller.clockStyle == .analog) ? .on : .off
        let digital = NSMenuItem(title: "Digital (Tiny5)", action: #selector(setDigitalClock), keyEquivalent: "")
        digital.target = self
        digital.state = (controller.clockStyle == .digital) ? .on : .off
        styleMenu.addItem(analog)
        styleMenu.addItem(digital)
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        if permission.authorization == .denied || permission.authorization == .restricted {
            let warn = NSMenuItem(title: "Allow Bluetooth in System Settings → Privacy → Bluetooth",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        if !NowPlaying.isAvailable {
            let warn = NSMenuItem(title: "Now-playing unavailable — clock only", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func connect() { controller.connect() }
    @objc private func disconnect() { controller.disconnect() }
    @objc private func setInterval(_ sender: NSMenuItem) { controller.intervalSeconds = sender.tag }
    @objc private func setAnalogClock() { controller.clockStyle = .analog }
    @objc private func setDigitalClock() { controller.clockStyle = .digital }
    @objc private func quit() { NSApp.terminate(nil) }
}
