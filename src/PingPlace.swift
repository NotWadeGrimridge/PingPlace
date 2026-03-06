import ApplicationServices
import Cocoa
import os.log

class NotificationMover: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let notificationCenterBundleID: String = "com.apple.notificationcenterui"
    private let paddingAboveDock: CGFloat = 30
    private var axObserver: AXObserver?
    private var statusItem: NSStatusItem?
    private var isMenuBarIconHidden: Bool = UserDefaults.standard.bool(forKey: "isMenuBarIconHidden")
    private let logger: Logger = .init(subsystem: "com.grimridge.PingPlace", category: "NotificationMover")
    private let debugMode: Bool = UserDefaults.standard.bool(forKey: "debugMode")
    private let launchAgentPlistPath: String = NSHomeDirectory() + "/Library/LaunchAgents/com.grimridge.PingPlace.plist"

    private struct ScreenCache {
        var initialPosition: CGPoint
        var initialWindowSize: CGSize
        var initialNotifSize: CGSize
        var initialPadding: CGFloat
    }

    private var screenCaches: [CGDirectDisplayID: ScreenCache] = [:]

    private var widgetMonitorTimer: Timer?
    private var windowPollingTimer: Timer?
    private var lastWidgetWindowCount: Int = 0
    private var lastKnownWindowCount: Int = 0
    private var pollingEndTime: Date?

    private var currentPosition: NotificationPosition = {
        guard let rawValue: String = UserDefaults.standard.string(forKey: "notificationPosition"),
              let position = NotificationPosition(rawValue: rawValue)
        else {
            return .topMiddle
        }
        return position
    }()

    private func debugLog(_ message: String) {
        guard debugMode else { return }
        logger.info("\(message, privacy: .public)")
    }

    func applicationDidFinishLaunching(_: Notification) {
        if !isMenuBarIconHidden {
            setupStatusItem()
        }
        checkAccessibilityPermissions()
        if AXIsProcessTrusted() {
            setupObserver()
            moveAllNotifications()
        }

        // Re-position when displays change (plug/unplug monitor, resolution change)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.debugLog("Screen parameters changed — clearing caches")
            self?.screenCaches.removeAll()
            self?.moveAllNotifications()
        }

        // Stop polling on sleep, reinitialize on wake
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.debugLog("System sleeping — stopping polling")
            self?.windowPollingTimer?.invalidate()
            self?.widgetMonitorTimer?.invalidate()
        }
        wsnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.debugLog("System woke — reinitializing")
            self?.screenCaches.removeAll()
            if AXIsProcessTrusted() {
                self?.setupObserver()
                self?.moveAllNotifications()
            }
        }
    }

    func applicationWillBecomeActive(_: Notification) {
        guard isMenuBarIconHidden else { return }
        isMenuBarIconHidden = false
        UserDefaults.standard.set(false, forKey: "isMenuBarIconHidden")
        setupStatusItem()
    }

    private func checkAccessibilityPermissions() {
        // Check without prompting first
        if AXIsProcessTrusted() { return }

        // Not trusted — prompt and open settings, but don't quit.
        // The user can grant permission and the app will pick it up via polling.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

        // Poll until trusted, then set up the observer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.setupObserver()
                self.moveAllNotifications()
            }
        }
    }

    func setupStatusItem() {
        guard !isMenuBarIconHidden else {
            statusItem = nil
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button: NSStatusBarButton = statusItem?.button, let menuBarIcon = NSImage(named: "MenuBarIcon") {
            menuBarIcon.isTemplate = true
            button.image = menuBarIcon
        }
        statusItem?.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        for position: NotificationPosition in NotificationPosition.allCases {
            let item = NSMenuItem(title: position.displayName, action: #selector(changePosition(_:)), keyEquivalent: "")
            item.representedObject = position
            item.state = position == currentPosition ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = FileManager.default.fileExists(atPath: launchAgentPlistPath) ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleMenuBarIcon(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let donateMenu = NSMenuItem(title: "Donate", action: nil, keyEquivalent: "")
        let donateSubmenu = NSMenu()
        donateSubmenu.addItem(NSMenuItem(title: "Ko-fi", action: #selector(openKofi), keyEquivalent: ""))
        donateSubmenu.addItem(NSMenuItem(title: "Buy Me a Coffee", action: #selector(openBuyMeACoffee), keyEquivalent: ""))
        donateMenu.submenu = donateSubmenu

        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(donateMenu)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func openKofi() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/wadegrimridge")!)
    }

    @objc private func openBuyMeACoffee() {
        NSWorkspace.shared.open(URL(string: "https://www.buymeacoffee.com/wadegrimridge")!)
    }

    @objc private func toggleMenuBarIcon(_: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon"
        alert.informativeText = "The menu bar icon will be hidden. To show it again, launch PingPlace again."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isMenuBarIconHidden = true
        UserDefaults.standard.set(true, forKey: "isMenuBarIconHidden")
        statusItem = nil
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let isEnabled = FileManager.default.fileExists(atPath: launchAgentPlistPath)

        if isEnabled {
            do {
                try FileManager.default.removeItem(atPath: launchAgentPlistPath)
                sender.state = .off
            } catch {
                showError("Failed to disable launch at login: \(error.localizedDescription)")
            }
        } else {
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.grimridge.PingPlace</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(Bundle.main.executablePath!)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            do {
                try plistContent.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
                sender.state = .on
            } catch {
                showError("Failed to enable launch at login: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func changePosition(_ sender: NSMenuItem) {
        guard let position: NotificationPosition = sender.representedObject as? NotificationPosition else { return }
        let oldPosition: NotificationPosition = currentPosition
        currentPosition = position
        UserDefaults.standard.set(position.rawValue, forKey: "notificationPosition")

        sender.menu?.items.forEach { item in
            item.state = (item.representedObject as? NotificationPosition) == position ? .on : .off
        }

        debugLog("Position changed: \(oldPosition.displayName) → \(position.displayName)")
        moveAllNotifications()
    }

    private func cacheInitialNotificationData(
        screen: NSScreen,
        windowSize: CGSize,
        notifSize: CGSize,
        position: CGPoint
    ) -> ScreenCache {
        let displayID = screen.displayID
        if let existing = screenCaches[displayID] { return existing }

        let screenWidth = screen.frame.width
        let (effectivePosition, padding) = NotificationGeometry.initialData(
            screenWidth: screenWidth,
            notifSize: notifSize,
            position: position
        )

        let cache = ScreenCache(
            initialPosition: effectivePosition,
            initialWindowSize: windowSize,
            initialNotifSize: notifSize,
            initialPadding: padding
        )
        screenCaches[displayID] = cache

        debugLog("Cached for display \(displayID) - size: \(notifSize), pos: \(effectivePosition), padding: \(padding)")
        return cache
    }

    private func isWidgetWindow(_ window: AXUIElement) -> Bool {
        if let identifier: String = getWindowIdentifier(window), identifier.hasPrefix("widget") {
            return true
        }
        if findElementWithWidgetIdentifier(root: window) != nil {
            return true
        }
        return false
    }

    func moveNotification(_ window: AXUIElement) {
        guard currentPosition != .topRight else { return }

        if isWidgetWindow(window) {
            debugLog("Skipping move - widget window detected")
            return
        }

        let targetSubroles: [String] = [
            "AXNotificationCenterBanner",
            "AXNotificationCenterAlert",
            "AXNotificationCenterNotification",
            "AXNotificationCenterBannerWindow",
        ]
        guard let windowSize: CGSize = getSize(of: window) else {
            debugLog("Failed to get window size")
            return
        }

        // Try finding banner container by subrole (works on older macOS)
        // Fall back to using the window itself (macOS 26.3+ uses AXSystemDialog)
        let notifSize: CGSize
        let position: CGPoint

        if let found = findElementWithSubrole(root: window, targetSubroles: targetSubroles),
           let size = getSize(of: found),
           let pos = getPosition(of: found) {
            notifSize = size
            position = pos
        } else if let size = getSize(of: window),
                  let pos = getPosition(of: window) {
            debugLog("Using window directly for positioning (macOS 26.3+ fallback)")
            notifSize = size
            position = pos
        } else {
            debugLog("Failed to get notification dimensions or find banner container")
            return
        }

        // Determine which screen this notification belongs to
        guard let screen = NotificationGeometry.screen(containing: position) else {
            debugLog("Could not determine screen for position \(position)")
            return
        }

        let cache = cacheInitialNotificationData(
            screen: screen,
            windowSize: windowSize,
            notifSize: notifSize,
            position: position
        )

        if position != cache.initialPosition {
            setPosition(window, x: cache.initialPosition.x, y: cache.initialPosition.y)
        }

        let newPos = NotificationGeometry.newPosition(
            for: currentPosition,
            windowSize: cache.initialWindowSize,
            notifSize: cache.initialNotifSize,
            origin: cache.initialPosition,
            padding: cache.initialPadding,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            paddingAboveDock: paddingAboveDock
        )

        setPosition(window, x: newPos.x, y: newPos.y)

        pollingEndTime = Date().addingTimeInterval(6.5)
        debugLog("Moved notification to \(currentPosition.displayName) at (\(newPos.x), \(newPos.y)) on display \(screen.displayID)")
    }

    private func moveAllNotifications() {
        guard let pid: pid_t = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else {
            debugLog("Cannot find Notification Center process")
            return
        }

        let app: AXUIElement = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows: [AXUIElement] = windowsRef as? [AXUIElement]
        else {
            debugLog("Failed to get notification windows")
            return
        }

        for window in windows {
            moveNotification(window)
        }
    }

    @objc func showAbout() {
        let aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aboutWindow.center()
        aboutWindow.title = "About PingPlace"
        aboutWindow.delegate = self

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))

        let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A"
        let copyright: String = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""

        let elements: [(NSView, CGFloat)] = [
            (createIconView(), 165),
            (createLabel("PingPlace", font: .boldSystemFont(ofSize: 16)), 110),
            (createLabel("Version \(version)"), 90),
            (createLabel("Made with <3 by Wade"), 70),
            (createTwitterButton(), 40),
            (createLabel(copyright, color: .secondaryLabelColor, size: 11), 20),
        ]

        for (view, y) in elements {
            view.frame = NSRect(x: 0, y: y, width: 300, height: 20)
            if view is NSImageView {
                view.frame = NSRect(x: 100, y: y, width: 100, height: 100)
            }
            contentView.addSubview(view)
        }

        aboutWindow.contentView = contentView
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createIconView() -> NSImageView {
        let iconImageView = NSImageView()
        if let iconImage = NSImage(named: "icon") {
            iconImageView.image = iconImage
            iconImageView.imageScaling = .scaleProportionallyDown
        }
        return iconImageView
    }

    private func createLabel(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor, size _: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.font = font
        label.textColor = color
        return label
    }

    private func createTwitterButton() -> NSButton {
        let button = NSButton()
        button.title = "@WadeGrimridge"
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = #selector(openTwitter)
        button.attributedTitle = NSAttributedString(string: "@WadeGrimridge", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        return button
    }

    @objc private func openTwitter() {
        NSWorkspace.shared.open(URL(string: "https://x.com/WadeGrimridge")!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func setupObserver() {
        guard let pid: pid_t = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else {
            debugLog("Failed to setup observer - Notification Center not found")
            return
        }

        let app: AXUIElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        AXObserverCreate(pid, observerCallback, &observer)
        axObserver = observer

        let selfPtr: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer!, app, kAXWindowCreatedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer!), .defaultMode)

        debugLog("Observer setup complete for Notification Center (PID: \(pid))")

        // Track existing window count at startup
        lastKnownWindowCount = getNotificationWindowCount()

        widgetMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            self.checkForWidgetChanges()
        }

        // Poll for new windows since kAXWindowCreatedNotification may not fire on macOS 26.3+
        windowPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.pollForNewWindows()
        }
    }

    private func getNotificationWindowCount() -> Int {
        guard let pid: pid_t = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else { return 0 }

        let app: AXUIElement = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return 0 }

        return windows.count
    }

    private func pollForNewWindows() {
        let currentCount = getNotificationWindowCount()

        if currentCount > lastKnownWindowCount {
            debugLog("Polling detected new window(s): \(lastKnownWindowCount) -> \(currentCount)")
            moveAllNotifications()
        }

        lastKnownWindowCount = currentCount
    }

    private func getWindowIdentifier(_ element: AXUIElement) -> String? {
        var identifierRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifierRef) == .success else {
            return nil
        }
        return identifierRef as? String
    }

    private func checkForWidgetChanges() {
        guard let pollingEnd: Date = pollingEndTime, Date() < pollingEnd else {
            return
        }

        let hasNCUI: Bool = hasNotificationCenterUI()
        let currentNCState: Int = hasNCUI ? 1 : 0

        if lastWidgetWindowCount != currentNCState {
            debugLog("Notification Center state changed (\(lastWidgetWindowCount) → \(currentNCState)) - triggering move")
            if !hasNCUI {
                moveAllNotifications()
            }
        }

        lastWidgetWindowCount = currentNCState
    }

    private func hasNotificationCenterUI() -> Bool {
        guard let pid: pid_t = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else { return false }

        let app: AXUIElement = AXUIElementCreateApplication(pid)
        return findElementWithWidgetIdentifier(root: app) != nil
    }

    private func findElementWithWidgetIdentifier(root: AXUIElement) -> AXUIElement? {
        if let identifier: String = getWindowIdentifier(root), identifier.hasPrefix("widget-local") {
            return root
        }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children: [AXUIElement] = childrenRef as? [AXUIElement] else { return nil }

        for child: AXUIElement in children {
            if let found: AXUIElement = findElementWithWidgetIdentifier(root: child) {
                return found
            }
        }
        return nil
    }

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var positionValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        guard let posVal: AnyObject = positionValue, AXValueGetType(posVal as! AXValue) == .cgPoint else {
            return nil
        }
        var position = CGPoint.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        return position
    }

    private func getWindowTitle(_ element: AXUIElement) -> String? {
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }

    private func getSize(of element: AXUIElement) -> CGSize? {
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard let sizeVal: AnyObject = sizeValue, AXValueGetType(sizeVal as! AXValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return size
    }

    private func setPosition(_ element: AXUIElement, x: CGFloat, y: CGFloat) {
        var point = CGPoint(x: x, y: y)
        let value: AXValue = AXValueCreate(.cgPoint, &point)!
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func findElementWithSubrole(root: AXUIElement, targetSubroles: [String]) -> AXUIElement? {
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(root, kAXSubroleAttribute as CFString, &subroleRef) == .success {
            if let subrole: String = subroleRef as? String, targetSubroles.contains(subrole) {
                return root
            }
        }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children: [AXUIElement] = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        for child: AXUIElement in children {
            if let found: AXUIElement = findElementWithSubrole(root: child, targetSubroles: targetSubroles) {
                return found
            }
        }
        return nil
    }
}

private func observerCallback(observer _: AXObserver, element: AXUIElement, notification: CFString, context: UnsafeMutableRawPointer?) {
    let mover: NotificationMover = Unmanaged<NotificationMover>.fromOpaque(context!).takeUnretainedValue()

    let notificationString: String = notification as String
    if notificationString == kAXWindowCreatedNotification as String {
        mover.moveNotification(element)
    }
}

@main
enum PingPlaceApp {
    static func main() {
        let app: NSApplication = .shared
        let delegate: NotificationMover = .init()
        app.delegate = delegate
        app.run()
    }
}
