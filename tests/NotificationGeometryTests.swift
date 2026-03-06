import Foundation

// Lightweight test runner — no XCTest dependency needed for `make test`.

private var testCount = 0
private var failCount = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    testCount += 1
    guard a == b else {
        failCount += 1
        print("  FAIL (\(file):\(line)): \(a) != \(b) \(msg)")
        return
    }
}

func assertApprox(_ a: CGFloat, _ b: CGFloat, accuracy: CGFloat = 0.1, _ msg: String = "", file: String = #file, line: Int = #line) {
    testCount += 1
    guard abs(a - b) <= accuracy else {
        failCount += 1
        print("  FAIL (\(file):\(line)): \(a) !~= \(b) (±\(accuracy)) \(msg)")
        return
    }
}

// --- Test data ---

let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1010)
let windowSize = CGSize(width: 1920, height: 1080)
let notifSize = CGSize(width: 350, height: 90)
let padding: CGFloat = 16.0
let paddingAboveDock: CGFloat = 30.0
let origin = CGPoint(x: 1920 - 350 - padding, y: 0)

// --- Tests ---

func testInitialDataNormalPosition() {
    print("  testInitialDataNormalPosition")
    let result = NotificationGeometry.initialData(
        screenWidth: 1920, notifSize: notifSize, position: CGPoint(x: 1554, y: 0)
    )
    assertApprox(result.padding, 16.0)
    assertApprox(result.effectivePosition.x, 1554)
}

func testInitialDataOffScreenCorrection() {
    print("  testInitialDataOffScreenCorrection")
    let result = NotificationGeometry.initialData(
        screenWidth: 1920, notifSize: notifSize, position: CGPoint(x: 1800, y: 0)
    )
    assertApprox(result.padding, 16.0)
    assertApprox(result.effectivePosition.x, 1554)
}

func testTopRight() {
    print("  testTopRight")
    let pos = NotificationGeometry.newPosition(
        for: .topRight, windowSize: windowSize, notifSize: notifSize,
        origin: origin, padding: padding,
        screenFrame: screenFrame, visibleFrame: visibleFrame, paddingAboveDock: paddingAboveDock
    )
    assertApprox(pos.x, 0)
    assertApprox(pos.y, 0)
}

func testTopLeft() {
    print("  testTopLeft")
    let pos = NotificationGeometry.newPosition(
        for: .topLeft, windowSize: windowSize, notifSize: notifSize,
        origin: origin, padding: padding,
        screenFrame: screenFrame, visibleFrame: visibleFrame, paddingAboveDock: paddingAboveDock
    )
    assertApprox(pos.x, padding - origin.x)
    assertApprox(pos.y, 0)
}

func testTopMiddle() {
    print("  testTopMiddle")
    let pos = NotificationGeometry.newPosition(
        for: .topMiddle, windowSize: windowSize, notifSize: notifSize,
        origin: origin, padding: padding,
        screenFrame: screenFrame, visibleFrame: visibleFrame, paddingAboveDock: paddingAboveDock
    )
    let expectedX = (windowSize.width - notifSize.width) / 2 - origin.x
    assertApprox(pos.x, expectedX)
    assertApprox(pos.y, 0)
}

func testBottomMiddle() {
    print("  testBottomMiddle")
    let pos = NotificationGeometry.newPosition(
        for: .bottomMiddle, windowSize: windowSize, notifSize: notifSize,
        origin: origin, padding: padding,
        screenFrame: screenFrame, visibleFrame: visibleFrame, paddingAboveDock: paddingAboveDock
    )
    let dockSize = screenFrame.height - visibleFrame.height
    let expectedY = windowSize.height - notifSize.height - dockSize - paddingAboveDock
    assertApprox(pos.y, expectedY)
}

