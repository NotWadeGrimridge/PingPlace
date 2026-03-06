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

        if failCount > 0 {
            print("\n\(failCount)/\(testCount) assertions FAILED")
            exit(1)
        } else {
            print("\nAll \(testCount) assertions passed.")
        }
    }
}
