import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow!
    private var webViewController: MessengerWebViewController!
    private var statusItem: NSStatusItem!
    private var cleanModeMenuItem: NSMenuItem?
    private var statusCleanModeMenuItem: NSMenuItem?
    private var alwaysOnTopMenuItem: NSMenuItem?
    private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupWindow()
        setupStatusItem()
        setupNotifications()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isQuitting = true
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Window Setup

    private func setupWindow() {
        webViewController = MessengerWebViewController()
        webViewController.onUnreadCountChanged = { [weak self] count in
            self?.updateUnreadBadge(count)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Messenger"
        window.minSize = NSSize(width: 480, height: 520)
        window.contentViewController = webViewController
        window.delegate = self
        window.setFrameAutosaveName("MacMessengerMainWindow")
        if !window.setFrameUsingName("MacMessengerMainWindow") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // Hide instead of quitting when clicking the close button so notifications keep arriving.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isQuitting {
            return true
        }
        sender.orderOut(nil)
        return false
    }

    @objc private func showMainWindow() {
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleWindowVisibility() {
        if mainWindow.isVisible && NSApp.isActive {
            mainWindow.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    // MARK: - Notifications & Unread Badge

    private func setupNotifications() {
        NotificationBridge.shared.configure()
        NotificationBridge.shared.onNotificationClicked = { [weak self] jsId, threadHref in
            guard let self else { return }
            self.showMainWindow()
            self.webViewController.triggerNotificationClick(jsId: jsId, threadHref: threadHref)
        }
    }

    private func updateUnreadBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        NSApp.dockTile.display()

        if let button = statusItem?.button {
            button.title = count > 0 ? " \(count)" : ""
        }
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "message.fill", accessibilityDescription: "Messenger")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show / Hide Messenger", action: #selector(toggleWindowVisibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: ""))
        menu.addItem(.separator())

        let cleanItem = NSMenuItem(title: "Hide Facebook Top Bar", action: #selector(toggleCleanMode), keyEquivalent: "")
        cleanItem.state = webViewController.isCleanModeEnabled ? .on : .off
        statusCleanModeMenuItem = cleanItem
        menu.addItem(cleanItem)

        menu.addItem(NSMenuItem(title: "Send Test Notification", action: #selector(sendTestNotification), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open in Default Browser", action: #selector(openInBrowser), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacMessenger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Main Application Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About MacMessenger", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide MacMessenger", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit MacMessenger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu (enables Copy/Paste/Undo/Select All inside WKWebView)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r"))
        viewMenu.addItem(NSMenuItem(title: "Go to Messages Home", action: #selector(goHome), keyEquivalent: "1"))
        viewMenu.addItem(.separator())

        let cleanItem = NSMenuItem(title: "Hide Facebook Top Bar", action: #selector(toggleCleanMode), keyEquivalent: "b")
        cleanItem.state = UserDefaults.standard.object(forKey: "HideFacebookTopNav") == nil || UserDefaults.standard.bool(forKey: "HideFacebookTopNav") ? .on : .off
        cleanModeMenuItem = cleanItem
        viewMenu.addItem(cleanItem)

        let floatItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        floatItem.keyEquivalentModifierMask = [.command, .option]
        alwaysOnTopMenuItem = floatItem
        viewMenu.addItem(floatItem)

        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Send Test Notification", action: #selector(sendTestNotification), keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(title: "Copy Unread Debug Info", action: #selector(copyDebugInfo), keyEquivalent: ""))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Actions

    @objc private func reloadPage() {
        webViewController.reload()
    }

    @objc private func goHome() {
        webViewController.loadMessenger()
    }

    @objc private func toggleCleanMode() {
        let next = !webViewController.isCleanModeEnabled
        webViewController.isCleanModeEnabled = next
        let state: NSControl.StateValue = next ? .on : .off
        cleanModeMenuItem?.state = state
        statusCleanModeMenuItem?.state = state
    }

    @objc private func toggleAlwaysOnTop() {
        let floating = mainWindow.level == .floating
        mainWindow.level = floating ? .normal : .floating
        alwaysOnTopMenuItem?.state = floating ? .off : .on
    }

    @objc private func zoomIn() {
        webViewController.adjustZoom(by: 0.1)
    }

    @objc private func zoomOut() {
        webViewController.adjustZoom(by: -0.1)
    }

    @objc private func zoomReset() {
        webViewController.resetZoom()
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(webViewController.webView.url ?? MessengerWebViewController.messengerURL)
    }

    @objc private func sendTestNotification() {
        NotificationBridge.shared.sendTestNotification()
    }

    @objc private func copyDebugInfo() {
        webViewController.copyDebugInfoToPasteboard()
    }
}
