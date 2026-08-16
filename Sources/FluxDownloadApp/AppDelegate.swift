import AppKit
import SwiftUI
import UserNotifications
import ServiceManagement
import FluxDownloadCore
import FluxDownloadPersistence
import FluxDownloadEngine
import FluxDownloadScheduler
import FluxDownloadBrowserProtocol
import FluxDownloadIPC
import FluxDownloadGrabber
import FluxDownloadMedia

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    var services: AppServices?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var statusItem: NSStatusItem?
    var addWindow: NSWindow?
    private var statusWindows: [UUID: NSWindow] = [:]
    private var userInitiatedLaunch = false

    static func main() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Brand.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.servicesProvider = self
        userInitiatedLaunch = NSApp.isActive
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSWindow.allowsAutomaticWindowTabbing = false
        Task { await boot() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        services?.repairIPCIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await services?.shutdown()
        }
    }

    @objc private func didWake() {
        Task { await services?.coordinator.schedule() }
    }

    private func boot() async {
        do {
            try AppPaths.ensureSupportDirectories()
            let services = try await AppServices.bootstrap()
            self.services = services
            installMenu()
            if services.settings.launchAtLogin && !services.settings.launchMinimized {
                services.settings.launchMinimized = true
                try? await services.store.saveSettings(services.settings)
            }
            if services.settings.menuBarEnabled {
                installStatusItem()
            }
            if !services.settings.onboardingCompleted {
                showOnboarding()
            } else if shouldShowMainWindowAtLaunch {
                showMainWindow()
            } else {
                enterBackground()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "FluxDownload could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private var shouldShowMainWindowAtLaunch: Bool {
        guard let settings = services?.settings else { return true }
        if settings.menuBarOnly { return false }
        let hasTray = settings.menuBarEnabled
        if hasTray && (settings.launchMinimized || (settings.launchAtLogin && !userInitiatedLaunch)) {
            return false
        }
        return true
    }

    private func enterBackground() {
        NSApp.setActivationPolicy(.accessory)
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil, let services {
            let view = MainView(services: services)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = Brand.name
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1100, height: 680))
            window.minSize = NSSize(width: 800, height: 480)
            window.center()
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        guard let services else { return }
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(services: services))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 520))
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showAddDownload(url: String = "") {
        guard let services else { return }
        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: AddDownloadView(services: services, initialURL: url))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Add Download"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 560))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        addWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func showDownloadStatus(id: UUID) {
        NSApp.setActivationPolicy(.regular)
        if let existing = statusWindows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let services else { return }
        let hosting = NSHostingController(
            rootView: DownloadStatusView(services: services, downloadID: id) { [weak self] in
                self?.statusWindows[id]?.close()
            }
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 450, height: 420))
        window.minSize = NSSize(width: 420, height: 280)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .normal
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        if let screen = NSScreen.main {
            let offset = CGFloat(statusWindows.count) * 28
            let x = screen.visibleFrame.maxX - 474
            let y = screen.visibleFrame.maxY - 454 - offset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        statusWindows[id] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        statusWindows = statusWindows.filter { $0.value !== window }
        let remaining = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.canBecomeKey }
        if remaining.isEmpty, services?.settings.menuBarEnabled == true {
            enterBackground()
        }
    }

    func showOnboarding() {
        guard let services else { return }
        NSApp.setActivationPolicy(.regular)
        let hosting = NSHostingController(rootView: OnboardingView(services: services))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        onboardingWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showScheduler() {
        showMainWindow()
        services?.sidebarSelection = .scheduler
    }

    func showGrabber() {
        showMainWindow()
        services?.sidebarSelection = .grabber
    }

    private func menuBarIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: Brand.name)
        image?.isTemplate = true
        return image
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarIcon()
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = Brand.name
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open \(Brand.name)", action: #selector(openFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Pause All", action: #selector(pauseAllFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Resume All", action: #selector(resumeAllFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        services?.statusItem = item
    }

    @objc func openFromMenu() { showMainWindow() }
    @objc func settingsFromMenu() { showSettings() }
    @objc func pauseAllFromMenu() { Task { try? await services?.coordinator.pauseAll() } }
    @objc func resumeAllFromMenu() { Task { try? await services?.coordinator.resumeAll() } }

    private func installMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(Brand.name)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(Brand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Add URL…", action: #selector(addURL), keyEquivalent: "n")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        let downloads = NSMenu(title: "Downloads")
        downloads.addItem(withTitle: "Start", action: #selector(startSelected), keyEquivalent: "s")
        downloads.addItem(withTitle: "Pause", action: #selector(pauseSelected), keyEquivalent: "p")
        downloads.addItem(withTitle: "Retry", action: #selector(retrySelected), keyEquivalent: "r")
        downloads.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "\u{8}")
        downloads.addItem(.separator())
        downloads.addItem(withTitle: "Pause All", action: #selector(pauseAllFromMenu), keyEquivalent: "")
        downloads.addItem(withTitle: "Resume All", action: #selector(resumeAllFromMenu), keyEquivalent: "")
        let dlItem = NSMenuItem(title: "Downloads", action: nil, keyEquivalent: "")
        dlItem.submenu = downloads
        main.addItem(dlItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Main Window", action: #selector(openFromMenu), keyEquivalent: "0")
        windowMenu.addItem(withTitle: "Scheduler", action: #selector(openScheduler), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "\(Brand.name) on GitHub", action: #selector(openRepository), keyEquivalent: "?")
        help.addItem(.separator())
        help.addItem(withTitle: "Buy me a coffee", action: #selector(openSupport), keyEquivalent: "")
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }

    @objc func addURL() { showAddDownload() }
    @objc func openScheduler() { showScheduler() }
    @objc func startSelected() { Task { await services?.startSelected() } }
    @objc func pauseSelected() { Task { await services?.pauseSelected() } }
    @objc func retrySelected() { Task { await services?.retrySelected() } }
    @objc func deleteSelected() { Task { await services?.deleteSelected() } }
    @objc func showAbout() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "About \(Brand.name)"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }

    @objc func openRepository() {
        NSWorkspace.shared.open(Brand.repositoryLink)
    }

    @objc func openSupport() {
        NSWorkspace.shared.open(Brand.supportLink)
    }
}
