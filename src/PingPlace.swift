import ApplicationServices
import Cocoa
import os.log

enum NotificationPosition: String, CaseIterable {
    case topLeft, topMiddle, topRight
    case middleLeft, deadCenter, middleRight
    case bottomLeft, bottomMiddle, bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topMiddle: return "Top Middle"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .deadCenter: return "Middle"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomMiddle: return "Bottom Middle"
        case .bottomRight: return "Bottom Right"
        }
    }
}

class NotificationMover: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let notificationCenterBundleID: String = "com.apple.notificationcenterui"
    private let paddingAboveDock: CGFloat = 30
    private var axObserver: AXObserver?
    private var statusItem: NSStatusItem?
    private var isMenuBarIconHidden: Bool = UserDefaults.standard.bool(forKey: "isMenuBarIconHidden")
    private let logger: Logger = .init(subsystem: "com.grimridge.PingPlace", category: "NotificationMover")
    private let debugMode: Bool = UserDefaults.standard.bool(forKey: "debugMode")
    private let launchAgentPlistPath: String = NSHomeDirectory() + "/Library/LaunchAgents/com.grimridge.PingPlace.plist"

    private var cachedInitialPosition: CGPoint?
    private var cachedInitialWindowSize: CGSize?
    private var cachedInitialNotifSize: CGSize?
    private var cachedInitialPadding: CGFloat?

    private var widgetMonitorTimer: Timer?
    private var lastWidgetWindowCount: Int = 0
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
        print("[DEBUG] \(message)")
    }

    func applicationDidFinishLaunching(_: Notification) {
        checkAccessibilityPermissions()
        setupObserver()
        if !isMenuBarIconHidden {
            setupStatusItem()
        }
        moveAllNotifications()
    }

    func applicationWillBecomeActive(_: Notification) {
        guard isMenuBarIconHidden else { return }
        isMenuBarIconHidden = false
        UserDefaults.standard.set(false, forKey: "isMenuBarIconHidden")
        setupStatusItem()
    }

    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "PingPlace needs accessibility permission to detect and move notifications.\n\nPlease grant permission in System Settings and restart the app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            NSApplication.shared.terminate(nil)
            return
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

    private func cacheInitialNotificationData(windowSize: CGSize, notifSize: CGSize, position: CGPoint) {
        guard cachedInitialPosition == nil else { return }

        let screenWidth: CGFloat = NSScreen.main!.frame.width
        var padding: CGFloat
        var effectivePosition = position

        if position.x + notifSize.width > screenWidth {
            debugLog("Detected incorrect initial position.x: \(position.x). Recalculating position.")
            padding = 16.0
            effectivePosition.x = screenWidth - notifSize.width - padding
        } else {
            let rightEdge: CGFloat = position.x + notifSize.width
            padding = screenWidth - rightEdge
        }

        cachedInitialPosition = effectivePosition
        cachedInitialWindowSize = windowSize
        cachedInitialNotifSize = notifSize
        cachedInitialPadding = padding

        debugLog("Initial notification cached - size: \(notifSize), position: \(effectivePosition), padding: \(padding)")
    }

    func moveNotification(_ window: AXUIElement) {
        guard currentPosition != .topRight else { return }

        // if let identifier: String = getWindowIdentifier(window), identifier.hasPrefix("widget") {
        //     return
        // }

        // if hasNotificationCenterUI() {
        //     debugLog("Skipping move - Notification Center UI detected")
        //     return
        // }

        let targetSubroles: [String] = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]
        guard let windowSize: CGSize = getSize(of: window),
              let bannerContainer: AXUIElement = findElementWithSubrole(root: window, targetSubroles: targetSubroles),
              let notifSize: CGSize = getSize(of: bannerContainer),
              let position: CGPoint = getPosition(of: bannerContainer)
        else {
            debugLog("Failed to get notification dimensions or find banner container")
            return
        }

        if cachedInitialPosition == nil {
            cacheInitialNotificationData(windowSize: windowSize, notifSize: notifSize, position: position)
        } else if position != cachedInitialPosition {
            setPosition(window, x: cachedInitialPosition!.x, y: cachedInitialPosition!.y)
        }

        let newPosition: (x: CGFloat, y: CGFloat) = calculateNewPosition(
            windowSize: cachedInitialWindowSize!,
            notifSize: cachedInitialNotifSize!,
            position: cachedInitialPosition!,
            padding: cachedInitialPadding!
        )

        setPosition(window, x: newPosition.x, y: newPosition.y)

        pollingEndTime = Date().addingTimeInterval(6.5)
        debugLog("Moved notification to \(currentPosition.displayName) at (\(newPosition.x), \(newPosition.y))")
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

        widgetMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            self.checkForWidgetChanges()
        }
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

    private func calculateNewPosition(
        windowSize: CGSize,
        notifSize: CGSize,
        position: CGPoint,
        padding: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        debugLog("Calculating new position with windowSize: \(windowSize), notifSize: \(notifSize), position: \(position), padding: \(padding)")
        
        guard let screen = NSScreen.main else {
            debugLog("Failed to get main screen")
            return (0, 0)
        }
        
        let screenFrame = screen.visibleFrame
        let newX: CGFloat
        let newY: CGFloat
        let horizontalPadding: CGFloat = 10.0 // Standard padding
        let verticalPadding: CGFloat = 10.0
        
        // Calculate X
        switch currentPosition {
        case .topLeft, .middleLeft, .bottomLeft:
            newX = screenFrame.minX + horizontalPadding
        case .topMiddle, .bottomMiddle, .deadCenter:
            newX = screenFrame.midX - (notifSize.width / 2)
        case .topRight, .middleRight, .bottomRight:
            newX = screenFrame.maxX - notifSize.width - horizontalPadding
        }
        
        // Calculate Y
        // Note: Screen coordinates origin is usually bottom-left in Cocoa (NSRect) but top-left in Accessibility (CGPoint)?
        // Accessibility API (AX) uses top-left as (0,0) of the main screen usually (flipped coordinates relative to Cocoa).
        // Let's assume AX uses global display coordinates where (0,0) is top-left of primary screen.
        // NSScreen.frame is bottom-left origin.
        // We need to convert.
        
        let screenHeight = screen.frame.height
        let screenY = screen.frame.origin.y // Usually 0 for main
        
        // Helper to convert Cocoa Y (bottom-up) to AX Y (top-down) if needed, 
        // BUT AXPosition usually matches the screen layout. 
        // Let's calculate purely in top-down logic assuming (0,0) is top-left of screen.
        
        let topPadding: CGFloat = screen.frame.height - screen.visibleFrame.maxY + verticalPadding // Menu bar area + padding
        let bottomPadding: CGFloat = screen.visibleFrame.minY + verticalPadding // Dock area + padding
        
        switch currentPosition {
        case .topLeft, .topMiddle, .topRight:
            newY = topPadding
        case .middleLeft, .middleRight, .deadCenter:
            newY = (screenHeight - notifSize.height) / 2
        case .bottomLeft, .bottomMiddle, .bottomRight:
            newY = screenHeight - notifSize.height - bottomPadding
        }

        debugLog("Calculated new position - x: \(newX), y: \(newY)")
        return (newX, newY)
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

let app: NSApplication = .shared
let delegate: NotificationMover = .init()
app.delegate = delegate
app.run()
