import SwiftUI
import AppKit

@main
struct PixooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let env = ProcessInfo.processInfo.environment
        // Headless preview hook: `DUMP_USAGE=1 swift run` renders the gizmo screens to PNGs.
        if env["DUMP_USAGE"] != nil {
            UsageGizmoPreview.dump(to: env["DUMP_USAGE_DIR"] ?? "/tmp/clawd")
            exit(0)
        }
        // Diagnostic: `DUMP_PLAN=1 swift run` prints which plan source answers and what it returns.
        if env["DUMP_STYLES"] != nil {
            UsageGizmoPreview.dumpStyles(to: env["DUMP_STYLES_DIR"] ?? "/tmp/styles")
            exit(0)
        }
        if env["DUMP_PLAN"] != nil {
            let sem = DispatchSemaphore(value: 0)
            Task {
                let s = await ClaudePlanReader.debugDump()
                try? (s + "\n").write(toFile: "/tmp/pixoo-plan-debug.txt", atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data((s + "\n").utf8))
                sem.signal()
            }
            sem.wait(); exit(0)
        }
    }

    var body: some Scene {
        // No visible window; the UI is the menu-bar NSStatusItem created by the delegate.
        Settings { EmptyView() }
    }
}

/// One menu-bar app that does both: a Claude Code usage gizmo and a now-playing display, on a
/// Divoom Pixoo 64 (auto-discovered on the LAN) or a Timebox over Bluetooth. Everything is toggled
/// from the menu; it auto-connects to a Pixoo on launch so it works out of the box.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let appName = "Claude Usage & Now Playing for Pixoo 64"
    let controller = TimeboxController()
    private let permission = BluetoothPermission()
    private var statusItem: NSStatusItem?
    private var simWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis",
                                     accessibilityDescription: Self.appName)
        item.button?.toolTip = Self.appName
        item.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        permission.start()   // Bluetooth permission prompt for the Timebox path

        // Echo status to stderr (invisible to end users; handy for diagnostics).
        Task { @MainActor [weak controller] in
            var last = ""
            while true {
                if let s = controller?.statusText, s != last {
                    last = s; FileHandle.standardError.write(Data("[status] \(s)\n".utf8))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // Out of the box: do both — the Claude usage gizmo plus now-playing (album art + clock).
        // All enabled screens interleave in the cycle. Each is toggleable from the menu.
        controller.showUsage = true   // album art + digital clock stay on by their defaults

        let env = ProcessInfo.processInfo.environment
        if env["RUN_SIM"] != nil {
            openSimulator()                                  // dev: on-screen panel
        } else if let host = env["PIXOO_HOST"], !host.isEmpty {
            controller.connectPixoo(host: host)              // dev/demo: explicit IP
        } else {
            controller.connectPixooAuto()                    // production: find it on the LAN
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let nowPlaying = NSMenuItem(title: "♪ \(controller.nowPlayingText)", action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        menu.addItem(nowPlaying)

        menu.addItem(.separator())

        if controller.isConnected {
            let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "")
            disconnectItem.target = self
            menu.addItem(disconnectItem)
        } else {
            let connectItem = NSMenuItem(title: "Connect", action: nil, keyEquivalent: "")
            let connectMenu = NSMenu()
            let timebox = NSMenuItem(title: "Timebox (Bluetooth)", action: #selector(connectTimebox), keyEquivalent: "")
            timebox.target = self
            connectMenu.addItem(timebox)
            connectMenu.addItem(.separator())
            let pixooAuto = NSMenuItem(title: "Pixoo 64 — find on network", action: #selector(connectPixooAuto), keyEquivalent: "")
            pixooAuto.target = self
            connectMenu.addItem(pixooAuto)
            let pixooIP = NSMenuItem(title: "Pixoo 64 — enter IP address…", action: #selector(connectPixooIP), keyEquivalent: "")
            pixooIP.target = self
            connectMenu.addItem(pixooIP)
            connectItem.submenu = connectMenu
            menu.addItem(connectItem)
        }

        let usageItem = NSMenuItem(title: "Claude usage (clawd)", action: #selector(toggleUsage), keyEquivalent: "")
        usageItem.target = self
        usageItem.state = controller.showUsage ? .on : .off
        menu.addItem(usageItem)

        let artItem = NSMenuItem(title: "Album art", action: #selector(toggleAlbumArt), keyEquivalent: "")
        artItem.target = self
        artItem.state = controller.showAlbumArt ? .on : .off
        menu.addItem(artItem)

        let artStyleItem = NSMenuItem(title: "Display Style", action: nil, keyEquivalent: "")
        let artStyleMenu = NSMenu()
        for id in [PixelArt.off] + PixelArt.presets.map(\.id) {
            let mi = NSMenuItem(title: id, action: #selector(setPixelStyle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = id
            mi.state = (controller.pixelStyleID == id) ? .on : .off
            artStyleMenu.addItem(mi)
        }
        artStyleItem.submenu = artStyleMenu
        menu.addItem(artStyleItem)

        let styleItem = NSMenuItem(title: "Clock", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for (title, style) in [("Off", TimeboxController.ClockStyle.off),
                               ("Analog", .analog), ("Digital", .digital)] {
            let sel: Selector = style == .off ? #selector(setNoClock)
                : style == .analog ? #selector(setAnalogClock) : #selector(setDigitalClock)
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            mi.state = (controller.clockStyle == style) ? .on : .off
            styleMenu.addItem(mi)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let sourceItem = NSMenuItem(title: "Now-playing source", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        let system = NSMenuItem(title: "System (any player)", action: #selector(setSystemSource), keyEquivalent: "")
        system.target = self
        system.state = (controller.artSource == .system) ? .on : .off
        let shazam = NSMenuItem(title: "Shazam (listen)", action: #selector(setShazamSource), keyEquivalent: "")
        shazam.target = self
        shazam.state = (controller.artSource == .shazam) ? .on : .off
        sourceMenu.addItem(system); sourceMenu.addItem(shazam)
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

        let intervalItem = NSMenuItem(title: "Screen dwell: \(controller.intervalSeconds)s", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for seconds in [5, 10, 12, 15, 30, 60] {
            let option = NSMenuItem(title: "\(seconds)s", action: #selector(setInterval(_:)), keyEquivalent: "")
            option.target = self
            option.tag = seconds
            option.state = (seconds == controller.intervalSeconds) ? .on : .off
            submenu.addItem(option)
        }
        intervalItem.submenu = submenu
        menu.addItem(intervalItem)

        let simItem = NSMenuItem(title: "Open simulator window (no device)", action: #selector(simulatorMenuItem), keyEquivalent: "")
        simItem.target = self
        menu.addItem(simItem)

        if permission.authorization == .denied || permission.authorization == .restricted {
            let warn = NSMenuItem(title: "Allow Bluetooth in System Settings → Privacy → Bluetooth",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About \(Self.appName)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func connectTimebox() { controller.connectTimebox() }
    @objc private func connectPixooAuto() { controller.connectPixooAuto() }
    @objc private func disconnect() { controller.disconnect() }

    /// Prompt for the Pixoo's IP and connect. The last-used address is remembered.
    @objc private func connectPixooIP() {
        let alert = NSAlert()
        alert.messageText = "Connect to Pixoo 64"
        alert.informativeText = "Enter your Pixoo's IP address. You can find it in the Divoom app under the device's settings."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "192.168.1.42"
        field.stringValue = UserDefaults.standard.string(forKey: "PixooHost") ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        UserDefaults.standard.set(host, forKey: "PixooHost")
        controller.connectPixoo(host: host)
    }

    @objc private func setInterval(_ sender: NSMenuItem) { controller.intervalSeconds = sender.tag }
    @objc private func setNoClock() { controller.clockStyle = .off }
    @objc private func setAnalogClock() { controller.clockStyle = .analog }
    @objc private func setDigitalClock() { controller.clockStyle = .digital }
    @objc private func setSystemSource() { controller.artSource = .system }
    @objc private func setShazamSource() { controller.artSource = .shazam }
    @objc private func toggleAlbumArt() { controller.showAlbumArt.toggle() }
    @objc private func setPixelStyle(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { controller.pixelStyleID = id }
    }
    @objc private func toggleUsage() { controller.showUsage.toggle() }
    @objc private func simulatorMenuItem() { openSimulator() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        func line(_ s: String) -> NSMutableAttributedString {
            NSMutableAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .paragraphStyle: para,
                .foregroundColor: NSColor.labelColor,
            ])
        }
        credits.append(line("Created by Marco van Hylckama Vlieg\n\n"))
        let x = line("Follow me on X: @AIandDesign\n")
        x.addAttribute(.link, value: "https://x.com/AIandDesign",
                       range: (x.string as NSString).range(of: "@AIandDesign"))
        credits.append(x)
        let site = line("ai-created.com")
        site.addAttribute(.link, value: "https://ai-created.com",
                          range: (site.string as NSString).range(of: "ai-created.com"))
        credits.append(site)

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: Self.appName, .credits: credits])
    }

    // MARK: - On-screen simulator (also used by RUN_SIM=1)

    private func openSimulator() {
        controller.connectSimulator()
        if simWindow == nil {
            let host = NSHostingController(rootView: PixooSimulatorView(screen: .shared))
            let win = NSWindow(contentViewController: host)
            win.title = "Pixoo Simulator"
            win.setContentSize(NSSize(width: 512, height: 512))
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.isReleasedWhenClosed = false
            win.center()
            simWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        simWindow?.makeKeyAndOrderFront(nil)
    }
}