func testDeadCenter() {
    print("  testDeadCenter")
    let pos = NotificationGeometry.newPosition(
        for: .deadCenter, windowSize: windowSize, notifSize: notifSize,
        origin: origin, padding: padding,
        screenFrame: screenFrame, visibleFrame: visibleFrame, paddingAboveDock: paddingAboveDock
    )
    let dockSize = screenFrame.height - visibleFrame.height
    let expectedY = (windowSize.height - notifSize.height) / 2 - dockSize
    assertApprox(pos.y, expectedY)
}

func testSecondScreenOffset() {
    print("  testSecondScreenOffset")
    let screen2Frame = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    let screen2Visible = CGRect(x: 1920, y: 0, width: 2560, height: 1370)
    let screen2Origin = CGPoint(x: 1920 + 2560 - 350 - padding, y: 0)

    let pos = NotificationGeometry.newPosition(
        for: .topLeft,
        windowSize: CGSize(width: 2560, height: 1440), notifSize: notifSize,
        origin: screen2Origin, padding: padding,
        screenFrame: screen2Frame, visibleFrame: screen2Visible, paddingAboveDock: paddingAboveDock
    )
    let expectedX = screen2Frame.minX + padding - screen2Origin.x
    assertApprox(pos.x, expectedX)
    assertApprox(pos.y, 0)
}

// --- AXSystemDialog offset tests (macOS 26.3+) ---

let dialogScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
let dialogVisible = CGRect(x: 0, y: 0, width: 2560, height: 1410)
let bannerSize = CGSize(width: 344, height: 57)

func testDialogTopMiddle_WindowAtOrigin() {
    print("  testDialogTopMiddle_WindowAtOrigin")
    let pos = NotificationGeometry.systemDialogPosition(
        for: .topMiddle,
        bannerPos: CGPoint(x: 2200, y: 46),
        windowPos: CGPoint(x: 0, y: 0),
        notifSize: bannerSize,
        screenFrame: dialogScreen, visibleFrame: dialogVisible, paddingAboveDock: 30
    )
    // Banner at x=2200 relative to window. Target = (2560-344)/2 = 1108.
    // Window should be at 1108 - 2200 = -1092
    assertApprox(pos.x, -1092)
    assertApprox(pos.y, 0)
}

func testDialogTopMiddle_WindowAlreadyShifted() {
    print("  testDialogTopMiddle_WindowAlreadyShifted")
    // Window already at -500, banner at 2200-500=1700 absolute
    let pos = NotificationGeometry.systemDialogPosition(
        for: .topMiddle,
        bannerPos: CGPoint(x: 1700, y: 46),
        windowPos: CGPoint(x: -500, y: 0),
        notifSize: bannerSize,
        screenFrame: dialogScreen, visibleFrame: dialogVisible, paddingAboveDock: 30
    )
    // bannerRel = 1700 - (-500) = 2200. Same result: 1108 - 2200 = -1092
    assertApprox(pos.x, -1092)
    assertApprox(pos.y, 0)
}

func testDialogTopMiddle_Idempotent() {
    print("  testDialogTopMiddle_Idempotent")
    // Already correctly positioned: window at -1092, banner at 1108
    let pos = NotificationGeometry.systemDialogPosition(
        for: .topMiddle,
        bannerPos: CGPoint(x: 1108, y: 46),
        windowPos: CGPoint(x: -1092, y: 0),
        notifSize: bannerSize,
        screenFrame: dialogScreen, visibleFrame: dialogVisible, paddingAboveDock: 30
    )
    assertApprox(pos.x, -1092)
    assertApprox(pos.y, 0)
}

func testDialogTopLeft() {
    print("  testDialogTopLeft")
    let pos = NotificationGeometry.systemDialogPosition(
        for: .topLeft,
        bannerPos: CGPoint(x: 2200, y: 46),
        windowPos: CGPoint(x: 0, y: 0),
        notifSize: bannerSize,
        screenFrame: dialogScreen, visibleFrame: dialogVisible, paddingAboveDock: 30
    )
    // Target X = 16, bannerRel = 2200. Window = 16 - 2200 = -2184
    assertApprox(pos.x, -2184)
    assertApprox(pos.y, 0)
}

func testDialogTopRight() {
    print("  testDialogTopRight")
    let pos = NotificationGeometry.systemDialogPosition(
        for: .topRight,
        bannerPos: CGPoint(x: 2200, y: 46),
        windowPos: CGPoint(x: 0, y: 0),
        notifSize: bannerSize,
        screenFrame: dialogScreen, visibleFrame: dialogVisible, paddingAboveDock: 30
    )
    // topRight: no shift, target = bannerPos, so window stays at 0
    assertApprox(pos.x, 0)
    assertApprox(pos.y, 0)
}

func testDialogBottomMiddle() {
    print("  testDialogBottomMiddle")
    let pos = NotificationGeometry.systemDialogPosition(
        for: .bottomMiddle,
        bannerPos: CGPoint(x: 2200, y: 46),
        windowPos: CGPoint(x: 0, y: 0),
        notifSize: bannerSize,
        screenFrame: dialogScreen, visibleFrame: dialogVisible, paddingAboveDock: 30
    )
    let dockSize: CGFloat = 1440 - 1410  // 30
    let targetY: CGFloat = 1440 - 57 - dockSize - 30  // 1323
    assertApprox(pos.x, -1092)
    assertApprox(pos.y, targetY - 46)
}

func testDialogDeadCenter() {
    print("  testDialogDeadCenter")
    let pos = NotificationGeometry.systemDialogPosition(
        for: .deadCenter,
        bannerPos: CGPoint(x: 2200, y: 46),
        windowPos: CGPoint(x: 0, y: 0),
        notifSize: bannerSize,
        screenFrame: dialogScreen, visibleFrame: dialogVisible, paddingAboveDock: 30
    )
    let dockSize: CGFloat = 30
    let targetY: CGFloat = (1440 - 57) / 2 - dockSize  // 661.5
    assertApprox(pos.x, -1092)
    assertApprox(pos.y, targetY - 46)
}

func testDialogSecondScreen() {
    print("  testDialogSecondScreen")
    let screen2 = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
    let screen2Vis = CGRect(x: 2560, y: 0, width: 1920, height: 1050)
    // Banner on second screen at x=4130 (near right edge of 1920-wide screen starting at 2560)
    let pos = NotificationGeometry.systemDialogPosition(
        for: .topMiddle,
        bannerPos: CGPoint(x: 4130, y: 46),
        windowPos: CGPoint(x: 0, y: 0),
        notifSize: bannerSize,
        screenFrame: screen2, visibleFrame: screen2Vis, paddingAboveDock: 30
    )
    // Target = 2560 + (1920-344)/2 = 2560 + 788 = 3348
    // bannerRel = 4130. Window = 3348 - 4130 = -782
    assertApprox(pos.x, -782)
    assertApprox(pos.y, 0)
}

// --- Runner ---

@main
enum TestRunner {
    static func main() {
        print("Running NotificationGeometry tests...")
        testInitialDataNormalPosition()
        testInitialDataOffScreenCorrection()
        testTopRight()
        testTopLeft()
        testTopMiddle()
        testBottomMiddle()
        testDeadCenter()
        testSecondScreenOffset()

        print("\nRunning AXSystemDialog offset tests...")
        testDialogTopMiddle_WindowAtOrigin()
        testDialogTopMiddle_WindowAlreadyShifted()
        testDialogTopMiddle_Idempotent()
        testDialogTopLeft()
        testDialogTopRight()
        testDialogBottomMiddle()
        testDialogDeadCenter()
        testDialogSecondScreen()

        if failCount > 0 {
            print("\n\(failCount)/\(testCount) assertions FAILED")
            exit(1)
        } else {
            print("\nAll \(testCount) assertions passed.")
        }
    }
}
